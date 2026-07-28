import Foundation
import AppKit

/// PlaudAddon — the user's Plaud voice-recorder library (recordings, AI
/// summaries, transcripts) exposed to the assistant as chat tools. Read-only
/// by design: Plaud's third-party API offers no writes, so processing a
/// recording or renaming speakers happens in Plaud's own UI (deep link).
///
/// Mount points (pattern: `CalendarAddon`): a master switch + settings tab
/// in `SettingsView`, tool attachment in `ChatService` via
/// `PlaudToolService`. Tools execute CLIENT-side — the same flow works for
/// every provider, including a remote Hermes endpoint: the model only ever
/// sees tool schemas and text results; OAuth tokens never leave this Mac.
@MainActor
final class PlaudAddon {
    static let shared = PlaudAddon()

    private let settings = PlaudSettings.shared

    private init() {}

    /// Tools attach only when the addon is on AND an account is connected.
    var isAvailable: Bool { settings.enabled && settings.isConnected }

    // MARK: - Connect / disconnect

    /// Interactive OAuth: browser round-trip, then an account snapshot for
    /// the settings card. Throws with a user-readable message on failure.
    func connect() async throws {
        defer { settings.pendingAuthURL = nil }
        try await PlaudClient.shared.authorize { url in
            // NSWorkspace is main-actor; the authorize actor calls this from
            // its own context. The URL is also parked in settings so the UI
            // can offer "copy the link" for a non-default browser.
            Task { @MainActor in
                PlaudSettings.shared.pendingAuthURL = url
                NSWorkspace.shared.open(url)
            }
        }
        settings.isConnected = PlaudClient.hasTokens
        // Best-effort profile fetch — a failure here must not fail connect.
        if let user = try? await PlaudClient.shared.currentUser() {
            settings.setAccount(
                name: user["nickname"] as? String,
                email: user["email"] as? String,
                avatarURL: user["avatar"] as? String
            )
        }
    }

    /// Aborts an OAuth flow stuck on "waiting for the browser" — e.g. the
    /// sign-in opened in the wrong browser and the user wants a redo.
    func cancelConnect() {
        Task { await PlaudClient.shared.cancelAuthorization() }
    }

    func disconnect() async {
        await PlaudClient.shared.logout()
        settings.isConnected = PlaudClient.hasTokens
        settings.clearAccount()
    }

    /// Re-sync the published connection flag with the Keychain (launch,
    /// external key changes).
    func refreshConnectionState() {
        settings.isConnected = PlaudClient.hasTokens
    }

    // MARK: - Deep link

    /// Plaud's web app — processing recordings and naming speakers live
    /// there, our integration is read-only.
    static func openInPlaud() {
        if let url = URL(string: PlaudClient.webAppURL) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Deep link to one recording in Plaud's MAIN web UI. Format supplied
    /// by the user from the app's own address bar (2026-07-28):
    /// `https://web.plaud.ai/file/<fileID>` — the note inside the normal
    /// interface, not the transdetail share-card.
    static func openRecording(_ fileID: String?) {
        guard let fileID, !fileID.isEmpty,
              let url = URL(string: PlaudClient.webAppURL + "file/\(fileID)") else {
            openInPlaud()
            return
        }
        NSWorkspace.shared.open(url)
    }
}
