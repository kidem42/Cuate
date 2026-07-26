import Foundation

/// Orchestrates a chat turn: builds the conversation history, resolves the
/// active provider/model/key, runs the agentic tool loop (web search), and
/// streams the reply. Also owns context compression (rolling summary).
enum ChatService {

    /// Events surfaced to the UI while a reply is being produced.
    enum ChatEvent {
        case text(String)
        /// Transient status for the "thinking" indicator (e.g. "Searching: …").
        case status(String)
        /// Emitted once at the end of a turn that used web search: a compact
        /// digest of the results, to be stored on the reply message so
        /// follow-up turns keep their grounding (see ChatMessage.toolContext).
        case toolContext(String)
        /// Agent turns (AgentGateway): the authoritative full reply text.
        /// Replaces everything streamed so far — Hermes deltas and the final
        /// `assistant.completed` text differ in whitespace, and a turn with
        /// the agent's streaming off delivers ONLY this event.
        case replaceText(String)
        /// Agent turns: the persisted tool-step summary for the reply
        /// (`ChatMessage.agentSteps`), emitted once at the end.
        case agentSteps(String)
        /// Agent turns: the gateway asked the human for permission mid-run.
        /// The window renders the inline card; `resolve` answers the gateway
        /// (and clears the matching banner). Dormant on Hermes 0.19.0 —
        /// wired for gateways that emit approval frames.
        case agentApproval(AgentApproval, resolve: @MainActor (AgentApprovalDecision) -> Void)
    }


    // MARK: - Streaming with the agent loop

    /// Streams the assistant reply for the current conversation.
    /// - Parameters:
    ///   - history: chat messages to send verbatim (already excludes the summarized prefix).
    ///   - summary: rolling summary of older turns, if any.
    ///   - store: write-back target for lazily computed OCR extractions.
    @MainActor
    static func streamReply(history: [ChatMessage], summary: String?, store: ChatStore) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        let settings = AppSettings.shared
        let providerID = settings.chatProvider

        // Keys come from an in-memory cache filled off the main thread; this
        // only awaits when a turn beats the launch warm to it. Never reads the
        // Keychain on the main actor — that used to freeze the panel per send.
        await APIKeyStore.warmIfNeeded()
        let apiKey = try settings.resolvedAPIKey(for: providerID)
        guard let model = settings.selectedModel(for: providerID) else {
            throw ProviderError.http(status: 0, message: "No model selected for \(providerID.displayName). Open Settings and load the model list.")
        }

        var systemPrompt = settings.systemPrompt
        // Mandatory rules ride along with every preset, invisibly.
        systemPrompt += "\n\n" + AppSettings.mandatoryPromptRules
        if let summary, !summary.isEmpty {
            systemPrompt += "\n\n[Summary of the earlier conversation — treat as established context]\n\(summary)"
        }
        // Date only (no time) — keeps the prompt prefix stable within a day
        // so implicit prompt caching still works.
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .full
        dateFormatter.locale = Locale(identifier: "en_US")
        systemPrompt += "\n\nToday's date: \(dateFormatter.string(from: Date()))."

        // DeepSeek (chat) and Gemini's mainstream flash models reject
        // max_tokens above 8192 — clamp there so the raised default for
        // artifact-sized replies doesn't break those providers.
        let providerTokenCap = (providerID == .deepseek || providerID == .gemini) ? 8192 : Int.max
        // Local models get their own cap (0 = unlimited, the request omits
        // max_tokens) — local tokens are free, so the cloud budget shouldn't
        // truncate them; thinking models were losing whole replies to it.
        var options = ChatRequestOptions(
            maxTokens: providerID == .ollama
                ? settings.localMaxTokens
                : min(settings.maxTokens, providerTokenCap),
            reasoning: settings.reasoningMode
        )
        options.modelSupportsReasoning = settings.modelSupportsReasoningControl(provider: providerID, model: model)
        // Attach web tools only when the model can actually call tools
        // (OpenRouter hosts models that can't) — otherwise the request errors.
        // web_search needs a Brave key; web_fetch is keyless and rides along
        // whenever tools are possible at all.
        if settings.webSearchEnabled,
           settings.modelSupportsTools(provider: providerID, model: model) {
            var tools: [ToolSpec] = []
            if BraveSearchService.isAvailable { tools.append(BraveSearchService.toolSpec) }
            tools.append(WebFetchService.toolSpec)
            options.tools = tools
            // Usage hint appended at request time — the user's editable prompt
            // stays clean; the tool's schema/description travels via the API.
            if BraveSearchService.isAvailable {
                systemPrompt += """


You have web tools. Use web_search when the answer depends on current events, live data, or facts you are unsure about; do not guess. Use web_fetch to read a specific page in full — a promising search result, or a URL the user gave you; prefer fetching the actual page over relying on search snippets when details matter. Citation rules for externally sourced facts: put an inline markdown link immediately after each fact, in the form ([Source Name](URL)). Never group links into a separate "Sources" section at the end. Do not add source links for answers from your own knowledge or the conversation.
"""
            } else {
                systemPrompt += """


You have a web_fetch tool: it downloads a web page and returns its readable text. Use it when the user gives a URL or when you know the exact page that answers the question. Citation rules for externally sourced facts: put an inline markdown link immediately after each fact, in the form ([Source Name](URL)). Never group links into a separate "Sources" section at the end.
"""
            }
        }

