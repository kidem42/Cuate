import Foundation

/// Global configuration for the app.
/// Secrets never live here — API keys are stored in the Keychain (`APIKeyStore`).
enum Config {
    // MARK: - Voice Recording
    /// Maximum duration for voice recordings (in seconds).
    /// Bounded by the strictest STT provider: Voxtral classic ≈ 30 min,
    /// OpenAI = 25 MB/file (≈ 50 min at our 64 kbps AAC). 20 min is safe everywhere.
    static let maxVoiceRecordingDuration: TimeInterval = 20 * 60

    // MARK: - Chat media retention
    /// Media in chat history (image attachments, voice recordings) older
    /// than this is dropped at launch: files deleted, references stripped —
    /// message TEXT stays. Keeps chat.json and Application Support from
    /// growing without bound when the user never clears the chat.
    nonisolated static let mediaRetentionDays = 15
}
