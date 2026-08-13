import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Provider identifiers

enum ProviderID: String, CaseIterable, Codable, Identifiable {
    case anthropic
    case openai
    case gemini
    case mistral
    case deepseek
    case openrouter
    case kimi
    case ollama
    case hermes // agent gateway (Addons/HermesAddon), not a conventional provider

    var id: String { rawValue }

    /// Local providers run on the user's machine (Ollama and other
    /// OpenAI-compatible servers) — no API key, availability is gated on
    /// endpoint reachability instead of a stored key.
    var isLocal: Bool { self == .ollama }

    /// Agent gateways (Hermes; OpenClaw later) — the third provider class.
    /// Never offered in the provider switcher or the common key list: the
    /// addon owns configuration, the role switcher owns selection, and the
    /// registry entry exists only as the HTTP fallback path.
    var isAgent: Bool { self == .hermes }

    /// Cloud providers need a Keychain API key; local ones do not. Agent
    /// tokens live in the addon's aux Keychain slot, not the provider slot.
    var requiresAPIKey: Bool { !isLocal && !isAgent }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openai: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .mistral: return "Mistral"
        case .deepseek: return "DeepSeek"
        case .openrouter: return "OpenRouter"
        case .kimi: return "Kimi (Moonshot)"
        case .ollama: return "Ollama (Local)"
        case .hermes: return "Hermes Agent"
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
        case .ollama: return "O"
        case .hermes: return "H"
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
        case .ollama: return 0x2B2B2B    // Ollama charcoal
        case .hermes: return 0x0EA5A4    // Hermes teal (Nous palette)
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
        // Local: no key page — link to the install/download page instead.
        case .ollama: return URL(string: "https://ollama.com/download")!
        // Agent: the key comes from the gateway's own .env, docs are the
        // closest thing to a "key page".
        case .hermes: return URL(string: "https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server")!
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
        case .ollama:
            // Common local defaults, best first — matched against the models the
            // user has actually pulled (falls back to the first installed one).
            return ["gemma3", "llama3.2", "qwen2.5", "mistral"]
        case .hermes:
            // Agent: model selection belongs to the gateway (the addon's
            // model lock), not to the common picker.
            return []
        }
    }

    /// Preferred models for the dictation cleanup pass, best first — matched
    /// the same way as `preferredDefaultModels`, against the provider's live
    /// list.
    ///
    /// Cleanup is a trivial task (fillers, punctuation, a translation at most)
    /// that runs once per PHRASE and strictly in order, so latency and price
    /// bind and a frontier model buys nothing: these are each provider's small
    /// tier, cheapest first. Chat defaults deliberately differ — there the same
    /// providers list their flagship first.
    ///
    /// Prices below are $ per 1M input/output tokens, from each provider's own
    /// pricing docs (checked 2026-08-12). They are a comment, not a contract:
    /// the resolver matches these ids against the provider's LIVE model list,
    /// so an id a provider stops serving is skipped rather than sent.
    var cleanupPreferredModels: [String] {
        switch self {
        case .openai:
            // luna (0.20/1.20) is the current generation's small tier, sold for
            // exactly this shape of work ("cost-sensitive, high-volume") and
            // able to turn reasoning off entirely. The fallbacks are the older
            // non-reasoning small models — cheaper on paper, but the whole spread
            // here is under a dollar a year at dictation volume, so latency
            // decides, not price.
            return ["gpt-5.6-luna", "gpt-4.1-nano", "gpt-4o-mini", "gpt-5-nano"]
        case .anthropic:
            // 1.00/5.00 — the cheapest and fastest Claude (Opus 5 is 5.00/25.00).
            return ["claude-haiku-4-5"]
        case .gemini:
            // Flash-Lite is the budget tier; 2.5 Flash-Lite is 0.10/0.40.
            return ["gemini-flash-lite-latest", "gemini-3.5-flash-lite", "gemini-2.5-flash-lite", "gemini-flash-latest"]
        case .mistral:
            // 0.06/0.18 — cheaper than both Ministral tiers (8B is 0.15/0.15).
            return ["mistral-small-latest", "ministral-3b-latest", "ministral-8b-latest"]
        case .deepseek:
            // 0.14/0.28 — half of deepseek-chat (0.28/0.42).
            return ["deepseek-v4-flash", "deepseek-chat"]
        case .openrouter:
            return []
        case .kimi:
            // 0.95/4.00 — the cheapest general Kimi (K3 is 3.00/15.00), but a
            // whole order of magnitude above OpenAI's and Mistral's small tiers.
            return ["kimi-k2.6"]
        case .ollama:
            // Small local models: free and instant, but the pull has to exist —
            // `cleanupCheapMarkers` catches any other small tag the user has.
            return ["gemma3:1b", "llama3.2:1b", "qwen2.5:3b", "gemma3", "llama3.2"]
        case .hermes:
            return []
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
    /// USD per ONE token (OpenRouter reports prices in that unit), captured
    /// from the catalog so aggregator models get exact per-model pricing.
    /// nil for catalogs that don't carry prices (or older cached entries).
    var promptPricePerToken: Double?
    var completionPricePerToken: Double?
}

/// Providers that can transcribe audio.
/// OCR backends. `apple` is native on-device (Vision, no key); `mistral` is
/// the cloud document model (layout-aware Markdown).
enum OCRProviderID: String, CaseIterable, Codable, Identifiable {
    case apple
    case mistral

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: return "Apple (on-device)"
        case .mistral: return "Mistral OCR"
        }
    }
}

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

