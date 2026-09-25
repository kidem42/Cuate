import Foundation

func L(_ key: String) -> String { key }
enum APIKeyStore {
    enum AuxKey { case deepgram }
    static func hasKey(for _: ProviderID) -> Bool { false }
    static func hasKey(aux _: AuxKey) -> Bool { false }
    static func key(for _: ProviderID) -> String? { nil }
    static func key(aux _: AuxKey) -> String? { nil }
}
enum Diagnostics { static func log(_ category: String, _ message: String) {} }
final class AppSettings {
    static let shared = AppSettings()
    func modelSupportsReasoningControl(provider: ProviderID, model: String) -> Bool { true }
    func openRouterModelInfo(for model: String) -> ModelInfo? { nil }
}
enum PricingCatalog {
    static func pricing(provider: ProviderID, model: String) -> ModelPricing? {
        ModelPricing(inputPerToken: 0.000001, outputPerToken: 0.000002,
                     cacheReadPerToken: 0.0000001, cacheWritePerToken: 0.00000125)
    }
}
final class SpendStore {
    static let shared = SpendStore()
    struct Receipt {
        let id: UUID
        let operation: String?
        let kind: SpendKind
        let usage: TokenUsage
        let cost: Double?
        let state: String?
        let basis: String?
        let outcome: String?
    }
    var receipts: [Receipt] = []
    func record(kind: SpendKind, provider: String, model: String, usage: TokenUsage,
                costUSD: Double?, isEstimate: Bool, id: UUID, timestamp: Date,
                operationID: String?, usageState: String?, costBasis: String?, completionState: String?) {
        receipts.append(Receipt(id: id, operation: operationID, kind: kind, usage: usage,
                                cost: costUSD, state: usageState, basis: costBasis, outcome: completionState))
    }
}
enum HTTPClient {
    static var frames: [[String: Any]] = []
    static var fail = false
    static var suspend = false
    static var request: URLRequest?
    static var requests: [URLRequest] = []
    static var batches: [[[String: Any]]] = []
    static func json(_ request: URLRequest) async throws -> Data { Data() }
    static func sseStream(_ value: URLRequest) -> AsyncThrowingStream<String, Error> {
        request = value
        requests.append(value)
        let batch = batches.isEmpty ? frames : batches.removeFirst()
        let error = fail
        let hanging = suspend
        return AsyncThrowingStream { c in
            let task = Task {
                for frame in batch {
                    c.yield(String(data: try! JSONSerialization.data(withJSONObject: frame), encoding: .utf8)!)
                }
                if hanging { try? await Task.sleep(nanoseconds: 60_000_000_000) }
                if error { c.finish(throwing: ProviderError.badResponse) } else { c.finish() }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}

@main struct ProviderAccountingContractTest {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        guard value() else { fatalError("FAILED: \(label)") }
    }
    static func run(_ base: any LLMProvider, model: String = "test", frames: [[String: Any]],
                    fail: Bool = false, options: ChatRequestOptions? = nil) async -> SpendStore.Receipt {
        HTTPClient.frames = frames; HTTPClient.fail = fail; HTTPClient.suspend = false
        let before = SpendStore.shared.receipts.count
        do {
            for try await _ in AccountingProvider(base: base).streamChat(
                messages: [LLMMessage(role: .user, text: "fixture")], model: model,
                systemPrompt: "fixture system", options: options ?? ChatRequestOptions(), apiKey: "") {}
        } catch {}
        for _ in 0..<100 where SpendStore.shared.receipts.count == before { await Task.yield() }
        check(SpendStore.shared.receipts.count == before + 1, "one receipt per attempted request")
        return SpendStore.shared.receipts.last!
    }
    static func body() -> [String: Any] {
        try! JSONSerialization.jsonObject(with: HTTPClient.request!.httpBody!) as! [String: Any]
    }
    static func main() async {
        let usage: [String: Any] = ["prompt_tokens": 1000, "completion_tokens": 100,
            "prompt_tokens_details": ["cached_tokens": 400, "cache_write_tokens": 200],
            "completion_tokens_details": ["reasoning_tokens": 30]]
        let normalized = ProviderUsage.chatCompletions(usage)
        check(normalized.inputTokens == 400 && normalized.cacheReadTokens == 400 && normalized.cacheWriteTokens == 200, "disjoint input buckets")
        check(normalized.outputTokens == 100 && normalized.reasoningTokens == 30, "reasoning is a subset of output")
        let deep = ProviderUsage.chatCompletions(["prompt_tokens": 1000, "prompt_cache_hit_tokens": 700, "prompt_cache_miss_tokens": 300])
        check(deep.cacheReadTokens == 700 && deep.inputTokens == 300, "DeepSeek native counters")
        check(ProviderUsage.chatCompletions(["prompt_tokens": 1000, "cached_tokens": 600]).cacheReadTokens == 600, "Kimi top-level cache counts")
        check(TokenUsage(exactCostUSD: 0.1).merged(with: TokenUsage()).exactCostUSD == nil, "partial exact sum must remain unknown")
        check(TokenUsage(exactCostUSD: 0.1).merged(with: TokenUsage(exactCostUSD: 0.2)).exactCostUSD! > 0.299, "fully known exact sum")

        let finish: [String: Any] = ["choices": [["finish_reason": "stop", "delta": [:]]]]
        var orUsage = usage; orUsage["cost"] = 0.001; orUsage["server_tool_use"] = ["web_search_requests": 2]
        let exact = await run(OpenAICompatibleProvider.openRouter, model: "anthropic/test", frames: [finish, ["usage": orUsage]], options: ChatRequestOptions(spendKind: .translation, operationID: "operation", reasoning: .fast))
        check(exact.cost == 0.001 && exact.basis == "provider", "OpenRouter exact total includes server tools once")
        check(exact.kind == .translation && exact.operation == "operation", "feature and operation linkage")
        check(exact.state == "complete" && exact.outcome == "completed", "complete receipt")
        let orMessages = body()["messages"] as! [[String: Any]]
        check((orMessages[0]["content"] as? [[String: Any]])?.first?["cache_control"] != nil, "OpenRouter Anthropic system breakpoint")
        check(body()["cache_control"] == nil, "no top-level routing restriction")
        check(body()["reasoning"] != nil, "background reasoning capability resolved")

        let unpricedTools = await run(OpenAICompatibleProvider.openRouter, frames: [finish, ["usage": usage]],
            options: ChatRequestOptions(serverTools: [ServerTool(type: "openrouter:web_search", parameters: [:])]))
        check(unpricedTools.cost == nil && unpricedTools.state == "complete", "token-only quote cannot hide unknown server-tool fees")
        let mistral = await run(OpenAICompatibleProvider.mistral, frames: [finish, ["usage": usage]], options: ChatRequestOptions(spendKind: .dictation, cacheKey: "stable", reasoning: .fast))
        check(body()["prompt_cache_key"] as? String == "stable", "Mistral stable cache key")
        check(mistral.basis == "catalog" && abs(mistral.cost! - 0.00089) < 1e-10, "cache write price and reasoning not double-counted")
        let zero = await run(OpenAICompatibleProvider.mistral, frames: [finish, ["usage": ["prompt_tokens": 0, "completion_tokens": 0]]])
        check(zero.state == "complete" && zero.cost == 0, "actual zero receipt differs from missing")
        let missing = await run(OpenAICompatibleProvider.mistral, frames: [], fail: true)
        check(missing.state == "missing" && missing.cost == nil && missing.outcome == "failed", "missing usage never fabricated")
        let partial = await run(OpenAICompatibleProvider.mistral, frames: [["usage": usage]], fail: true)
        check(partial.state == "partial" && partial.usage.inputTokens == 400 && partial.cost == nil, "partial counts survive network error")
        let errorFrame = await run(OpenAICompatibleProvider.openRouter, frames: [["usage": orUsage, "error": ["message": "fixture failure"]]])
        check(errorFrame.cost == 0.001 && errorFrame.outcome == "failed", "usage on error frame retained")
        let eof = await run(OpenAICompatibleProvider.mistral, frames: [["usage": usage]])
        check(eof.state == "partial" && eof.outcome == "incomplete", "EOF without terminal marker")

        let responseUsage: [String: Any] = ["input_tokens": 1000, "output_tokens": 100,
            "input_tokens_details": ["cached_tokens": 400, "cache_write_tokens": 200],
            "output_tokens_details": ["reasoning_tokens": 30]]
        for status in ["completed", "incomplete", "failed"] {
            let row = await run(OpenAICompatibleProvider.openAI, frames: [["type": "response.\(status)", "response": ["usage": responseUsage]]])
            check(row.state == "complete" && row.usage.cacheWriteTokens == 200, "Responses \(status) usage")
            check(row.outcome == status, "Responses \(status) status")
        }
        let start: [String: Any] = ["type": "message_start", "message": ["usage": ["input_tokens": 100, "cache_creation_input_tokens": 200, "cache_read_input_tokens": 300, "output_tokens": 1]]]
        let delta: [String: Any] = ["type": "message_delta", "usage": ["output_tokens": 50], "delta": ["stop_reason": "end_turn"]]
        let anthropic = await run(AnthropicProvider(), frames: [start, delta, ["type": "message_stop"]])
        check(anthropic.state == "complete" && anthropic.usage.inputTokens == 100 && anthropic.usage.outputTokens == 50, "Anthropic cumulative output replaces initial count")
        let interrupted = await run(AnthropicProvider(), frames: [start], fail: true)
        check(interrupted.state == "partial" && interrupted.usage.cacheWriteTokens == 200, "Anthropic initial usage survives failure")
        let gemini = await run(GeminiProvider(), frames: [["usageMetadata": ["promptTokenCount": 1000, "cachedContentTokenCount": 400, "candidatesTokenCount": 50, "thoughtsTokenCount": 20], "candidates": [["finishReason": "STOP"]]]])
        check(gemini.state == "complete" && gemini.usage.inputTokens == 600 && gemini.usage.outputTokens == 70, "Gemini thoughts added once")

        HTTPClient.frames = [start]; HTTPClient.fail = false; HTTPClient.suspend = true
        let before = SpendStore.shared.receipts.count
        let cancel = Task {
            do { for try await _ in AccountingProvider(base: AnthropicProvider()).streamChat(messages: [], model: "test", systemPrompt: nil, options: ChatRequestOptions(), apiKey: "") {} } catch {}
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        cancel.cancel(); await cancel.value
        for _ in 0..<100 where SpendStore.shared.receipts.count == before { await Task.yield() }
        check(SpendStore.shared.receipts.count == before + 1, "cancel records once")
        check(SpendStore.shared.receipts.last!.outcome == "cancelled", "cancel outcome")
        check(SpendStore.shared.receipts.last!.usage.inputTokens == 100, "cancel retains initial counters")
        check(Set(SpendStore.shared.receipts.map(\.id)).count == SpendStore.shared.receipts.count, "attempt IDs unique")
        HTTPClient.suspend = false; HTTPClient.fail = false
        HTTPClient.requests = []
        let toolFrame: [String: Any] = ["choices": [["finish_reason": "tool_calls", "delta": ["tool_calls": [["index": 0, "id": "call1", "function": ["name": "web_fetch", "arguments": "{\"url\":\"https://example.invalid\"}"]]]]]]]
        func answer(_ text: String) -> [[String: Any]] {
            [["choices": [["finish_reason": "stop", "delta": ["content": text]]]], ["usage": usage]]
        }
        HTTPClient.batches = [[toolFrame, ["usage": usage]], answer("first part <continue/>"), answer("second part")]
        let state = ChatService.TurnState()
        let store = ChatStore()
        for _ in 0..<2 {
            do { for try await _ in try await ChatService.streamReply(history: [ChatMessage(text: "question")], summary: nil, store: store, state: state) {} }
            catch { fatalError("chat loop failed: \(error)") }
        }
        check(HTTPClient.requests.count == 3, "one tool round then two answer requests")
        let bodies = HTTPClient.requests.map { try! JSONSerialization.jsonObject(with: $0.httpBody!) as! [String: Any] }
        check(bodies[0]["tools"] != nil && bodies[1]["tools"] == nil && bodies[2]["tools"] == nil, "tool budget survives auto-continue")
        let continued = bodies[2]["messages"] as! [[String: Any]]
        check(continued.contains { $0["role"] as? String == "tool" && $0["content"] as? String == "retained fixture page" }, "tool result retained in continuation")
        check(continued.last?["content"] as? String == "Continue.", "continuation appended to working state")
        check(!continued.contains { ($0["content"] as? String)?.contains("<continue/>") == true }, "control marker removed from saved answer")
        let lastReceipts = SpendStore.shared.receipts.suffix(3)
        check(Set(lastReceipts.compactMap(\.operation)).count == 1, "loop and continuation share operation ID")
        // Real Responses serializer: one-shot input is not a cache write.
        for kind: SpendKind in [.dictation, .translation, .summary, .layoutFix] {
            _ = await run(OpenAICompatibleProvider.openAI, model: "gpt-5.6-sol", frames: [],
                          options: ChatRequestOptions(spendKind: kind))
            let request = body()
            check((request["prompt_cache_options"] as? [String: String])?["mode"] == "explicit", "one-shot \(kind) uses selected cache boundary")
            let input = request["input"] as! [[String: Any]]
            let instructions = (input[0]["content"] as! [[String: Any]])[0]
            check(instructions["text"] as? String == "fixture system" && input[0]["role"] as? String == "developer", "instructions retain text and authority")
            let payload = (input[1]["content"] as! [[String: Any]])[0]
            check(payload["text"] as? String == "fixture" && payload["prompt_cache_breakpoint"] == nil, "unique payload preserved without cache-write breakpoint")
            check(request["instructions"] == nil, "instruction not duplicated")
        }
        _ = await run(OpenAICompatibleProvider.openAI, model: "gpt-5.6-terra", frames: [],
                      options: ChatRequestOptions(requestContext: "Today's date: fixture."))
        let chatBody = body()
        check(chatBody["prompt_cache_options"] == nil, "chat keeps growing-prefix implicit caching")
        check(chatBody["instructions"] as? String == "fixture system", "chat instruction prefix remains stable")
        let chatInput = chatBody["input"] as! [[String: Any]]
        check(chatInput.last?["role"] as? String == "developer" && chatInput.last?["content"] as? String == "Today's date: fixture.", "date follows history at developer priority")
        check(chatBody["store"] as? Bool == false, "no server conversation persistence enabled")
        check(chatBody["prompt_cache_retention"] == nil, "no unsupported 24h retention")
        _ = await run(OpenAICompatibleProvider.openAI, model: "gpt-4.1", frames: [],
                      options: ChatRequestOptions(spendKind: .translation, cacheKey: "stable"))
        check(body()["prompt_cache_options"] == nil && body()["instructions"] as? String == "fixture system", "legacy model keeps original schema")
        check(body()["prompt_cache_key"] as? String == "stable", "legacy model routing key stable")
        check(!OpenAIPromptCache.supportsExplicitBreakpoints(model: "gpt-5.60"), "model boundary exact")
        var oneShot: [String: Any] = ["model": "gpt-5.6-sol", "input": [["role": "user", "content": "unique long payload"]]]
        OpenAIPromptCache.apply(to: &oneShot, options: ChatRequestOptions(spendKind: .summary))
        check((oneShot["input"] as! [[String: Any]]).count == 1, "summary without reusable instructions gets no invented prefix")
        let history: [[String: Any]] = [["role": "user", "content": "retained first fact"], ["role": "assistant", "content": String(repeating: "retained detail ", count: 5000)], ["role": "user", "content": "new question"]]
        func datedBody(_ day: String) -> [String: Any] {
            var body: [String: Any] = ["model": "gpt-5.6-sol", "instructions": "unchanged instructions", "input": history]
            OpenAIPromptCache.apply(to: &body, options: ChatRequestOptions(requestContext: day))
            return body
        }
        let firstDate = datedBody("September 24"), nextDate = datedBody("September 25")
        let firstInput = firstDate["input"] as! [[String: Any]], nextInput = nextDate["input"] as! [[String: Any]]
        let beforeDate = try! JSONSerialization.data(withJSONObject: Array(firstInput.dropLast()), options: [.sortedKeys])
        let afterDate = try! JSONSerialization.data(withJSONObject: Array(nextInput.dropLast()), options: [.sortedKeys])
        check(beforeDate == afterDate, "date change preserves complete history prefix byte-for-byte")
        check(beforeDate == (try! JSONSerialization.data(withJSONObject: history, options: [.sortedKeys])), "no history, detail or instruction removed")
        print("Provider accounting contracts: \(checks) passed")
    }
}

// Minimal host seams for exercising the actual ChatService stream loop.
struct ChatMessage { let text: String }
final class ChatStore {}
enum ProviderRegistry {
    static func provider(for id: ProviderID) -> any LLMProvider { AccountingProvider(base: OpenAICompatibleProvider.mistral) }
}
enum BraveSearchService {
    static let toolSpec = ToolSpec(name: "web_search", description: "", parameters: [:])
    static func search(query: String) async throws -> String { "fixture search" }
}
enum WebFetchService {
    static let toolSpec = ToolSpec(name: "web_fetch", description: "", parameters: [:])
    static func fetch(urlString: String) async throws -> String { "retained fixture page" }
}
enum CalendarToolService {
    static func canHandle(_ name: String) -> Bool { false }
    static func statusLine(for call: ToolCall) -> String { "" }
    static func run(_ call: ToolCall) async -> String { "" }
}
enum DocumentToolService {
    static func canHandle(_ name: String) -> Bool { false }
    static func statusLine(for call: ToolCall) -> String { "" }
    static func run(_ call: ToolCall, store: ChatStore) async -> String { "" }
}
enum PlaudToolService {
    static func canHandle(_ name: String) -> Bool { false }
    static func statusLine(for call: ToolCall) -> String { "" }
    static func run(_ call: ToolCall) async -> String { "" }
    static func takePendingAttachments() -> [String] { [] }
}
extension ChatService {
    static func prepare(history: [ChatMessage], summary: String?, store: ChatStore) async throws -> PreparedTurn {
        PreparedTurn(providerID: .mistral, apiKey: "", model: "fixture", systemPrompt: "fixture",
                     options: ChatRequestOptions(tools: [WebFetchService.toolSpec], serverTools: [ServerTool(type: "fixture", parameters: [:])]),
                     maxToolIterations: 1, supportsVision: false, hasDocumentTool: false)
    }
    static func uploadPendingDocuments(in history: [ChatMessage], providerID: ProviderID, apiKey: String,
                                       store: ChatStore, status: (String) -> Void) async -> [ChatMessage] { history }
    static func buildMessages(from history: [ChatMessage], providerID: ProviderID, supportsVision: Bool,
                               hasDocumentTool: Bool, documentsAsText: Bool, store: ChatStore,
                               status: (String) -> Void) async throws -> [LLMMessage] {
        history.map { LLMMessage(role: .user, text: $0.text) }
    }
    static func explainRoutingError(_ error: Error, providerID: ProviderID) -> Error { error }
}
