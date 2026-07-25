import Foundation

// MARK: - Model pricing

/// USD prices per ONE token (LiteLLM's unit — multiply by counts directly).
/// nil fields mean "unknown"; `cost(for:)` falls back conservatively:
/// unknown cache-read bills at the input rate, unknown cache-write at 1.25×
/// input (the Anthropic premium — the only provider that bills writes today).
struct ModelPricing {
    var inputPerToken: Double?
    var outputPerToken: Double?
    var cacheReadPerToken: Double?
    var cacheWritePerToken: Double?

    /// Turn cost in USD, or nil when the base input/output prices are unknown
    /// (the ledger then stores tokens only and the UI flags "no price").
    func cost(for usage: TokenUsage) -> Double? {
        guard let input = inputPerToken, let output = outputPerToken else { return nil }
        let read = cacheReadPerToken ?? input
        let write = cacheWritePerToken ?? input * 1.25
        return Double(usage.inputTokens) * input
            + Double(usage.outputTokens) * output
            + Double(usage.cacheReadTokens) * read
            + Double(usage.cacheWriteTokens) * write
    }
}

// MARK: - Catalog

/// Per-model chat prices + flat rates for non-token services (OCR, STT).
///
/// Three sources, in priority order at lookup time:
/// 1. `pricing-cache.json` in the data directory — written by the weekly
///    LiteLLM refresh; survives app updates, applies from the next launch.
/// 2. The bundled snapshot below (same LiteLLM field names, so one parser
///    serves both) — the floor that always works offline.
/// 3. OpenRouter models are NOT here: the caller passes the live catalog
///    price from `ModelInfo` (see `ChatService`), which is exact per-model.
nonisolated enum PricingCatalog {

    // MARK: Lookup

    /// Resolves pricing for a provider+model. Matching: exact id first, then
    /// the LONGEST catalog key that is a prefix of the model id — so
    /// "claude-sonnet-5" matches "claude-sonnet-5-20250929", and "gpt-5.5"
    /// prefers the "gpt-5.5" entry over "gpt-5".
    static func pricing(provider: ProviderID, model: String) -> ModelPricing? {
        // Local models run on the user's machine — always free. Returning an
        // all-zero price (not nil) makes the ledger record $0.00 rather than
        // "no price".
        if provider.isLocal {
            return ModelPricing(inputPerToken: 0, outputPerToken: 0,
                                cacheReadPerToken: 0, cacheWritePerToken: 0)
        }
        guard let table = catalog[provider.rawValue] else { return nil }
        if let exact = table[model] { return exact }
        let candidate = table.keys
            .filter { model.hasPrefix($0) }
            .max { $0.count < $1.count }
        return candidate.flatMap { table[$0] }
    }

    /// Flat rates for non-token services, USD per unit.
    static let ocrPerPage: [OCRProviderID: Double] = [
        .mistral: 0.001 // $1 per 1000 pages
    ]
    static let sttPerMinute: [STTProviderID: Double] = [
        .mistral: 0.001,   // Voxtral mini transcribe
        .openai: 0.006,    // gpt-4o-transcribe
        .deepgram: 0.0043  // Nova-3 pay-as-you-go
    ]
    /// Brave Search "Base AI" plan rate ($5 CPM). The free tier bills nothing —
    /// treat the figure as an upper-bound estimate, not an invoice.
    static let searchPerQuery = 0.005

    // MARK: Storage

    /// provider rawValue → model key → pricing. Loaded once per launch:
    /// bundled snapshot overlaid with the on-disk refresh cache. A refresh
    /// performed during this launch takes effect on the next one — keeps the
    /// table immutable and lock-free after first use.
    private static let catalog: [String: [String: ModelPricing]] = {
        var merged = parse(snapshotJSON.data(using: .utf8) ?? Data())
        if let cached = try? Data(contentsOf: cacheURL) {
            for (provider, models) in parse(cached) {
                merged[provider, default: [:]].merge(models) { _, new in new }
            }
        }
        return merged
    }()

    private static var cacheURL: URL {
        ChatStore.baseDirectory.appendingPathComponent("pricing-cache.json")
    }

    /// Parses {provider: {model: {input_cost_per_token, ...}}} (LiteLLM field
    /// names, USD per token). Tolerant: skips malformed entries.
    private static func parse(_ data: Data) -> [String: [String: ModelPricing]] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        var result: [String: [String: ModelPricing]] = [:]
        for (provider, value) in json {
            guard provider != "fetched_at", let models = value as? [String: Any] else { continue }
            var table: [String: ModelPricing] = [:]
            for (model, fields) in models {
                guard let f = fields as? [String: Any] else { continue }
                let pricing = ModelPricing(
                    inputPerToken: f["input_cost_per_token"] as? Double,
                    outputPerToken: f["output_cost_per_token"] as? Double,
                    cacheReadPerToken: f["cache_read_input_token_cost"] as? Double,
                    cacheWritePerToken: f["cache_creation_input_token_cost"] as? Double
                )
                if pricing.inputPerToken != nil || pricing.outputPerToken != nil {
                    table[model] = pricing
                }
            }
            if !table.isEmpty { result[provider] = table }
        }
        return result
    }

    // MARK: Weekly refresh from LiteLLM

    /// Community-maintained price DB (the de-facto standard LibreChat/LiteLLM
    /// ecosystem uses). ~3 MB; filtered down to our providers before caching.
    private static let remoteURL = URL(string:
        "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    private static let refreshInterval: TimeInterval = 7 * 24 * 3600

    /// Fire-and-forget: refreshes the on-disk cache when it is missing or
    /// older than a week. Network errors are silent — the snapshot still
    /// applies. Called lazily from the spend path (first record per launch).
    static func refreshIfStale() {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < refreshInterval {
            return
        }
        Task.detached(priority: .utility) {
            guard let (data, response) = try? await HTTPClient.session.data(from: remoteURL),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

            var filtered: [String: [String: Any]] = [:]
            for (key, value) in json {
                guard let fields = value as? [String: Any],
                      fields["input_cost_per_token"] is Double else { continue }
                guard let (provider, model) = mapLiteLLMKey(key) else { continue }
                filtered[provider, default: [:]][model] = [
                    "input_cost_per_token": fields["input_cost_per_token"] ?? NSNull(),
                    "output_cost_per_token": fields["output_cost_per_token"] ?? NSNull(),
                    "cache_read_input_token_cost": fields["cache_read_input_token_cost"] ?? NSNull(),
                    "cache_creation_input_token_cost": fields["cache_creation_input_token_cost"] ?? NSNull()
                ].compactMapValues { $0 is NSNull ? nil : $0 }
            }
            guard !filtered.isEmpty else { return }
            var payload: [String: Any] = filtered
            payload["fetched_at"] = ISO8601DateFormatter().string(from: Date())
            if let out = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
                try? out.write(to: cacheURL, options: .atomic)
                Diagnostics.log("pricing", "refresh.done providers=\(filtered.count)")
            }
        }
    }

    /// Maps a LiteLLM catalog key ("gemini/gemini-2.5-flash", "claude-…",
    /// "deepseek/deepseek-chat") to (our provider rawValue, bare model id).
    /// OpenRouter is deliberately skipped — its live catalog is exact.
    private static func mapLiteLLMKey(_ key: String) -> (String, String)? {
        if let bare = strip(key, prefix: "anthropic/") { return ("anthropic", bare) }
        if key.hasPrefix("claude") { return ("anthropic", key) }
        if let bare = strip(key, prefix: "gemini/") { return ("gemini", bare) }
        if let bare = strip(key, prefix: "deepseek/") { return ("deepseek", bare) }
        if let bare = strip(key, prefix: "mistral/") { return ("mistral", bare) }
        if let bare = strip(key, prefix: "moonshot/") ?? strip(key, prefix: "moonshotai/") {
            return ("kimi", bare)
        }
        if key.hasPrefix("gpt") || key.hasPrefix("o1") || key.hasPrefix("o3")
            || key.hasPrefix("o4") || key.hasPrefix("chatgpt") || key.hasPrefix("chat-latest") {
            return ("openai", key)
        }
        return nil
    }

    private static func strip(_ key: String, prefix: String) -> String? {
        // Only one path segment deep: "gemini/foo" yes, "vertex/gemini/foo" no.
        guard key.hasPrefix(prefix) else { return nil }
        let bare = String(key.dropFirst(prefix.count))
        return bare.contains("/") ? nil : bare
    }

    // MARK: Bundled snapshot

    /// USD per token, LiteLLM field names. Curated for the providers the app
    /// ships; refreshed copies land in `pricing-cache.json` and win on merge.
    /// Snapshot date: 2026-07. Sources: Anthropic price sheet; provider docs
    /// (DeepSeek V4 hit/miss, Kimi K2.x cached, Gemini 2.5, Mistral, OpenAI).
    private static let snapshotJSON = """
    {
      "anthropic": {
        "claude-fable-5":    {"input_cost_per_token": 1e-05, "output_cost_per_token": 5e-05, "cache_read_input_token_cost": 1e-06, "cache_creation_input_token_cost": 1.25e-05},
        "claude-mythos-5":   {"input_cost_per_token": 1e-05, "output_cost_per_token": 5e-05, "cache_read_input_token_cost": 1e-06, "cache_creation_input_token_cost": 1.25e-05},
        "claude-opus-4-8":   {"input_cost_per_token": 5e-06, "output_cost_per_token": 2.5e-05, "cache_read_input_token_cost": 5e-07, "cache_creation_input_token_cost": 6.25e-06},
        "claude-opus-4-7":   {"input_cost_per_token": 5e-06, "output_cost_per_token": 2.5e-05, "cache_read_input_token_cost": 5e-07, "cache_creation_input_token_cost": 6.25e-06},
        "claude-opus-4-6":   {"input_cost_per_token": 5e-06, "output_cost_per_token": 2.5e-05, "cache_read_input_token_cost": 5e-07, "cache_creation_input_token_cost": 6.25e-06},
        "claude-opus-4-5":   {"input_cost_per_token": 5e-06, "output_cost_per_token": 2.5e-05, "cache_read_input_token_cost": 5e-07, "cache_creation_input_token_cost": 6.25e-06},
        "claude-opus-4-1":   {"input_cost_per_token": 1.5e-05, "output_cost_per_token": 7.5e-05, "cache_read_input_token_cost": 1.5e-06, "cache_creation_input_token_cost": 1.875e-05},
        "claude-opus-4-0":   {"input_cost_per_token": 1.5e-05, "output_cost_per_token": 7.5e-05, "cache_read_input_token_cost": 1.5e-06, "cache_creation_input_token_cost": 1.875e-05},
        "claude-sonnet-5":   {"input_cost_per_token": 3e-06, "output_cost_per_token": 1.5e-05, "cache_read_input_token_cost": 3e-07, "cache_creation_input_token_cost": 3.75e-06},
        "claude-sonnet-4":   {"input_cost_per_token": 3e-06, "output_cost_per_token": 1.5e-05, "cache_read_input_token_cost": 3e-07, "cache_creation_input_token_cost": 3.75e-06},
        "claude-haiku-4-5":  {"input_cost_per_token": 1e-06, "output_cost_per_token": 5e-06, "cache_read_input_token_cost": 1e-07, "cache_creation_input_token_cost": 1.25e-06},
        "claude-3-5-haiku":  {"input_cost_per_token": 8e-07, "output_cost_per_token": 4e-06},
        "claude-3-haiku":    {"input_cost_per_token": 2.5e-07, "output_cost_per_token": 1.25e-06}
      },
      "openai": {
        "gpt-5.5":      {"input_cost_per_token": 5e-06, "output_cost_per_token": 3e-05, "cache_read_input_token_cost": 5e-07},
        "gpt-5-mini":   {"input_cost_per_token": 2.5e-07, "output_cost_per_token": 2e-06, "cache_read_input_token_cost": 2.5e-08},
        "gpt-5-nano":   {"input_cost_per_token": 5e-08, "output_cost_per_token": 4e-07, "cache_read_input_token_cost": 5e-09},
        "gpt-5-chat":   {"input_cost_per_token": 1.25e-06, "output_cost_per_token": 1e-05, "cache_read_input_token_cost": 1.25e-07},
        "chat-latest":  {"input_cost_per_token": 1.25e-06, "output_cost_per_token": 1e-05, "cache_read_input_token_cost": 1.25e-07},
        "gpt-5":        {"input_cost_per_token": 1.25e-06, "output_cost_per_token": 1e-05, "cache_read_input_token_cost": 1.25e-07},
        "gpt-4.1":      {"input_cost_per_token": 2e-06, "output_cost_per_token": 8e-06, "cache_read_input_token_cost": 5e-07},
        "gpt-4.1-mini": {"input_cost_per_token": 4e-07, "output_cost_per_token": 1.6e-06, "cache_read_input_token_cost": 1e-07},
        "gpt-4.1-nano": {"input_cost_per_token": 1e-07, "output_cost_per_token": 4e-07, "cache_read_input_token_cost": 2.5e-08},
        "gpt-4o":       {"input_cost_per_token": 2.5e-06, "output_cost_per_token": 1e-05, "cache_read_input_token_cost": 1.25e-06},
        "gpt-4o-mini":  {"input_cost_per_token": 1.5e-07, "output_cost_per_token": 6e-07, "cache_read_input_token_cost": 7.5e-08},
        "o3":           {"input_cost_per_token": 2e-06, "output_cost_per_token": 8e-06, "cache_read_input_token_cost": 5e-07},
        "o4-mini":      {"input_cost_per_token": 1.1e-06, "output_cost_per_token": 4.4e-06, "cache_read_input_token_cost": 2.75e-07}
      },
      "gemini": {
        "gemini-flash-latest":    {"input_cost_per_token": 3e-07, "output_cost_per_token": 2.5e-06, "cache_read_input_token_cost": 7.5e-08},
        "gemini-2.5-pro":         {"input_cost_per_token": 1.25e-06, "output_cost_per_token": 1e-05, "cache_read_input_token_cost": 3.1e-07},
        "gemini-2.5-flash":       {"input_cost_per_token": 3e-07, "output_cost_per_token": 2.5e-06, "cache_read_input_token_cost": 7.5e-08},
        "gemini-2.5-flash-lite":  {"input_cost_per_token": 1e-07, "output_cost_per_token": 4e-07, "cache_read_input_token_cost": 2.5e-08},
        "gemini-2.0-flash":       {"input_cost_per_token": 1e-07, "output_cost_per_token": 4e-07, "cache_read_input_token_cost": 2.5e-08},
        "gemini-1.5-flash":       {"input_cost_per_token": 7.5e-08, "output_cost_per_token": 3e-07},
        "gemini-1.5-pro":         {"input_cost_per_token": 1.25e-06, "output_cost_per_token": 5e-06}
      },
      "mistral": {
        "mistral-large":  {"input_cost_per_token": 2e-06, "output_cost_per_token": 6e-06},
        "mistral-medium": {"input_cost_per_token": 4e-07, "output_cost_per_token": 2e-06},
        "mistral-small":  {"input_cost_per_token": 1e-07, "output_cost_per_token": 3e-07},
        "codestral":      {"input_cost_per_token": 3e-07, "output_cost_per_token": 9e-07}
      },
      "deepseek": {
        "deepseek-chat":     {"input_cost_per_token": 1.4e-07, "output_cost_per_token": 2.8e-07, "cache_read_input_token_cost": 2.8e-09},
        "deepseek-reasoner": {"input_cost_per_token": 4.35e-07, "output_cost_per_token": 8.7e-07, "cache_read_input_token_cost": 3.625e-09}
      },
      "kimi": {
        "kimi-k3":   {"input_cost_per_token": 3e-06, "output_cost_per_token": 1.5e-05, "cache_read_input_token_cost": 3e-07},
        "kimi-k2.7": {"input_cost_per_token": 9.5e-07, "output_cost_per_token": 4e-06, "cache_read_input_token_cost": 1.6e-07},
        "kimi-k2.6": {"input_cost_per_token": 9.5e-07, "output_cost_per_token": 4e-06, "cache_read_input_token_cost": 1.6e-07},
        "kimi-k2.5": {"input_cost_per_token": 6e-07, "output_cost_per_token": 3e-06, "cache_read_input_token_cost": 1e-07},
        "kimi-k2":   {"input_cost_per_token": 6e-07, "output_cost_per_token": 2.5e-06, "cache_read_input_token_cost": 1.5e-07}
      }
    }
    """
}
