import Foundation

/// Chat provider for OpenAI-compatible APIs: OpenAI, Mistral, DeepSeek.
/// Uses `POST {base}/chat/completions` with SSE streaming, function calling,
/// and `GET {base}/models`.
struct OpenAICompatibleProvider: LLMProvider {
    let providerID: ProviderID
    let baseURL: URL

    static let openAI = OpenAICompatibleProvider(
        providerID: .openai,
        baseURL: URL(string: "https://api.openai.com/v1")!
    )
    static let mistral = OpenAICompatibleProvider(
        providerID: .mistral,
        baseURL: URL(string: "https://api.mistral.ai/v1")!
    )
    static let deepSeek = OpenAICompatibleProvider(
        providerID: .deepseek,
        baseURL: URL(string: "https://api.deepseek.com/v1")!
    )
    static let openRouter = OpenAICompatibleProvider(
        providerID: .openrouter,
        baseURL: URL(string: "https://openrouter.ai/api/v1")!
    )

    /// Builds a request with the Bearer key and any provider-specific headers.
    /// OpenRouter gets an `X-Title` attribution header for its app rankings.
    private func makeRequest(path: String, apiKey: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if providerID == .openrouter {
            request.setValue("AISpotlight", forHTTPHeaderField: "X-Title")
        }
        return request
    }

    // MARK: - Chat

    func streamChat(
        messages: [LLMMessage],
        model: String,
        systemPrompt: String?,
        options: ChatRequestOptions,
        apiKey: String
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        // OpenAI's current primary endpoint is /v1/responses — unlike
        // /v1/chat/completions it supports function tools together with
        // reasoning. Mistral/DeepSeek stay on chat/completions.
        if providerID == .openai {
            return streamResponsesAPI(
                messages: messages,
                model: model,
                systemPrompt: systemPrompt,
                options: options,
                apiKey: apiKey
            )
        }
        var request = makeRequest(path: "chat/completions", apiKey: apiKey)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var apiMessages: [[String: Any]] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            apiMessages.append(["role": "system", "content": systemPrompt])
        }
        for message in messages {
            switch message.role {
            case .tool:
                apiMessages.append([
                    "role": "tool",
                    "tool_call_id": message.toolCallID ?? "",
                    "content": message.text
                ])
            case .assistant where !message.toolCalls.isEmpty:
                var entry: [String: Any] = [
                    "role": "assistant",
                    "tool_calls": message.toolCalls.map { call in
                        [
                            "id": call.id,
                            "type": "function",
                            "function": ["name": call.name, "arguments": call.argumentsJSON]
                        ]
                    }
                ]
                if !message.text.isEmpty { entry["content"] = message.text }
                apiMessages.append(entry)
            default:
                if message.images.isEmpty {
                    apiMessages.append(["role": message.role.rawValue, "content": message.text])
                } else {
                    var parts: [[String: Any]] = []
                    if !message.text.isEmpty {
                        parts.append(["type": "text", "text": message.text])
                    }
                    for image in message.images {
                        parts.append([
                            "type": "image_url",
                            "image_url": ["url": "data:\(image.mimeType);base64,\(image.base64)"]
                        ])
                    }
                    apiMessages.append(["role": message.role.rawValue, "content": parts])
                }
            }
        }

