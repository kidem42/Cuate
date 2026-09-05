package com.aispotlight.android.chat

import android.content.Context
import com.aispotlight.android.core.ChatRequestOptions
import com.aispotlight.android.core.DocumentPreflight
import com.aispotlight.android.core.LLMDocument
import com.aispotlight.android.core.LLMImage
import com.aispotlight.android.core.LLMMessage
import com.aispotlight.android.core.LLMStreamEvent
import com.aispotlight.android.core.ProviderException
import com.aispotlight.android.core.ProviderID
import com.aispotlight.android.core.ReasoningMode
import com.aispotlight.android.core.TokenUsage
import com.aispotlight.android.data.ChatAttachment
import com.aispotlight.android.data.ChatMessage
import com.aispotlight.android.data.ImageStore
import com.aispotlight.android.data.SpendKind
import com.aispotlight.android.data.SpendTracker
import com.aispotlight.android.providers.BraveSearchService
import com.aispotlight.android.providers.WebFetchService
import com.aispotlight.android.providers.MistralOCRService
import com.aispotlight.android.providers.OpenAIFilesService
import com.aispotlight.android.providers.ModelPricing
import com.aispotlight.android.providers.PricingCatalog
import com.aispotlight.android.providers.ProviderRegistry
import com.aispotlight.android.settings.ApiKeyStore
import com.aispotlight.android.settings.AppSettings
import com.aispotlight.android.settings.Presets
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Orchestrates a chat turn: builds the conversation history, resolves the
 * active provider/model/key, runs the agentic tool loop (web search), and
 * streams the reply. Also owns context compression (rolling summary).
 * Port of `ChatService.swift`.
 */
object ChatService {

    /** Events surfaced to the UI while a reply is being produced. */
    sealed class ChatEvent {
        data class Text(val chunk: String) : ChatEvent()
        /** Transient status for the "thinking" indicator (e.g. "Searching: …"). */
        data class Status(val text: String) : ChatEvent()
        /**
         * Emitted once at the end of a turn that used web search: a compact
         * digest of the results, stored on the reply message so follow-up
         * turns keep their grounding.
         */
        data class ToolContext(val digest: String) : ChatEvent()
        /**
         * Soft monthly budget threshold crossed (80% / 100%) — the ViewModel
         * surfaces it as a persisted system line in the chat.
         */
        data class BudgetWarning(val text: String) : ChatEvent()
        /** A persisted system line (not sent to the LLM): e.g. an upload that fell back to text. */
        data class Note(val text: String) : ChatEvent()
    }

    // Tool budget lives in Settings (1–12, AppSettings.maxToolIterations) —
    // the desktop 3.20 port replaced the old MAX_TOOL_ITERATIONS constant.

    /**
     * How many extra working rounds one reply may request with a trailing
     * `<continue/>` marker (each round gets a fresh tool budget). Bounds the
     * auto-continuation so a marker-happy model can't loop forever.
     */
    const val MAX_AUTO_CONTINUES = 3

    /**
     * Detects a trailing `<continue/>` continuation marker and returns the
     * text without it. The marker is a contract taught in
     * [Presets.mandatoryPromptRules] (the desktop 3.20 mechanic).
     */
    fun stripContinueMarker(text: String): Pair<String, Boolean> {
        val tail = text.trimEnd()
        val marker = listOf("<continue/>", "<continue />").firstOrNull { tail.endsWith(it) }
            ?: return text to false
        return tail.removeSuffix(marker).trimEnd() to true
    }

    /**
     * With the "recent images as pixels" option on, user photos within this
     * many trailing conversational messages (≈ the last 3 exchanges) are sent
     * as pixels instead of degrading to their OCR extraction — follow-up
     * questions about a photo keep actually seeing it.
     */
    private const val RECENT_PIXEL_WINDOW = 6

    // MARK: - Streaming with the agent loop

