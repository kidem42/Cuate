import Foundation
import Combine

extension Notification.Name {
    /// Posted when the addon's enable flag or role list changes — the chat
    /// header rebuilds its switcher entries on this (pattern:
    /// `worldTimeAddonDidChange`).
    static let hermesAddonDidChange = Notification.Name("hermesAddonDidChange")
    /// Posted when the gateway connection state changes (role chip dot).
    static let hermesConnectionDidChange = Notification.Name("hermesConnectionDidChange")
    /// Posted when the set/content of gateway sessions changed from OUR side
    /// (a turn created one, a rename/delete landed) — the sidebar list
    /// refreshes on it without waiting for a reopen.
    static let hermesSessionsDidChange = Notification.Name("hermesSessionsDidChange")
}

/// How agent-conversation text is retained locally (AGENT-ADDONS-NOTES.md
/// §6.1). The gateway is the source of truth either way; "mirror" keeps only
/// a bounded local cache and pages older text in from the agent, "archive"
/// keeps everything forever like ordinary chats.
enum HermesHistoryMode: String, CaseIterable, Identifiable {
    case mirror
    case archive

    var id: String { rawValue }
}

/// Persisted settings for the HermesAddon. Own `UserDefaults` keys (prefix
/// `hermes.`), nothing in the app's `AppSettings` — the addon stays fully
/// self-contained (pattern: `WorldTimeSettings`). The gateway token lives in
/// the Keychain (`APIKeyStore.AuxKey.hermes`), never here.
@MainActor
final class HermesSettings: ObservableObject {
    static let shared = HermesSettings()

    private let defaults = UserDefaults.standard

