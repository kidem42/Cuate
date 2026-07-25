import Foundation
import AVFoundation

/// Speech-to-text via provider APIs.
/// Mistral (Voxtral) and OpenAI share the same OpenAI-style
/// `POST /v1/audio/transcriptions` multipart endpoint; Deepgram uses its
/// own `POST /v1/listen` with a raw binary body.
enum TranscriptionService {

    /// Transcribes the audio file using the configured STT provider.
    /// Falls back to any STT provider that has a key if the preferred one doesn't.
    @MainActor
    static func transcribe(audioURL: URL) async throws -> String {
        let settings = AppSettings.shared
        let preferred = settings.sttProvider

        // Key lookups below are cache-only (never a securityd round trip on the
        // main actor) — make sure the cache is filled first.
        await APIKeyStore.warmIfNeeded()
        let candidates: [STTProviderID] = [preferred] + STTProviderID.allCases.filter { $0 != preferred }
        guard let provider = candidates.first(where: { $0.hasKey }),
              let apiKey = provider.apiKey else {
            throw ProviderError.transcriptionUnavailable
        }

        let model = settings.sttModel(for: provider)
        // Off the main thread: a minutes-long recording is megabytes, and the
        // module defaults to MainActor — an unannotated read would block UI.
        let audioData = try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: audioURL)
        }.value

        let text: String
        switch provider {
        case .mistral, .openai:
            text = try await transcribeOpenAIStyle(
                provider: provider, apiKey: apiKey, model: model,
                audioData: audioData, filename: audioURL.lastPathComponent
            )
        case .deepgram:
            text = try await transcribeDeepgram(apiKey: apiKey, model: model, audioData: audioData)
        }

        // STT bills per audio minute — read the real duration off the asset.
        let seconds = (try? await AVURLAsset(url: audioURL).load(.duration).seconds) ?? 0
        if seconds > 0 {
            let minutes = seconds / 60
            SpendStore.shared.record(
                kind: .stt, provider: provider.rawValue, model: model,
                units: minutes,
                costUSD: PricingCatalog.sttPerMinute[provider].map { $0 * minutes }
            )
        }
        return text
    }

    // MARK: - Connection pre-warm

    /// Fire-and-forget TCP+TLS warm-up to the active STT provider's host,
    /// called when dictation starts recording. The first transcription request
    /// then rides an already-open connection — DNS + TCP + TLS (~200–500 ms)
    /// happen while the user is still speaking, instead of being added to the
    /// first phrase's insertion latency. A cheap unauthenticated GET to the
    /// API root is enough; the response (typically 401/404) is discarded —
    /// only the pooled connection in `HTTPClient.session` matters.
    static func prewarmConnection() {
        let preferred = AppSettings.shared.sttProvider
        let candidates: [STTProviderID] = [preferred] + STTProviderID.allCases.filter { $0 != preferred }
        guard let provider = candidates.first(where: { $0.hasKey }) else { return }
        let host: String
        switch provider {
        case .mistral: host = "https://api.mistral.ai/v1/models"
        case .openai: host = "https://api.openai.com/v1/models"
        case .deepgram: host = "https://api.deepgram.com/v1/projects"
        }
        var request = URLRequest(url: URL(string: host)!)
        request.timeoutInterval = 5
        Task.detached(priority: .utility) {
            _ = try? await HTTPClient.session.data(for: request)
        }
    }

    // MARK: - OpenAI-style multipart (Mistral, OpenAI)

    /// nonisolated: multipart assembly copies the audio bytes — keep it off
    /// the main actor (which is this module's default isolation).
    private nonisolated static func transcribeOpenAIStyle(
        provider: STTProviderID, apiKey: String, model: String,
        audioData: Data, filename: String
    ) async throws -> String {
        let endpoint: URL
        switch provider {
        case .mistral:
            endpoint = URL(string: "https://api.mistral.ai/v1/audio/transcriptions")!
        default:
            endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        appendField(name: "model", value: model)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let data = try await HTTPClient.json(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw ProviderError.decoding("no `text` in transcription response")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Deepgram

    /// `POST /v1/listen` with the audio file as the raw request body.
    /// `language=multi` enables nova-3's multilingual mode (covers en, ru,
    /// es, de, fr, hi, pt, ja, it, nl — including code-switching mid-speech).
    private nonisolated static func transcribeDeepgram(apiKey: String, model: String, audioData: Data) async throws -> String {
        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "language", value: "multi"),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type") // recordings are AAC in an .m4a container
        request.httpBody = audioData

        let data = try await HTTPClient.json(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [String: Any],
              let channels = results["channels"] as? [[String: Any]],
              let alternatives = channels.first?["alternatives"] as? [[String: Any]],
              let transcript = alternatives.first?["transcript"] as? String else {
            throw ProviderError.decoding("no transcript in Deepgram response")
        }
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
