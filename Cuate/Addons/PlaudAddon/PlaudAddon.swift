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

    /// Keeps the grant rotating while the app runs (see `startSessionUpkeep`).
    private var upkeepTimer: Timer?
    /// Re-arms the connection flag once the Keychain warms up.
    private var keychainObserver: NSObjectProtocol?

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
        settings.needsReauth = false
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
        settings.needsReauth = false
        settings.clearAccount()
    }

    /// Re-sync the published connection flag with the Keychain (launch,
    /// external key changes).
    func refreshConnectionState() {
        let connected = PlaudClient.hasTokens
        // Logged on the EDGE only: this flag gates every Plaud tool, and when
        // it sat false after an update nothing in the log said so.
        if connected != settings.isConnected {
            Diagnostics.log("plaud", "connected=\(connected)")
        }
        settings.isConnected = connected
        if settings.isConnected { settings.needsReauth = false }
    }

    // MARK: - Session health

    /// The client dropped a rejected grant: flip the card to "reconnect"
    /// instead of leaving a green checkmark over a dead account. The account
    /// name/avatar stay — the reconnect prompt names who to sign back in as.
    func handleSessionExpired() {
        settings.isConnected = false
        settings.needsReauth = true
    }

    /// Verifies the stored session against Plaud (one profile call) and
    /// refreshes the account card. Cheap, and the only way the settings
    /// indicator can tell "connected" from "the Keychain still has a blob".
    func verifyConnection() async {
        // `hasTokens` is a cache-only read: a cold Keychain cache answers
        // "no key" and would flip a perfectly good account to "not connected".
        await APIKeyStore.warmIfNeeded()
        guard settings.enabled, PlaudClient.hasTokens else {
            refreshConnectionState()
            return
        }
        if let user = try? await PlaudClient.shared.currentUser() {
            settings.setAccount(
                name: user["nickname"] as? String,
                email: user["email"] as? String,
                avatarURL: user["avatar"] as? String
            )
        }
        // A dead grant already cleared the Keychain inside the client — this
        // is what turns that into "Session expired" on screen.
        refreshConnectionState()
    }

    /// Launch hook: rotate the grant now and every few hours after. Plaud's
    /// refresh token dies on a ~week clock, so an app that only ever touches
    /// Plaud when the model asks loses the session over any quiet week
    /// (2026-08-05: 8 days idle → refresh 401 → account silently dead).
    func startSessionUpkeep() {
        guard upkeepTimer == nil else { return }
        // The connection flag is seeded at launch from a cache-only Keychain
        // probe, and right after an app update the ACL re-authorizes for a few
        // seconds — the probe says "no key" and the addon reads as
        // disconnected until something asks again. The store republishes when
        // the warm read lands, so re-arm on it: without this the Plaud tools
        // (and the agent's recording chips) stayed off after every update
        // until the user opened Settings (live, 2026-08-16).
        keychainObserver = NotificationCenter.default.addObserver(
            forName: .apiKeysDidChange, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in PlaudAddon.shared.refreshConnectionState() }
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in await PlaudAddon.shared.maintainSession() }
        }
        // Nobody is waiting on this — let the system coalesce it.
        timer.tolerance = 600
        upkeepTimer = timer
        Task { @MainActor in await maintainSession() }
    }

    private func maintainSession() async {
        guard settings.enabled else { return }
        await APIKeyStore.warmIfNeeded()
        guard PlaudClient.hasTokens else { return }
        await PlaudClient.shared.keepAliveIfNeeded()
        refreshConnectionState()
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
