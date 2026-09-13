import Foundation

// Standalone wire-policy regression tests; no app launch or network.
// Shapes verified against local Ollama 0.33.2 and:
// https://github.com/ollama/ollama/blob/v0.34.0/openai/openai.go
@main
struct OllamaCompatibilityContractTest {
    static func main() throws {
        var checks = 0
        func expect(_ condition: Bool, _ name: String) {
            guard condition else { fatalError(name) }
            checks += 1
        }

        // A reasoning-only SSE delta must survive even with null content.
        let chunk = Data(#"{"choices":[{"delta":{"role":"assistant","content":null,"reasoning":"Synthetic thought."}}]}"#.utf8)
        let json = try JSONSerialization.jsonObject(with: chunk) as! [String: Any]
        let choices = json["choices"] as! [[String: Any]]
        let delta = choices[0]["delta"] as! [String: Any]
        expect(OllamaCompatibility.reasoningDelta(delta) == "Synthetic thought.", "native reasoning was discarded")
        expect(OllamaCompatibility.reasoningDelta(["reasoning_content": "legacy"]) == "legacy", "legacy fallback")
        expect(OllamaCompatibility.reasoningDelta(["reasoning": "new", "reasoning_content": "old"]) == "new", "do not duplicate two spellings")
        expect(OllamaCompatibility.reasoningDelta(["reasoning": NSNull(), "reasoning_content": "legacy"]) == "legacy", "null fallback")
        expect(OllamaCompatibility.reasoningDelta(["reasoning": "", "reasoning_content": "legacy"]) == "legacy", "empty fallback")
        expect(OllamaCompatibility.reasoningDelta(["content": "OK"]) == nil, "answer is not reasoning")
        expect(OllamaCompatibility.reasoningDelta(["reasoning": 42]) == nil, "malformed reasoning")

        for (mode, expected) in [("auto", nil), ("fast", "low"), ("deep", "high")] as [(String, String?)] {
            expect(OllamaCompatibility.reasoningEffort(mode: mode, supported: true, preferNoReasoning: false) == expected, "effort: \(mode)")
            expect(OllamaCompatibility.reasoningEffort(mode: mode, supported: false, preferNoReasoning: false) == nil, "non-thinking model: \(mode)")
        }
        expect(OllamaCompatibility.reasoningEffort(mode: "auto", supported: true, preferNoReasoning: true) == "low", "background lowest effort")
        expect(OllamaCompatibility.reasoningEffort(mode: "deep", supported: false, preferNoReasoning: true) == nil, "unknown model gets no extra parameter")

        // Custom aliases must be judged by capabilities, not words in IDs.
        let catalog: [(String, [String]?)] = [
            ("my-image-chat", ["completion", "vision"]),
            ("audio-assistant", ["completion", "audio", "thinking"]),
            ("ocr-helper", ["completion"]),
            ("custom-vector-model", ["embedding"]),
            ("picture-generator", ["image"]),
            ("old-server-model", []),
            ("show-request-failed", nil)
        ]
        let selected = catalog.filter { OllamaCompatibility.isChatModel(capabilities: $0.1) }.map { $0.0 }
        expect(selected == ["my-image-chat", "audio-assistant", "ocr-helper", "old-server-model", "show-request-failed"], "native capability filtering with safe fallback")
        print("Ollama compatibility: \(checks) checks passed")
    }
}
