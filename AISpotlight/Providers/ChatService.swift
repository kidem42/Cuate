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
    }

    private static let maxToolIterations = 4

    // MARK: - Streaming with the agent loop

    /// Streams the assistant reply for the current conversation.
    /// - Parameters:
    ///   - history: chat messages to send verbatim (already excludes the summarized prefix).
    ///   - summary: rolling summary of older turns, if any.
    @MainActor
    static func streamReply(history: [ChatMessage], summary: String?) async throws -> AsyncThrowingStream<ChatEvent, Error> {
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
        if settings.webSearchEnabled, BraveSearchService.isAvailable {
            options.tools = [BraveSearchService.toolSpec]
            // Usage hint appended at request time — the user's editable prompt
            // stays clean; the tool's schema/description travels via the API.
            systemPrompt += """


You have a web_search tool. Use it when the answer depends on current events, live data, or facts you are unsure about; do not guess. Citation rules for externally sourced facts: put an inline markdown link immediately after each fact, in the form ([Source Name](URL)). Never group links into a separate "Sources" section at the end. Do not add source links for answers from your own knowledge or the conversation.
"""
        }

        let initialMessages = try await buildMessages(from: history, providerID: providerID)
        let provider = ProviderRegistry.provider(for: providerID)
        Diagnostics.log("chat", "turn.start provider=\(providerID.rawValue) model=\(model) history=\(history.count) tools=\(options.tools.count)")

        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                var messages = initialMessages
                var iteration = 0
                var chunkCount = 0
                var totalChars = 0
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
    /// Images are attached only for the most recent user message (older turns
    /// keep a textual note instead) to bound token cost. If the provider does
    /// not support vision (DeepSeek), the image is run through Mistral OCR and
    /// injected as text.
    private static func buildMessages(
        from history: [ChatMessage],
        providerID: ProviderID
    ) async throws -> [LLMMessage] {
        let conversational = history.filter { $0.messageType != .system }
        let lastUserID = conversational.last(where: { $0.isUser })?.id

        var result: [LLMMessage] = []
        for message in conversational {
            let role: LLMMessage.Role = message.isUser ? .user : .assistant
            var text = message.text
            var images: [LLMImage] = []

            if !message.attachments.isEmpty {
                if message.id == lastUserID {
                    if providerID.supportsVision {
                        images = message.attachments.map {
                            LLMImage(mimeType: $0.mimeType, base64: $0.base64)
                        }
                    } else {
                        // Non-vision provider: OCR the attachments into text.
                        guard MistralOCRService.isAvailable else {
                            throw ProviderError.visionUnsupported(providerID)
                        }
                        for attachment in message.attachments where attachment.mimeType.hasPrefix("image") {
                            let ocrText = try await MistralOCRService.extractText(
                                imageBase64: attachment.base64,
                                mimeType: attachment.mimeType
                            )
                            text += "\n\n[Image content extracted via OCR]:\n\(ocrText)"
                        }
                    }
                } else {
                    text += "\n[The user attached an image earlier in the conversation.]"
                }
            }

            guard !text.isEmpty || !images.isEmpty else { continue }
            result.append(LLMMessage(role: role, text: text, images: images))
        }
        return result
    }

    // MARK: - Context compression (rolling summary)

    /// Character-based token estimate (≈ 4 chars per token).
    private static func estimatedTokens(_ messages: ArraySlice<ChatMessage>) -> Int {
        messages.reduce(0) { $0 + $1.text.count } / 4
    }

    /// Threshold beyond which older turns are folded into the rolling summary.
    private static let compressionTokenThreshold = 6000
    /// How many recent messages always stay verbatim.
    private static let keepRecentCount = 8

    /// Industry-standard sliding window + rolling summary: when the verbatim
    /// history grows past the threshold, older turns are summarized by the
    /// same model and replaced with a compact context note. UI messages stay
    /// intact — only the API context shrinks.
    @MainActor
    static func compressHistoryIfNeeded(store: ChatStore) async {
        let settings = AppSettings.shared
        guard let apiKey = APIKeyStore.key(for: settings.chatProvider),
              let model = settings.selectedModel(for: settings.chatProvider) else { return }

        let start = min(store.summaryCoversCount, store.messages.count)
        let active = store.messages[start...]
        guard active.count > keepRecentCount + 4,
              estimatedTokens(active) > compressionTokenThreshold else { return }

        let toSummarize = active.dropLast(keepRecentCount).filter { $0.messageType != .system }
        guard !toSummarize.isEmpty else { return }
        Diagnostics.log("chat", "compress.start messages=\(toSummarize.count)")
        let newCoversCount = store.messages.count - keepRecentCount

        var transcript = ""
        if let existing = store.conversationSummary {
            transcript += "Previous summary:\n\(existing)\n\n"
        }
        transcript += toSummarize
            .map { "\($0.isUser ? "User" : "Assistant"): \($0.text)" }
            .joined(separator: "\n")

        let prompt = """
Summarize the following conversation in under 300 words. Preserve concrete facts, \
names, numbers, decisions made, user preferences, and open tasks. Write it as \
context notes, not prose.

\(transcript)
"""

        let provider = ProviderRegistry.provider(for: settings.chatProvider)
        var summary = ""
        do {
            let stream = provider.streamChat(
                messages: [LLMMessage(role: .user, text: prompt)],
                model: model,
                systemPrompt: nil,
                options: ChatRequestOptions(maxTokens: 1024, reasoning: .fast),
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
        store.setSummary(trimmed, coversCount: newCoversCount)
    }
}
