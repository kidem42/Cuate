package com.aispotlight.android.chat

import android.content.Context
import com.aispotlight.android.core.ChatRequestOptions
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
import com.aispotlight.android.providers.ModelPricing
import com.aispotlight.android.providers.PricingCatalog
import com.aispotlight.android.providers.ProviderRegistry
import com.aispotlight.android.settings.ApiKeyStore
import com.aispotlight.android.settings.AppSettings
import com.aispotlight.android.settings.Presets
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
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
            val tools = buildList {
                if (BraveSearchService.isAvailable) add(BraveSearchService.toolSpec)
                add(WebFetchService.toolSpec)
            }
            options = options.copy(tools = tools)
            // Usage hint appended at request time — the user's editable prompt
            // stays clean; the tool's schema/description travels via the API.
            systemPrompt += if (BraveSearchService.isAvailable) {
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

        val supportsVision = settings.modelSupportsVision(providerID, model)
        val initialMessages = buildMessages(context, history, providerID, supportsVision, onAttachmentOCR)
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
        // Token usage summed across the agent loop's model calls; received
        // chars accumulate for the estimate fallback on interrupted streams.
        var turnUsage = TokenUsage()
        var receivedChars = 0
        try {
            while (true) {
                iteration += 1
                var turnText = ""
                var toolCalls = emptyList<com.aispotlight.android.core.ToolCall>()

                provider.streamChat(messages, model, systemPrompt, options, apiKey).collect { event ->
                    when (event) {
                        is LLMStreamEvent.Text -> {
                            turnText += event.chunk
                            emit(ChatEvent.Text(event.chunk))
                        }
                        is LLMStreamEvent.ToolCalls -> toolCalls = event.calls
                        is LLMStreamEvent.Usage -> turnUsage = turnUsage.merged(event.usage)
                    }
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
                        role = LLMMessage.Role.ASSISTANT, text = turnText, toolCalls = toolCalls
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
                role = LLMMessage.Role.ASSISTANT, text = turnText, toolCalls = toolCalls
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
            throw e
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
        return SpendTracker.record(
            kind = kind, provider = providerID.id, model = model,
            usage = effective, costUSD = pricing?.cost(effective), isEstimate = isEstimate,
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
     */
    private suspend fun buildMessages(
        context: Context,
        history: List<ChatMessage>,
        providerID: ProviderID,
        supportsVision: Boolean,
        onAttachmentOCR: suspend (String, String, String) -> Unit,
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

        val result = mutableListOf<LLMMessage>()
        for (message in conversational) {
            var text = message.text
            var images = emptyList<LLMImage>()

            if (message.attachments.isNotEmpty()) {
                if (message.id in pixelIDs) {
                    if (supportsVision) {
                        images = message.attachments.mapNotNull { attachment ->
                            val base64 = ImageStore.contentBase64(context, attachment)
                            if (base64.isEmpty()) null else LLMImage(attachment.mimeType, base64)
                        }
                    } else {
                        // Non-vision provider: OCR the attachments into text.
                        if (!MistralOCRService.isAvailable) {
                            throw ProviderException.visionUnsupported(providerID)
                        }
                        for (attachment in message.attachments) {
                            if (!attachment.mimeType.startsWith("image")) continue
                            val ocrText = cachedOCRText(context, attachment, message.id, onAttachmentOCR)
                            text += "\n\n[Image content extracted via OCR]:\n$ocrText"
                        }
                    }
                } else {
                    var extractedAny = false
                    for (attachment in message.attachments) {
                        if (!attachment.mimeType.startsWith("image")) continue
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

            if (text.isEmpty() && images.isEmpty()) continue
            result.add(LLMMessage(
                role = if (message.isUser) LLMMessage.Role.USER else LLMMessage.Role.ASSISTANT,
                text = text,
                images = images,
            ))
        }
        return result
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
