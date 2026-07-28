import Foundation
import Combine
import AppKit

/// HermesAddon — connects a self-hosted Hermes Agent (Nous Research) as an
/// isolated role in the prompt switcher. The agent is a black box with its
/// own prompt, tools, memory and model keys; we are one more surface of the
/// same agent the user already talks to elsewhere (AGENT-ADDONS-NOTES.md).
///
/// Mount points (pattern: `CalendarAddon`): master switch + settings tab in
/// `SettingsView`, roles in the chat header switcher, the agent-turn branch
/// in the chat pipeline, and the management sidebar.
@MainActor
final class HermesAddon: ObservableObject {
    static let shared = HermesAddon()

    static let addonID = "hermes"

    private let settings = HermesSettings.shared

    /// Connection state for the role chip; refreshed by `probe()`.
    @Published private(set) var connectionState: AgentConnectionState = .unknown
    /// Gateway capabilities from the last successful probe — gates UI
    /// sections (sessions, skills, approvals). nil until first contact.
    @Published private(set) var capabilities: HermesCapabilities?
    /// Skills from the last successful probe — shared by the sidebar list
    /// and the composer's slash autocomplete (the agent itself interprets
    /// "/skill-name …" in plain message text — probed live, fixtures).
    @Published private(set) var cachedSkills: [HermesSkill] = []
    /// Provider/model catalog + the agent's current pair (composer picker).
    @Published private(set) var cachedProviders: [HermesProviderOption] = []
    @Published private(set) var currentModelPair: (provider: String, model: String)?

    /// True while OUR chat pipeline streams a turn — the background poll
    /// must not misreport our own reply as outside activity.
    var streamActive = false

    /// Background gateway poll (§7.1: notifications must also cover runs we
    /// did NOT start — Hermes has no push channel, so we ask periodically).
    private var pollTask: Task<Void, Never>?
    /// sessionID → message_count at the last look (baseline seeded silently).
    private var lastSeenCounts: [String: Int] = [:]

    private init() {}

    // MARK: - Availability

    /// The addon is usable when switched on and a token is stored. Actual
    /// liveness is the role chip's job (probe) — a temporarily unreachable
    /// gateway must not eject the role from the switcher.
    var isAvailable: Bool {
        settings.enabled && APIKeyStore.hasKey(aux: .hermes)
    }

    // MARK: - Roles

    /// Roles offered in the prompt switcher: one per gateway model/profile
    /// (from the cached `/v1/models` list, usually a single "hermes-agent").
    /// Gated on the master switch ALONE — a missing key must not hide the
    /// role (the user flips the toggle, sees nothing, and is lost; e2e
    /// 2026-07-25). A keyless send answers with a pointer to the settings.
    /// Before the first successful probe the default pseudo-model stands in.
    var roles: [AgentRole] {
        guard settings.enabled else { return [] }
        let ids = settings.cachedAgentIDs.isEmpty ? ["hermes-agent"] : settings.cachedAgentIDs
        return ids.map { agentID in
            AgentRole(
                id: AgentRole.makeID(addonID: Self.addonID, agentID: agentID),
                addonID: Self.addonID,
                agentID: agentID,
                displayName: roleDisplayName(for: agentID),
                icon: "🤖"
            )
        }
    }

    private func roleDisplayName(for agentID: String) -> String {
        // The default pseudo-model reads better as plain "Hermes"; real
        // profile names pass through as-is.
        agentID == "hermes-agent" ? "Hermes" : agentID
    }

    // MARK: - Transport

    /// A transport bound to the current endpoint + token. Value type — cheap
    /// to make per call site, always up to date with the settings.
    func transport() -> HermesTransport {
        HermesTransport(baseURL: settings.baseURL, apiKey: APIKeyStore.key(aux: .hermes) ?? "")
    }

    // MARK: - Probe

