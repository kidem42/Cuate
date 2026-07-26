import SwiftUI

extension Notification.Name {
    /// "Continue here": binds the active Hermes role's conversation to an
    /// existing gateway session (userInfo["sessionID"]). ChatWindow reloads
    /// the conversation and runs catch-up sync.
    static let hermesContinueSession = Notification.Name("hermesContinueSession")
}

/// The addon's Settings tab (pattern: `CalendarSettingsView`). One-time
/// configuration lives here: connection, key, model lock, history mode,
/// notifications, diagnostics, and the gateway session list. Operational
/// controls (skills, jobs, live sessions) live in the chat sidebar.
struct HermesSettingsView: View {
    @ObservedObject private var settings = HermesSettings.shared
    @ObservedObject private var addon = HermesAddon.shared
    // Re-renders on interface-language changes (the L() pattern).
    @ObservedObject private var appSettings = AppSettings.shared

    @State private var keyInput = ""
    @State private var maskedKey: String? = APIKeyStore.maskedKey(aux: .hermes)
    @State private var probeState: ProbeState = .idle
    @State private var lockOptions: [HermesProviderOption] = []
    @State private var sessions: [HermesSessionInfo] = []
    @State private var sessionsLoaded = false

    private enum ProbeState: Equatable {
        case idle
        case testing
        case result(String, ok: Bool)
    }

    /// Onboarding commands: enable the API server + read the key back.
    /// Local (this Mac) and remote (over SSH) variants — the remote one adds
    /// `API_SERVER_HOST=0.0.0.0`: the default binds loopback only, and the
    /// connection from another machine silently refuses without it.
    private static let setupLocalCommands = """
    echo 'API_SERVER_ENABLED=true' >> ~/.hermes/.env
    echo "API_SERVER_KEY=$(openssl rand -hex 24)" >> ~/.hermes/.env
    hermes gateway install
    """
    private static let showLocalKeyCommand = """
    grep '^API_SERVER_KEY=' ~/.hermes/.env | cut -d= -f2
    """
    private static let setupRemoteCommands = """
    ssh USER@HOST 'echo API_SERVER_ENABLED=true >> ~/.hermes/.env; \\
      echo API_SERVER_HOST=0.0.0.0 >> ~/.hermes/.env; \\
      echo API_SERVER_KEY=$(openssl rand -hex 24) >> ~/.hermes/.env; \\
      hermes gateway restart'
    ssh USER@HOST "grep '^API_SERVER_KEY=' ~/.hermes/.env"
    """

    @State private var dashboardTokenInput = ""
    @State private var dashboardTokenMasked: String? = APIKeyStore.maskedKey(aux: .hermesDashboard)