        var body: [String: Any] = [
            "model": model,
            "messages": apiMessages,
            "stream": true,
            "max_tokens": options.maxTokens
        ]
        if !options.tools.isEmpty {
            body["tools"] = options.tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parameters
                    ]
                ]
            }
        }
        // OpenRouter accepts a reasoning-effort knob directly on chat/completions
        // (Mistral/DeepSeek do not). Only sent for models the catalog says
        // support it, so it never reaches a model that would reject it.
        if providerID == .openrouter,
           options.reasoning != .auto,
           options.modelSupportsReasoning {
            body["reasoning"] = ["effort": options.reasoning == .fast ? "low" : "high"]
        }
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }

        let sse = HTTPClient.sseStream(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                // Tool call deltas arrive fragmented — accumulate by index.
                var pendingCalls: [Int: (id: String, name: String, args: String)] = [:]
                do {
                    for try await payload in sse {
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                        // OpenRouter (and some gateways) can surface a mid-stream
                        // error inside a data frame instead of a non-2xx status.
                        if let error = json["error"] as? [String: Any],
                           let message = error["message"] as? String {
                            throw ProviderError.http(status: (error["code"] as? Int) ?? 200, message: message)
                        }

                        guard let choices = json["choices"] as? [[String: Any]],
                              let choice = choices.first else { continue }

                        if let delta = choice["delta"] as? [String: Any] {
                            if let content = delta["content"] as? String, !content.isEmpty {
                                continuation.yield(.text(content))
                            }
                            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                                for fragment in toolCalls {
                                    let index = fragment["index"] as? Int ?? 0
                                    var entry = pendingCalls[index] ?? (id: "", name: "", args: "")
                                    if let id = fragment["id"] as? String { entry.id = id }
                                    if let function = fragment["function"] as? [String: Any] {
                                        if let name = function["name"] as? String { entry.name += name }
                                        if let args = function["arguments"] as? String { entry.args += args }
                                    }
                                    pendingCalls[index] = entry
                                }
                            }
                        }
                    }
                    if !pendingCalls.isEmpty {
                        let calls = pendingCalls.sorted { $0.key < $1.key }.map { _, entry in
                            ToolCall(
                                id: entry.id.isEmpty ? UUID().uuidString : entry.id,
                                name: entry.name,
                                argumentsJSON: entry.args.isEmpty ? "{}" : entry.args
                            )
                        }
                        continuation.yield(.toolCalls(calls))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - OpenAI Responses API

    /// `POST /v1/responses` with SSE streaming. Supports function tools
    /// together with reasoning (the chat/completions limitation doesn't apply).
    private func streamResponsesAPI(
        messages: [LLMMessage],
        model: String,
        systemPrompt: String?,
        options: ChatRequestOptions,
        apiKey: String
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        var request = URLRequest(url: baseURL.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var input: [[String: Any]] = []
        for message in messages {
            switch message.role {
            case .tool:
                input.append([
                    "type": "function_call_output",
                    "call_id": message.toolCallID ?? "",
                    "output": message.text
                ])
            case .assistant where !message.toolCalls.isEmpty:
                if !message.text.isEmpty {
                    input.append([
                        "role": "assistant",
                        "content": [["type": "output_text", "text": message.text]]
                    ])
                }
                for call in message.toolCalls {
                    input.append([
                        "type": "function_call",
                        "call_id": call.id,
                        "name": call.name,
                        "arguments": call.argumentsJSON
                    ])
                }
            case .assistant:
                input.append([
                    "role": "assistant",
                    "content": [["type": "output_text", "text": message.text]]
                ])
            case .user:
                var parts: [[String: Any]] = []
                if !message.text.isEmpty {
                    parts.append(["type": "input_text", "text": message.text])
                }
                for image in message.images {
                    parts.append([
                        "type": "input_image",
                        "image_url": "data:\(image.mimeType);base64,\(image.base64)"
                    ])
                }
                input.append(["role": "user", "content": parts])
            }
        }

        var body: [String: Any] = [
            "model": model,
            "input": input,
            "stream": true,
            "store": false, // don't persist conversations server-side
            "max_output_tokens": options.maxTokens
        ]
        if let systemPrompt, !systemPrompt.isEmpty {
            body["instructions"] = systemPrompt
        }
        if !options.tools.isEmpty {
            // Responses API uses a flat function-tool shape.
            body["tools"] = options.tools.map { tool in
                [
                    "type": "function",
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.parameters
                ]
            }
        }
        if options.reasoning != .auto,
           ModelCapabilities.supportsReasoningControl(provider: .openai, model: model) {
            body["reasoning"] = ["effort": options.reasoning == .fast ? "low" : "high"]
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }

        let sse = HTTPClient.sseStream(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var pendingCalls: [ToolCall] = []
                do {
                    for try await payload in sse {
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = json["type"] as? String else { continue }

                        switch type {
                        case "response.output_text.delta":
                            if let delta = json["delta"] as? String, !delta.isEmpty {
                                continuation.yield(.text(delta))
                            }
                        case "response.output_item.done":
                            // Complete function call arrives assembled here.
                            if let item = json["item"] as? [String: Any],
                               item["type"] as? String == "function_call",
                               let name = item["name"] as? String {
                                pendingCalls.append(ToolCall(
                                    id: item["call_id"] as? String ?? UUID().uuidString,
                                    name: name,
                                    argumentsJSON: item["arguments"] as? String ?? "{}"
                                ))
                            }
                        case "response.failed", "response.incomplete":
                            if let response = json["response"] as? [String: Any],
                               let error = response["error"] as? [String: Any],
                               let message = error["message"] as? String {
                                throw ProviderError.http(status: 200, message: message)
                            }
                        case "error":
                            let message = json["message"] as? String ?? "Unknown streaming error"
                            throw ProviderError.http(status: 200, message: message)
                        default:
                            break
                        }
                    }
                    if !pendingCalls.isEmpty {
                        continuation.yield(.toolCalls(pendingCalls))
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
        let request = makeRequest(path: "models", apiKey: apiKey)

        let data = try await HTTPClient.json(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else {
            throw ProviderError.decoding("unexpected /models payload")
        }

        var ids: [String] = []
        for item in items {
            guard let id = item["id"] as? String else { continue }
            // Mistral advertises capabilities — keep chat-capable models only.
            if let caps = item["capabilities"] as? [String: Any],
               let chat = caps["completion_chat"] as? Bool, chat == false {
                continue
            }
            if isLikelyChatModel(id) {
                ids.append(id)
            }
        }
        return ids.sorted()
    }

    /// Filters out obviously non-chat models (embeddings, audio, images, moderation).
    private func isLikelyChatModel(_ id: String) -> Bool {
        let lower = id.lowercased()
        let excluded = [
            "embed", "whisper", "tts", "dall-e", "image", "moderation",
            "transcribe", "audio", "realtime", "ocr", "voxtral", "davinci",
            "babbage", "codestral-embed"
        ]
        return !excluded.contains { lower.contains($0) }
    }

    // MARK: - Model catalog (OpenRouter)

    /// Fetches the full model catalog with per-model capabilities, parsed from
    /// OpenRouter's richer `/models` payload (`architecture.input_modalities`,
    /// `supported_parameters`). Unfiltered on purpose: the catalog is used to
    /// validate whatever slug the user types, so it must accept every model
    /// OpenRouter serves. The key is optional (the endpoint is public).
    func fetchModelCatalog(apiKey: String?) async throws -> [ModelInfo] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        if providerID == .openrouter {
            request.setValue("AISpotlight", forHTTPHeaderField: "X-Title")
        }

        let data = try await HTTPClient.json(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else {
            throw ProviderError.decoding("unexpected /models payload")
        }

        var catalog: [ModelInfo] = []
        for item in items {
            guard let id = item["id"] as? String else { continue }

            let inputModalities = (item["architecture"] as? [String: Any])?["input_modalities"] as? [String] ?? []
            let params = item["supported_parameters"] as? [String] ?? []
            catalog.append(ModelInfo(
                id: id,
                supportsVision: inputModalities.contains("image"),
                supportsTools: params.contains("tools"),
                supportsReasoning: params.contains("reasoning"),
                supportedParameters: params
            ))
        }
        return catalog
    }

    // MARK: - Key validation

    /// Verifies the API key with a cheap authenticated call. OpenRouter's
    /// `/models` is public, so a key check there would pass even with a bad key;
    /// `/api/v1/key` requires a valid key and returns its limits/usage.
    func validateKey(apiKey: String) async throws {
        if providerID == .openrouter {
            let request = makeRequest(path: "key", apiKey: apiKey)
            _ = try await HTTPClient.json(request)
        } else {
            _ = try await fetchModels(apiKey: apiKey)
        }
    }
}
