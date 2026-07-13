import Foundation

// MARK: - Provider identifiers

enum ProviderID: String, CaseIterable, Codable, Identifiable {
    case anthropic
    case openai
    case gemini
    case mistral
    case deepseek

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openai: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .mistral: return "Mistral"
        case .deepseek: return "DeepSeek"
        }
    }

    /// Whether the provider's chat API accepts image content blocks.
    var supportsVision: Bool {
        switch self {
        case .deepseek: return false
        default: return true
        }
    }

    /// Short badge label used for the provider icon (no logo assets needed).
    var badgeLetter: String {
        switch self {
        case .anthropic: return "C"
        case .openai: return "AI"
        case .gemini: return "G"
        case .mistral: return "M"
        case .deepseek: return "DS"
        }
    }

    /// Brand-ish accent used behind the badge letter.
    var brandColorHex: UInt {
        switch self {
        case .anthropic: return 0xD4A27F // Claude clay
        case .openai: return 0x10A37F    // OpenAI green
        case .gemini: return 0x4285F4    // Google blue
        case .mistral: return 0xFA520F   // Mistral orange
        case .deepseek: return 0x4D6BFE  // DeepSeek blue
        }
    }

    /// Page where the user can create an API key for this provider.
    var apiKeyURL: URL {
        switch self {
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")!
        case .openai: return URL(string: "https://platform.openai.com/api-keys")!
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")!
        case .mistral: return URL(string: "https://console.mistral.ai/api-keys")!
        case .deepseek: return URL(string: "https://platform.deepseek.com/api_keys")!
        }
    }
}

/// Providers that can transcribe audio.
enum STTProviderID: String, CaseIterable, Codable, Identifiable {
    case mistral
    case openai

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mistral: return "Mistral (Voxtral)"
        case .openai: return "OpenAI"
        }
    }

    var defaultModel: String {
        switch self {
        case .mistral: return "voxtral-mini-latest"
        case .openai: return "gpt-4o-transcribe"
        }
    }

    /// The chat provider whose API key is reused for transcription.
    var keyProvider: ProviderID {
        switch self {
        case .mistral: return .mistral
        case .openai: return .openai
        }
    }
}

// MARK: - Messages

struct LLMImage {
    let mimeType: String
    let base64: String
}

struct LLMMessage {
    enum Role: String {
        case user
        case assistant
        case tool
    }

    let role: Role
    let text: String
    var images: [LLMImage] = []
    /// Tool calls the assistant requested (assistant role only).
    var toolCalls: [ToolCall] = []
    /// For `.tool` role: which call this result answers.
    var toolCallID: String?
    /// For `.tool` role: the tool's name (Gemini requires it in the response).
    var toolName: String?
}

// MARK: - Tools

/// A function tool the model may call (JSON-schema parameters).
struct ToolSpec {
    let name: String
    let description: String
    let parameters: [String: Any]
}

/// A concrete call the model requested.
struct ToolCall {
    let id: String
    let name: String
    /// Raw JSON string with the call arguments.
    let argumentsJSON: String

    var arguments: [String: Any] {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }
}

/// Events produced while streaming a single model turn.
enum LLMStreamEvent {
    case text(String)
    /// Emitted once at the end of the turn when the model requested tools.
    case toolCalls([ToolCall])
}

/// Reasoning depth preference, mapped to provider-specific parameters.
enum ReasoningMode: String, CaseIterable, Codable, Identifiable {
    case auto
    case fast
    case deep

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return L("reasoning.auto")
        case .fast: return L("reasoning.fast")
        case .deep: return L("reasoning.deep")
        }
    }
}

/// Per-request options resolved from settings.
struct ChatRequestOptions {
    var maxTokens: Int = 8192
    var reasoning: ReasoningMode = .auto
    var tools: [ToolSpec] = []
}

// MARK: - Protocols

protocol LLMProvider {
    var providerID: ProviderID { get }

    /// Streams one model turn: text chunks and, possibly, tool call requests.
    func streamChat(
        messages: [LLMMessage],
        model: String,
        systemPrompt: String?,
        options: ChatRequestOptions,
        apiKey: String
    ) -> AsyncThrowingStream<LLMStreamEvent, Error>

    /// Fetches the list of available chat model identifiers.
    func fetchModels(apiKey: String) async throws -> [String]
}

// MARK: - Model capabilities

enum ModelCapabilities {
    /// Whether the reasoning selector has any effect for this provider+model.
    static func supportsReasoningControl(provider: ProviderID, model: String) -> Bool {
        let m = model.lowercased()
        switch provider {
        case .openai:
            return m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4") || m.contains("gpt-5")
        case .anthropic:
            return m.contains("opus-4-6") || m.contains("opus-4-7") || m.contains("opus-4-8")
                || m.contains("sonnet-4-6") || m.contains("sonnet-5")
                || m.contains("fable") || m.contains("mythos")
        case .gemini:
            return m.contains("2.5") || m.contains("gemini-3")
        case .mistral, .deepseek:
            return false
        }
    }
}

// MARK: - Errors

enum ProviderError: LocalizedError {
    case missingAPIKey(ProviderID)
    case badResponse
    case http(status: Int, message: String)
    case decoding(String)
    case visionUnsupported(ProviderID)
    case transcriptionUnavailable

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "No API key for \(provider.displayName). Add one in Settings."
        case .badResponse:
            return "The server returned an unexpected response."
        case .http(let status, let message):
            return "API error (HTTP \(status)): \(message)"
        case .decoding(let details):
            return "Failed to decode the response: \(details)"
        case .visionUnsupported(let provider):
            return "\(provider.displayName) does not support images. Configure a Mistral key to enable OCR fallback, or switch the chat provider."
        case .transcriptionUnavailable:
            return "No transcription provider configured. Add a Mistral or OpenAI key in Settings."
        }
    }

    /// Builds an HTTP error with a sanitized, human-readable message.
    /// Extracts `error.message`-style fields from a JSON body and truncates it,
    /// so raw response dumps (and anything sensitive in them) never reach the UI.
    static func fromHTTP(status: Int, body: Data) -> ProviderError {
        var message = "Request failed."
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let msg = error["message"] as? String {
                message = msg
            } else if let msg = json["message"] as? String {
                message = msg
            } else if let detail = json["detail"] as? String {
                message = detail
            }
        } else if let text = String(data: body, encoding: .utf8), !text.isEmpty {
            message = text
        }
        if message.count > 300 {
            message = String(message.prefix(300)) + "…"
        }
        return .http(status: status, message: message)
    }
}

// MARK: - HTTP helpers

enum HTTPClient {
    /// Shared session; ephemeral so responses are never written to a shared URL cache on disk.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    static func json(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.fromHTTP(status: http.statusCode, body: data)
        }
        return data
    }

    /// Performs a request and yields the `data:` payloads of an SSE stream.
    /// Terminates on `[DONE]` or end of stream. On a non-2xx status the body
    /// is collected and surfaced as a sanitized error.
    static func sseStream(_ request: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw ProviderError.badResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        throw ProviderError.fromHTTP(status: http.statusCode, body: body)
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        if !payload.isEmpty {
                            continuation.yield(payload)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
