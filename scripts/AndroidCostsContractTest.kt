import android.content.Context
import com.aispotlight.android.core.*
import com.aispotlight.android.chat.*
import com.aispotlight.android.providers.*
import com.aispotlight.android.data.*
import com.aispotlight.android.settings.AppSettings
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.toList
import org.json.JSONObject
import org.json.JSONArray

private var checks = 0
private fun verify(ok: Boolean, label: String) { check(ok) { label }; checks++ }
private fun responses(text: String = "answer", terminal: String = "completed", usage: String? = """{"input_tokens":100,"output_tokens":20,"input_tokens_details":{"cached_tokens":40,"cache_write_tokens":10}}"""): List<String> = buildList {
 add(JSONObject().put("type","response.output_text.delta").put("delta",text).toString())
 if (terminal != "EOF") add(JSONObject().put("type","response.$terminal").put("response",JSONObject().apply { usage?.let { put("usage",JSONObject(it)) } }).toString())
}
private fun chatFrames(usage: String? = """{"prompt_tokens":100,"completion_tokens":20}""", finish: String = "stop") = buildList {
 add("""{"choices":[{"delta":{"content":"answer"},"finish_reason":"$finish"}]}""")
 usage?.let { add("""{"choices":[],"usage":$it}""") }
}
private fun toolResponse(): List<String> = listOf("""{"type":"response.output_item.done","item":{"type":"function_call","call_id":"call-1","name":"web_search","arguments":"{\"query\":\"facts\"}"}}""") + responses("")
private suspend fun call(id: ProviderID = ProviderID.OPENAI, model: String = "gpt-5.6", options: ChatRequestOptions = ChatRequestOptions(), instruction: String? = "Reusable instructions") =
 ProviderRegistry.provider(id).streamChat(listOf(LLMMessage(LLMMessage.Role.USER,"unique payload")),model,instruction,options,"fixture").toList()
private fun notes(fact: String) = JSONObject().put("facts",JSONArray().put(fact)).put("decisions",JSONArray()).put("preferences",JSONArray()).put("openTasks",JSONArray()).toString()