    /**
     * Streams the assistant reply.
     * @param history chat messages to send verbatim (already excludes the summarized prefix).
     * @param summary rolling summary of older turns, if any.
     * @param presetSystemPrompt system prompt override for the conversation's preset
     *        (null = the settings working copy).
     */
    fun streamReply(
        context: Context,
        history: List<ChatMessage>,
        summary: String?,
        presetSystemPrompt: String?,
        /** Write-back target for lazily computed OCR extractions (messageId, attachmentId, text). */
        onAttachmentOCR: suspend (String, String, String) -> Unit = { _, _, _ -> },
        /** Write-back for a provider-side copy (messageId, attachmentId, fileId, provider, expiresAtMillis). */
        onAttachmentRemote: suspend (String, String, String, String, Long?) -> Unit = { _, _, _, _, _ -> },
    ): Flow<ChatEvent> = flow {
        val settings = AppSettings.current
        val providerID = settings.chatProvider.value

        val apiKey = ApiKeyStore.key(providerID)
            ?: throw ProviderException.missingAPIKey(providerID)
        val model = settings.selectedModel(providerID)
            ?: throw ProviderException.http(0, "No model selected for ${providerID.displayName}. Open Settings and load the model list.")

        var systemPrompt = presetSystemPrompt ?: settings.systemPrompt.value
        // Mandatory rules ride along with every preset, invisibly.
        systemPrompt += "\n\n" + Presets.mandatoryPromptRules
        if (!summary.isNullOrEmpty()) {
            systemPrompt += "\n\n[Summary of the earlier conversation — treat as established context]\n$summary"
        }
        // Date only (no time) — keeps the prompt prefix stable within a day
        // so implicit prompt caching still works.
        val dateFormatter = SimpleDateFormat("EEEE, MMMM d, yyyy", Locale.US)
        systemPrompt += "\n\nToday's date: ${dateFormatter.format(Date())}."

        // DeepSeek (chat) and Gemini's mainstream flash models reject
        // max_tokens above 8192 — clamp there.
        val providerTokenCap =
            if (providerID == ProviderID.DEEPSEEK || providerID == ProviderID.GEMINI) 8192 else Int.MAX_VALUE
        var options = ChatRequestOptions(
            maxTokens = minOf(settings.maxTokens.value, providerTokenCap),
            reasoning = settings.reasoningMode.value,
            modelSupportsReasoning = settings.modelSupportsReasoningControl(providerID, model),
        )
        // Attach web tools only when the model can actually call tools
        // (OpenRouter hosts models that can't) — otherwise the request errors.
        // web_search needs a Brave key; web_fetch is keyless and rides along
        // whenever tools are possible at all.
        if (settings.webSearchEnabled.value &&
            settings.modelSupportsTools(providerID, model)
        ) {
            // OpenRouter's own web tools replace ours when the user left them
            // on: one key, no Brave. They run on OpenRouter's side and mix
            // with our function tools in the same request.
            val serverSearch = providerID == ProviderID.OPENROUTER && settings.openRouterWebSearch.value
            val serverFetch = providerID == ProviderID.OPENROUTER && settings.openRouterWebFetch.value
            val tools = buildList {
                if (!serverSearch && BraveSearchService.isAvailable) add(BraveSearchService.toolSpec)
                if (!serverFetch) add(WebFetchService.toolSpec)
            }
            val serverTools = buildList {
                if (serverSearch) add(com.aispotlight.android.core.ServerTool(
                    "openrouter:web_search", org.json.JSONObject().put("max_results", 5).put("max_uses", 5)
                ))
                // "openrouter" is their free fetch engine; the others bill.
                if (serverFetch) add(com.aispotlight.android.core.ServerTool(
                    "openrouter:web_fetch", org.json.JSONObject().put("engine", "openrouter").put("max_uses", 5)
                ))
            }
            options = options.copy(tools = tools, serverTools = serverTools)
            // Usage hint appended at request time — the user's editable prompt
            // stays clean; the tool's schema/description travels via the API.
            systemPrompt += if (serverSearch || BraveSearchService.isAvailable) {
                "\n\n" +
                    "You have web tools. Use web_search when the answer depends on current events, live data, or facts you are unsure about; do not guess. " +
                    "Use web_fetch to read a specific page in full — a promising search result, or a URL the user gave you; prefer fetching the actual page over relying on search snippets when details matter. " +
                    "Citation rules for externally sourced facts: put an inline markdown link immediately after each fact, in the form ([Source Name](URL)). " +
                    "Never group links into a separate \"Sources\" section at the end. " +
                    "Do not add source links for answers from your own knowledge or the conversation."
            } else {
                "\n\n" +
                    "You have a web_fetch tool: it downloads a web page and returns its readable text. " +
                    "Use it when the user gives a URL or when you know the exact page that answers the question. " +
                    "Citation rules for externally sourced facts: put an inline markdown link immediately after each fact, in the form ([Source Name](URL)). " +
                    "Never group links into a separate \"Sources\" section at the end."
            }
        }

        // Documents attached earlier in this chat: the read_document tool
        // lets the model open them on demand — only when there is something
        // to open and the model can call tools (the web tools' gate).
        val liveDocuments = DocumentToolService.liveDocuments(context, history)
        val documentTools = if (settings.modelSupportsTools(providerID, model)) {
            DocumentToolService.toolSpecs(liveDocuments)
        } else {
            emptyList()
        }
        if (documentTools.isNotEmpty()) {
            options = options.copy(tools = options.tools + documentTools)
            systemPrompt += "\n\n" + DocumentToolService.systemPromptHint()
        }
        val hasDocumentTool = documentTools.isNotEmpty()
        // OpenRouter: every turn that involves a document goes only to
        // providers that don't collect data.
        val lastUserHasDocuments = history.lastOrNull { it.isUser }?.attachments?.any { it.isDocument } ?: false
        options = options.copy(
            modelSupportsNativeDocuments = settings.modelSupportsNativeDocuments(providerID, model),
            denyDataCollection = providerID == ProviderID.OPENROUTER && (hasDocumentTool || lastUserHasDocuments),
            zdrOnly = providerID == ProviderID.OPENROUTER && settings.openRouterZDROnly.value,
        )
        val supportsVision = settings.modelSupportsVision(providerID, model)
        // Attach turn: the documents of the last user message get their
        // provider-side copy (OpenAI) before the request is built.
        val preparedHistory = uploadPendingDocuments(
            context, history, providerID, apiKey, onAttachmentRemote,
            onStatus = { emit(ChatEvent.Status(it)) },
            onNote = { emit(ChatEvent.Note(it)) },
        )
        val initialMessages = buildMessages(
            context, preparedHistory, providerID, supportsVision,
            hasDocumentTool, documentsAsText = false, onAttachmentOCR,
        ) { emit(ChatEvent.Status(it)) }
        val provider = ProviderRegistry.provider(providerID)
        com.aispotlight.android.core.Diagnostics.log(
            "chat", "turn.start provider=${providerID.id} model=$model history=${history.size} tools=${options.tools.size}"
        )

        val maxToolIterations = settings.maxToolIterations.value
        var messages = initialMessages
        var iteration = 0
        // Search results gathered this turn — handed to the UI at the end so
        // they persist on the reply message as grounding.
        var toolDigest = ""
        val citedURLs = mutableSetOf<String>()
        // Token usage summed across the agent loop's model calls; received
        // chars accumulate for the estimate fallback on interrupted streams.
        var turnUsage = TokenUsage()
        var receivedChars = 0
        // One retry when the provider rejects a document reference: the same
        // turn again with the documents as local text.
        var documentRetryDone = false
        try {
            while (true) {
                iteration += 1
                var turnText = ""
                var turnReasoning = ""
                var toolCalls = emptyList<com.aispotlight.android.core.ToolCall>()

                try {
                    provider.streamChat(messages, model, systemPrompt, options, apiKey).collect { event ->
                        when (event) {
                            is LLMStreamEvent.Text -> {
                                turnText += event.chunk
                                emit(ChatEvent.Text(event.chunk))
                            }
                            is LLMStreamEvent.ToolCalls -> toolCalls = event.calls
                            // Kept for the tool loop only (DeepSeek wants it
                            // back); never rendered.
                            is LLMStreamEvent.Reasoning -> turnReasoning += event.chunk
                            is LLMStreamEvent.Citations -> {
                                // Server-side search: the sources become the
                                // grounding digest, same as Brave.
                                for (cite in event.citations) {
                                    if (!citedURLs.add(cite.url)) continue
                                    val heading = if (cite.title.isEmpty()) cite.url else "${cite.title} — ${cite.url}"
                                    toolDigest += (if (toolDigest.isEmpty()) "" else "\n\n") + "$heading\n${cite.content.take(400)}"
                                }
                            }
                            is LLMStreamEvent.Usage -> turnUsage = turnUsage.merged(event.usage)
                        }
                    }
                } catch (e: ProviderException) {
                    val message = e.message ?: ""
                    if (!documentRetryDone && iteration == 1 &&
                        message.lowercase().contains("file") &&
                        messages.any { it.documents.isNotEmpty() }
                    ) {
                        documentRetryDone = true
                        com.aispotlight.android.core.Diagnostics.log(
                            "files", "attach turn rejected (${message.take(120)}) — retrying with local text"
                        )
                        messages = buildMessages(
                            context, preparedHistory, providerID, supportsVision,
                            hasDocumentTool, documentsAsText = true, onAttachmentOCR,
                        ) { emit(ChatEvent.Status(it)) }
                        iteration = 0
                        continue
                    }
                    throw e
                }
                receivedChars += turnText.length

                if (toolCalls.isEmpty()) break

                if (iteration > maxToolIterations) {
                    // Tool budget exhausted mid-hunt (the desktop 3.20 fix).
                    // Breaking here used to end the turn SILENTLY — a
                    // data-hungry request could burn every iteration on
                    // searches and the user got "(empty reply)". Instead:
                    // answer the pending calls with a budget notice, take the
                    // tools away, and run ONE final turn so the model must
                    // write its answer from what it already gathered.
                    com.aispotlight.android.core.Diagnostics.log(
                        "chat", "tool budget exhausted — forcing final answer"
                    )
                    messages = messages + LLMMessage(
                        role = LLMMessage.Role.ASSISTANT, text = turnText, toolCalls = toolCalls,
                        reasoningContent = turnReasoning.ifEmpty { null },
                    )
                    for (call in toolCalls) {
                        messages = messages + LLMMessage(
                            role = LLMMessage.Role.TOOL,
                            text = "Tool budget for this turn is exhausted. Do not request more tools — write the final answer now from the information already gathered.",
                            toolCallID = call.id,
                            toolName = call.name,
                        )
                    }
                    options = options.copy(tools = emptyList())
                    emit(ChatEvent.Status("Thinking…"))
                    continue
                }

            // Record the assistant turn with its calls, execute the tools,
            // and loop for the follow-up turn.
            messages = messages + LLMMessage(
                role = LLMMessage.Role.ASSISTANT, text = turnText, toolCalls = toolCalls,
                reasoningContent = turnReasoning.ifEmpty { null },
            )
            for (call in toolCalls) {
                com.aispotlight.android.core.Diagnostics.log("chat", "tool.call ${call.name}")
                val result: String
                if (call.name == BraveSearchService.toolSpec.name) {
                    val query = call.arguments.optString("query")
                    emit(ChatEvent.Status("Searching: $query"))
                    result = try {
                        val r = BraveSearchService.search(query)
                        toolDigest += (if (toolDigest.isEmpty()) "" else "\n\n") + "Search \"$query\":\n$r"
                        r
                    } catch (e: Exception) {
                        "Search failed: ${e.message}"
                    }
                } else if (call.name == WebFetchService.toolSpec.name) {
                    val urlString = call.arguments.optString("url")
                    val host = urlString.toHttpUrlOrNull()?.host ?: urlString
                    emit(ChatEvent.Status("Reading page: $host"))
                    result = try {
                        val r = WebFetchService.fetch(urlString)
                        // Digest keeps only the head of a page — fetches are
                        // big and must not evict search grounding from the 6k cap.
                        toolDigest += (if (toolDigest.isEmpty()) "" else "\n\n") + "Fetched $urlString:\n${r.take(1500)}"
                        r
                    } catch (e: Exception) {
                        "Fetch failed: ${e.message}"
                    }
                } else if (DocumentToolService.canHandle(call.name)) {
                    emit(ChatEvent.Status(DocumentToolService.statusLine(call)))
                    // Not in toolDigest: document text is big and re-fetchable.
                    result = DocumentToolService.run(context, call, liveDocuments, onAttachmentOCR)
                } else {
                    result = "Unknown tool: ${call.name}"
                }
                messages = messages + LLMMessage(
                    role = LLMMessage.Role.TOOL,
                    text = result,
                    toolCallID = call.id,
                    toolName = call.name,
                )
            }
                emit(ChatEvent.Status("Thinking…"))
            }
        } catch (e: Exception) {
            // The turn still consumed tokens (cancelled/failed streams bill
            // whatever was generated) — record what we know, then rethrow.
            recordSpend(SpendKind.CHAT, providerID, model, turnUsage, messages, receivedChars)
            throw explainRoutingError(context, e, providerID)
        }
        if (toolDigest.isNotEmpty()) {
            // Capped: one digest rides along on future requests (most recent
            // reply only — see buildMessages).
            emit(ChatEvent.ToolContext(toolDigest.take(6000)))
        }
        com.aispotlight.android.core.Diagnostics.log("chat", "turn.end iterations=$iteration")
        recordSpend(SpendKind.CHAT, providerID, model, turnUsage, messages, receivedChars)?.let {
            emit(ChatEvent.BudgetWarning(it))
        }
    }

