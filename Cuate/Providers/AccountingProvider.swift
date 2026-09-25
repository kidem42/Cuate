import Foundation

/// One receipt per provider request, including unsuccessful attempts. Feature
/// code supplies purpose/operation, never calculates or aggregates charges.
@MainActor
struct AccountingProvider: LLMProvider {
    let base: any LLMProvider
    var providerID: ProviderID { base.providerID }

    func fetchModels(apiKey: String) async throws -> [String] {
        try await base.fetchModels(apiKey: apiKey)
    }

    func validateKey(apiKey: String) async throws {
        try await base.validateKey(apiKey: apiKey)
    }

    func streamChat(messages: [LLMMessage], model: String, systemPrompt: String?,
                    options original: ChatRequestOptions, apiKey: String)
        -> AsyncThrowingStream<LLMStreamEvent, Error> {
        var options = original
        options.modelSupportsReasoning = AppSettings.shared.modelSupportsReasoningControl(
            provider: providerID, model: model)
        options.cacheKey = options.cacheKey ?? "cuate.\(options.spendKind.rawValue)"
        let operation = options.operationID ?? UUID().uuidString
        let requestID = UUID()
        let started = Date()
        let provider = providerID
        var pricing = PricingCatalog.pricing(provider: provider, model: model)
        if provider == .openrouter, let info = AppSettings.shared.openRouterModelInfo(for: model),
           let input = info.promptPricePerToken, let output = info.completionPricePerToken {
            pricing = ModelPricing(inputPerToken: input, outputPerToken: output,
                                   cacheReadPerToken: nil, cacheWritePerToken: nil)
        }

        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                var latest: TokenUsage?
                var complete = false
                var outcome = "completed"
                var finished = false
                options.reportUsage = { usage, final in
                    guard !finished else { return }
                    latest = usage
                    complete = final
                    original.reportUsage?(usage, final)
                }
                options.reportOutcome = { value in
                    outcome = value
                    original.reportOutcome?(value)
                }
                defer {
                    finished = true
                    if Task.isCancelled { outcome = "cancelled" }
                    let usage = latest ?? TokenUsage()
                    let exact = usage.exactCostUSD
                    // Partial counts are a known minimum, not an estimate of
                    // the whole bill. Missing usage is never fabricated as zero.
                    // Token prices cannot reconstruct OpenRouter server-tool
                    // fees when the provider omitted its all-inclusive charge.
                    let catalogCanPrice = complete && !(provider == .openrouter
                        && (!options.serverTools.isEmpty || usage.serverSearchRequests > 0))
                    let cost = exact ?? (catalogCanPrice ? pricing?.cost(for: usage) : nil)
                    let basis = exact != nil ? "provider" : (cost != nil ? "catalog" : "unknown")
                    SpendStore.shared.record(
                        kind: options.spendKind, provider: provider.rawValue, model: model,
                        usage: usage, costUSD: cost, isEstimate: !complete,
                        id: requestID, timestamp: started, operationID: operation,
                        usageState: latest == nil ? "missing" : (complete ? "complete" : "partial"),
                        costBasis: basis, completionState: outcome)
                }
                do {
                    try Task.checkCancellation()
                    for try await event in base.streamChat(messages: messages, model: model,
                                                           systemPrompt: systemPrompt,
                                                           options: options, apiKey: apiKey) {
                        try Task.checkCancellation()
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    if outcome == "completed" { outcome = "failed" }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason { task.cancel() }
            }
        }
    }
}
