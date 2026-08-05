import SwiftUI

/// Root of the DETACHED sidebar panel: the column lives in its own child
/// window docked left of the chat (the chat panel never resizes for it), so
/// it carries its own themed surface and palette environment.
struct AgentSidebarPanelRoot: View {
    let role: AgentRole
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = ThemePalette.palette(for: settings.theme, scheme: colorScheme)
        HermesSidebarView(role: role)
            .frame(maxHeight: .infinity, alignment: .top)
            .environment(\.themePalette, palette)
            .fontDesign(palette.fontDesign)
            .themedPanelSurface(palette, cornerRadius: 18, decorations: false)
    }
}

/// The management column shown next to the chat while a Hermes role is
/// active: sessions, skills, toolsets and the agent's runtime — operational
/// control DURING the dialog, without leaving for a browser dashboard
/// (Hermes' own web dashboard cannot chat; we offer both in one window).
///
/// Composition is capability-gated: a feature the gateway doesn't serve
/// hides its section, it never breaks the column. Jobs (`jobs_admin`) and
/// memory (`memory_write_api`) are OFF on a default 0.19.0 gateway — those
/// sections appear only when the server enables them.
struct HermesSidebarView: View {
    @Environment(\.themePalette) private var palette
    @ObservedObject private var addon = HermesAddon.shared
    @ObservedObject private var settings = HermesSettings.shared

    let role: AgentRole