    // MARK: - Master switch

    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "hermes.enabled")
            NotificationCenter.default.post(name: .hermesAddonDidChange, object: nil)
        }
    }

    // MARK: - Connection

    static let defaultEndpoint = "http://127.0.0.1:8642"

    @Published var endpointURL: String {
        didSet { defaults.set(endpointURL, forKey: "hermes.endpointURL") }
    }

    /// Resolved base URL (falls back to the default when the field is garbage).
    var baseURL: URL {
        URL(string: endpointURL.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: Self.defaultEndpoint)!
    }

    /// Whether the gateway lives on ANOTHER machine — file attachments then
    /// need the dashboard courier (paths from this Mac mean nothing there).
    var isRemoteGateway: Bool {
        guard let host = baseURL.host?.lowercased() else { return false }
        return !["127.0.0.1", "localhost", "::1"].contains(host)
    }

    /// Hermes DASHBOARD server (:9119) — a separate service with the files
    /// API (`/api/files/upload-stream`): the API server itself rejects file
    /// inputs (proved in source, 2026-07-26). Optional; empty = not set up.
    /// Token lives in Keychain (`AuxKey.hermesDashboard`).
    @Published var dashboardURL: String {
        didSet { defaults.set(dashboardURL, forKey: "hermes.dashboardURL") }
    }

    var dashboardBaseURL: URL? {
        let trimmed = dashboardURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    // MARK: - Role / model routing

    /// Model ids from the gateway's `/v1/models` (usually one per profile).
    /// Cached so roles appear in the switcher without waiting for a fetch.
    @Published var cachedAgentIDs: [String] {
        didSet {
            defaults.set(cachedAgentIDs, forKey: "hermes.cachedAgentIDs")
            NotificationCenter.default.post(name: .hermesAddonDidChange, object: nil)
        }
    }

    /// The (provider, model) pair locked onto every NEW gateway session.
    /// Required: a fresh Hermes session inherits the literal "hermes-agent"
    /// and every turn 404s until a model lock is set (Hermes-API-Fixtures.md).
    /// Empty = don't lock, let the gateway route (covers future Hermes
    /// versions that fix the default route).
    @Published var lockProvider: String {
        didSet { defaults.set(lockProvider, forKey: "hermes.lockProvider") }
    }
    @Published var lockModel: String {
        didSet { defaults.set(lockModel, forKey: "hermes.lockModel") }
    }

    // MARK: - Host app features in agent sessions

    /// Whether the app's OWN model-backed image features (ImageAddon actions,
    /// OCR extract) surface inside agent conversations. Off by default — the
    /// agent owns its sessions end-to-end, our tools don't mix in uninvited.
    /// Opting in brings them into agent chats on the app's keys/models
    /// (configured in their own tabs); results stay local to this app.
    @Published var imageFeaturesEnabled: Bool {
        didSet { defaults.set(imageFeaturesEnabled, forKey: "hermes.imageFeaturesEnabled") }
    }

    // MARK: - History retention (mirror by default)

    @Published var historyMode: HermesHistoryMode {
        didSet { defaults.set(historyMode.rawValue, forKey: "hermes.historyMode") }
    }

    /// Mirror mode: how many newest messages stay in the local cache
    /// (older text is paged in from the gateway on scroll).
    @Published var mirrorCacheLimit: Int {
        didSet { defaults.set(mirrorCacheLimit, forKey: "hermes.mirrorCacheLimit") }
    }

    // MARK: - Notifications

    /// Hide command/action text in notification banners (lock-screen privacy).
    @Published var hideNotificationDetails: Bool {
        didSet { defaults.set(hideNotificationDetails, forKey: "hermes.hideNotificationDetails") }
    }

    // MARK: - Reasoning effort (composer control)

    /// Hermes effort ladder (their composer's OPTIONS popover). "" = don't
    /// send, the agent's own default applies. Sent as
    /// `model_options.reasoning_effort` — accepted silently by 0.19.0.
    static let effortLevels = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    @Published var reasoningEffort: String {
        didSet { defaults.set(reasoningEffort, forKey: "hermes.reasoningEffort") }
    }

    // MARK: - Active session per role
    //
    // Each gateway session opens as its OWN conversation (streaming
    // isolation like isolated presets); this remembers which one a role
    // shows when it activates. nil = the role's default thread.

    @Published private(set) var activeSessionByRole: [String: String] {
        didSet { defaults.set(activeSessionByRole, forKey: "hermes.activeSessionByRole") }
    }

    func activeSession(roleID: String) -> String? {
        activeSessionByRole[roleID]
    }

    func setActiveSession(_ sessionID: String?, roleID: String) {
        if let sessionID {
            activeSessionByRole[roleID] = sessionID
        } else {
            activeSessionByRole.removeValue(forKey: roleID)
        }
    }

    // MARK: - Per-session model locks (composer label accuracy)
    //
    // sessionID → "provider|model" WE locked it to. Every session carries
    // its own lock on the gateway; the composer must show the OPEN
    // session's model, not the global default (they diverge).

    @Published private(set) var sessionModelLocks: [String: String] {
        didSet { defaults.set(sessionModelLocks, forKey: "hermes.sessionModelLocks") }
    }

    func modelLock(forSession sessionID: String) -> (provider: String, model: String)? {
        guard let raw = sessionModelLocks[sessionID] else { return nil }
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    func recordModelLock(provider: String, model: String, forSession sessionID: String) {
        sessionModelLocks[sessionID] = "\(provider)|\(model)"
    }

    // MARK: - Pinned messages (Telegram-style, agent chats)
    //
    // conversationKey → pinned message UUIDs, in pin order. Local metadata:
    // the gateway knows nothing about it.

    @Published private(set) var pinnedMessagesByConversation: [String: [String]] {
        didSet { defaults.set(pinnedMessagesByConversation, forKey: "hermes.pinnedMessages") }
    }

    func pinnedMessages(forConversationKey key: String) -> [String] {
        pinnedMessagesByConversation[key] ?? []
    }

    func isMessagePinned(_ messageID: String, conversationKey key: String) -> Bool {
        pinnedMessagesByConversation[key]?.contains(messageID) ?? false
    }

    func toggleMessagePin(_ messageID: String, conversationKey key: String) {
        var pins = pinnedMessagesByConversation[key] ?? []
        if let index = pins.firstIndex(of: messageID) {
            pins.remove(at: index)
        } else {
            pins.append(messageID)
        }
        if pins.isEmpty {
            pinnedMessagesByConversation.removeValue(forKey: key)
        } else {
            pinnedMessagesByConversation[key] = pins
        }
    }

    // MARK: - Unread watermarks (sidebar badges)
    //
    // sessionID → the gateway message_count last seen with that session's
    // conversation OPEN on a visible panel. Anything above it is "unread".
    // First sighting seeds silently (old history must not flood as unread).

    @Published private(set) var sessionReadCounts: [String: Int] {
        didSet { defaults.set(sessionReadCounts, forKey: "hermes.sessionReadCounts") }
    }

    func readCount(for sessionID: String) -> Int? {
        sessionReadCounts[sessionID]
    }

    func markSessionRead(_ sessionID: String, count: Int) {
        if sessionReadCounts[sessionID] != count {
            sessionReadCounts[sessionID] = count
        }
    }

    // MARK: - Session marks (pin / color)
    //
    // LOCAL metadata: the gateway stores neither pins nor colors (the
    // Hermes desktop keeps its own, client-side too) — so these marks live
    // here and do not sync to other Hermes surfaces.

    @Published private(set) var pinnedSessions: [String] {
        didSet { defaults.set(pinnedSessions, forKey: "hermes.pinnedSessions") }
    }

    /// sessionID → color name ("red"/"yellow"/"green"/"blue").
    @Published private(set) var sessionColors: [String: String] {
        didSet { defaults.set(sessionColors, forKey: "hermes.sessionColors") }
    }

    func isSessionPinned(_ id: String) -> Bool { pinnedSessions.contains(id) }

    func toggleSessionPin(_ id: String) {
        if let index = pinnedSessions.firstIndex(of: id) {
            pinnedSessions.remove(at: index)
        } else {
            pinnedSessions.append(id)
        }
    }

    func sessionColor(_ id: String) -> String? { sessionColors[id] }

    func setSessionColor(_ color: String?, for id: String) {
        if let color {
            sessionColors[id] = color
        } else {
            sessionColors.removeValue(forKey: id)
        }
    }

    /// Drops marks for a session that no longer exists on the gateway.
    func forgetSessionMarks(_ id: String) {
        pinnedSessions.removeAll { $0 == id }
        sessionColors.removeValue(forKey: id)
    }

    // MARK: - Sidebar collapse state (per role)

    /// roleID → the user collapsed the management column for that role.
    @Published private(set) var sidebarCollapsed: [String: Bool] {
        didSet { defaults.set(sidebarCollapsed, forKey: "hermes.sidebarCollapsed") }
    }

    func isSidebarCollapsed(roleID: String) -> Bool {
        sidebarCollapsed[roleID] ?? false
    }

    func setSidebarCollapsed(_ collapsed: Bool, roleID: String) {
        sidebarCollapsed[roleID] = collapsed
    }

    // MARK: - Conversation ↔ gateway session mapping

    /// storageKey (ChatStore.ConversationID) → gateway session id. A role's
    /// conversation binds to one Hermes session; "continue here" from the
    /// sessions list rebinds it. Plain dictionary in defaults — session ids
    /// are not secrets.
    @Published private(set) var sessionMap: [String: String] {
        didSet { defaults.set(sessionMap, forKey: "hermes.sessionMap") }
    }

    func sessionID(forConversationKey key: String) -> String? {
        sessionMap[key]
    }

    func bindSession(_ sessionID: String, toConversationKey key: String) {
        sessionMap[key] = sessionID
    }

    func unbindSession(forConversationKey key: String) {
        sessionMap.removeValue(forKey: key)
    }

    // MARK: - Init

    private init() {
        enabled = defaults.bool(forKey: "hermes.enabled")
        endpointURL = defaults.string(forKey: "hermes.endpointURL") ?? Self.defaultEndpoint
        dashboardURL = defaults.string(forKey: "hermes.dashboardURL") ?? ""
        cachedAgentIDs = defaults.stringArray(forKey: "hermes.cachedAgentIDs") ?? []
        lockProvider = defaults.string(forKey: "hermes.lockProvider") ?? ""
        lockModel = defaults.string(forKey: "hermes.lockModel") ?? ""
        imageFeaturesEnabled = defaults.bool(forKey: "hermes.imageFeaturesEnabled")
        historyMode = HermesHistoryMode(rawValue: defaults.string(forKey: "hermes.historyMode") ?? "")
            ?? .mirror
        let cache = defaults.integer(forKey: "hermes.mirrorCacheLimit")
        mirrorCacheLimit = cache > 0 ? cache : 500
        hideNotificationDetails = defaults.bool(forKey: "hermes.hideNotificationDetails")
        reasoningEffort = defaults.string(forKey: "hermes.reasoningEffort") ?? ""
        activeSessionByRole = (defaults.dictionary(forKey: "hermes.activeSessionByRole") as? [String: String]) ?? [:]
        sessionReadCounts = (defaults.dictionary(forKey: "hermes.sessionReadCounts") as? [String: Int]) ?? [:]
        pinnedMessagesByConversation = (defaults.dictionary(forKey: "hermes.pinnedMessages") as? [String: [String]]) ?? [:]
        sessionModelLocks = (defaults.dictionary(forKey: "hermes.sessionModelLocks") as? [String: String]) ?? [:]
        pinnedSessions = defaults.stringArray(forKey: "hermes.pinnedSessions") ?? []
        sessionColors = (defaults.dictionary(forKey: "hermes.sessionColors") as? [String: String]) ?? [:]
        sidebarCollapsed = (defaults.dictionary(forKey: "hermes.sidebarCollapsed") as? [String: Bool]) ?? [:]
        sessionMap = (defaults.dictionary(forKey: "hermes.sessionMap") as? [String: String]) ?? [:]
    }
}