    /**
     * OpenRouter answers a request no endpoint can serve under its routing
     * constraints (the account's privacy page, our `data_collection: deny` on
     * document turns, the ZDR toggle) with a bare 503 — say what to do.
     */
    private fun explainRoutingError(context: Context, error: Exception, providerID: ProviderID): Exception {
        if (providerID != ProviderID.OPENROUTER || error !is ProviderException) return error
        val message = error.message ?: return error
        val text = message.lowercase()
        val routing = text.contains("http 503") || text.contains("routing requirements") ||
            text.contains("data policy") || text.contains("no endpoints")
        if (!routing) return error
        return ProviderException(error.kind, context.getString(com.aispotlight.android.R.string.or_routing_hint) + "\n" + message)
    }

    // MARK: - Spend recording

    /**
     * Records one model call (or agent-loop turn) into the spend ledger — the
     * Android port of the macOS `recordSpend`. When the provider reported no
     * usage (cancelled/failed stream), falls back to the script-aware
     * character estimate and flags the record. Returns a budget warning when
     * a threshold was crossed.
     */
    private fun recordSpend(
        kind: SpendKind,
        providerID: ProviderID,
        model: String,
        usage: TokenUsage,
        sentMessages: List<LLMMessage>,
        receivedChars: Int,
    ): String? {
        var effective = usage
        var isEstimate = false
        if (effective.isEmpty) {
            if (receivedChars == 0 && sentMessages.isEmpty()) return null
            // Interrupted before the usage frame: estimate. Input from the last
            // request's messages, output from streamed characters at a blended
            // ~3 chars/token (between ASCII /4 and Cyrillic ×2/5).
            effective = TokenUsage(
                inputTokens = sentMessages.sumOf { estimatedTokens(it.text) },
                outputTokens = receivedChars / 3,
            )
            isEstimate = true
            if (effective.isEmpty) return null
        }

        // Price: the local catalog; for OpenRouter, the live per-model price
        // from its /models catalog is exact and wins. Cache-read there is
        // billed at the full input rate (conservative).
        var pricing = PricingCatalog.pricing(providerID, model)
        if (providerID == ProviderID.OPENROUTER) {
            val info = AppSettings.current.openRouterCatalog.value[model]
            val prompt = info?.promptPricePerToken
            val completion = info?.completionPricePerToken
            if (prompt != null && completion != null) {
                pricing = ModelPricing(
                    inputPerToken = prompt, outputPerToken = completion,
                    cacheReadPerToken = prompt, cacheWritePerToken = prompt,
                )
            }
        }
        var costUSD = pricing?.cost(effective)
        // OpenRouter reports the exact charge, server tools included: book
        // it, with the search share moved to its own line so the provider
        // total still equals what OpenRouter charged.
        var searchShare = 0.0
        if (providerID == ProviderID.OPENROUTER && effective.serverSearchRequests > 0) {
            searchShare = effective.serverSearchRequests * PricingCatalog.OPENROUTER_SEARCH_PER_REQUEST
            SpendTracker.record(
                kind = SpendKind.SEARCH, provider = providerID.id, model = "web_search",
                units = effective.serverSearchRequests.toDouble(), costUSD = searchShare, isEstimate = true,
            )
        }
        if (providerID == ProviderID.OPENROUTER && effective.exactCostUSD != null) {
            costUSD = (effective.exactCostUSD - searchShare).coerceAtLeast(0.0)
        }
        return SpendTracker.record(
            kind = kind, provider = providerID.id, model = model,
            usage = effective, costUSD = costUSD, isEstimate = isEstimate,
        )
    }

