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

    /// Conversations OUR chat pipeline is streaming a turn into right now
    /// (several Hermes sessions can run at once). Two consumers:
    /// - the background poll must not misreport our own replies as outside
    ///   activity (and one turn ending must not unmute it while another
    ///   still runs);
    /// - the mirror sync must not touch a conversation mid-turn. Its old
    ///   guard was `store.isLoading`, which a session switch wipes — a
    ///   catch-up then ran DURING the run and inserted the gateway's rows
    ///   for the in-flight reply as duplicate bubbles (app.log 2026-07-29
    ///   12:40: catchUp between turn start and turn.end).
    /// `@Published` so the sidebar's session rows can show a live "agent is
    /// working here" wave: it changes once per turn start/end — a cheap
    /// invalidation, nothing per-chunk rides on it.
    @Published private var activeTurnKeys: [String: Int] = [:]
    var streamActive: Bool { !activeTurnKeys.isEmpty }
    func beginStreaming(conversationKey: String) {
        activeTurnKeys[conversationKey, default: 0] += 1
    }
    func endStreaming(conversationKey: String) {
        guard let count = activeTurnKeys[conversationKey] else { return }
        if count <= 1 {
            activeTurnKeys.removeValue(forKey: conversationKey)
        } else {
            activeTurnKeys[conversationKey] = count - 1
        }
    }
    func isTurnActive(forConversationKey key: String) -> Bool {
        activeTurnKeys[key] != nil
    }

    /// Background gateway poll (§7.1: notifications must also cover runs we
    /// did NOT start — Hermes has no push channel, so we ask periodically).
    private var pollTask: Task<Void, Never>?
    /// sessionID → message_count at the last look (baseline seeded silently).
    private var lastSeenCounts: [String: Int] = [:]

    /// sessionID → unread VISIBLE messages (sidebar badge). The gateway's
    /// message_count includes tool rows — see `unreadCount(for:)`.
    @Published private(set) var unreadBadges: [String: Int] = [:]
    /// sessionID → the message_count each badge was computed at (stale →
    /// the transcript tail is refetched); plus in-flight fetch dedup.
    private var badgeComputedAt: [String: Int] = [:]
    private var badgeFetchesInFlight: Set<String> = []

    private init() {
        // A Mac waking from sleep still wears last night's connection state
        // (green chip, no banner) while the network is only coming up — the
        // first sidebar action then fails with zero explanation (2026-08-03:
        // "new session" looked like a dead button). Re-probe shortly after
        // wake so the chip/banner turn honest within seconds; the 30s
        // background poll keeps self-healing until the gateway answers.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                let addon = HermesAddon.shared
                guard addon.isAvailable else { return }
                // Interfaces need a beat — probing at t=0 fails every time.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await addon.probe()
            }
        }
    }

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

    // MARK: - Session deletion

    /// Deletes a gateway session AND every local trace of it — the ONE path
    /// both delete buttons (sidebar list, settings list) go through.
    ///
    /// Gateway-first, and NOT fire-and-forget: a silently failed DELETE once
    /// left the session alive on the gateway while a list dropped it — every
    /// other surface (the phone) kept showing "deleted" sessions and the
    /// user blamed their sync (e2e 2026-07-27). On failure nothing local is
    /// touched; rethrows so the caller can keep its row.
    ///
    /// Local cleanup: the session's own mirrored thread is dropped (its
    /// source of truth is gone) and every binding pointing at the session is
    /// released so the next send starts fresh instead of 404-ing. A role's
    /// DEFAULT thread keeps its messages on purpose — it is only unbound,
    /// the on-screen chat must not vanish from under the user.
    func deleteSession(id: String) async throws {
        try await transport().deleteSession(id: id)
        settings.forgetSessionMarks(id)
        for role in roles {
            let sessionThread = role.conversationID(sessionID: id).storageKey
            for key in [role.conversationID.storageKey, sessionThread]
            where settings.sessionID(forConversationKey: key) == id {
                settings.unbindSession(forConversationKey: key)
            }
            if settings.activeSession(roleID: role.id) == id {
                settings.setActiveSession(nil, roleID: role.id)
            }
            ChatPersistence.deleteConversation(key: sessionThread)
        }
        NotificationCenter.default.post(name: .hermesSessionsDidChange, object: nil)
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
            }
            // Context window of the agent's model, resolved by Hermes itself
            // (the gauge's authoritative source). Older gateways 404 the
            // route — `try?` leaves the cached value / table fallback in
            // charge (HermesModelContext.limit).
            if let info = try? await transport.modelInfo() {
                settings.recordAgentContext(model: info.model, length: info.contextLength)
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

    /// Re-reads the provider/model catalog from the gateway. The truth
    /// about availability lives THERE (its picker logic, its caches, its
    /// quota handling — 2026-07-29) — the composer menu must mirror it
    /// whenever the user comes back to the panel, not the snapshot of the
    /// launch-time probe (a gateway-side picker fix stayed invisible until
    /// an app restart). Throttled: the triggers (panel key, app active,
    /// composer appear) fire in bursts.
    private var lastCatalogRefresh: Date = .distantPast
    func refreshCatalogIfStale() async {
        guard Date().timeIntervalSince(lastCatalogRefresh) > 15 else { return }
        lastCatalogRefresh = Date()
        guard isAvailable, let options = try? await transport().modelOptions() else { return }
        cachedProviders = options.providers
        currentModelPair = options.current
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
        refreshUnreadBadges(sessions: sessions)
    }

    /// Immediate read-marking for the session whose conversation just came
    /// on screen. The sidebar's watermark pass only rides the 30s poll
    /// (muted during any streaming turn) and sidebar reloads — waiting for
    /// it left badges hanging long after the user had opened the thread
    /// (report 2026-07-31). The badge retires optimistically right away;
    /// the watermark trues up from a fresh sessions fetch.
    func markSessionRead(_ sessionID: String) async {
        unreadBadges.removeValue(forKey: sessionID)
        badgeComputedAt.removeValue(forKey: sessionID)
        guard let sessions = try? await transport().sessions(limit: 50),
              let row = sessions.first(where: { $0.id == sessionID }) else { return }
        settings.markSessionRead(sessionID, count: row.messageCount)
        // The user is looking at these rows — they must not come back as
        // an "outside activity" banner either.
        lastSeenCounts[sessionID] = row.messageCount
        refreshUnreadBadges(sessions: sessions)
    }

    /// Unread messages of a session, in MESSAGES the user would see — not in
    /// gateway transcript rows. The raw watermark delta counts tool results
    /// and tool-call shells too, so one agent turn showed as "34 unread";
    /// the badge now reads from `unreadBadges` (computed from the transcript
    /// tail), and 0 stands in while a fresh delta is still being resolved.
    func unreadCount(for session: HermesSessionInfo) -> Int {
        guard let read = settings.readCount(for: session.id),
              session.messageCount > read else { return 0 }
        return unreadBadges[session.id] ?? 0
    }

    /// Recomputes visible-unread badges for sessions whose raw message_count
    /// moved past the read watermark. One transcript fetch per (session,
    /// count) — the poll and the sidebar reload both funnel through here.
    private func refreshUnreadBadges(sessions: [HermesSessionInfo]) {
        for session in sessions {
            guard let read = settings.readCount(for: session.id),
                  session.messageCount > read else {
                // Read (or freshly seeded) — retire any stale badge.
                if unreadBadges[session.id] != nil {
                    unreadBadges.removeValue(forKey: session.id)
                    badgeComputedAt.removeValue(forKey: session.id)
                }
                continue
            }
            guard badgeComputedAt[session.id] != session.messageCount,
                  !badgeFetchesInFlight.contains(session.id) else { continue }
            badgeFetchesInFlight.insert(session.id)
            Task { @MainActor in
                defer { badgeFetchesInFlight.remove(session.id) }
                let started = ContinuousClock.now
                guard let rows = try? await transport().messages(sessionID: session.id) else { return }
                // Perf telemetry (2026-07-31): this is a FULL-transcript
                // fetch parsed on the main actor, one per unread session per
                // count change — with dozens of sessions and background
                // agents it was a suspected источник просадок скролла.
                let elapsed = started.duration(to: .now)
                let ms = Int(elapsed.components.seconds) * 1000
                    + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
                if ms > 50 {
                    Diagnostics.log("hermes", "badge.fetch session=\(session.id) rows=\(rows.count) ms=\(ms)")
                }
                // Rows are append-only: the first `read` ones were on screen
                // when the watermark was set — everything after is new.
                // Visible = what the transcript renders as bubbles: user
                // turns and assistant rows with actual text (tool results
                // and bare tool-call shells stay out).
                // User rows minus compaction artifacts — a context summary
                // the gateway injected must not light the badge.
                let visible = rows.suffix(max(0, rows.count - read)).filter {
                    ($0.role == "user" && HermesCompaction.visibleUserText($0.content) != nil)
                        || ($0.role == "assistant"
                            && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.count
                badgeComputedAt[session.id] = session.messageCount
                // Never 0 while the raw count moved: an all-tool tail still
                // means the agent worked here since the user last looked.
                unreadBadges[session.id] = max(1, visible)
            }
        }
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
            // (session.preview alone echoed the TITLE — a1b384d; the full
            // fetch stays until the parse moves off the main actor.)
            var preview = session.preview ?? ""
            let previewStart = ContinuousClock.now
            if let rows = try? await transport().messages(sessionID: session.id),
               let lastReply = rows.last(where: { $0.role == "assistant" && !$0.content.isEmpty }) {
                preview = lastReply.content
                let elapsed = previewStart.duration(to: .now)
                let ms = Int(elapsed.components.seconds) * 1000
                    + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
                if ms > 50 {
                    Diagnostics.log("hermes", "poll.preview session=\(session.id) rows=\(rows.count) ms=\(ms)")
                }
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
    /// The explicit choice is NOT validated against the catalog: the catalog
    /// mirrors the gateway's momentary mood (quota cooldowns shrink it —
    /// live 2026-07-29), while limits renew on the user's schedule. A model
    /// that is truly gone fails the send with a visible hint
    /// (`HermesAgentSession.annotateGatewayFailure`) — the user re-picks;
    /// nothing silently overrides their choice (4.6 regression: the old
    /// auto-heal reverted an explicit pick back to the quota-dead provider).
    func resolveLockPair() async -> (provider: String, model: String)? {
        if !settings.lockProvider.isEmpty, !settings.lockModel.isEmpty {
            return (settings.lockProvider, settings.lockModel)
        }
        return (try? await transport().modelOptions())?.current
    }
}

extension Notification.Name {
    /// Object: the user-facing notice string. ChatWindow shows it as one
    /// system line in the active agent chat (model-switch feedback).
    static let hermesSystemNotice = Notification.Name("hermesSystemNotice")
}