extension LLMImage {
    /// Longest side beyond which cloud providers downscale server-side anyway
    /// (Anthropic caps at 1568px; OpenAI/Gemini tile below that). Pixels above
    /// this never reach the model — they only cost upload bytes and latency.
    private static let maxModelDimension = 1568
    /// Payloads at or under this many bytes pass through un-recoded when the
    /// pixels already fit — recompression would only lose quality.
    private static let maxPassthroughBytes = 4 << 20

    /// Wire image for cloud providers: downscaled to fit `maxModelDimension`
    /// and re-encoded (JPEG for opaque images, PNG when alpha is present).
    /// Small-enough images, non-images, GIFs (animation would be flattened)
    /// and anything undecodable pass through unchanged. The Hermes addon
    /// goes through here too (since 4.4): original-size screenshots blew
    /// through reverse-proxy body limits as opaque 413s, and the gateway's
    /// model downscales to the same ceiling server-side anyway.
    static func forModel(mimeType: String, base64: String) -> LLMImage {
        let original = LLMImage(mimeType: mimeType, base64: base64)
        guard mimeType.hasPrefix("image"), mimeType != "image/gif",
              let data = Data(base64Encoded: base64),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return original }

        let fitsPixels = max(width, height) <= maxModelDimension
        if fitsPixels && data.count <= maxPassthroughBytes { return original }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxModelDimension,
            kCGImageSourceCreateThumbnailWithTransform: true, // bake EXIF orientation
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
        else { return original }

        let hasAlpha: Bool
        switch scaled.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
        default: hasAlpha = true
        }
        let encoded = NSMutableData()
        let type: UTType = hasAlpha ? .png : .jpeg
        guard let destination = CGImageDestinationCreateWithData(encoded, type.identifier as CFString, 1, nil)
        else { return original }
        let encodeOptions: [CFString: Any] = hasAlpha
            ? [:]
            : [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(destination, scaled, encodeOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination), encoded.length > 0 else { return original }
        // Recode of an already-fitting (but heavy) image must actually shrink
        // it; a downscale is kept regardless — fewer pixels is the point.
        guard !fitsPixels || encoded.length < data.count else { return original }
        return LLMImage(
            mimeType: hasAlpha ? "image/png" : "image/jpeg",
            base64: (encoded as Data).base64EncodedString()
        )
    }
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

/// Token counts reported by a provider for one model turn. Field semantics
/// are normalized across providers (each provider maps its own names here):
/// `inputTokens` is the UNCACHED input; cache traffic is split out because it
/// bills at different rates (Anthropic: write ×1.25, read ×0.1; DeepSeek:
/// hit ≈ 1/50 of miss). `reasoningTokens` are informational — providers that
/// report them (OpenAI, Gemini) already include them in `outputTokens`.
struct TokenUsage {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    var reasoningTokens = 0

    var isEmpty: Bool {
        inputTokens == 0 && outputTokens == 0 && cacheReadTokens == 0
            && cacheWriteTokens == 0 && reasoningTokens == 0
    }

    /// Sums two turns — used when an agentic loop makes several model calls
    /// within one user-visible turn.
    func merged(with other: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: inputTokens + other.inputTokens,
            outputTokens: outputTokens + other.outputTokens,
            cacheReadTokens: cacheReadTokens + other.cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens + other.cacheWriteTokens,
            reasoningTokens: reasoningTokens + other.reasoningTokens
        )
    }
}

/// Events produced while streaming a single model turn.
enum LLMStreamEvent {
    case text(String)
    /// Emitted once at the end of the turn when the model requested tools.
    case toolCalls([ToolCall])
    /// Emitted once per model call, right before the stream finishes, when the
    /// provider reported token usage. Absent on interrupted streams — callers
    /// fall back to an estimate.
    case usage(TokenUsage)
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
    /// Mechanical rewrites (dictation cleanup) want no reasoning at all: the
    /// thinking tokens cost latency on a pass that runs once per phrase and
    /// buys nothing on "strip the fillers, add the commas". Honored only where
    /// the model documents an off switch (see `supportsNoReasoning`);
    /// elsewhere the request falls back to the lowest effort it does accept.
    var preferNoReasoning: Bool = false
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
        case .mistral, .deepseek, .openrouter, .kimi, .ollama, .hermes:
            return false
        }
    }

    /// Whether the model documents `effort: "none"` — reasoning fully off, not
    /// merely shallow. Only OpenAI's 5.6 generation states it (luna's model
    /// page: "none, low, medium (default), high, xhigh, max"); everything else
    /// gets the lowest effort it accepts instead of a value it would reject.
    static func supportsNoReasoning(provider: ProviderID, model: String) -> Bool {
        provider == .openai && model.lowercased().contains("gpt-5.6")
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
