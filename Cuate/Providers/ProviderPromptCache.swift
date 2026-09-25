import Foundation

enum ProviderPromptCache {
    /// OpenRouter's Anthropic routes accept block-level cache_control. Keep
    /// existing tool calls/results and image parts verbatim; add at most two
    /// breakpoints and never change the message's role or ordering.
    static func anthropicMessages(_ input: [[String: Any]]) -> [[String: Any]] {
        var messages = input
        let system = messages.firstIndex { $0["role"] as? String == "system" }
        let tail = messages.lastIndex { entry in
            if let text = entry["content"] as? String { return !text.isEmpty }
            return (entry["content"] as? [[String: Any]])?.isEmpty == false
        }
        for index in Set([system, tail].compactMap { $0 }) {
            var blocks: [[String: Any]]
            if let text = messages[index]["content"] as? String {
                blocks = [["type": "text", "text": text]]
            } else {
                blocks = messages[index]["content"] as? [[String: Any]] ?? []
            }
            guard !blocks.isEmpty else { continue }
            blocks[blocks.count - 1]["cache_control"] = ["type": "ephemeral"]
            messages[index]["content"] = blocks
        }
        return messages
    }
}
