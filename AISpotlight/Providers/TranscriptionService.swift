import Foundation

/// Speech-to-text via provider APIs.
/// Mistral (Voxtral) and OpenAI share the same OpenAI-style
/// `POST /v1/audio/transcriptions` multipart endpoint.
enum TranscriptionService {

    /// Transcribes the audio file using the configured STT provider.
    /// Falls back to any STT provider that has a key if the preferred one doesn't.
    @MainActor
    static func transcribe(audioURL: URL) async throws -> String {
        let settings = AppSettings.shared
        let preferred = settings.sttProvider

        let candidates: [STTProviderID] = [preferred] + STTProviderID.allCases.filter { $0 != preferred }
        guard let provider = candidates.first(where: { APIKeyStore.hasKey(for: $0.keyProvider) }) else {
            throw ProviderError.transcriptionUnavailable
        }
        guard let apiKey = APIKeyStore.key(for: provider.keyProvider) else {
            throw ProviderError.transcriptionUnavailable
        }

        let model = settings.sttModel(for: provider)
        let endpoint: URL
        switch provider {
        case .mistral:
            endpoint = URL(string: "https://api.mistral.ai/v1/audio/transcriptions")!
        case .openai:
            endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        }

        let audioData = try Data(contentsOf: audioURL)
        let filename = audioURL.lastPathComponent

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
}
