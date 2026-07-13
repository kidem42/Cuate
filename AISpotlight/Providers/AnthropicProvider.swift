import Foundation

/// Anthropic Messages API (`POST /v1/messages`) with SSE streaming and tool use.
struct AnthropicProvider: LLMProvider {
    let providerID: ProviderID = .anthropic
    private let baseURL = URL(string: "https://api.anthropic.com/v1")!
    private let apiVersion = "2023-06-01"

    // MARK: - Chat

    func streamChat(
        messages: [LLMMessage],
        model: String,
        systemPrompt: String?,
        options: ChatRequestOptions,
        apiKey: String
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        var request = URLRequest(url: baseURL.appendingPathComponent("messages"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")

        var apiMessages: [[String: Any]] = []
        for message in messages {
            switch message.role {
            case .tool:
                // Tool results are user-role content blocks in the Anthropic API.
                apiMessages.append([
                    "role": "user",
                    "content": [[
                        "type": "tool_result",
                        "tool_use_id": message.toolCallID ?? "",
                        "content": message.text
                    ]]
                ])
            case .assistant where !message.toolCalls.isEmpty:
                var blocks: [[String: Any]] = []
                if !message.text.isEmpty {
                    blocks.append(["type": "text", "text": message.text])
                }
                for call in message.toolCalls {
                    blocks.append([
                        "type": "tool_use",
                        "id": call.id,
                        "name": call.name,
                        "input": call.arguments
                    ])
                }
                apiMessages.append(["role": "assistant", "content": blocks])
            default:
                if message.images.isEmpty {
                    apiMessages.append(["role": message.role.rawValue, "content": message.text])
                } else {
                    var blocks: [[String: Any]] = []
                    for image in message.images {
                        blocks.append([
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": image.mimeType,
                                "data": image.base64
                            ]
                        ])
                    }
                    if !message.text.isEmpty {
                        blocks.append(["type": "text", "text": message.text])
                    }
                    apiMessages.append(["role": message.role.rawValue, "content": blocks])
                }
            }
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": min(options.maxTokens, Self.maxTokensCap(for: model)),
            "messages": apiMessages,
            "stream": true
        ]
        if let systemPrompt, !systemPrompt.isEmpty {
            // Long system prompts (summaries, memory) benefit from prompt caching.
            if systemPrompt.count > 8000 {
                body["system"] = [[
                    "type": "text",
                    "text": systemPrompt,
                    "cache_control": ["type": "ephemeral"]
                ]]
            } else {
                body["system"] = systemPrompt
            }
        }
        if !options.tools.isEmpty {
            body["tools"] = options.tools.map { tool in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": tool.parameters
                ]
            }
        }
        // Reasoning: adaptive thinking on modern Claude models.
        if options.reasoning != .auto,
           ModelCapabilities.supportsReasoningControl(provider: .anthropic, model: model) {
            if options.reasoning == .deep {
                body["thinking"] = ["type": "adaptive"]
                body["output_config"] = ["effort": "high"]
            } else {
                body["output_config"] = ["effort": "low"]
            }
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }

        let sse = HTTPClient.sseStream(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var pendingCalls: [Int: (id: String, name: String, args: String)] = [:]
                do {
                    for try await payload in sse {
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = json["type"] as? String else { continue }

                        switch type {
                        case "content_block_start":
                            if let index = json["index"] as? Int,
                               let block = json["content_block"] as? [String: Any],
                               block["type"] as? String == "tool_use" {
                                pendingCalls[index] = (
                                    id: block["id"] as? String ?? UUID().uuidString,
                                    name: block["name"] as? String ?? "",
                                    args: ""
                                )
                            }
                        case "content_block_delta":
                            guard let delta = json["delta"] as? [String: Any] else { continue }
                            if delta["type"] as? String == "text_delta",
                               let text = delta["text"] as? String, !text.isEmpty {
                                continuation.yield(.text(text))
                            } else if delta["type"] as? String == "input_json_delta",
                                      let index = json["index"] as? Int,
                                      let partial = delta["partial_json"] as? String {
                                pendingCalls[index]?.args += partial
                            }
                        case "error":
                            if let error = json["error"] as? [String: Any],
                               let message = error["message"] as? String {
                                throw ProviderError.http(status: 200, message: message)
                            }
                        default:
                            break
                        }
                    }
                    if !pendingCalls.isEmpty {
                        let calls = pendingCalls.sorted { $0.key < $1.key }.map { _, entry in
                            ToolCall(
                                id: entry.id,
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

    /// Output-token ceilings differ per model generation — exceeding them is a 400.
    private static func maxTokensCap(for model: String) -> Int {
        let m = model.lowercased()
        if m.contains("claude-3-haiku") { return 4096 }
        if m.contains("claude-3-5") || m.contains("claude-3-7") { return 8192 }
        if m.contains("opus-4-0") || m.contains("opus-4-1") || m.contains("claude-opus-4-2025") { return 32000 }
        if m.contains("haiku-4-5") { return 64000 }
        return 128_000 // modern models (Opus 4.5+, Sonnet 4.5+, Fable/Mythos 5)
    }

    // MARK: - Models

    func fetchModels(apiKey: String) async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")

        let data = try await HTTPClient.json(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else {
            throw ProviderError.decoding("unexpected /models payload")
        }
        return items.compactMap { $0["id"] as? String }
    }
}