    // MARK: - History → provider messages

    /**
     * Converts chat history into provider messages — full port of the macOS
     * policy:
     * - Images are attached as PIXELS only for the most recent user message
     *   (bounds token cost) — or, with the opt-in "recent images as pixels"
     *   setting, for user messages within [RECENT_PIXEL_WINDOW] too.
     * - Older turns keep their content as a cached OCR extraction (computed
     *   lazily, persisted on the attachment via [onAttachmentOCR]) instead of
     *   a content-free note.
     * - When the selected model does not support vision (DeepSeek, or a
     *   text-only OpenRouter model), images are run through Mistral OCR and
     *   injected as text.
     * - Documents follow the same shape with a different fallback: the most
     *   recent user message (the attach turn) carries them in full — as an
     *   OpenAI file reference when one exists, else as locally extracted text
     *   — and every older message keeps a one-line placeholder that points the
     *   model at the read_document tool. [documentsAsText] forces the text
     *   form (the retry after a provider rejected the reference).
     */
    private suspend fun buildMessages(
        context: Context,
        history: List<ChatMessage>,
        providerID: ProviderID,
        supportsVision: Boolean,
        hasDocumentTool: Boolean,
        documentsAsText: Boolean,
        onAttachmentOCR: suspend (String, String, String) -> Unit,
        onStatus: suspend (String) -> Unit = {},
    ): List<LLMMessage> {
        val conversational = history.filter { it.messageType != ChatMessage.Type.SYSTEM && !it.isError }
        val lastUserID = conversational.lastOrNull { it.isUser }?.id
        // Messages whose photos travel as pixels: always the newest user
        // message; with the opt-in setting also user messages inside the
        // trailing window (recurring vision-token cost, bounded by the window).
        val pixelIDs = buildSet {
            lastUserID?.let { add(it) }
            if (supportsVision && AppSettings.current.recentImagesAsPixels.value) {
                conversational.takeLast(RECENT_PIXEL_WINDOW)
                    .filter { it.isUser }
                    .forEach { add(it.id) }
            }
        }
        // Search-result grounding rides on the most recent reply that has it —
        // mirrors the images-only-on-last policy, so the cost stays bounded.
        val lastToolContextID = conversational.lastOrNull { !it.isUser && !it.toolContext.isNullOrEmpty() }?.id
        // Older attachments without a cached extraction are OCR'd once (then
        // persisted); capped per turn so an image-heavy history can't stall
        // the reply behind a burst of OCR calls.
        var lazyOCRBudget = 3

        // The attach turn's inline text, across all its documents: one
        // message must never eat the context on its own.
        var inlineBudget = DocumentPreflight.INLINE_TEXT_CHARACTER_CAP_PER_MESSAGE
        var attachNative = 0
        var attachInline = 0
        var attachInlineChars = 0
        val result = mutableListOf<LLMMessage>()
        for (message in conversational) {
            var text = message.text
            var images = emptyList<LLMImage>()
            val documents = mutableListOf<LLMDocument>()
            val imageAttachments = message.attachments.filter { it.mimeType.startsWith("image") }
            val documentAttachments = message.attachments.filter { !it.mimeType.startsWith("image") }
            for (attachment in documentAttachments) {
                val label = documentLabel(attachment)
                if (message.id == lastUserID) {
                    val remote = attachment.remoteFileId
                    val file = ImageStore.file(context, attachment)
                    if (providerID == ProviderID.OPENAI && !documentsAsText && attachment.hasLiveRemoteFile && remote != null) {
                        documents.add(LLMDocument(attachment.filename, attachment.mimeType, remoteFileId = remote))
                        attachNative += 1
                    } else if (providerID == ProviderID.OPENROUTER && !documentsAsText &&
                        DocumentPreflight.isPDF(attachment.mimeType) && file.exists() &&
                        file.length() <= DocumentPreflight.MAX_INLINE_FILE_BYTES
                    ) {
                        // The PDF itself, base64, on this turn only; the engine
                        // (native / cloudflare-ai) is the provider's call.
                        val base64 = withContext(Dispatchers.IO) {
                            android.util.Base64.encodeToString(file.readBytes(), android.util.Base64.NO_WRAP)
                        }
                        documents.add(LLMDocument(attachment.filename, attachment.mimeType, inlineBase64 = base64))
                        attachNative += 1
                    } else {
                        val extracted = cachedDocumentText(context, attachment, message.id, onAttachmentOCR, onStatus)
                        if (!extracted.isNullOrEmpty()) {
                            var body = extracted
                            val cap = minOf(DocumentPreflight.INLINE_TEXT_CHARACTER_CAP, maxOf(0, inlineBudget))
                            if (body.length > cap) {
                                body = body.take(cap) + if (hasDocumentTool) {
                                    "\n[Truncated — the rest is available through read_document]"
                                } else {
                                    "\n[Truncated]"
                                }
                            }
                            inlineBudget -= body.length
                            attachInline += 1
                            attachInlineChars += body.length
                            text += "\n\n[Document: $label]\n$body"
                        } else {
                            text += "\n\n[Document attached: $label — not readable by this provider]"
                        }
                    }
                } else {
                    text += if (hasDocumentTool) {
                        "\n[Attached document: $label — open it with read_document when needed]"
                    } else {
                        "\n[Attached document: $label — re-attach it to discuss its content]"
                    }
                }
            }
                if (imageAttachments.isNotEmpty()) {
                if (message.id in pixelIDs) {
                    if (supportsVision) {
                        images = imageAttachments.mapNotNull { attachment ->
                            // Downscaled copy for the wire; originals stay
                            // untouched for OCR / image-processing tracks.
                            val base64 = ImageStore.contentBase64(context, attachment)
                            if (base64.isEmpty()) null
                            else LLMImage.forModel(attachment.mimeType, base64)
                        }
                    } else {
                        // Non-vision provider: OCR the attachments into text.
                        if (!MistralOCRService.isAvailable) {
                            throw ProviderException.visionUnsupported(providerID)
                        }
                        for (attachment in imageAttachments) {
                            val ocrText = cachedOCRText(context, attachment, message.id, onAttachmentOCR)
                            text += "\n\n[Image content extracted via OCR]:\n$ocrText"
                        }
                    }
                } else {
                    var extractedAny = false
                    for (attachment in imageAttachments) {
                        var extracted = attachment.ocrText
                        if (extracted == null && lazyOCRBudget > 0 && MistralOCRService.isAvailable) {
                            lazyOCRBudget -= 1
                            extracted = try {
                                cachedOCRText(context, attachment, message.id, onAttachmentOCR)
                            } catch (_: Exception) {
                                null
                            }
                        }
                        if (!extracted.isNullOrEmpty()) {
                            text += "\n\n[Image attached earlier in the conversation; extracted content:]\n${extracted.take(4000)}"
                            extractedAny = true
                        }
                    }
                    if (!extractedAny) {
                        text += "\n[The user attached an image earlier in the conversation.]"
                    }
                }
                }
            if (message.id == lastToolContextID && message.toolContext != null) {
                text += "\n\n[Web search results this answer was based on:]\n${message.toolContext}"
            }
            if (text.isEmpty() && images.isEmpty() && documents.isEmpty()) continue
            result.add(LLMMessage(
                role = if (message.isUser) LLMMessage.Role.USER else LLMMessage.Role.ASSISTANT,
                text = text,
                images = images,
                documents = documents,
            ))
        }
        if (attachNative + attachInline > 0) {
            com.aispotlight.android.core.Diagnostics.log(
                "files", "attach turn provider=${providerID.id} native=$attachNative inline=$attachInline inlineChars=$attachInlineChars"
            )
        }
        return result
    }

