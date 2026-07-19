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
    }

    private static let maxToolIterations = 4

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

        guard let apiKey = APIKeyStore.key(for: providerID) else {
            throw ProviderError.missingAPIKey(providerID)
        }
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

        var options = ChatRequestOptions(
            maxTokens: settings.maxTokens,
            reasoning: settings.reasoningMode
        )
        options.modelSupportsReasoning = settings.modelSupportsReasoningControl(provider: providerID, model: model)
        // Attach the web-search tool only when the model can actually call tools
        // (OpenRouter hosts models that can't) — otherwise the request errors.
        if settings.webSearchEnabled,
           BraveSearchService.isAvailable,
           settings.modelSupportsTools(provider: providerID, model: model) {
            options.tools = [BraveSearchService.toolSpec]
            // Usage hint appended at request time — the user's editable prompt
            // stays clean; the tool's schema/description travels via the API.
            systemPrompt += """


You have a web_search tool. Use it when the answer depends on current events, live data, or facts you are unsure about; do not guess. Citation rules for externally sourced facts: put an inline markdown link immediately after each fact, in the form ([Source Name](URL)). Never group links into a separate "Sources" section at the end. Do not add source links for answers from your own knowledge or the conversation.
"""
        }

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
                            }
                        }

                        guard !toolCalls.isEmpty, iteration <= maxToolIterations else { break }

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
                    continuation.finish()
                } catch {
                    Diagnostics.log("chat", "turn.error \(String(error.localizedDescription.prefix(200)))")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
                        guard MistralOCRService.isAvailable else {
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
                        if extracted == nil, lazyOCRBudget > 0, MistralOCRService.isAvailable {
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
        let text = try await MistralOCRService.extractText(
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
        guard let apiKey = APIKeyStore.key(for: settings.chatProvider),
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
        do {
            let stream = provider.streamChat(
                messages: [LLMMessage(role: .user, text: prompt)],
                model: model,
                systemPrompt: nil,
                options: ChatRequestOptions(maxTokens: 2048, reasoning: .fast),
                apiKey: apiKey
            )
            for try await event in stream {
                if case .text(let chunk) = event { summary += chunk }
            }
        } catch {
            return // compression is best-effort; try again next turn
        }

        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Diagnostics.log("chat", "compress.done chars=\(trimmed.count) covers=\(newCoversCount)")
        store.setSummary(trimmed, coversCount: newCoversCount, for: target)
    }
}
