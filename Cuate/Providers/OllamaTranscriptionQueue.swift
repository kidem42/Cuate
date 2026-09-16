import Foundation

/// One local STT operation at a time across chat and dictation. Cancelling a
/// queued job never cancels the job ahead of it or lets later jobs overtake it.
actor OllamaTranscriptionQueue {
    private var tail: Task<Void, Never>?
    private var tailID: UUID?

    func run(_ operation: @escaping @Sendable () async throws -> String) async throws -> String {
        let previous = tail
        let id = UUID()
        let job = Task {
            await previous?.value
            try Task.checkCancellation()
            return try await operation()
        }
        tailID = id
        tail = Task { _ = try? await job.value }
        defer {
            if tailID == id { tail = nil; tailID = nil }
        }
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }
}