    /** "contract.pdf, 12 pages" / "notes.docx" — for placeholders. */
    private fun documentLabel(attachment: ChatAttachment): String {
        val pages = attachment.pageCount ?: return attachment.filename
        return "${attachment.filename}, $pages page${if (pages == 1) "" else "s"}"
    }

    /** Server-side expiry for uploads = the media retention window (App.sweepExpiredMedia). */
    private const val REMOTE_EXPIRY_SECONDS = 15L * 24 * 60 * 60

    /**
     * Attach turn on OpenAI: the documents of the last user message get their
     * provider-side copy here, once; a re-attach or a duplicate already
     * carries one. An upload failure degrades that document to the local text
     * path with a note — the turn itself always goes out.
     */
    private suspend fun uploadPendingDocuments(
        context: Context,
        history: List<ChatMessage>,
        providerID: ProviderID,
        apiKey: String,
        onAttachmentRemote: suspend (String, String, String, String, Long?) -> Unit,
        onStatus: suspend (String) -> Unit,
        onNote: suspend (String) -> Unit,
    ): List<ChatMessage> {
        if (providerID != ProviderID.OPENAI) return history
        val index = history.indexOfLast { it.isUser }
        if (index < 0) return history
        val message = history[index]
        if (message.attachments.none { it.isDocument && !it.hasLiveRemoteFile }) return history
        val updated = message.attachments.map { attachment ->
            if (!attachment.isDocument || attachment.hasLiveRemoteFile) return@map attachment
            val file = ImageStore.file(context, attachment)
            if (!file.exists()) return@map attachment
            onStatus("Uploading ${attachment.filename}…")
            try {
                val uploaded = OpenAIFilesService.upload(
                    file, attachment.filename, attachment.mimeType, REMOTE_EXPIRY_SECONDS, apiKey
                )
                com.aispotlight.android.core.Diagnostics.log(
                    "files", "upload id=${uploaded.id} bytes=${file.length()} pages=${attachment.pageCount ?: 0} expires=${uploaded.expiresAtMillis ?: "none"}"
                )
                onAttachmentRemote(message.id, attachment.id, uploaded.id, providerID.id, uploaded.expiresAtMillis)
                attachment.copy(
                    remoteFileId = uploaded.id, remoteProvider = providerID.id,
                    remoteExpiresAt = uploaded.expiresAtMillis,
                )
            } catch (e: Exception) {
                com.aispotlight.android.core.Diagnostics.log(
                    "files", "upload failed ${attachment.filename}: ${e.message?.take(160)}"
                )
                onNote("${attachment.filename} was sent as text — the upload failed: ${e.message}")
                attachment
            }
        }
        return history.toMutableList().also { it[index] = message.copy(attachments = updated) }
    }

