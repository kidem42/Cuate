import Foundation

/// Cache policy follows request reuse, never the meaning/name of a user prompt.
/// GPT-5.6+ writes cost 1.25x input; one-shot payloads should not be written.
enum OpenAIPromptCache {
    static func supportsExplicitBreakpoints(model: String) -> Bool {
        ["gpt-5.6", "gpt-6"].contains { model == $0 || model.hasPrefix($0 + "-") }
    }

    static func apply(to body: inout [String: Any], options: ChatRequestOptions) {
        guard let model = body["model"] as? String else { return }
        guard supportsExplicitBreakpoints(model: model) else {
            // Legacy routing benefits from a stable key. Do not impose a
            // retention policy that may conflict with the organization's ZDR.
            if let key = options.cacheKey { body["prompt_cache_key"] = key }
            return
        }
        var input = body["input"] as? [[String: Any]] ?? []
        switch options.spendKind {
        case .dictation, .translation, .summary, .layoutFix:
            body["prompt_cache_options"] = ["mode": "explicit"]
            if let instructions = body.removeValue(forKey: "instructions") as? String,
               !instructions.isEmpty {
                input.insert([
                    "role": "developer",
                    "content": [["type": "input_text", "text": instructions,
                                 "prompt_cache_breakpoint": ["mode": "explicit"]]]
                ], at: 0)
            }
            // No reusable instructions means no breakpoint and no cache
            // writes. User text is still sent completely and verbatim.
        case .chat, .ocr, .stt, .search, .image:
            break // Growing conversations keep OpenAI's implicit caching.
        }
        if let context = options.requestContext, !context.isEmpty {
            // Transient app context follows the reusable conversation prefix.
            // It is not persisted into history or prepended on the next call.
            input.append(["role": "developer", "content": context])
        }
        body["input"] = input
    }
}
