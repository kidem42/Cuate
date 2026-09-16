import Foundation

/// Pure wire policies for Ollama's native catalog and OpenAI chat endpoint.
/// Verified against Ollama 0.33.2 responses and the 0.34.0 API sources.
nonisolated enum OllamaCompatibility {
    static func supportsTranscription(capabilities: [String], remote: Bool?) -> Bool {
        // Old caches and unknown capabilities must not enable audio uploads.
        remote == false && capabilities.contains("audio") && capabilities.contains("completion")
    }

    static func displayCapabilities(_ capabilities: [String]) -> [String] {
        let order = ["completion", "vision", "tools", "thinking", "audio", "embedding", "insert", "image"]
        let normalized = Set(capabilities.map { $0 == "reasoning" ? "thinking" : $0 })
        return order.filter { normalized.contains($0) } + normalized.subtracting(order).sorted()
    }

    static func reasoningDelta(_ delta: [String: Any]) -> String? {
        // Prefer Ollama's field; tolerate older compatible proxies without
        // emitting the same trace twice when both spellings are present.
        for key in ["reasoning", "reasoning_content"] {
            if let value = delta[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    static func reasoningEffort(mode: String, supported: Bool, preferNoReasoning: Bool) -> String? {
        guard supported else { return nil }
        // Some thinking models cannot disable thinking (e.g. GPT-OSS).
        // Background rewrites therefore use the lowest supported effort.
        if preferNoReasoning { return "low" }
        switch mode {
        case "fast": return "low"
        case "deep": return "high"
        default: return nil // Auto preserves the server/model default.
        }
    }

    static func isChatModel(capabilities: [String]?) -> Bool {
        // Missing metadata is not evidence that a custom model cannot chat.
        guard let capabilities, !capabilities.isEmpty else { return true }
        return capabilities.contains("completion")
    }
}