    /**
     * Local extraction with per-attachment persistence (the document twin of
     * [cachedOCRText]): computed once on the phone, written back onto the
     * attachment. Null when the type isn't readable locally or nothing
     * readable was found (a scan).
     */
    private suspend fun cachedDocumentText(
        context: Context,
        attachment: ChatAttachment,
        messageId: String,
        onAttachmentOCR: suspend (String, String, String) -> Unit,
        onStatus: suspend (String) -> Unit,
    ): String? {
        attachment.ocrText?.takeIf { it.isNotEmpty() }?.let { return it }
        val file = ImageStore.file(context, attachment)
        if (!file.exists()) return null
        onStatus("Reading ${attachment.filename}…")
        val text = withContext(Dispatchers.IO) { DocumentTextService.extract(file, attachment.mimeType) }
            ?: return null
        onAttachmentOCR(messageId, attachment.id, text)
        com.aispotlight.android.core.Diagnostics.log("files", "extract ${attachment.filename} chars=${text.length}")
        return text
    }

    /**
     * OCR with per-attachment persistence: returns the cached extraction, or
     * runs OCR once and writes the result back — retries and later turns never
     * re-pay the call.
     */
    private suspend fun cachedOCRText(
        context: Context,
        attachment: ChatAttachment,
        messageId: String,
        onAttachmentOCR: suspend (String, String, String) -> Unit,
    ): String {
        attachment.ocrText?.takeIf { it.isNotEmpty() }?.let { return it }
        val base64 = ImageStore.contentBase64(context, attachment)
        if (base64.isEmpty()) return ""
        val text = MistralOCRService.extractText(base64, attachment.mimeType)
        onAttachmentOCR(messageId, attachment.id, text)
        return text
    }

