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
        /// File-backed attachments a tool produced mid-turn (Plaud note
        /// chips) — appended to the reply message so the bubble grows
        /// clickable previews.
        case attachments([ChatAttachment])
        /// Agent turns (AgentGateway): the authoritative full reply text.
        /// Replaces everything streamed so far — Hermes deltas and the final
        /// `assistant.completed` text differ in whitespace, and a turn with
        /// the agent's streaming off delivers ONLY this event.
        case replaceText(String)
        /// Agent turns: the persisted tool-step summary for the reply
        /// (`ChatMessage.agentSteps`), emitted once at the end.
        case agentSteps(String)
        /// Agent turns: the journal AS IT FILLS — the whole list so far, re-
        /// sent on every step change (a turn emits tens of steps, not tens of
        /// thousands of tokens, so a snapshot per step is cheaper than
        /// reconciling deltas). Feeds the live list inside the thinking pill;
        /// the persisted `.agentSteps` summary still lands at the end.
        case agentStepsLive([AgentStep])
        /// Agent turns: the gateway asked the human for permission mid-run.
        /// The window renders the inline card; `resolve` answers the gateway
        /// (and clears the matching banner). Dormant on Hermes 0.19.0 —
        /// wired for gateways that emit approval frames.
        case agentApproval(AgentApproval, resolve: @MainActor (AgentApprovalDecision) -> Void)
        /// Agent turns: a mid-turn follow-up the agent never read (steered
        /// in after its last tool batch — `AgentTurnEvent.undeliveredFollowUp`).
        /// The window sends the text as the next turn once this one is
        /// delivered; the user's bubble is already in the chat.
        case agentFollowUp(String)
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
            // OpenRouter's own web tools replace ours when the user left them
            // on: one key, no Brave. They run on OpenRouter's side and mix
            // with our function tools in the same request.
            let serverSearch = providerID == .openrouter && settings.openRouterWebSearch
            let serverFetch = providerID == .openrouter && settings.openRouterWebFetch
            var tools: [ToolSpec] = []
            if serverSearch {
                options.serverTools.append(ServerTool(
                    type: "openrouter:web_search", parameters: ["max_results": 5, "max_uses": 5]
                ))
            } else if BraveSearchService.isAvailable {
                tools.append(BraveSearchService.toolSpec)
            }
            if serverFetch {
                // "openrouter" is their free fetch engine; the others bill.
                options.serverTools.append(ServerTool(
                    type: "openrouter:web_fetch", parameters: ["engine": "openrouter", "max_uses": 5]
                ))
            } else {
                tools.append(WebFetchService.toolSpec)
            }
            options.tools = tools
            // Usage hint appended at request time — the user's editable prompt
            // stays clean; the tool's schema/description travels via the API.
            if serverSearch || BraveSearchService.isAvailable {
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

        // Plaud addon tools: same gate as the calendar (addon available +
        // tool-capable model), plus the addon's own exposure setting — in
        // "/plaud only" mode the notes stay invisible until the user opens
        // the turn with the /plaud command, which also pins the answer to
        // the notes.
        let plaudInvoked = (history.last(where: \.isUser)?.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().hasPrefix("/plaud")) ?? false
        if PlaudAddon.shared.isAvailable,
           PlaudSettings.shared.alwaysAvailable || plaudInvoked,
           settings.modelSupportsTools(provider: providerID, model: model) {
            let plaudTools = PlaudToolService.toolSpecs()
            if !plaudTools.isEmpty {
                options.tools += plaudTools
                systemPrompt += "\n\n" + PlaudToolService.systemPromptHint()
                if plaudInvoked {
                    systemPrompt += "\n" + PlaudToolService.invokedPromptHint()
                }
            }
        }

        // Documents attached earlier in this chat: the read_document tool
        // lets the model open them on demand — only when there is something
        // to open and the model can call tools (the addons' gate).
        var documentTools: [ToolSpec] = []
        if !store.conversation.isAgent,
           settings.modelSupportsTools(provider: providerID, model: model) {
            documentTools = DocumentToolService.toolSpecs(store: store)
        }
        if !documentTools.isEmpty {
            options.tools += documentTools
            systemPrompt += "\n\n" + DocumentToolService.systemPromptHint()
        }
        let hasDocumentTool = !documentTools.isEmpty
        options.modelSupportsNativeDocuments = settings.modelSupportsNativeDocuments(provider: providerID, model: model)
        // OpenRouter: every turn that involves a document goes only to
        // providers that don't collect data — the user must be able to send
        // a document without checking who serves the model this time.
        let lastUserHasDocuments = history.last(where: \.isUser)?.attachments.contains(where: \.isDocument) ?? false
        options.denyDataCollection = providerID == .openrouter && (hasDocumentTool || lastUserHasDocuments)
        options.zdrOnly = providerID == .openrouter && settings.openRouterZDROnly

        // Snapshotted per turn: a mid-stream Settings change applies to the
        // NEXT reply, not the one already running its agent loop.
        let maxToolIterations = max(1, settings.maxToolIterations)

        let supportsVision = settings.modelSupportsVision(provider: providerID, model: model)
        let provider = ProviderRegistry.provider(for: providerID)
        Diagnostics.log("chat", "turn.start provider=\(providerID.rawValue) model=\(model) history=\(history.count) tools=\(options.tools.count)")

        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                // Built inside the stream: the attach-turn uploads and the
                // local extraction report their status lines through it.
                var messages: [LLMMessage] = []
                var iteration = 0
                var chunkCount = 0
                var totalChars = 0
                // Search results gathered this turn — handed to the UI at the
                // end so they persist on the reply message as grounding.
                var toolDigest = ""
                var citedURLs = Set<String>()
                // Token usage summed across the agent loop's model calls; text
                // accumulated for the estimate fallback on interrupted streams.
                var turnUsage = TokenUsage()
                var receivedChars = 0
                // One retry when the provider rejects a document reference:
                // the same turn again with the document as local text.
                var documentRetryDone = false
                do {
                    let preparedHistory = await uploadPendingDocuments(
                        in: history, providerID: providerID, apiKey: apiKey, store: store
                    ) { continuation.yield(.status($0)) }
                    messages = try await buildMessages(
                        from: preparedHistory,
                        providerID: providerID,
                        supportsVision: supportsVision,
                        hasDocumentTool: hasDocumentTool,
                        documentsAsText: false,
                        store: store
                    ) { continuation.yield(.status($0)) }
                    while true {
                        iteration += 1
                        var turnText = ""
                        var turnReasoning = ""
                        var toolCalls: [ToolCall] = []

                        let stream = provider.streamChat(
                            messages: messages,
                            model: model,
                            systemPrompt: systemPrompt,
                            options: options,
                            apiKey: apiKey
                        )
                        do {
                            for try await event in stream {
                                switch event {
                                case .text(let chunk):
                                    turnText += chunk
                                    chunkCount += 1
                                    totalChars += chunk.count
                                    continuation.yield(.text(chunk))
                                case .reasoning(let chunk):
                                    // Kept for the tool loop only (DeepSeek
                                    // wants it back); never rendered.
                                    turnReasoning += chunk
                                case .citations(let cites):
                                    // Server-side search: the sources become
                                    // the grounding digest, same as Brave.
                                    for cite in cites where !citedURLs.contains(cite.url) {
                                        citedURLs.insert(cite.url)
                                        let heading = cite.title.isEmpty ? cite.url : "\(cite.title) — \(cite.url)"
                                        toolDigest += (toolDigest.isEmpty ? "" : "\n\n")
                                            + "\(heading)\n\(String(cite.content.prefix(400)))"
                                    }
                                case .toolCalls(let calls):
                                    toolCalls = calls
                                case .usage(let usage):
                                    turnUsage = turnUsage.merged(with: usage)
                                }
                            }
                        } catch ProviderError.http(let status, let message)
                            where !documentRetryDone && iteration == 1
                                && (status == 400 || status == 200)
                                && message.lowercased().contains("file")
                                && messages.contains(where: { !$0.documents.isEmpty }) {
                            documentRetryDone = true
                            Diagnostics.log("files", "attach turn rejected (\(message.prefix(120))) — retrying with local text")
                            messages = try await buildMessages(
                                from: preparedHistory,
                                providerID: providerID,
                                supportsVision: supportsVision,
                                hasDocumentTool: hasDocumentTool,
                                documentsAsText: true,
                                store: store
                            ) { continuation.yield(.status($0)) }
                            iteration = 0
                            continue
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
                            messages.append(LLMMessage(role: .assistant, text: turnText, toolCalls: toolCalls,
                                                       reasoningContent: turnReasoning.isEmpty ? nil : turnReasoning))
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
                        messages.append(LLMMessage(role: .assistant, text: turnText, toolCalls: toolCalls,
                                                   reasoningContent: turnReasoning.isEmpty ? nil : turnReasoning))
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
                            } else if PlaudToolService.canHandle(call.name) {
                                continuation.yield(.status(PlaudToolService.statusLine(for: call)))
                                // Not in toolDigest either: note/transcript
                                // payloads are huge and re-fetchable by ID.
                                result = await PlaudToolService.run(call)
                                let chips = PlaudToolService.takePendingAttachments()
                                if !chips.isEmpty {
                                    continuation.yield(.attachments(chips))
                                }
                            } else if DocumentToolService.canHandle(call.name) {
                                continuation.yield(.status(DocumentToolService.statusLine(for: call)))
                                // Not in toolDigest: document text is big and
                                // re-fetchable through the tool.
                                result = await DocumentToolService.run(call, store: store)
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
                    continuation.finish(throwing: Self.explainRoutingError(error, providerID: providerID))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// OpenRouter answers a request no endpoint can serve under its routing
    /// constraints (the account's privacy page, our `data_collection: deny`
    /// on document turns, the ZDR toggle) with a bare 503 — say what to do.
    static func explainRoutingError(_ error: Error, providerID: ProviderID) -> Error {
        guard providerID == .openrouter, let providerError = error as? ProviderError,
              case .http(let status, let message) = providerError else { return error }
        let text = message.lowercased()
        let routing = status == 503 || text.contains("routing requirements")
            || text.contains("data policy") || text.contains("no endpoints")
        guard routing else { return error }
        return ProviderError.http(status: status, message: L("or.routingHint") + "\n" + message)
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
        var costUSD = pricing?.cost(for: usage)
        // OpenRouter reports the exact charge, server tools included: book
        // it, with the search share moved to its own line so the provider
        // total still equals what OpenRouter charged.
        var searchShare = 0.0
        if providerID == .openrouter, usage.serverSearchRequests > 0 {
            searchShare = Double(usage.serverSearchRequests) * PricingCatalog.openRouterSearchPerRequest
            SpendStore.shared.record(
                kind: .search, provider: providerID.rawValue, model: "web_search",
                units: Double(usage.serverSearchRequests), costUSD: searchShare, isEstimate: true
            )
        }
        if providerID == .openrouter, let exact = usage.exactCostUSD {
            costUSD = max(0, exact - searchShare)
        }
        return SpendStore.shared.record(
            kind: kind, provider: providerID.rawValue, model: model,
            usage: usage, costUSD: costUSD, isEstimate: isEstimate
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
    /// OCR and injected as text. `supportsVision` is resolved per-model by
    /// the caller.
    ///
    /// Documents follow the same shape with a different fallback: the most
    /// recent user message (the attach turn) carries them in full — as an
    /// OpenAI file reference when one exists, else as locally extracted text
    /// — and every older message keeps a one-line placeholder that points the
    /// model at the read_document tool. `documentsAsText` forces the text
    /// form (the retry after a provider rejected the reference).
    private static func buildMessages(
        from history: [ChatMessage],
        providerID: ProviderID,
        supportsVision: Bool,
        hasDocumentTool: Bool,
        documentsAsText: Bool,
        store: ChatStore,
        status: ((String) -> Void)? = nil
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
        // The attach turn's inline text, across all its documents: one
        // message must never eat the context on its own (DeepSeek and the
        // other non-native providers get the text inline).
        var inlineBudget = DocumentPreflight.inlineTextCharacterCapPerMessage
        var attachNative = 0
        var attachInline = 0
        var attachInlineChars = 0
        for message in conversational {
            let role: LLMMessage.Role = message.isUser ? .user : .assistant
            var text = message.text
            var images: [LLMImage] = []
            var documents: [LLMDocument] = []
            let imageAttachments = message.attachments.filter { !$0.isDocument }
            let documentAttachments = message.attachments.filter { $0.isDocument }

            if !imageAttachments.isEmpty {
                if message.id == lastUserID {
                    if supportsVision {
                        images = imageAttachments.map {
                            // Downscaled copy for the wire; originals stay
                            // untouched for OCR / image-processing tracks.
                            LLMImage.forModel(mimeType: $0.mimeType, base64: $0.contentBase64)
                        }
                    } else {
                        // Non-vision provider: OCR the attachments into text.
                        guard OCRService.isAvailable else {
                            throw ProviderError.visionUnsupported(providerID)
                        }
                        for attachment in imageAttachments where attachment.mimeType.hasPrefix("image") {
                            let ocrText = try await cachedOCRText(for: attachment, of: message, store: store)
                            text += "\n\n[Image content extracted via OCR]:\n\(ocrText)"
                        }
                    }
                } else {
                    var extractedAny = false
                    for attachment in imageAttachments where attachment.mimeType.hasPrefix("image") {
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

            for attachment in documentAttachments {
                let label = documentLabel(attachment)
                if message.id == lastUserID {
                    if providerID == .openai, !documentsAsText, attachment.hasLiveRemoteFile,
                       let remote = attachment.remoteFileID {
                        documents.append(LLMDocument(
                            filename: attachment.filename, mimeType: attachment.mimeType, remoteFileID: remote
                        ))
                        attachNative += 1
                    } else if providerID == .openrouter, !documentsAsText,
                              DocumentPreflight.isPDF(mime: attachment.mimeType),
                              let data = attachment.data, data.count <= DocumentPreflight.maxInlineFileBytes {
                        // The PDF itself, base64, on this turn only; the engine
                        // (native / cloudflare-ai) is the provider's call.
                        documents.append(LLMDocument(
                            filename: attachment.filename, mimeType: attachment.mimeType,
                            inlineBase64: data.base64EncodedString()
                        ))
                        attachNative += 1
                    } else if let extracted = await cachedDocumentText(for: attachment, of: message, store: store, status: status) {
                        var body = extracted
                        let cap = min(DocumentPreflight.inlineTextCharacterCap, max(0, inlineBudget))
                        if body.count > cap {
                            body = String(body.prefix(cap))
                                + (hasDocumentTool
                                    ? "\n[Truncated — the rest is available through read_document]"
                                    : "\n[Truncated]")
                        }
                        inlineBudget -= body.count
                        attachInline += 1
                        attachInlineChars += body.count
                        text += "\n\n[Document: \(label)]\n\(body)"
                    } else {
                        text += "\n\n[Document attached: \(label) — not readable by this provider]"
                    }
                } else {
                    text += hasDocumentTool
                        ? "\n[Attached document: \(label) — open it with read_document when needed]"
                        : "\n[Attached document: \(label) — re-attach it to discuss its content]"
                }
            }

            if message.id == lastToolContextID, let toolContext = message.toolContext {
                text += "\n\n[Web search results this answer was based on:]\n\(toolContext)"
            }

            guard !text.isEmpty || !images.isEmpty || !documents.isEmpty else { continue }
            result.append(LLMMessage(role: role, text: text, images: images, documents: documents))
        }
        if attachNative + attachInline > 0 {
            Diagnostics.log("files", "attach turn provider=\(providerID.rawValue) native=\(attachNative) inline=\(attachInline) inlineChars=\(attachInlineChars)")
        }
        return result
    }

    /// "contract.pdf, 12 pages" / "notes.docx" — for placeholders and the summary.
    static func documentLabel(_ attachment: ChatAttachment) -> String {
        if let pages = attachment.pageCount {
            return "\(attachment.filename), \(pages) page\(pages == 1 ? "" : "s")"
        }
        return attachment.filename
    }

    /// Attach turn on OpenAI: the documents of the last user message get
    /// their provider-side copy here, once; re-attached chips already carry
    /// one. An upload failure degrades that document to the local text path
    /// with a system note — the turn itself always goes out.
    @MainActor
    private static func uploadPendingDocuments(
        in history: [ChatMessage],
        providerID: ProviderID,
        apiKey: String,
        store: ChatStore,
        status: (String) -> Void
    ) async -> [ChatMessage] {
        guard providerID == .openai,
              let index = history.lastIndex(where: { $0.isUser }) else { return history }
        var history = history
        let message = history[index]
        for (position, attachment) in message.attachments.enumerated()
        where attachment.isDocument && !attachment.hasLiveRemoteFile {
            guard let data = attachment.data else { continue }
            status(String(format: L("panel.uploadingDoc"), attachment.filename))
            do {
                let uploaded = try await OpenAIFilesService.upload(
                    data: data, filename: attachment.filename, mimeType: attachment.mimeType,
                    expiresInSeconds: Config.mediaRetentionDays * 86_400, apiKey: apiKey
                )
                let expires = uploaded.expiresAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none"
                Diagnostics.log("files", "upload id=\(uploaded.id) bytes=\(data.count) pages=\(attachment.pageCount ?? 0) expires=\(expires)")
                history[index].attachments[position].remoteFileID = uploaded.id
                history[index].attachments[position].remoteProvider = providerID.rawValue
                history[index].attachments[position].remoteExpiresAt = uploaded.expiresAt
                store.updateAttachment(messageID: message.id, attachmentID: attachment.id) {
                    $0.remoteFileID = uploaded.id
                    $0.remoteProvider = providerID.rawValue
                    $0.remoteExpiresAt = uploaded.expiresAt
                }
            } catch {
                Diagnostics.log("files", "upload failed \(attachment.filename): \(error.localizedDescription.prefix(160))")
                store.addMessage(
                    text: String(format: L("panel.docSentAsText"), attachment.filename, error.localizedDescription),
                    isUser: false, messageType: .system
                )
            }
        }
        return history
    }

    /// Local extraction with per-attachment persistence (the document twin of
    /// `cachedOCRText`): computed once, written back onto the attachment.
    @MainActor
    private static func cachedDocumentText(
        for attachment: ChatAttachment,
        of message: ChatMessage,
        store: ChatStore,
        status: ((String) -> Void)?
    ) async -> String? {
        if let cached = attachment.ocrText, !cached.isEmpty { return cached }
        guard let data = attachment.data else { return nil }
        status?(String(format: L("panel.readingDoc"), attachment.filename))
        let text = await DocumentTextService.extract(
            data: data, mimeType: attachment.mimeType, ocrLanguages: DocumentTextService.ocrLanguages()
        )
        if let text {
            store.updateAttachment(messageID: message.id, attachmentID: attachment.id) { $0.ocrText = text }
        }
        Diagnostics.log("files", "extract \(attachment.filename) chars=\(text?.count ?? 0)")
        return text
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
                for attachment in message.attachments where !attachment.isDocument {
                    if let ocr = attachment.ocrText, !ocr.isEmpty {
                        line += "\n[Attached image content: \(String(ocr.prefix(1000)))]"
                    }
                }
                // Documents keep their name (the notes must remember which
                // files were discussed); their text lives behind the tool.
                for attachment in message.attachments where attachment.isDocument {
                    line += "\n[Attached document: \(documentLabel(attachment))]"
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