        // Calendar addon tools ride the same tool-capability gate. Both the
        // specs AND the prompt hint live inside this one condition: addon off,
        // access missing, or a tool-less model → zero tools, zero prompt bytes.
        if CalendarAddon.shared.isAvailable,
           settings.modelSupportsTools(provider: providerID, model: model) {
            let calendarTools = CalendarToolService.toolSpecs()
            if !calendarTools.isEmpty {
                options.tools += calendarTools
                systemPrompt += "\n\n" + CalendarToolService.systemPromptHint()
            }
        }

        // Snapshotted per turn: a mid-stream Settings change applies to the
        // NEXT reply, not the one already running its agent loop.
        let maxToolIterations = max(1, settings.maxToolIterations)

        let supportsVision = settings.modelSupportsVision(provider: providerID, model: model)
        let initialMessages = try await buildMessages(
            from: history,
            providerID: providerID,
            supportsVision: supportsVision,
            store: store
        )
        let provider = ProviderRegistry.provider(for: providerID)
        Diagnostics.log("chat", "turn.start provider=\(providerID.rawValue) model=\(model) history=\(history.count) tools=\(options.tools.count)")

        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                var messages = initialMessages
                var iteration = 0
                var chunkCount = 0
                var totalChars = 0
                // Search results gathered this turn — handed to the UI at the
                // end so they persist on the reply message as grounding.
                var toolDigest = ""
                // Token usage summed across the agent loop's model calls; text
                // accumulated for the estimate fallback on interrupted streams.
                var turnUsage = TokenUsage()
                var receivedChars = 0
                do {
                    while true {
                        iteration += 1
                        var turnText = ""
                        var toolCalls: [ToolCall] = []

                        let stream = provider.streamChat(
                            messages: messages,
                            model: model,
                            systemPrompt: systemPrompt,
                            options: options,
                            apiKey: apiKey
                        )
                        for try await event in stream {
                            switch event {
                            case .text(let chunk):
                                turnText += chunk
                                chunkCount += 1
                                totalChars += chunk.count
                                continuation.yield(.text(chunk))
                            case .toolCalls(let calls):
                                toolCalls = calls
                            case .usage(let usage):
                                turnUsage = turnUsage.merged(with: usage)
                            }
                        }
                        receivedChars += turnText.count

                        guard !toolCalls.isEmpty else { break }

                        if iteration > maxToolIterations {
                            // Tool budget exhausted mid-hunt. Breaking here
                            // used to end the turn SILENTLY — a data-hungry
                            // request (charts, tables of stats) could burn
                            // every iteration on searches and the user got
                            // "(empty reply)". Instead: answer the pending
                            // calls with a budget notice, take the tools
                            // away, and run ONE final turn so the model must
                            // write its answer from what it already gathered.
                            Diagnostics.log("chat", "tool budget exhausted — forcing final answer")
                            messages.append(LLMMessage(role: .assistant, text: turnText, toolCalls: toolCalls))
                            for call in toolCalls {
                                messages.append(LLMMessage(
                                    role: .tool,
                                    text: "Tool budget for this turn is exhausted. Do not request more tools — write the final answer now from the information already gathered.",
                                    toolCallID: call.id,
                                    toolName: call.name
                                ))
                            }
                            options.tools = []
                            continuation.yield(.status(L("panel.thinking")))
                            continue
                        }

                        // Record the assistant turn with its calls, execute the
                        // tools, and loop for the follow-up turn.
                        messages.append(LLMMessage(role: .assistant, text: turnText, toolCalls: toolCalls))
                        for call in toolCalls {
                            Diagnostics.log("chat", "tool.call \(call.name)")
                            let result: String
                            if call.name == BraveSearchService.toolSpec.name {
                                let query = call.arguments["query"] as? String ?? ""
                                continuation.yield(.status("\(L("panel.searching")): \(query)"))
                                do {
                                    result = try await BraveSearchService.search(query: query)
                                    toolDigest += (toolDigest.isEmpty ? "" : "\n\n")
                                        + "Search \"\(query)\":\n\(result)"
                                } catch {
                                    result = "Search failed: \(error.localizedDescription)"
                                }
                            } else if call.name == WebFetchService.toolSpec.name {
                                let urlString = call.arguments["url"] as? String ?? ""
                                let host = URL(string: urlString)?.host ?? urlString
                                continuation.yield(.status("\(L("panel.fetchingPage")): \(host)"))
                                do {
                                    result = try await WebFetchService.fetch(urlString: urlString)
                                    // Digest keeps only the head of a page —
                                    // fetches are big and must not evict the
                                    // search grounding from the 6k cap.
                                    toolDigest += (toolDigest.isEmpty ? "" : "\n\n")
                                        + "Fetched \(urlString):\n\(result.prefix(1500))"
                                } catch {
                                    result = "Fetch failed: \(error.localizedDescription)"
                                }
                            } else if CalendarToolService.canHandle(call.name) {
                                continuation.yield(.status(CalendarToolService.statusLine(for: call)))
                                // Calendar results are not added to toolDigest:
                                // the digest is web grounding for follow-ups;
                                // schedule data goes stale by design.
                                result = await CalendarToolService.run(call)
                            } else {
                                result = "Unknown tool: \(call.name)"
                            }
                            messages.append(LLMMessage(
                                role: .tool,
                                text: result,
                                toolCallID: call.id,
                                toolName: call.name
                            ))
                        }
                        continuation.yield(.status(L("panel.thinking")))
                    }
                    if !toolDigest.isEmpty {
                        // Capped: one digest rides along on future requests
                        // (most recent reply only — see buildMessages).
                        continuation.yield(.toolContext(String(toolDigest.prefix(6000))))
                    }
                    Diagnostics.log("chat", "turn.end iterations=\(iteration) chunks=\(chunkCount) chars=\(totalChars)")
                    if let warning = recordSpend(kind: .chat, providerID: providerID, model: model,
                                                 usage: turnUsage, sentMessages: messages,
                                                 receivedChars: receivedChars) {
                        // Soft budget alert — one system line, never a block.
                        store.addMessage(text: warning, isUser: false, messageType: .system)
                    }
                    continuation.finish()
                } catch {
                    Diagnostics.log("chat", "turn.error \(String(error.localizedDescription.prefix(200)))")
                    // The turn still consumed tokens (cancelled streams bill
                    // whatever was generated) — record what we know.
                    recordSpend(kind: .chat, providerID: providerID, model: model,
                                usage: turnUsage, sentMessages: messages,
                                receivedChars: receivedChars)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Spend recording

    /// Records one model call (or agent-loop turn) into the spend ledger.
    /// When the provider reported no usage (cancelled/failed stream), falls
    /// back to the script-aware character estimate and flags the record.
    /// Returns a budget-warning message when a threshold was crossed.
    @MainActor
    @discardableResult
    private static func recordSpend(
        kind: SpendKind,
        providerID: ProviderID,
        model: String,
        usage: TokenUsage,
        sentMessages: [LLMMessage],
        receivedChars: Int
    ) -> String? {
        var usage = usage
        var isEstimate = false
        if usage.isEmpty {
            guard receivedChars > 0 || !sentMessages.isEmpty else { return nil }
            // Interrupted before the usage frame: estimate. Input from the
            // last request's messages, output from streamed characters at a
            // blended ~3 chars/token (between ASCII /4 and Cyrillic ×2/5).
            usage.inputTokens = sentMessages.reduce(0) { $0 + estimatedTokens($1.text) }
            usage.outputTokens = receivedChars / 3
            isEstimate = true
            guard !usage.isEmpty else { return nil }
        }

        // Price: the local catalog; for OpenRouter, the live per-model price
        // from its /models catalog is exact and wins. Cache-read there is
        // billed at full input rate (conservative — OpenRouter's per-model
        // cache discounts aren't in the catalog payload).
        var pricing = PricingCatalog.pricing(provider: providerID, model: model)
        if providerID == .openrouter,
           let info = AppSettings.shared.openRouterModelInfo(for: model),
           let prompt = info.promptPricePerToken,
           let completion = info.completionPricePerToken {
            pricing = ModelPricing(
                inputPerToken: prompt, outputPerToken: completion,
                cacheReadPerToken: prompt, cacheWritePerToken: prompt
            )
        }
        return SpendStore.shared.record(
            kind: kind, provider: providerID.rawValue, model: model,
            usage: usage, costUSD: pricing?.cost(for: usage), isEstimate: isEstimate
        )
    }

    // MARK: - History → provider messages

    /// Converts chat history into provider messages.
    ///
    /// Images are attached as pixels only for the most recent user message
    /// (bounds token cost). Older turns keep their content as a cached OCR
    /// extraction (computed lazily, persisted on the attachment) instead of a
    /// content-free note. When the selected model does not support vision
    /// (DeepSeek, or a text-only OpenRouter model), the image is run through
    /// Mistral OCR and injected as text. `supportsVision` is resolved
    /// per-model by the caller.
    private static func buildMessages(
        from history: [ChatMessage],
        providerID: ProviderID,
        supportsVision: Bool,
        store: ChatStore
    ) async throws -> [LLMMessage] {
        let conversational = history.filter { $0.messageType != .system }
        let lastUserID = conversational.last(where: { $0.isUser })?.id
        // Search-result grounding rides on the most recent reply that has it —
        // mirrors the images-only-on-last policy, so the cost stays bounded.
        let lastToolContextID = conversational.last(where: { !$0.isUser && $0.toolContext?.isEmpty == false })?.id
        // Older attachments without a cached extraction are OCR'd once (then
        // persisted); capped per turn so an image-heavy history can't stall
        // the reply behind a burst of OCR calls — the rest catch up next turns.
        var lazyOCRBudget = 3

        var result: [LLMMessage] = []
        for message in conversational {
            let role: LLMMessage.Role = message.isUser ? .user : .assistant
            var text = message.text
            var images: [LLMImage] = []

            if !message.attachments.isEmpty {
                if message.id == lastUserID {
                    if supportsVision {
                        images = message.attachments.map {
                            LLMImage(mimeType: $0.mimeType, base64: $0.contentBase64)
                        }
                    } else {
                        // Non-vision provider: OCR the attachments into text.
                        guard OCRService.isAvailable else {
                            throw ProviderError.visionUnsupported(providerID)
                        }
                        for attachment in message.attachments where attachment.mimeType.hasPrefix("image") {
                            let ocrText = try await cachedOCRText(for: attachment, of: message, store: store)
                            text += "\n\n[Image content extracted via OCR]:\n\(ocrText)"
                        }
                    }
                } else {
                    var extractedAny = false
                    for attachment in message.attachments where attachment.mimeType.hasPrefix("image") {
                        var extracted = attachment.ocrText
                        if extracted == nil, lazyOCRBudget > 0, OCRService.isAvailable {
                            lazyOCRBudget -= 1
                            extracted = try? await cachedOCRText(for: attachment, of: message, store: store)
                        }
                        if let extracted, !extracted.isEmpty {
                            text += "\n\n[Image attached earlier in the conversation; extracted content:]\n\(String(extracted.prefix(4000)))"
                            extractedAny = true
                        }
                    }
                    if !extractedAny {
                        text += "\n[The user attached an image earlier in the conversation.]"
                    }
                }
            }

            if message.id == lastToolContextID, let toolContext = message.toolContext {
                text += "\n\n[Web search results this answer was based on:]\n\(toolContext)"
            }

            guard !text.isEmpty || !images.isEmpty else { continue }
            result.append(LLMMessage(role: role, text: text, images: images))
        }
        return result
    }

    /// OCR with per-attachment persistence: returns the cached extraction, or
    /// runs OCR once and writes the result back onto the attachment — retries
    /// and later turns never re-pay the call, and the content survives the
    /// message aging out of the pixels-attached window.
    @MainActor
    private static func cachedOCRText(
        for attachment: ChatAttachment,
        of message: ChatMessage,
        store: ChatStore
    ) async throws -> String {
        if let cached = attachment.ocrText, !cached.isEmpty { return cached }
        let text = try await OCRService.extractText(
            imageBase64: attachment.contentBase64,
            mimeType: attachment.mimeType
        )
        store.setAttachmentOCRText(text, messageID: message.id, attachmentID: attachment.id)
        return text
    }

    // MARK: - Context compression (rolling summary)

    /// Character-based token estimate, script-aware: ASCII runs ≈ 4 chars per
    /// token, but Cyrillic (and other non-Latin scripts) tokenize much denser
    /// — ≈ 2.5 chars per token. A flat /4 undercounted Russian chats by ~2x,
    /// silently doubling the real compression threshold.
    private static func estimatedTokens(_ text: String) -> Int {
        var ascii = 0
        var dense = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII { ascii += 1 } else { dense += 1 }
        }
        return ascii / 4 + dense * 2 / 5
    }