    // MARK: - Context compression (rolling summary)

    /**
     * Character-based token estimate, script-aware: ASCII runs ≈ 4 chars per
     * token, but Cyrillic (and other non-Latin scripts) tokenize much denser
     * — ≈ 2.5 chars per token.
     */
    private fun estimatedTokens(text: String): Int {
        var ascii = 0
        var dense = 0
        for (ch in text) {
            if (ch.code < 128) ascii++ else dense++
        }
        return ascii / 4 + dense * 2 / 5
    }

    private fun estimatedTokens(messages: List<ChatMessage>): Int =
        messages.sumOf { message ->
            // Cached OCR extractions ride into the request as older-image
            // grounding (see buildMessages) — count them too.
            estimatedTokens(message.text) +
                message.attachments.sumOf { estimatedTokens(it.ocrText ?: "") }
        }

    /**
     * Threshold beyond which older turns are folded into the rolling summary.
     * Deliberately generous: prompt caching makes a long verbatim prefix cheap,
     * and verbatim history always beats summarized recall.
     */
    private const val COMPRESSION_TOKEN_THRESHOLD = 24_000
    /** How many recent messages always stay verbatim. */
    private const val KEEP_RECENT_COUNT = 12

    /** Result of a compression pass. */
    data class CompressionResult(val summary: String, val coversCount: Int)