    @State private var sessions: [HermesSessionInfo] = []
    @State private var skills: [HermesSkill] = []
    @State private var toolsets: [HermesToolset] = []
    @State private var currentModel: (provider: String, model: String)?
    @State private var loadedSessions = false
    @State private var loadedSkills = false
    @State private var loadedToolsets = false
    @State private var loadedModel = false
    /// Inline rename state (context menu → «Переименовать»).
    @State private var renamingSessionID: String?
    @State private var renameDraft = ""
    /// "New session" in flight / failed. The create is a network round-trip
    /// that a wake-from-sleep Mac loses silently — the click looked like a
    /// no-op, got repeated, and the user was left guessing (2026-08-03).
    /// The button shows a spinner while working and an honest line when the
    /// gateway didn't answer; re-entry is guarded so impatient clicks can't
    /// queue duplicate sessions.
    @State private var creatingSession = false
    @State private var createSessionFailed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                // Connection trouble → say WHY the sections are empty (an
                // unauthorized 401 used to just render blank lists — the
                // honest banner replaces the silence; e2e 2026-07-25).
                connectionBanner
                sessionsSection
                if addon.capabilities?.supports("skills_api") ?? true {
                    skillsSection
                    toolsetsSection
                }
                agentSection
            }
            .padding(12)
        }
        .frame(width: AgentSidebarLayout.width)
        .task {
            // Fresh probe first: the key may have just been saved and the
            // cached connection state gone stale. Then the sections load
            // independently and lazily — the chat never waits.
            await addon.probe()
            await reloadAll()
        }
        // The settings tab's probe succeeded (key saved, endpoint fixed) →
        // refresh the column without reopening it.
        .onReceive(NotificationCenter.default.publisher(for: .hermesConnectionDidChange)) { _ in
            Task { await reloadAll() }
        }
        // A turn just created a session (or moved its counters) — the list
        // updates live.
        .onReceive(NotificationCenter.default.publisher(for: .hermesSessionsDidChange)) { _ in
            Task { await loadSessions() }
        }
    }

    @ViewBuilder
    private var connectionBanner: some View {
        if case .disconnected(let detail) = addon.connectionState {
            VStack(alignment: .leading, spacing: 6) {
                Label(detail, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundColor(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button(HL("hermes.tab")) {
                    SettingsView.pendingTab = .hermes
                    NotificationCenter.default.post(
                        name: .selectSettingsTab, object: SettingsTab.hermes.rawValue)
                    NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
                }
                .font(.system(size: 11))
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func reloadAll() async {
        async let a: Void = loadSessions()
        async let b: Void = loadSkills()
        async let c: Void = loadToolsets()
        async let d: Void = loadModel()
        _ = await (a, b, c, d)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            headerRow
            contextGauge
        }
    }

    /// Context fill of the OPEN session — a hairline bar with "25K/262K"
    /// under the role's name. Numbers come from `run.completed`: patched
    /// gateways send the true fill (`usage.context_tokens`, the last call's
    /// prompt size); stock ones only give run-cumulative sums, so the value
    /// is capped at the window — a multi-tool turn otherwise "fills" the
    /// gauge severalfold (seen live: 2188K/1050K). Amber past 70%, red past
    /// 85%, where the gateway starts compacting on its own. The denominator
    /// is PER-MODEL (HermesModelContext — Hermes' own table + the gateway's
    /// `model/info`), not one global constant.
    @ViewBuilder
    private var contextGauge: some View {
        if let sessionID = HermesSettings.shared.activeSession(roleID: role.id),
           !sessionID.isEmpty,
           let used = HermesSettings.shared.contextTokens(forSession: sessionID),
           case let limit = HermesModelContext.limit(
               forModel: gaugeModel(forSession: sessionID), settings: settings
           ),
           limit > 0 {
            let used = min(used, limit)
            let fraction = Double(used) / Double(limit)
            let tint: Color = fraction > 0.85 ? .red
                : (fraction > 0.7 ? .orange : palette.secondaryText)
            Button {
                // The gateway's own /compact (alias of /compress) — it folds
                // the middle of the conversation into a summary in place.
                NotificationCenter.default.post(name: .hermesCompactContext, object: nil)
            } label: {
                HStack(spacing: 6) {
                    ZStack(alignment: .leading) {
                        Capsule().fill(palette.secondaryText.opacity(0.18))
                            .frame(height: 4)
                        GeometryReader { geo in
                            Capsule().fill(tint.opacity(0.85))
                                .frame(width: max(2, geo.size.width * fraction), height: 4)
                        }
                        .frame(height: 4)
                    }
                    Text("\(HermesSidebarView.tokensLabel(used))/\(HermesSidebarView.tokensLabel(limit))")
                        .font(.system(size: 10))
                        .foregroundColor(tint)
                        .fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .help(HL("hermes.composer.context.help"))
        }
    }

    /// The model whose context window the gauge measures, most specific
    /// first — the same chain as the composer label: the session's own
    /// lock → the gateway's session row → the global default for new
    /// sessions → the agent's configured model. The literal
    /// "hermes-agent" pseudo-model (an unlocked fresh session) means "the
    /// agent's own model" — returned as nil so the resolver uses the
    /// cached `model/info` answer.
    private func gaugeModel(forSession sessionID: String) -> String? {
        if let lock = settings.modelLock(forSession: sessionID) { return lock.model }
        if let row = sessions.first(where: { $0.id == sessionID })?.model,
           !row.isEmpty, row != "hermes-agent" {
            return row
        }
        if !settings.lockModel.isEmpty { return settings.lockModel }
        return addon.currentModelPair?.model
    }

    /// 262144 → "262K".
    static func tokensLabel(_ tokens: Int) -> String {
        tokens >= 1000 ? "\(tokens / 1000)K" : "\(tokens)"
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            ProviderGlyph(name: role.addonID, fallbackLetter: String(role.icon.prefix(1)), size: 14)
            Text(role.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(palette.primaryText)
            Spacer()
            // Management that needs WRITE access (skill toggles, backends,
            // MCP, messengers) lives in the Hermes app — we deliberately
            // don't fake it here (no admin API; см. обсуждение 2026-07-25).
            Button {
                openHermesApp()
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11))
                    .foregroundColor(palette.secondaryText)
            }
            .buttonStyle(PlainButtonStyle())
            .help(HL("hermes.sidebar.openApp"))
        }
    }

    /// Opens the Hermes desktop app (it registers the hermes:// scheme;
    /// falling back to a plain app launch when the scheme doesn't resolve).
    private func openHermesApp() {
        if let url = URL(string: "hermes://"),
           NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else {
            let bundled = NSHomeDirectory() + "/.hermes/hermes-agent/apps/desktop/release/mac-arm64/Hermes.app"
            NSWorkspace.shared.open(URL(fileURLWithPath: bundled))
        }
    }

    // MARK: Sessions

    /// Session color marks (LOCAL — the gateway stores no pins/colors, the
    /// Hermes desktop keeps its own client-side too).
    private static let markColors: [(name: String, color: Color)] = [
        ("red", .red), ("orange", .orange), ("yellow", .yellow),
        ("green", .green), ("teal", .teal), ("blue", .blue),
        ("purple", .purple), ("pink", .pink), ("gray", .gray)
    ]

    /// Menus render SF Symbols monochrome — a REAL colored dot needs a
    /// non-template NSImage swatch (this is why the color menu looked all
    /// gray; e2e 2026-07-25).
    private static func swatchImage(for color: Color) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(color).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Pinned first, then most recently active — the Hermes desktop's order.
    private var orderedSessions: [HermesSessionInfo] {
        sessions.sorted { a, b in
            let pinnedA = settings.isSessionPinned(a.id)
            let pinnedB = settings.isSessionPinned(b.id)
            if pinnedA != pinnedB { return pinnedA }
            return (a.lastActive ?? .distantPast) > (b.lastActive ?? .distantPast)
        }
    }

    private var sessionsSection: some View {
        AgentSidebarSection(title: HL("hermes.sessions.header"), stateKey: "sessions",
                            isLoading: !loadedSessions, count: sessions.count,
                            defaultExpanded: true,
                            helpText: HL("hermes.sessions.help")) {
            Button {
                startNewSession()
            } label: {
                HStack(spacing: 5) {
                    if creatingSession {
                        ProgressView().controlSize(.mini)
                        Text(HL("hermes.sessions.creating"))
                            .font(.system(size: 11))
                            .foregroundColor(palette.secondaryText)
                    } else {
                        Label(HL("hermes.sessions.new"), systemImage: "plus.circle")
                            .font(.system(size: 11))
                            .foregroundColor(palette.ink)
                    }
                }
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(creatingSession)

            if createSessionFailed {
                Label(HL("hermes.sessions.createFailed"), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundColor(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The open thread's session (each session = its own conversation).
            let boundID = ChatWindowBridge.chatStore.flatMap {
                settings.sessionID(forConversationKey: $0.conversation.storageKey)
            }
            ForEach(orderedSessions) { session in
                sessionRow(session, boundID: boundID)
            }
            if sessions.isEmpty {
                Text(HL("hermes.sessions.empty"))
                    .font(.system(size: 11))
                    .foregroundColor(palette.secondaryText)
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: HermesSessionInfo, boundID: String?) -> some View {
        let isBound = session.id == boundID
        let colorName = settings.sessionColor(session.id)
        let markColor = Self.markColors.first { $0.name == colorName }?.color

        if renamingSessionID == session.id {
            // Inline rename: commit on ⏎, cancel on Esc (field loses focus).
            TextField("", text: $renameDraft, onCommit: {
                commitRename(session)
            })
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .onExitCommand { renamingSessionID = nil }
        } else {
            Button {
                NotificationCenter.default.post(
                    name: .hermesContinueSession, object: nil,
                    userInfo: ["sessionID": session.id]
                )
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let markColor {
                        Circle().fill(markColor).frame(width: 7, height: 7)
                    } else {
                        Image(systemName: isBound ? "checkmark.circle.fill" : "bubble.left")
                            .font(.system(size: 10))
                            .foregroundColor(palette.ink)
                    }
                    let hasTitle = session.title?.isEmpty == false
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 3) {
                            if settings.isSessionPinned(session.id) {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 8))
                                    .foregroundColor(palette.secondaryText)
                            }
                            Text(hasTitle ? session.title! : session.id)
                                .font(.system(size: 12, weight: isBound ? .medium : .regular))
                                .foregroundColor(palette.primaryText)
                                .lineLimit(1)
                            // "Agent is working here": a tiny equalizer wave
                            // beside the title while a turn WE started runs
                            // in this session (turns driven from Telegram/CLI
                            // are outside the local registry). Rendered only
                            // while active, so its timeline never ticks idle.
                            if isAgentWorking(session.id) {
                                MiniActivityWave(color: markColor ?? palette.accent)
                                    .help(HL("hermes.sessions.working"))
                            }
                        }
                        // Title and preview both derive from the first
                        // message — a second line under a titled row only
                        // DUPLICATED it (report 2026-07-31). The preview
                        // stays where it carries information: sessions
                        // listed by raw id (CLI-made, no title), with our
                        // invisible briefing preamble stripped.
                        if !hasTitle, let raw = session.preview {
                            let preview = HermesBriefing.stripped(raw)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            // A TRUNCATED preview can carry the open tag
                            // with its closing tag cut off — stripped()
                            // passes that through; show nothing instead.
                            if !preview.isEmpty, !preview.hasPrefix(HermesBriefing.openTag) {
                                Text(preview)
                                    .font(.system(size: 10))
                                    .foregroundColor(palette.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                    }
                    // Unread badge: growth past the read watermark (set
                    // while the session's thread is open on screen).
                    let unread = addon.unreadCount(for: session)
                    if unread > 0 {
                        Spacer(minLength: 4)
                        Text("\(unread)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(palette.accent, in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .contextMenu {
                Button(HL("hermes.sessions.continue")) {
                    NotificationCenter.default.post(
                        name: .hermesContinueSession, object: nil,
                        userInfo: ["sessionID": session.id]
                    )
                }
                Button(HL("hermes.sessions.rename")) {
                    renameDraft = session.title ?? ""
                    renamingSessionID = session.id
                }
                Button(settings.isSessionPinned(session.id)
                       ? HL("hermes.sessions.unpin") : HL("hermes.sessions.pin")) {
                    settings.toggleSessionPin(session.id)
                }
                Menu(HL("hermes.sessions.color")) {
                    ForEach(Self.markColors, id: \.name) { mark in
                        Button {
                            settings.setSessionColor(mark.name, for: session.id)
                        } label: {
                            Label {
                                Text(HL("hermes.sessions.color.\(mark.name)")
                                     + (colorName == mark.name ? " ✓" : ""))
                            } icon: {
                                Image(nsImage: Self.swatchImage(for: mark.color))
                                    .renderingMode(.original)
                            }
                        }
                    }
                    Divider()
                    Button(HL("hermes.sessions.color.none")) {
                        settings.setSessionColor(nil, for: session.id)
                    }
                }
                Divider()
                Button(role: .destructive) {
                    deleteSession(session)
                } label: {
                    Text(HL("hermes.sessions.delete"))
                }
            }
        }
    }

    // MARK: Session actions

    /// Creates a fresh gateway session, binds the role's chat to it and
    /// mirrors it in (same route the "continue here" flow takes).
    private func startNewSession() {
        guard !creatingSession else { return }
        creatingSession = true
        createSessionFailed = false
        Task {
            defer { creatingSession = false }
            let info: HermesSessionInfo
            do {
                info = try await addon.transport().createSession(title: "Cuate — \(role.displayName)")
            } catch {
                // NOT swallowed (the old `try?` made the click a silent
                // no-op right after wake, before the network was back):
                // the row above the list says what happened, the log says
                // why, and a re-probe turns the connection banner honest —
                // its state was still last night's green.
                createSessionFailed = true
                Diagnostics.log("hermes", "session.create.fail \(String(error.localizedDescription.prefix(120)))")
                await addon.probe()
                return
            }
            // Placeholder name: the first message in this thread renames it
            // (a button has no text to name the session after).
            HermesSettings.shared.markAwaitingTitle(info.id)
            if let pair = await addon.resolveLockPair() {
                try? await addon.transport().lockModel(sessionID: info.id, provider: pair.provider, model: pair.model)
                // The composer label reads the per-session record — a
                // button-made session must show its lock like any other.
                HermesSettings.shared.recordModelLock(provider: pair.provider, model: pair.model, forSession: info.id)
            }
            NotificationCenter.default.post(
                name: .hermesContinueSession, object: nil,
                userInfo: ["sessionID": info.id]
            )
            await loadSessions()
        }
    }

    private func commitRename(_ session: HermesSessionInfo) {
        let title = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingSessionID = nil
        guard !title.isEmpty, title != session.title else { return }
        Task {
            try? await addon.transport().renameSession(id: session.id, title: title)
            await loadSessions()
        }
    }

    private func deleteSession(_ session: HermesSessionInfo) {
        Task {
            // NOT try? — a silently failed DELETE left the session alive on
            // the gateway while this list dropped it: every other surface
            // (the phone) kept showing "deleted" sessions and the user
            // blamed their sync (e2e 2026-07-27). On failure the row stays
            // and the reason lands in diagnostics.
            do {
                try await addon.transport().deleteSession(id: session.id)
            } catch {
                Diagnostics.log("hermes", "session.delete.fail id=\(session.id) \(String(error.localizedDescription.prefix(120)))")
                await loadSessions()
                return
            }
            settings.forgetSessionMarks(session.id)
            // Unbind every thread pointing at the deleted session (default
            // thread and the session's own conversation) so the next send
            // starts fresh instead of 404-ing; drop the local mirror of the
            // session thread — its source of truth is gone.
            let sessionThread = role.conversationID(sessionID: session.id).storageKey
            for key in [role.conversationID.storageKey, sessionThread]
            where settings.sessionID(forConversationKey: key) == session.id {
                settings.unbindSession(forConversationKey: key)
            }
            if settings.activeSession(roleID: role.id) == session.id {
                settings.setActiveSession(nil, roleID: role.id)
            }
            ChatPersistence.deleteConversation(key: sessionThread)
            await loadSessions()
        }
    }

    private func loadSessions() async {
        sessions = (try? await addon.transport().sessions(limit: 50)) ?? []
        addon.updateReadWatermarks(sessions: sessions)
        loadedSessions = true
    }

    // MARK: Skills

    private var skillsSection: some View {
        AgentSidebarSection(title: HL("hermes.sidebar.skills"), stateKey: "skills",
                            isLoading: !loadedSkills, count: skills.count,
                            helpText: HL("hermes.skills.help")) {
            ForEach(skills) { skill in
                AgentSidebarRow(title: skill.name, caption: skill.description, systemImage: "sparkles")
                    .help(skill.description)
            }
        }
    }

    private func loadSkills() async {
        skills = (try? await addon.transport().skills()) ?? []
        loadedSkills = true
    }

    // MARK: Toolsets

    private var toolsetsSection: some View {
        AgentSidebarSection(title: HL("hermes.sidebar.toolsets"), stateKey: "toolsets",
                            isLoading: !loadedToolsets, count: toolsets.count,
                            helpText: HL("hermes.toolsets.help")) {
            ForEach(toolsets) { toolset in
                // The gateway's label arrives emoji-prefixed — used as is.
                AgentSidebarRow(
                    title: toolset.label,
                    caption: toolset.enabled ? nil : HL("hermes.sidebar.toolsetOff")
                )
                .opacity(toolset.enabled ? 1 : 0.5)
                .help(toolset.description)
            }
        }
    }

    private func loadToolsets() async {
        toolsets = (try? await addon.transport().toolsets()) ?? []
        loadedToolsets = true
    }

    // MARK: Agent runtime

    private var agentSection: some View {
        AgentSidebarSection(title: HL("hermes.sidebar.agent"), stateKey: "agent",
                            isLoading: !loadedModel, defaultExpanded: true,
                            helpText: HL("hermes.agent.help")) {
            if let model = currentModel {
                AgentSidebarRow(title: model.model, caption: model.provider, systemImage: "cpu")
            }
            // Where the agent's tools execute. The admin config API is off
            // by default, so the terminal backend itself is not readable —
            // the host + the capabilities' own runtime statement is what we
            // can honestly show (§ security: the human should know where an
            // approved command runs).
            AgentSidebarRow(
                title: settings.baseURL.host ?? settings.endpointURL,
                caption: HL("hermes.sidebar.execNote"),
                systemImage: "desktopcomputer"
            )
        }
    }

    private func loadModel() async {
        currentModel = (try? await addon.transport().modelOptions())?.current
        loadedModel = true
    }

    /// Whether a turn WE started is running in this session right now. The
    /// registry keys by conversation, the sidebar rows by session — the
    /// (small, @Published) session map bridges the two, so rows re-render on
    /// every turn start/end.
    private func isAgentWorking(_ sessionID: String) -> Bool {
        guard let key = settings.sessionMap.first(where: { $0.value == sessionID })?.key
        else { return false }
        return addon.isTurnActive(forConversationKey: key)
    }
}

/// Tiny three-bar equalizer beside a session title — the ThinkingEqualizer's
/// wave scaled to text height. Only ever mounted for sessions with a turn in
/// flight, so its 20 fps timeline never runs idle.
private struct MiniActivityWave: View {
    let color: Color
    private let period = 1.1
    private let cascade = 0.18

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 1.5) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = (now - Double(index) * cascade) * 2 * .pi / period
                    let wave = (1 - cos(phase)) / 2
                    RoundedRectangle(cornerRadius: 0.8)
                        .fill(color)
                        .frame(width: 2, height: 3 + 5 * wave)
                        .opacity(0.45 + 0.55 * wave)
                }
            }
            // Fixed frame: the bars breathe INSIDE it, the row never jitters.
            .frame(width: 2 * 3 + 1.5 * 2, height: 9)
        }
    }
}