    /// Remote-file courier: the dashboard's files API (needed only when the
    /// gateway is on another machine).
    private var dashboardSection: some View {
        Section {
            TextField(HL("hermes.dash.url"), text: $settings.dashboardURL,
                      prompt: Text(HL("hermes.dash.url.placeholder")))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            HStack {
                if let masked = dashboardTokenMasked {
                    Text(masked)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(HL("hermes.conn.key.remove")) {
                        _ = APIKeyStore.remove(aux: .hermesDashboard)
                        dashboardTokenMasked = nil
                    }
                } else {
                    SecureField(HL("hermes.dash.token"), text: $dashboardTokenInput)
                        .textFieldStyle(.roundedBorder)
                    Button(HL("hermes.conn.key.save")) {
                        if APIKeyStore.set(dashboardTokenInput, aux: .hermesDashboard) {
                            dashboardTokenInput = ""
                            dashboardTokenMasked = APIKeyStore.maskedKey(aux: .hermesDashboard)
                        }
                    }
                    .disabled(dashboardTokenInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } header: {
            Text(HL("hermes.dash.header"))
        } footer: {
            Text(HL("hermes.dash.caption"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var body: some View {
        Form {
            connectionSection
            dashboardSection
            setupSection
            modelSection
            historySection
            appFeaturesSection
            notificationsSection
            sessionsSection
        }
        .formStyle(.grouped)
        .task {
            // Silent initial probe so the tab opens with live state.
            if case .idle = probeState { await runProbe(interactive: false) }
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section {
            TextField(HL("hermes.conn.endpoint"), text: $settings.endpointURL)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .help(HL("hermes.conn.endpoint.help"))

            HStack {
                if let masked = maskedKey {
                    Text(masked)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(HL("hermes.conn.key.remove")) {
                        _ = APIKeyStore.remove(aux: .hermes)
                        maskedKey = nil
                    }
                } else {
                    SecureField(HL("hermes.conn.key.placeholder"), text: $keyInput)
                        .textFieldStyle(.roundedBorder)
                    Button(HL("hermes.conn.key.save")) {
                        if APIKeyStore.set(keyInput, aux: .hermes) {
                            keyInput = ""
                            maskedKey = APIKeyStore.maskedKey(aux: .hermes)
                            Task { await runProbe(interactive: true) }
                        }
                    }
                    .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            HStack(spacing: 10) {
                Button(HL("hermes.conn.test")) {
                    Task { await runProbe(interactive: true) }
                }
                .disabled(probeState == .testing)
                switch probeState {
                case .idle:
                    EmptyView()
                case .testing:
                    ProgressView().controlSize(.small)
                    Text(HL("hermes.conn.testing")).foregroundColor(.secondary)
                case .result(let message, let ok):
                    Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(ok ? .green : .orange)
                    Text(message)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text(HL("hermes.conn.header"))
        } footer: {
            Text(HL("hermes.conn.security"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func runProbe(interactive: Bool) async {
        if interactive { probeState = .testing }
        let result = await addon.probe()
        let ok = result.status == .ok
        var message = result.status.message
        if ok, let info = result.serverInfo {
            message += " (\(info))"
        }
        // The silent startup probe only surfaces success — a red banner
        // before the user did anything reads as an error out of nowhere.
        if interactive || ok {
            probeState = .result(message, ok: ok)
        }
        if ok {
            lockOptions = (try? await addon.transport().modelOptions())?.providers ?? []
            await refreshSessions()
        }
    }

    // MARK: - Server-side setup instructions

    private var setupSection: some View {
        Section {
            // Hermes on THIS Mac: enable once, then read the key back.
            Text(HL("hermes.setup.local.title"))
                .font(.callout.weight(.medium))
            commandBlock(Self.setupLocalCommands)
            Text(HL("hermes.setup.showKey"))
                .font(.caption)
                .foregroundColor(.secondary)
            commandBlock(Self.showLocalKeyCommand)

            Divider()

            // Hermes on a remote machine: same over SSH, plus the bind to
            // 0.0.0.0 — without it the server listens on loopback only.
            Text(HL("hermes.setup.remote.title"))
                .font(.callout.weight(.medium))
            commandBlock(Self.setupRemoteCommands)
            Text(HL("hermes.setup.remote.caption"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text(HL("hermes.setup.header"))
        }
    }

    /// Monospaced command card with a copy button.
    private func commandBlock(_ commands: String) -> some View {
        HStack(alignment: .top) {
            Text(commands)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(HL("hermes.setup.copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commands, forType: .string)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Model lock

    private var modelSection: some View {
        Section {
            Picker(HL("hermes.model.header"), selection: lockSelection) {
                Text(HL("hermes.model.auto")).tag("")
                ForEach(lockOptions.filter { !$0.models.isEmpty }) { option in
                    // Flat "provider / model" list; only providers that
                    // actually serve models on this gateway.
                    ForEach(option.models, id: \.self) { model in
                        Text("\(option.name) · \(model)").tag("\(option.slug)|\(model)")
                    }
                }
            }
        } footer: {
            Text(HL("hermes.model.caption"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "provider|model" combined tag ↔ the two stored fields.
    private var lockSelection: Binding<String> {
        Binding {
            settings.lockProvider.isEmpty ? "" : "\(settings.lockProvider)|\(settings.lockModel)"
        } set: { raw in
            let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
            settings.lockProvider = parts.count == 2 ? parts[0] : ""
            settings.lockModel = parts.count == 2 ? parts[1] : ""
        }
    }

    // MARK: - History

    private var historySection: some View {
        Section {
            Picker(HL("hermes.history.header"), selection: $settings.historyMode) {
                Text(HL("hermes.history.mirror")).tag(HermesHistoryMode.mirror)
                Text(HL("hermes.history.archive")).tag(HermesHistoryMode.archive)
            }
            .pickerStyle(.segmented)
        } header: {
            Text(HL("hermes.history.header"))
        } footer: {
            Text(HL("hermes.history.caption"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Host app features (separate opt-in, ImageAddon + OCR)

    private var appFeaturesSection: some View {
        Section {
            Toggle(HL("hermes.appFeatures.toggle"), isOn: $settings.imageFeaturesEnabled)
        } header: {
            Text(HL("hermes.appFeatures.header"))
        } footer: {
            Text(HL("hermes.appFeatures.caption"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        Section {
            Toggle(HL("hermes.notif.hideDetails"), isOn: $settings.hideNotificationDetails)
        } header: {
            Text(HL("hermes.notif.header"))
        } footer: {
            Text(HL("hermes.notif.hideDetails.caption"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Sessions

    private var sessionsSection: some View {
        Section {
            if sessions.isEmpty {
                Text(sessionsLoaded ? HL("hermes.sessions.empty") : "…")
                    .foregroundColor(.secondary)
            }
            ForEach(sessions) { session in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title?.isEmpty == false ? session.title! : session.id)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            if let source = session.source {
                                Text(source).font(.caption).foregroundColor(.secondary)
                            }
                            Text(String(format: HL("hermes.sessions.messages"), session.messageCount))
                                .font(.caption).foregroundColor(.secondary)
                            if let active = session.lastActive {
                                Text(active, style: .relative)
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                        if let preview = session.preview, !preview.isEmpty {
                            Text(preview)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Button(HL("hermes.sessions.continue")) {
                        NotificationCenter.default.post(
                            name: .hermesContinueSession, object: nil,
                            userInfo: ["sessionID": session.id]
                        )
                    }
                    .font(.caption)
                    Button(role: .destructive) {
                        Task {
                            try? await addon.transport().deleteSession(id: session.id)
                            await refreshSessions()
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button(HL("hermes.sessions.refresh")) {
                Task { await refreshSessions() }
            }
        } header: {
            Text(HL("hermes.sessions.header"))
        } footer: {
            Text(HL("hermes.sessions.caption"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func refreshSessions() async {
        sessions = (try? await addon.transport().sessions()) ?? []
        sessionsLoaded = true
    }
}

/// Master switch for the General tab (pattern: `WorldTimeEnableToggle`).
struct HermesEnableToggle: View {
    @ObservedObject private var settings = HermesSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: $settings.enabled) { FeatureTitle(raw: HL("hermes.general.enable")) }
                .onChange(of: settings.enabled) { _, enabled in
                    guard enabled else { return }
                    // Predictable TCC moment: permission is asked when the
                    // user flips the switch, never at app start or mid-chat
                    // (the CalendarAddon pattern). The probe fills the role
                    // list so the switcher shows the agent right away.
                    NotificationService.shared.requestPermissionIfNeeded()
                    Task { await HermesAddon.shared.probe() }
                }
            Text(HL("hermes.general.enable.caption"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