    /**
     * Sliding window + rolling summary: when the verbatim history grows past
     * the threshold, older turns are summarized by the same model and replaced
     * with a compact context note. UI messages stay intact — only the API
     * context shrinks. Returns null when no compression is needed (or it failed;
     * compression is best-effort — try again next turn).
     *
     * @param activeMessages messages currently outside the summarized prefix.
     * @param totalMessageCount total messages in the conversation.
     * @param existingSummary the current rolling summary, if any.
     */
    suspend fun compressHistoryIfNeeded(
        activeMessages: List<ChatMessage>,
        totalMessageCount: Int,
        existingSummary: String?,
    ): CompressionResult? {
        val settings = AppSettings.current
        val providerID = settings.chatProvider.value
        val apiKey = ApiKeyStore.key(providerID) ?: return null
        val model = settings.selectedModel(providerID) ?: return null

        if (activeMessages.size <= KEEP_RECENT_COUNT + 4) return null
        if (estimatedTokens(activeMessages) <= COMPRESSION_TOKEN_THRESHOLD) return null

        val toSummarize = activeMessages.dropLast(KEEP_RECENT_COUNT)
            .filter { it.messageType != ChatMessage.Type.SYSTEM }
        if (toSummarize.isEmpty()) return null
        val newCoversCount = totalMessageCount - KEEP_RECENT_COUNT

        var transcript = ""
        if (existingSummary != null) {
            transcript += "Previous summary:\n$existingSummary\n\n"
        }
        transcript += toSummarize.joinToString("\n") { message ->
            "${if (message.isUser) "User" else "Assistant"}: ${message.text}"
        }

        // Merge-style prompt: each compression folds new turns INTO the
        // previous summary instead of re-summarizing a summary.
        val prompt = """
Maintain the running context notes for an ongoing conversation. Merge the previous summary (if present) with the new turns below into ONE updated set of notes.

Rules:
- Group the notes under these headings: Facts; Decisions; User preferences; Open tasks.
- Carry forward every item from the previous summary that has not been explicitly superseded - merging must never lose established facts, names, numbers or preferences.
- Add new items from the transcript; compress wording, not content.
- Under 600 words. Terse notes, not prose. Write content in the conversation's language.

$transcript
""".trim()

        val provider = ProviderRegistry.provider(providerID)
        val summary = StringBuilder()
        var usage = TokenUsage()
        val summarizeMessages = listOf(LLMMessage(role = LLMMessage.Role.USER, text = prompt))
        try {
            provider.streamChat(
                messages = summarizeMessages,
                model = model,
                systemPrompt = null,
                options = ChatRequestOptions(maxTokens = 2048, reasoning = ReasoningMode.FAST),
                apiKey = apiKey,
            ).collect { event ->
                if (event is LLMStreamEvent.Text) summary.append(event.chunk)
                if (event is LLMStreamEvent.Usage) usage = usage.merged(event.usage)
            }
        } catch (_: Exception) {
            return null // compression is best-effort; try again next turn
        }
        // Summarization is a real paid call — account for it (budget warnings
        // are surfaced by the visible chat turn, not here).
        recordSpend(SpendKind.SUMMARY, providerID, model, usage, summarizeMessages, summary.length)

        val trimmed = summary.toString().trim()
        if (trimmed.isEmpty()) return null
        return CompressionResult(summary = trimmed, coversCount = newCoversCount)
    }
}
