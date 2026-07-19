import Foundation

// MARK: - Provider identifiers

enum ProviderID: String, CaseIterable, Codable, Identifiable {
    case anthropic
    case openai
    case gemini
    case mistral
    case deepseek
    case openrouter
    case kimi

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openai: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .mistral: return "Mistral"
        case .deepseek: return "DeepSeek"
        case .openrouter: return "OpenRouter"
        case .kimi: return "Kimi (Moonshot)"
        }
    }

    /// Whether the user types a model slug freely (OpenRouter aggregates 300+
    /// models from many vendors) instead of picking from a fetched dropdown.
    var usesManualModelEntry: Bool {
        self == .openrouter
    }

    /// Coarse per-provider vision default. For OpenRouter, vision is decided
    /// per-model from the `/models` catalog (see `ModelInfo`), not here.
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
        case .openrouter: return "OR"
        case .kimi: return "K"
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
        case .openrouter: return 0x6467F2 // OpenRouter indigo
        case .kimi: return 0x16191E      // Kimi charcoal
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
        case .openrouter: return URL(string: "https://openrouter.ai/keys")!
        case .kimi: return URL(string: "https://platform.moonshot.ai/console/api-keys")!
        }
    }

    /// Catalog page where the user browses model slugs to paste into the field
    /// (OpenRouter only — the others use a fetched dropdown).
    var modelCatalogURL: URL? {
        switch self {
        case .openrouter: return URL(string: "https://openrouter.ai/models")!
        default: return nil
        }
    }

    /// Preferred default chat models per provider, best first. When a key is
    /// saved we fetch the live model list and auto-select the first of these
    /// the provider actually serves — matched exactly, or as the prefix of a
    /// dated snapshot id (e.g. "claude-sonnet-5" matches
    /// "claude-sonnet-5-20250929"). The lists favor rolling "-latest" aliases
    /// and long-lived model families so they keep resolving as providers ship
    /// new versions; if none match, the first model in the list is used.
    var preferredDefaultModels: [String] {
        switch self {
        case .openai:
            return ["chat-latest"]
        case .anthropic:
            return ["claude-sonnet-5", "claude-opus-4-8", "claude-sonnet-4-5", "claude-haiku-4-5"]
        case .gemini:
            return ["gemini-flash-latest", "gemini-2.0-flash", "gemini-2.5-flash", "gemini-1.5-flash"]
        case .mistral:
            return ["mistral-large-latest", "mistral-medium-latest", "mistral-small-latest"]
        case .deepseek:
            return ["deepseek-chat", "deepseek-reasoner"]
        case .openrouter:
            // OpenRouter's model set is user-typed (see `usesManualModelEntry`),
            // so there is no auto-selected default from a fetched list.
            return []
        case .kimi:
            return ["kimi-k3", "kimi-k2.6", "kimi-k2.7-code"]
        }
    }
}

// MARK: - Model catalog metadata

/// Per-model capabilities, parsed from a provider's model catalog. Used for
/// aggregators (OpenRouter) where capabilities vary model-to-model and cannot
/// be inferred from the `ProviderID` alone.
///
/// `supportedParameters` keeps the provider's raw tunable-parameter list (e.g.
/// "temperature", "top_p", "reasoning", "tools") so a future capability-aware
/// "advanced parameters" UI can be built from the cache without re-fetching.
/// The three booleans are the subset the app acts on today.
struct ModelInfo: Codable, Equatable {
    let id: String
    var supportsVision: Bool
    var supportsTools: Bool
    var supportsReasoning: Bool
    var supportedParameters: [String] = []
}

/// Providers that can transcribe audio.
enum STTProviderID: String, CaseIterable, Codable, Identifiable {
    case mistral
    case openai
    case deepgram

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mistral: return "Mistral (Voxtral)"
        case .openai: return "OpenAI"
        case .deepgram: return "Deepgram"
        }
    }

    var defaultModel: String {
        switch self {
        case .mistral: return "voxtral-mini-latest"
        case .openai: return "gpt-4o-transcribe"
        case .deepgram: return "nova-3"
        }
    }

    /// Whether a usable API key is configured for this STT provider.
    /// Mistral/OpenAI reuse their chat-provider key; Deepgram is STT-only
    /// and has its own key slot (`APIKeyStore.AuxKey.deepgram`).
    /// Uses the cached presence check — safe to call from SwiftUI bodies.
    var hasKey: Bool {
        switch self {
        case .mistral: return APIKeyStore.hasKey(for: .mistral)
        case .openai: return APIKeyStore.hasKey(for: .openai)
        case .deepgram: return APIKeyStore.hasKey(aux: .deepgram)
        }
    }

    var apiKey: String? {
        switch self {
        case .mistral: return APIKeyStore.key(for: .mistral)
        case .openai: return APIKeyStore.key(for: .openai)
        case .deepgram: return APIKeyStore.key(aux: .deepgram)
        }
    }

    /// Page where the user can create an API key for this provider.
    var apiKeyURL: URL {
        switch self {
        case .mistral: return ProviderID.mistral.apiKeyURL
        case .openai: return ProviderID.openai.apiKeyURL
        case .deepgram: return URL(string: "https://console.deepgram.com/")!
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
    /// Whether the selected model honors a reasoning-effort control. Resolved
    /// by the caller (on the main actor, where the model catalog lives) so the
    /// provider layer never has to reach into app state.
    var modelSupportsReasoning: Bool = false
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

    /// Verifies an API key with a cheap authenticated call, throwing on failure.
    func validateKey(apiKey: String) async throws
}

extension LLMProvider {
    /// Default: a valid key can list models. Providers whose `/models` is public
    /// (OpenRouter) override this with an endpoint that actually requires a key.
    func validateKey(apiKey: String) async throws {
        _ = try await fetchModels(apiKey: apiKey)
    }
}

// MARK: - Model capabilities

enum ModelCapabilities {
    /// Whether the reasoning selector has any effect for this provider+model.
    /// For OpenRouter the answer comes from the fetched model catalog, not from
    /// the slug, so callers there consult `AppSettings.openRouterModelInfo`
    /// instead of this string-based heuristic (which returns false).
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
        case .mistral, .deepseek, .openrouter, .kimi:
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
            } else if let error = json["error"] as? String {
                message = error
            } else if let msg = json["message"] as? String {
                message = msg
            } else if let detail = json["detail"] as? String {
                message = detail
            } else if let msg = json["err_msg"] as? String {
                // Deepgram's error shape: {"err_code": ..., "err_msg": ...}
                message = msg
            }
        } else if let text = String(data: body, encoding: .utf8), !text.isEmpty {
            message = text
        }
        if message.count > 600 {
            message = String(message.prefix(600)) + "…"
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
