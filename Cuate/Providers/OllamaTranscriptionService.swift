import Foundation

enum OllamaTranscriptionService {
    private static let queue = OllamaTranscriptionQueue()

    enum Failure: LocalizedError {
        case unavailable, changedEndpoint, audio, response
        var errorDescription: String? {
            switch self {
            case .unavailable: return L("voice.ollama.unavailable")
            case .changedEndpoint: return L("voice.ollama.changedEndpoint")
            case .audio: return L("voice.ollama.audioError")
            case .response: return L("voice.ollama.responseError")
            }
        }
    }

    static func transcribe(audioURL: URL, endpoint: String, model: String) async throws -> String {
        try await queue.run {
            // Explicit worker: approachable concurrency otherwise permits a
            // nonisolated async function to keep its caller's executor.
            let worker = Task.detached(priority: .userInitiated) {
                try await perform(audioURL: audioURL, endpoint: endpoint, model: model)
            }
            return try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
        }
    }

    private static func validateEndpoint(_ endpoint: String) throws {
        guard AppSettings.shared.localModelsEnabled,
              AppSettings.shared.localEndpointURL == endpoint else { throw Failure.changedEndpoint }
    }

    private static func thinkingCapability(endpoint: String, model: String) async throws -> Bool {
        try validateEndpoint(endpoint)
        guard !model.isEmpty else { throw Failure.unavailable }
        // Recheck routing/capabilities before sending audio, even with a warm
        // cache: a model alias can be replaced by an Ollama cloud model.
        let info = try await OllamaAdminService(endpointURL: endpoint).show(model: model)
        try validateEndpoint(endpoint)
        guard info.supportsOllamaTranscription else { throw Failure.unavailable }
        return info.supportsReasoning
    }

    private nonisolated static func perform(audioURL: URL, endpoint: String, model: String) async throws -> String {
        let thinking = try await thinkingCapability(endpoint: endpoint, model: model)
        let reader: OllamaAudioReader
        do { reader = try OllamaAudioReader(url: audioURL) }
        catch { throw Failure.audio }
        var transcripts: [String] = []
        while true {
            try Task.checkCancellation()
            let wav: Data?
            do { wav = try reader.next() }
            catch is CancellationError { throw CancellationError() }
            catch { throw Failure.audio }
            guard let wav else { break }
            try await validateEndpoint(endpoint)
            let request = try OllamaTranscriptionWire.request(endpoint: endpoint, model: model, wav: wav, thinking: thinking)
            let response = try await HTTPClient.json(request)
            try Task.checkCancellation()
            try await validateEndpoint(endpoint)
            do { transcripts.append(try OllamaTranscriptionWire.transcript(response)) }
            catch { throw Failure.response }
        }
        return transcripts.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
