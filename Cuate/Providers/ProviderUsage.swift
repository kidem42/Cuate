import Foundation

/// Normalization is per API contract. A present all-zero usage is still a
/// receipt; callers must track its presence separately from TokenUsage.isEmpty.
enum ProviderUsage {
    static func chatCompletions(_ data: [String: Any]) -> TokenUsage {
        var usage = TokenUsage()
        let details = data["prompt_tokens_details"] as? [String: Any] ?? [:]
        let cached = max(0, details["cached_tokens"] as? Int ?? data["cached_tokens"] as? Int ?? 0)
        let written = max(0, details["cache_write_tokens"] as? Int ?? 0)
        if let hit = data["prompt_cache_hit_tokens"] as? Int,
           let miss = data["prompt_cache_miss_tokens"] as? Int {
            usage.cacheReadTokens = max(0, hit)
            usage.inputTokens = max(0, miss)
        } else {
            usage.cacheReadTokens = cached
            usage.cacheWriteTokens = written
            usage.inputTokens = max(0, (data["prompt_tokens"] as? Int ?? 0) - cached - written)
        }
        usage.outputTokens = max(0, data["completion_tokens"] as? Int ?? 0)
        usage.reasoningTokens = max(0, (data["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int ?? 0)
        usage.exactCostUSD = (data["cost"] as? NSNumber).map { max(0, $0.doubleValue) }
        usage.serverSearchRequests = max(0, (data["server_tool_use"] as? [String: Any])?["web_search_requests"] as? Int ?? 0)
        return usage
    }

    static func responses(_ data: [String: Any]) -> TokenUsage {
        let details = data["input_tokens_details"] as? [String: Any] ?? [:]
        let cached = max(0, details["cached_tokens"] as? Int ?? 0)
        let written = max(0, details["cache_write_tokens"] as? Int ?? 0)
        return TokenUsage(
            inputTokens: max(0, (data["input_tokens"] as? Int ?? 0) - cached - written),
            outputTokens: max(0, data["output_tokens"] as? Int ?? 0),
            cacheReadTokens: cached, cacheWriteTokens: written,
            reasoningTokens: max(0, (data["output_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int ?? 0))
    }
}