    /// Health + authorized discovery in one pass: verifies the gateway,
    /// refreshes capabilities and the role list, updates the connection
    /// state. Returns the structured result for the settings' diagnostics.
    @discardableResult
    func probe() async -> GatewayProbe.Result {
        let transport = transport()
        var serverInfo: String?
        do {
            serverInfo = try await transport.health()
        } catch {
            let status = (error as? HermesTransportError)?.probeStatus
                ?? GatewayProbe.status(forTransportError: error)
            setConnection(.disconnected(status.message))
            return GatewayProbe.Result(status: status, serverInfo: nil)
        }
        do {
            let models = try await transport.models()
            capabilities = try? await transport.capabilities()
            if let skills = try? await transport.skills() {
                cachedSkills = skills
            }
            if let options = try? await transport.modelOptions() {
                cachedProviders = options.providers
                currentModelPair = options.current
                // Stale-lock cleanup rides every probe, so a rotten model
                // slug is caught at connect time, not at the failed send.
                validateLock(against: options.providers, current: options.current)
            }
            if settings.cachedAgentIDs != models {
                settings.cachedAgentIDs = models
            }
            guard !models.isEmpty else {
                setConnection(.degraded(GatewayProbe.Status.noAgents.message))
                return GatewayProbe.Result(status: .noAgents, serverInfo: serverInfo)
            }
            setConnection(.connected)
            return GatewayProbe.Result(status: .ok, serverInfo: serverInfo)
        } catch {
            let status = (error as? HermesTransportError)?.probeStatus
                ?? GatewayProbe.status(forTransportError: error)
            setConnection(.disconnected(status.message))
            return GatewayProbe.Result(status: status, serverInfo: serverInfo)
        }
    }

    private func setConnection(_ state: AgentConnectionState) {
        guard connectionState != state else { return }
        connectionState = state
        NotificationCenter.default.post(name: .hermesConnectionDidChange, object: nil)
    }

    // MARK: - Background activity poll