fun main() = runBlocking {
 SpendTracker.init(Context())
 val ledger = AppDatabase.ledger
 val settings = AppSettings.current
 verify(PromptCache.supportsExplicit("gpt-5.6-2026"),"dated cache family")
 verify(PromptCache.supportsExplicit("gpt-6"),"GPT6 cache family")
 verify(!PromptCache.supportsExplicit("gpt-5.60"),"family boundary")
 verify(!PromptCache.supportsExplicit("gpt-60"),"GPT6 boundary")
 val history = listOf(ChatMessage(text="a".repeat(32000),isUser=true), ChatMessage(text="reply",isUser=false), ChatMessage(text="new",isUser=true))
 verify(ContextCompressionPolicy.split(history,null,7000)==2,"compress small message count")
 verify(ContextCompressionPolicy.split(history.take(1),null,7000)==null,"retain newest huge user turn")
 val small = listOf(ChatMessage(text="old",isUser=true),ChatMessage(text="a".repeat(20000),isUser=true))
 verify(ContextCompressionPolicy.split(small,"x".repeat(10000),7000)==1,"count existing summary")
 verify(ContextCompressionPolicy.validatedSummary("{}")==null,"missing sections")
 verify(ContextCompressionPolicy.validatedSummary(notes("a"))=="Facts:\n- a","valid notes")
 for (raw in listOf(notes(""),notes("a")+"junk","```json\n${notes("a")}\n```",notes("a").replace("[\"a\"]","[17]"),notes("a").replace("\"facts\"","\"alien\""))) {
  verify(ContextCompressionPolicy.validatedSummary(raw)==null,"reject malformed note")
 }
 val grounding = ChatMessage(text="old",isUser=true,toolContext="tool proof",attachments=listOf(ChatAttachment(filename="image.png",mimeType="image/png",filePath="x",ocrText="full OCR")))
 verify(ContextCompressionPolicy.transcript(grounding).contains("full OCR") && ContextCompressionPolicy.transcript(grounding).contains("tool proof"),"summary grounding")
 verify(TokenUsage(exactCostUSD=0.3).merged(TokenUsage()).exactCostUSD==null,"unknown charge stays unknown")

 // Actual serializers and parsers behind a fake network seam; no HTTP calls.
 HttpClient.frames.add(responses())
 call(options=ChatRequestOptions(operationID="answer-1",requestContext="transient date"))
 val first = ledger.records.last()
 verify(first.inputTokens==50 && first.cacheReadTokens==40 && first.cacheWriteTokens==10 && first.outputTokens==20,"OpenAI partition")
 verify(first.usageState=="complete" && first.completionState=="completed" && first.operationID=="answer-1","receipt metadata")
 verify(kotlin.math.abs(first.costUSD!!-0.1065)<0.000001,"cache pricing without double count")
 val chatBody = HttpClient.bodies.last()
 verify(!chatBody.has("prompt_cache_options") && chatBody.getJSONArray("input").getJSONObject(1).getString("role")=="developer","chat implicit cache with trailing context")
 HttpClient.frames.add(responses(notes("fact")))
 call(options=ChatRequestOptions(spendKind=SpendKind.SUMMARY))
 val summaryBody = HttpClient.bodies.last()
 verify(summaryBody.getJSONObject("prompt_cache_options").getString("mode")=="explicit","summary explicit cache")
 verify(!summaryBody.has("instructions") && summaryBody.getJSONArray("input").getJSONObject(0).getJSONArray("content").getJSONObject(0).has("prompt_cache_breakpoint"),"cache reusable instruction only")
 verify(!summaryBody.getJSONArray("input").getJSONObject(1).toString().contains("prompt_cache_breakpoint"),"unique summary payload uncached")
 HttpClient.frames.add(responses()); call(model="gpt-5.5",options=ChatRequestOptions(cacheKey="stable"))
 verify(HttpClient.bodies.last().getString("prompt_cache_key")=="stable" && !HttpClient.bodies.last().has("prompt_cache_retention"),"legacy cache routing")
 HttpClient.frames.add(responses()); call(options=ChatRequestOptions(spendKind=SpendKind.SUMMARY),instruction=null)
 verify(HttpClient.bodies.last().getJSONArray("input").length()==1,"no empty instruction breakpoint")
 HttpClient.frames.add(responses(terminal="EOF",usage=null)); call()
 verify(ledger.records.last().usageState=="missing" && ledger.records.last().costUSD==null && ledger.records.last().completionState=="incomplete","EOF missing is not an estimate")
 for (terminal in listOf("failed","incomplete")) {
  HttpClient.frames.add(responses(terminal=terminal))
  verify(runCatching { call() }.isFailure,"terminal failure throws")
  verify(ledger.records.last().inputTokens==50,"failed response usage retained")
 }
 for (id in listOf(ProviderID.MISTRAL,ProviderID.DEEPSEEK,ProviderID.KIMI,ProviderID.OPENROUTER)) {
  val usage = when(id) {
   ProviderID.DEEPSEEK -> """{"prompt_tokens":100,"completion_tokens":20,"prompt_cache_hit_tokens":70,"prompt_cache_miss_tokens":30}"""
   ProviderID.KIMI -> """{"prompt_tokens":100,"completion_tokens":20,"cached_tokens":70}"""
   ProviderID.OPENROUTER -> """{"prompt_tokens":100,"completion_tokens":20,"cost":0.5,"server_tool_use":{"web_search_requests":2}}"""
   else -> """{"prompt_tokens":100,"completion_tokens":20}"""
  }
  val count = ledger.records.size
  HttpClient.frames.add(chatFrames(usage)); call(id,if(id==ProviderID.OPENROUTER) "anthropic/claude" else "model",ChatRequestOptions(cacheKey="stable"))
  verify(ledger.records.size==count+1,"one receipt for $id")
  verify(ledger.records.last().usageState=="complete","complete usage $id")
  if (id==ProviderID.DEEPSEEK || id==ProviderID.KIMI) verify(ledger.records.last().inputTokens==30 && ledger.records.last().cacheReadTokens==70,"cache split $id")
  if (id==ProviderID.OPENROUTER) {
   verify(ledger.records.last().costUSD==0.5,"OpenRouter exact tools charge once")
   val body=HttpClient.bodies.last()
   verify(!body.has("cache_control") && body.getJSONArray("messages").getJSONObject(0).getJSONArray("content").getJSONObject(0).has("cache_control"),"OpenRouter block breakpoints")
  }
  if (id==ProviderID.MISTRAL) verify(HttpClient.bodies.last().getString("prompt_cache_key")=="stable","Mistral stable cache key")
 }
 HttpClient.frames.add(chatFrames())
 call(ProviderID.OPENROUTER,"model",ChatRequestOptions(serverTools=listOf(ServerTool("openrouter:web_search",JSONObject()))))
 verify(ledger.records.last().costUSD==null,"server tool charge not guessed")
 HttpClient.frames.add(listOf("""{"candidates":[{"content":{"parts":[{"text":"a"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":100,"cachedContentTokenCount":30,"candidatesTokenCount":20,"thoughtsTokenCount":5}}"""))
 val gemini=call(ProviderID.GEMINI,"gemini")
 verify(gemini.any { it is LLMStreamEvent.Usage } && ledger.records.last().outputTokens==25 && ledger.records.last().inputTokens==70,"Gemini usage emitted and reasoning counted once")
 val anthropicStart="""{"type":"message_start","message":{"usage":{"input_tokens":20,"cache_creation_input_tokens":40,"cache_read_input_tokens":60}}}"""
 HttpClient.frames.add(listOf(anthropicStart,"""{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":8}}""","""{"type":"message_stop"}"""))
 call(ProviderID.ANTHROPIC,"claude")
 verify(ledger.records.last().outputTokens==8 && ledger.records.last().cacheWriteTokens==40 && ledger.records.last().usageState=="complete","Anthropic cumulative receipt")
 HttpClient.frames.add(listOf(anthropicStart)); HttpClient.fail=CancellationException("cancel")
 verify(runCatching { call(ProviderID.ANTHROPIC,"claude") }.isFailure,"cancel propagates")
 HttpClient.fail=null
 verify(ledger.records.last().usageState=="partial" && ledger.records.last().inputTokens==20 && ledger.records.last().completionState=="cancelled","cancel keeps partial usage")

 val captured=PricingCatalog.price
 HttpClient.beforeRequest={ PricingCatalog.price=ModelPricing(99.0,99.0) }
 HttpClient.frames.add(responses()); call()
 verify(kotlin.math.abs(ledger.records.last().costUSD!!-0.1065)<0.000001,"price snapshot at request start")
 HttpClient.beforeRequest=null; PricingCatalog.price=captured
 val oldCount=ledger.records.size; val oldAttempts=ledger.attempts
 ledger.failCount=2
 SpendTracker.recordAwait(SpendKind.OCR,"mistral","ocr",costUSD=0.01)
 verify(ledger.records.size==oldCount+1 && ledger.attempts==oldAttempts+3,"durable retry exactly once")
 val oldTotal=SpendTracker.sessionUSD.value
 ledger.failCount=3
 SpendTracker.recordAwait(SpendKind.OCR,"mistral","ocr",costUSD=123.0)
 verify(SpendTracker.failedWrites.value==1 && SpendTracker.sessionUSD.value==oldTotal,"failed write visible, totals unchanged")

 // Actual ChatService: one budget, frozen provider/model, and complete tool context across continuations.
 settings.webSearchEnabled.value=true
 val turn=ChatService.TurnState()
 val startReceipts=ledger.records.size
 HttpClient.frames.add(toolResponse()); HttpClient.frames.add(responses("working <continue/>"))
 ChatService.streamReply(Context(),history.takeLast(1),null,null,turn).toList()
 verify(BraveSearchService.calls==1 && turn.remainingToolRounds==0,"one tool round consumed")
 verify(!HttpClient.bodies.last().has("tools"),"tools removed at budget exhaustion")
 settings.chatProvider.value=ProviderID.KIMI; settings.model="other"
 HttpClient.frames.add(responses("done"))
 ChatService.streamReply(Context(),history.takeLast(1),null,null,turn).toList()
 val continued=HttpClient.bodies.last()
 verify(continued.getString("model")=="gpt-5.6" && continued.toString().contains("function_call_output") && continued.toString().contains("grounding"),"frozen turn and retained tool result")
 verify(!continued.has("tools") && ledger.records.drop(startReceipts).map { it.operationID }.distinct()==listOf(turn.operationID),"shared budget and receipt grouping")
 HttpClient.frames.add(toolResponse()); HttpClient.frames.add(toolResponse())
 verify(runCatching { ChatService.streamReply(Context(),history.takeLast(1),null,null,turn).toList() }.isFailure,"unoffered tool retry bounded")
 verify(BraveSearchService.calls==1,"unoffered calls never executed")
 settings.chatProvider.value=ProviderID.OPENAI; settings.model="gpt-5.6"; settings.webSearchEnabled.value=false

 // Three actual summary calls fold notes forward without repeating covered raw messages.
 var current=history
 var previous: String?=null
 var total=history.size
 repeat(3) { round ->
  HttpClient.frames.add(responses(notes("fact-$round")))
  val compressed=ChatService.compressHistoryIfNeeded(current,total,previous)!!
  val body=HttpClient.bodies.last().getJSONArray("input").toString()
  verify(previous==null || body.contains("fact-${round-1}"),"rolling summary keeps previous notes")
  verify(compressed.coversCount==total-1,"whole newest turn retained")
  verify(ledger.records.last().kind=="summary","summary accounted separately")
  previous=compressed.summary
  current=listOf(current.last().copy(text="old-$round "+"x".repeat(32000)),ChatMessage(text="new-$round",isUser=true))
  total++
 }
 for (bad in listOf("prose",notes("x".repeat(10000)),notes(""))) {
  HttpClient.frames.add(responses(bad))
  verify(ChatService.compressHistoryIfNeeded(history,history.size,null)==null,"reject unusable summary")
 }
 HttpClient.frames.add(responses(notes("valid"),terminal="EOF"))
 verify(ChatService.compressHistoryIfNeeded(history,history.size,null)==null,"reject incomplete summary")
 HttpClient.frames.add(responses(notes("valid"))); HttpClient.fail=CancellationException("cancel")
 verify(runCatching { ChatService.compressHistoryIfNeeded(history,history.size,null) }.exceptionOrNull() is CancellationException,"summary cancellation propagates")
 HttpClient.fail=null

 // Request vs answer denominators, unknown usage, and immutable legacy rows.
 val receipt = ledger.records.first().copy(kind="chat", operationID="one", usageState="complete", inputTokens=100, cacheReadTokens=0,cacheWriteTokens=0,outputTokens=10)
 val grouped = listOf(receipt,receipt.copy(id="second"),receipt.copy(id="third",operationID="two",inputTokens=400))
 verify(SpendAnalytics.perAnswer(grouped)?.input==300 && SpendAnalytics.perAnswer(grouped)?.count==2,"per answer grouping")
 verify(SpendAnalytics.perRequest(grouped)?.input==200 && SpendAnalytics.perRequest(grouped)?.count==3,"per request grouping")
 verify(SpendAnalytics.perAnswer(grouped+receipt.copy(id="missing",usageState="missing"))?.count==1,"exclude entire partial answer")
 verify(SpendAnalytics.perRequest(listOf(receipt.copy(usageState=null)))==null,"legacy aggregate not a request")

 val pins=PinNavigationPolicy.ordered(listOf(ChatMessage(id="old",text="",isUser=true,timestamp=10),ChatMessage(id="new",text="",isUser=true,timestamp=30)))
 verify(pins.first().id=="new" && PinNavigationPolicy.nearest(pins,11)=="old","nearest pin in chronological order")
 verify(PinNavigationPolicy.target(pins,0,false)=="new" && PinNavigationPolicy.target(pins,0,true)=="old" && PinNavigationPolicy.target(pins,1,true)=="new","pin jump then older with wrap")

 // Actual coordinator extracted without rewriting its algorithm. Transactional fake replaces Room I/O.
 val coordinator=CompressionCoordinator()
 val dao=coordinator.dao
 fun seed() {
  dao.conversations["A"]=Conversation(id="A",title="A",presetName="isolated")
  dao.conversations["B"]=Conversation(id="B",title="B",presetName="other",summary="B notes")
  dao.messages["A"]=history
  coordinator.activeConversation=dao.conversations["A"]
  coordinator._activeConversationId.value="A"
 }
 seed(); HttpClient.frames.add(responses(notes("safe")))
 HttpClient.beforeRequest={
  coordinator._activeConversationId.value="B"
  coordinator.activeConversation=dao.conversations["B"]
 }
 coordinator.runCompression("A")
 verify(dao.conversations["A"]!!.summary=="Facts:\n- safe" && coordinator.activeConversation?.summary=="B notes","isolated chat result cannot overwrite active chat")
 HttpClient.beforeRequest=null
 for (mutation in listOf("clear","edit","attachment","summary","delete","append")) {
  seed(); HttpClient.frames.add(responses(notes("safe")))
  HttpClient.beforeRequest={
   when(mutation) {
    "clear" -> dao.messages["A"]=listOf(ChatMessage(text="new",isUser=true))
    "edit" -> dao.messages["A"]=history.toMutableList().also { it[0]=it[0].copy(text="edited") }
    "attachment" -> dao.messages["A"]=history.toMutableList().also { it[0]=it[0].copy(attachments=grounding.attachments) }
    "summary" -> dao.conversations["A"]=dao.conversations["A"]!!.copy(summary="newer")
    "delete" -> dao.conversations.remove("A")
    "append" -> dao.messages["A"]=history+ChatMessage(text="append",isUser=true)
   }
  }
  coordinator.runCompression("A")
  verify((dao.conversations["A"]?.summary=="Facts:\n- safe") == (mutation=="append"),"snapshot guard $mutation")
 }
 HttpClient.beforeRequest=null
 seed(); HttpClient.frames.add(responses(notes("single")))
 val started=CompletableDeferred<Unit>(); val release=CompletableDeferred<Unit>()
 HttpClient.beforeFrames={ started.complete(Unit); release.await() }
 val running=launch { coordinator.runCompression("A") }
 started.await()
 val before=HttpClient.bodies.size
 coordinator.runCompression("A")
 verify(HttpClient.bodies.size==before,"per-conversation single flight")
 release.complete(Unit); running.join(); HttpClient.beforeFrames=null
 verify(dao.conversations["A"]!!.summary=="Facts:\n- single","single flight completes")
 val pinLoader=PinLoader()
 val many=(0 until 6000).map { ChatMessage(id="pin-$it",text="row",isUser=true,timestamp=1) }
 dao.messages["A"]=many
 pinLoader._messages.value=many.takeLast(120); pinLoader.totalMessageCount=many.size
 verify(pinLoader.locatePin("pin-0")==0 && pinLoader._messages.value.size==6000,"pin beyond forty pages with identical timestamps")
 verify(pinLoader.locatePin("gone")==-1,"deleted pin does not loop")
 pinLoader._messages.value=many.takeLast(120)
 dao.onPage={ pinLoader._activeConversationId.value="B" }
 verify(pinLoader.locatePin("pin-0")==-1 && pinLoader._messages.value.size==120,"switch cancels pin materialization")
 dao.onPage=null
 val prefs=android.content.SharedPreferences()
 val compressionSettings=com.aispotlight.android.settings.CompressionSettingsHarness(prefs)
 verify(compressionSettings.compressionThreshold.value==7000,"default threshold for existing/no-saved-preference install")
 compressionSettings.setCompressionThreshold(5000)
 verify(com.aispotlight.android.settings.CompressionSettingsHarness(prefs).compressionThreshold.value==5000,"threshold persists")
 compressionSettings.setCompressionThreshold(0)
 verify(compressionSettings.compressionThreshold.value==1000,"lower bound")
 compressionSettings.setCompressionThreshold(Int.MAX_VALUE)
 verify(compressionSettings.compressionThreshold.value==200000,"upper bound")
 println("Android provider/compression/accounting contracts: $checks passed")
}
