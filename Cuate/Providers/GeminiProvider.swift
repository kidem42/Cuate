import Foundation

/// Google Gemini API (`generateContent` streaming via SSE) with function calling.
/// The API key is sent in the `x-goog-api-key` header — never as a URL query
/// parameter, where it could leak into logs.
struct GeminiProvider: LLMProvider {
    let providerID: ProviderID = .gemini
    private let baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!

    // MARK: - Chat

    func streamChat(
        messages: [LLMMessage],
        model: String,
        systemPrompt: String?,
        options: ChatRequestOptions,
        apiKey: String
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let url = baseURL
            .appendingPathComponent("models")
            .appendingPathComponent("\(model):streamGenerateContent")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "alt", value: "sse")]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        var contents: [[String: Any]] = []
        for message in messages {
            switch message.role {
            case .tool:
                contents.append([
                    "role": "user",
                    "parts": [[
                        "functionResponse": [
                            "name": message.toolName ?? "tool",
                            "response": ["result": message.text]
                        ]
                    ]]
                ])
            case .assistant where !message.toolCalls.isEmpty:
                var parts: [[String: Any]] = []
                if !message.text.isEmpty {
                    parts.append(["text": message.text])
                }
                for call in message.toolCalls {
                    parts.append([
                        "functionCall": [
                            "name": call.name,
                            "args": call.arguments
                        ]
                    ])
                }
                contents.append(["role": "model", "parts": parts])
            default:
                var parts: [[String: Any]] = []
                if !message.text.isEmpty {
                    parts.append(["text": message.text])
                }
                for image in message.images {
                    parts.append([
                        "inline_data": [
                            "mime_type": image.mimeType,
                            "data": image.base64
                        ]
                    ])
                }
                contents.append([
                    "role": message.role == .assistant ? "model" : "user",
                    "parts": parts
                ])
            }
        }

        var generationConfig: [String: Any] = ["maxOutputTokens": options.maxTokens]
        // Reasoning control differs by generation and MUST NOT be mixed:
        // Gemini 3.x takes thinkingLevel (strings), 2.5 takes thinkingBudget
        // (numbers); sending both is an API error, budget 0 is rejected on Pro.
        if options.reasoning != .auto {
            let m = model.lowercased()
            if m.contains("gemini-3") {
                generationConfig["thinkingConfig"] = [
                    "thinkingLevel": options.reasoning == .fast ? "low" : "high"
                ]
            } else if m.contains("2.5"), options.reasoning == .fast, m.contains("flash") {
                generationConfig["thinkingConfig"] = ["thinkingBudget": 0]
            }
            // 2.5 deep / 2.5-pro fast: dynamic thinking is the default — omit.
        }

        var body: [String: Any] = [
            "contents": contents,
            "generationConfig": generationConfig
        ]
        if let systemPrompt, !systemPrompt.isEmpty {
            body["systemInstruction"] = ["parts": [["text": systemPrompt]]]
        }
        if !options.tools.isEmpty {
            body["tools"] = [[
                "functionDeclarations": options.tools.map { tool in
                    [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parameters
                    ]
                }
            ]]
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }

        let sse = HTTPClient.sseStream(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var pendingCalls: [ToolCall] = []
                var usage = TokenUsage()
                do {
                    for try await payload in sse {
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        // usageMetadata is cumulative and rides on stream chunks;
                        // the final one can be usage-only (no candidates/parts),
                        // so it must be read BEFORE the content guard skips it.
                        if let meta = json["usageMetadata"] as? [String: Any] {
                            let prompt = meta["promptTokenCount"] as? Int ?? 0
                            let cached = meta["cachedContentTokenCount"] as? Int ?? 0
                            usage.inputTokens = max(0, prompt - cached)
                            usage.cacheReadTokens = cached
                            let thoughts = meta["thoughtsTokenCount"] as? Int ?? 0
                            // Gemini API bills thinking at the output rate but
                            // reports it separately from candidatesTokenCount.
                            usage.outputTokens = (meta["candidatesTokenCount"] as? Int ?? 0) + thoughts
                            usage.reasoningTokens = thoughts
                        }
                        guard let candidates = json["candidates"] as? [[String: Any]],
                              let content = candidates.first?["content"] as? [String: Any],
                              let parts = content["parts"] as? [[String: Any]] else { continue }
                        for part in parts {
                            if let text = part["text"] as? String, !text.isEmpty {
                                continuation.yield(.text(text))
                            }
                            if let functionCall = part["functionCall"] as? [String: Any],
                               let name = functionCall["name"] as? String {
                                let args = functionCall["args"] as? [String: Any] ?? [:]
                                let argsJSON = (try? JSONSerialization.data(withJSONObject: args))
                                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                                pendingCalls.append(ToolCall(
                                    id: UUID().uuidString,
                                    name: name,
                                    argumentsJSON: argsJSON
                                ))
                            }
                        }
                    }
                    if !pendingCalls.isEmpty {
                        continuation.yield(.toolCalls(pendingCalls))
                    }
                    if !usage.isEmpty {
                        continuation.yield(.usage(usage))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Models

    func fetchModels(apiKey: String) async throws -> [String] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("models"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "pageSize", value: "200")]

        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let data = try await HTTPClient.json(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["models"] as? [[String: Any]] else {
            throw ProviderError.decoding("unexpected /models payload")
        }

        var ids: [String] = []
        for item in items {
            guard let name = item["name"] as? String else { continue }
            // Keep only models that can generate content (chat).
            if let methods = item["supportedGenerationMethods"] as? [String],
               !methods.contains("generateContent") {
                continue
            }
            let id = name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
            if id.lowercased().contains("embedding") { continue }
            ids.append(id)
        }
        return ids.sorted()
    }
}