    private static func estimatedTokens(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { sum, message in
            // Cached OCR extractions ride into the request as older-image
            // grounding (see buildMessages) — count them too.
            sum + estimatedTokens(message.text)
                + message.attachments.reduce(0) { $0 + estimatedTokens($1.ocrText ?? "") }
        }
    }

    /// Threshold beyond which older turns are folded into the rolling summary.
    /// Deliberately generous: prompt caching (explicit breakpoints for
    /// Anthropic, implicit for OpenAI/Gemini/DeepSeek) makes a long verbatim
    /// prefix cheap, and verbatim history always beats summarized recall.
    private static let compressionTokenThreshold = 24_000
    /// How many recent messages always stay verbatim.
    private static let keepRecentCount = 12

    /// Industry-standard sliding window + rolling summary: when the verbatim
    /// history grows past the threshold, older turns are summarized by the
    /// same model and replaced with a compact context note. UI messages stay
    /// intact — only the API context shrinks.
    @MainActor
    static func compressHistoryIfNeeded(store: ChatStore) async {
        let settings = AppSettings.shared
        await APIKeyStore.warmIfNeeded()
        guard let apiKey = try? settings.resolvedAPIKey(for: settings.chatProvider),
              let model = settings.selectedModel(for: settings.chatProvider) else { return }

        // Captured BEFORE the summarization call: it takes seconds, and the
        // user may switch conversations meanwhile — the result must land in
        // the conversation it was computed for (see ChatStore.setSummary).
        let target = store.conversation
        // Window-aware: activeContextMessages already skips the summarized
        // prefix, and coversCount is an ABSOLUTE index into the conversation
        // (the store's window is a suffix — plain messages.count would
        // undercount and shift the summary boundary onto the wrong turns).
        let active = store.activeContextMessages
        guard active.count > keepRecentCount + 4,
              estimatedTokens(active) > compressionTokenThreshold else { return }

        let toSummarize = active.dropLast(keepRecentCount).filter { $0.messageType != .system }
        guard !toSummarize.isEmpty else { return }
        Diagnostics.log("chat", "compress.start messages=\(toSummarize.count)")
        let newCoversCount = store.totalMessageCount - keepRecentCount

        var transcript = ""
        if let existing = store.conversationSummary {
            transcript += "Previous summary:\n\(existing)\n\n"
        }
        transcript += toSummarize
            .map { message in
                var line = "\(message.isUser ? "User" : "Assistant"): \(message.text)"
                // Image content would otherwise vanish from the conversation's
                // memory the moment its message crosses the summary boundary.
                for attachment in message.attachments {
                    if let ocr = attachment.ocrText, !ocr.isEmpty {
                        line += "\n[Attached image content: \(String(ocr.prefix(1000)))]"
                    }
                }
                return line
            }
            .joined(separator: "\n")

        // Merge-style prompt: each compression folds new turns INTO the
        // previous summary instead of re-summarizing a summary — a hard word
        // cap with a rewrite-from-scratch prompt was bleeding early facts out
        // of long conversations, one compression at a time.
        let prompt = """
Maintain the running context notes for an ongoing conversation. Merge the previous \
summary (if present) with the new turns below into ONE updated set of notes.

Rules:
- Group the notes under these headings: Facts; Decisions; User preferences; Open tasks.
- Carry forward every item from the previous summary that has not been explicitly \
superseded — merging must never lose established facts, names, numbers or preferences.
- Add new items from the transcript; compress wording, not content.
- Under 600 words. Terse notes, not prose. Write content in the conversation's language.

\(transcript)
"""

        let provider = ProviderRegistry.provider(for: settings.chatProvider)
        var summary = ""
        var usage = TokenUsage()
        let summarizeMessages = [LLMMessage(role: .user, text: prompt)]
        do {
            let stream = provider.streamChat(
                messages: summarizeMessages,
                model: model,
                systemPrompt: nil,
                options: ChatRequestOptions(maxTokens: 2048, reasoning: .fast),
                apiKey: apiKey
            )
            for try await event in stream {
                if case .text(let chunk) = event { summary += chunk }
                if case .usage(let u) = event { usage = usage.merged(with: u) }
            }
        } catch {
            return // compression is best-effort; try again next turn
        }
        // Summarization is a real paid call — account for it (no budget
        // warning here; the visible chat turn already surfaces those).
        recordSpend(kind: .summary, providerID: settings.chatProvider, model: model,
                    usage: usage, sentMessages: summarizeMessages,
                    receivedChars: summary.count)

        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Diagnostics.log("chat", "compress.done chars=\(trimmed.count) covers=\(newCoversCount)")
        store.setSummary(trimmed, coversCount: newCoversCount, for: target)
    }
}