    /// Watches the gateway for activity in sessions BOUND to our role
    /// conversations: a run finished via Telegram/cron/another surface (or
    /// one that outlived our app restart) grows the session's message count
    /// — that becomes a "task finished" banner (§7.1) and a mirror sync for
    /// the on-screen conversation. Idempotent; call on launch and enable.
    func startBackgroundPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, self.isAvailable, !self.streamActive else { continue }
                // Self-heal: a gateway restart / dropped VPN / early keyless
                // 401 must not park the chip on red forever — re-probe until
                // green, then watch sessions.
                if self.connectionState != .connected {
                    await self.probe()
                }
                guard self.connectionState == .connected else { continue }
                await self.pollBoundSessions()
            }
        }
    }

    /// Re-seeds the activity baseline after OUR OWN turn — its message-count
    /// growth must not come back as an "outside activity" banner.
    func reseedPollBaseline() async {
        guard let sessions = try? await transport().sessions(limit: 50) else { return }
        for session in sessions {
            lastSeenCounts[session.id] = session.messageCount
        }
    }

    /// Advances the read watermarks from a fresh sessions list: the session
    /// whose conversation is OPEN on a visible panel is read up to its
    /// current count; sessions never seen before seed silently (their whole
    /// history is not "unread"). Everything else accrues badge counts.
    func updateReadWatermarks(sessions: [HermesSessionInfo]) {
        // "Looking at it" = the panel is up OR the app is frontmost: the
        // panel-only check left badges stuck on the conversation the user
        // was reading in a normal window (e2e 2026-07-27).
        let watching = FloatingPanelWindow.chatPanel?.isVisible == true || NSApp.isActive
        let openKey = watching ? ChatWindowBridge.chatStore?.conversation.storageKey : nil
        let openSession = openKey.flatMap { settings.sessionID(forConversationKey: $0) }
        for session in sessions {
            if session.id == openSession || settings.readCount(for: session.id) == nil {
                settings.markSessionRead(session.id, count: session.messageCount)
            }
        }
    }

    /// Unread messages of a session (nil watermark = freshly seeded → 0).
    func unreadCount(for session: HermesSessionInfo) -> Int {
        max(0, session.messageCount - (settings.readCount(for: session.id) ?? session.messageCount))
    }

    private func pollBoundSessions() async {
        guard let sessions = try? await transport().sessions(limit: 50) else { return }
        // A session appeared or vanished on ANOTHER surface (their app,
        // CLI, Telegram) — the sidebar list must learn without a reopen.
        let ids = Set(sessions.map(\.id))
        if ids != Set(lastSeenCounts.keys) {
            NotificationCenter.default.post(name: .hermesSessionsDidChange, object: nil)
        }
        updateReadWatermarks(sessions: sessions)
        // conversationKey ↔ sessionID (the map is stored the other way).
        let bindings = settings.sessionMap // [conversationKey: sessionID]
        for session in sessions {
            let previous = lastSeenCounts[session.id]
            lastSeenCounts[session.id] = session.messageCount
            // First sighting seeds the baseline silently.
            guard let previous, session.messageCount > previous else { continue }
            guard let conversationKey = bindings.first(where: { $0.value == session.id })?.key,
                  let role = roles.first else { continue }
            // Preview: the newest assistant text from the transcript tail.
            var preview = session.preview ?? ""
            if let rows = try? await transport().messages(sessionID: session.id),
               let lastReply = rows.last(where: { $0.role == "assistant" && !$0.content.isEmpty }) {
                preview = lastReply.content
            }
            NotificationService.shared.postTurnCompleted(
                roleID: role.id, roleName: role.displayName,
                preview: preview, conversationKey: conversationKey
            )
            // The on-screen conversation refreshes through its own poll; a
            // hidden one syncs on the next summon. Nudge listeners anyway so
            // an open transcript updates promptly.
            NotificationCenter.default.post(name: .hermesConnectionDidChange, object: nil)
        }
    }

    // MARK: - Sessions per conversation

    /// The AgentSession for one CONVERSATION of a role (each gateway session
    /// is its own conversation). Reuses the bound gateway session; a missing
    /// binding is created lazily on the first send. nil key = the role's
    /// currently active thread.
    func agentSession(for role: AgentRole, conversationKey: String? = nil) -> HermesAgentSession {
        HermesAgentSession(addon: self, role: role, conversationKey: conversationKey)
    }

    /// Model-lock pair for new sessions: the explicit setting when present,
    /// else the gateway's current top-level (provider, model) from
    /// `/api/model/options` — the agent's own configured default.
    ///
    /// The explicit lock is re-validated against the FRESH catalog: model
    /// slugs rot (OpenRouter rotates free tiers — `tencent/hy3:free`,
    /// 2026-07-28), and a stale lock 404s every send. A dead pair falls
    /// back to the agent's default and posts one system line to the chat.
    func resolveLockPair() async -> (provider: String, model: String)? {
        let options = try? await transport().modelOptions()
        if !settings.lockProvider.isEmpty, !settings.lockModel.isEmpty {
            guard let options else {
                // Gateway unreachable right now — keep the user's choice.
                return (settings.lockProvider, settings.lockModel)
            }
            if isLockValid(in: options.providers) {
                return (settings.lockProvider, settings.lockModel)
            }
            resetStaleLock(fallback: options.current)
            return options.current
        }
        return options?.current
    }

    /// True when the saved lock pair still exists in the gateway's catalog.
    private func isLockValid(in providers: [HermesProviderOption]) -> Bool {
        providers.contains {
            $0.slug == settings.lockProvider && $0.models.contains(settings.lockModel)
        }
    }

    /// Clears a dead lock and tells the user once (system line in the chat,
    /// via ChatWindow's listener) which model replaced the vanished one.
    func validateLock(against providers: [HermesProviderOption], current: (provider: String, model: String)?) {
        guard !settings.lockProvider.isEmpty, !settings.lockModel.isEmpty,
              !providers.isEmpty, !isLockValid(in: providers) else { return }
        resetStaleLock(fallback: current)
    }

    /// Heals an EXISTING session whose per-session lock points at a model
    /// that vanished from the gateway's catalog (the global-default reset
    /// above only covers new sessions): re-locks the session to the agent's
    /// current default and tells the user with one system line.
    func healSessionLockIfStale(sessionID: String) async {
        guard let recorded = settings.modelLock(forSession: sessionID) else { return }
        guard let options = try? await transport().modelOptions(),
              !options.providers.isEmpty else { return }
        let valid = options.providers.contains {
            $0.slug == recorded.provider && $0.models.contains(recorded.model)
        }
        guard !valid, let fallback = options.current,
              fallback.model != recorded.model else { return }
        try? await transport().lockModel(
            sessionID: sessionID, provider: fallback.provider, model: fallback.model
        )
        settings.recordModelLock(
            provider: fallback.provider, model: fallback.model, forSession: sessionID
        )
        Diagnostics.log("hermes", "sessionLock.stale \(recorded.model) → \(fallback.model) session=\(sessionID)")
        postLockNotice(stale: recorded.model, fallback: fallback)
    }

    private func resetStaleLock(fallback: (provider: String, model: String)?) {
        let stale = settings.lockModel
        settings.lockProvider = ""
        settings.lockModel = ""
        Diagnostics.log("hermes", "modelLock.stale \(stale) — reset to agent default")
        postLockNotice(stale: stale, fallback: fallback)
    }

    private func postLockNotice(stale: String, fallback: (provider: String, model: String)?) {
        var notice = HL("hermes.lock.stale").replacingOccurrences(of: "%model%", with: stale)
        notice = notice.replacingOccurrences(
            of: "%fallback%", with: fallback?.model ?? HL("hermes.lock.agentDefault")
        )
        NotificationCenter.default.post(name: .hermesModelLockReset, object: notice)
    }
}

extension Notification.Name {
    /// Object: the user-facing notice string. ChatWindow shows it as one
    /// system line in the active agent chat.
    static let hermesModelLockReset = Notification.Name("hermesModelLockReset")
}
