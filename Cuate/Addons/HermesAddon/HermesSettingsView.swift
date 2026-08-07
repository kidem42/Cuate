import SwiftUI

extension Notification.Name {
    /// "Continue here": binds the active Hermes role's conversation to an
    /// existing gateway session (userInfo["sessionID"]). ChatWindow reloads
    /// the conversation and runs catch-up sync.
    static let hermesContinueSession = Notification.Name("hermesContinueSession")

    /// Context gauge clicked: run the gateway's own `/compact` (alias of
    /// `/compress`) as an ordinary turn in the open agent conversation.
    static let hermesCompactContext = Notification.Name("hermesCompactContext")
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

    /// Onboarding commands for a REMOTE gateway over SSH (the local case is
    /// fully automated — HermesLocalGateway). `API_SERVER_HOST=0.0.0.0` is
    /// required: the default binds loopback only, and the connection from
    /// another machine silently refuses without it.
    private static let setupRemoteCommands = """
    ssh USER@HOST 'echo API_SERVER_ENABLED=true >> ~/.hermes/.env; \\
      echo API_SERVER_HOST=0.0.0.0 >> ~/.hermes/.env; \\
      echo API_SERVER_KEY=$(openssl rand -hex 24) >> ~/.hermes/.env; \\
      hermes gateway install; hermes gateway restart'
    ssh USER@HOST "grep '^API_SERVER_KEY=' ~/.hermes/.env"
    """

    /// Context-metric patch for a REMOTE gateway — the same edit
    /// HermesLocalGateway performs on this Mac, as a paste-into-the-VPS
    /// block (we have no file access over there). Anchored by code with a
    /// backup next to the file; idempotent; refuses untouched on foreign
    /// layouts. Battle-tested on the maintainer's VPS 2026-07-30. Mirrors
    /// `HermesLocalGateway.contextPatchLine` — keep the two in sync.
    private static let contextPatchRemoteCommands = """
    HP=$(hermes --version 2>/dev/null | sed -n 's/^Install directory: //p'); \\
    [ -z "$HP" ] && HP=$(dirname "$(dirname "$(dirname "$(find /root /home /opt /usr/local \\
      -name api_server.py -path '*/gateway/platforms/*' 2>/dev/null | head -1)")")"); \\
    echo "hermes at: $HP"; \\
    HERMES_DIR="$HP" python3 - <<'EOF' && hermes gateway restart
    import os, re, pathlib
    p = pathlib.Path(os.environ["HERMES_DIR"]) / "gateway/platforms/api_server.py"
    src = p.read_text()
    if '"context_tokens"' in src:
        print("already patched"); raise SystemExit
    pathlib.Path(str(p) + ".bak").write_text(src)  # backup
    pat = re.compile(r'^(\\s*)("total_tokens": getattr\\(agent, "session_total_tokens", 0\\) or 0,)$', re.M)
    line = '"context_tokens": max(0, getattr(getattr(agent, "context_compressor", None), "last_prompt_tokens", 0) or 0),'
    src2, n = pat.subn(lambda m: m.group(0) + "\\n" + m.group(1) + line, src)
    assert n >= 1, "anchor not found - different Hermes version, patch by hand"
    p.write_text(src2)
    print(f"ok: patched {n} site(s)")
    EOF
    """

    @State private var dashboardTokenInput = ""
    @State private var dashboardTokenMasked: String? = APIKeyStore.maskedKey(aux: .hermesDashboard)

    /// One-click local setup (HermesLocalGateway).
    private enum AutoSetupState: Equatable {
        case idle
        case running(String)
        case succeeded
        case failed(String)
    }
    @State private var autoSetupState: AutoSetupState = .idle

    /// Context-metric patch of the LOCAL gateway (usage.context_tokens —
    /// HermesLocalGateway). nil until the async check ran.
    private enum PatchRowState: Equatable {
        case checking
        case offer
        case running
        case done
        case failed(String)
    }
    @State private var patchRowState: PatchRowState?

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
            briefingSection
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
            autoSetupRow
            contextPatchRow
        } header: {
            Text(HL("hermes.conn.header"))
        } footer: {
            Text(HL("hermes.conn.security"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Offered only when the probe failed, the endpoint is this Mac and a
    /// Hermes install is present — the exact situation the app can repair
    /// itself: the gateway process (which hosts the API server) is not
    /// running as a service.
    /// Whether the offer row is visible: the probe failed against a local
    /// endpoint with Hermes installed — or a setup pass already ran and its
    /// outcome (success line included) must stay on screen.
    private var autoSetupVisible: Bool {
        if autoSetupState != .idle { return true }
        guard case .result(_, ok: false) = probeState else { return false }
        return HermesLocalGateway.isLocalEndpoint(settings.endpointURL)
            && HermesLocalGateway.isInstalled()
    }

    @ViewBuilder
    private var autoSetupRow: some View {
        if autoSetupVisible {
            VStack(alignment: .leading, spacing: 8) {
                if autoSetupState != .succeeded {
                    Text(HL("hermes.auto.found"))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    switch autoSetupState {
                    case .succeeded:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(HL("hermes.auto.ok"))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    case .running(let step):
                        ProgressView().controlSize(.small)
                        Text(step).foregroundColor(.secondary)
                    case .idle, .failed:
                        Button(HL("hermes.auto.run")) {
                            Task { await runAutoSetup() }
                        }
                        if case .failed(let message) = autoSetupState {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(message)
                                .font(.callout)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    /// Offer to patch the LOCAL gateway's context metric when it doesn't
    /// serve `usage.context_tokens` yet (stock install, or `hermes update`
    /// rolled our patch back). Checked lazily on the pane's appearance;
    /// silent when already patched or when there is nothing local to patch —
    /// the row only surfaces an actionable offer or its outcome.
    @ViewBuilder
    private var contextPatchRow: some View {
        if HermesLocalGateway.isLocalEndpoint(settings.endpointURL),
           HermesLocalGateway.isInstalled() {
            VStack(alignment: .leading, spacing: 8) {
                switch patchRowState {
                case nil, .checking:
                    EmptyView()
                case .offer:
                    Text(HL("hermes.patch.found"))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(HL("hermes.patch.run")) {
                        Task { await runContextPatch() }
                    }
                case .running:
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(HL("hermes.patch.running")).foregroundColor(.secondary)
                    }
                case .done:
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        Text(HL("hermes.patch.ok"))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .failed(let message):
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        Text(message)
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .task(id: settings.endpointURL) {
                guard patchRowState == nil || patchRowState == .checking else { return }
                patchRowState = .checking
                let state = await HermesLocalGateway.contextPatchState()
                // .patched and .unavailable both mean "nothing to offer" —
                // the row stays invisible rather than celebrating a default.
                patchRowState = state == .patchable ? .offer : nil
            }
        }
    }

    private func runContextPatch() async {
        patchRowState = .running
        do {
            try await HermesLocalGateway.applyContextPatchAndRestart()
            patchRowState = .done
        } catch {
            patchRowState = .failed(error.localizedDescription)
        }
    }

    /// Env → service → key → probe. On success the key from `.env` is the
    /// canonical one: it replaces whatever is stored, the endpoint follows
    /// the configured port, and the regular probe re-runs — its green line
    /// doubles as the "key verified" confirmation (the probe authenticates
    /// with the Bearer key; a bad key would come back as 401).
    private func runAutoSetup() async {
        autoSetupState = .running(HL("hermes.auto.running"))
        do {
            let result = try await HermesLocalGateway.autoSetup { step in
                Task { @MainActor in
                    if case .running = autoSetupState { autoSetupState = .running(step) }
                }
            }
            guard APIKeyStore.set(result.key, aux: .hermes) else {
                autoSetupState = .failed(HL("hermes.auto.err.keychain"))
                return
            }
            maskedKey = APIKeyStore.maskedKey(aux: .hermes)
            settings.endpointURL = "http://127.0.0.1:\(result.port)"
            // A just-bootstrapped gateway can briefly 401 while its auth
            // warms up — give the probe a few tries before calling it a fail.
            for attempt in 0..<3 {
                autoSetupState = .running(HL("hermes.auto.step.health"))
                await runProbe(interactive: true)
                if case .result(_, ok: true) = probeState { break }
                if attempt < 2 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            }
            if case .result(_, ok: true) = probeState {
                autoSetupState = .succeeded
            } else {
                autoSetupState = .failed(HL("hermes.auto.err.probe"))
            }
        } catch {
            autoSetupState = .failed(error.localizedDescription)
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
            // The probe above just refreshed the cached catalog.
            lockOptions = addon.cachedProviders
            await refreshSessions()
        }
    }

    // MARK: - Server-side setup instructions

    private var setupSection: some View {
        Section {
            // Hermes on THIS Mac needs no terminal: the one-click card in
            // the Connection section (HermesLocalGateway) does everything.
            Text(HL("hermes.setup.local.auto"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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

            Divider()

            // Accurate context gauge on a remote gateway: paste-block for
            // the VPS terminal (locally the app applies the same patch
            // itself — contextPatchRow / autoSetup).
            Text(HL("hermes.setup.patch.title"))
                .font(.callout.weight(.medium))
            commandBlock(Self.contextPatchRemoteCommands)
            Text(HL("hermes.setup.patch.caption"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Full VPS walkthrough (HTTPS, no VPN) — battle-tested, written
            // to be self-sufficient: read it in the preview window, or copy
            // and hand it to any capable LLM to be walked through.
            HStack(spacing: 8) {
                Button(HL("hermes.vps.open")) {
                    ArtifactPreview.show(
                        kind: .markdown,
                        content: HermesVPSGuide.markdown,
                        title: "Hermes on a VPS"
                    )
                }
                Button(HL("hermes.setup.copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(HermesVPSGuide.markdown, forType: .string)
                }
                Spacer()
            }
            Text(HL("hermes.vps.caption"))
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

    // MARK: - Formatting briefing (per-session preamble, HermesBriefing)

    private var briefingSection: some View {
        Section {
            Toggle(HL("hermes.briefing.toggle"), isOn: $settings.briefingEnabled)
        } header: {
            Text(HL("hermes.briefing.header"))
        } footer: {
            Text(HL("hermes.briefing.caption"))
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
                            // Shared path: gateway DELETE + full local
                            // cleanup (unbind, drop the session's mirror).
                            // This button used to fire the bare transport
                            // call and leave an orphaned local thread that
                            // 404-ed on the next send.
                            do {
                                try await addon.deleteSession(id: session.id)
                            } catch {
                                Diagnostics.log("hermes", "session.delete.fail id=\(session.id) \(String(error.localizedDescription.prefix(120)))")
                            }
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


// MARK: - Embedded VPS setup guide

/// The full "Hermes on a VPS in 4 steps" walkthrough (docs/hermes-vps-setup.md,
/// keep the two in sync). Shown from Settings in the markdown preview window
/// and copyable as one piece — written to be self-sufficient so the user can
/// hand it to any capable LLM and be walked through with their values.
enum HermesVPSGuide {
    static let markdown = """
# Hermes on a VPS in 4 steps

You need: a VPS (Ubuntu 22/24, 2+ GB RAM) and a domain. The agent becomes
reachable from any network over HTTPS — no VPN.

This guide is self-sufficient: follow it yourself, or paste it whole into any
capable LLM and it will walk you through with your values filled in.

## Step 1 — DNS

At your domain registrar: two A-records pointing at the server's IP —
`agent` and `dash`. (Server IP: run `curl -s -4 ifconfig.me` on the server —
the `-4` matters, without it you may get an IPv6 address.)

## Step 2 — install (the only interactive step)

```bash
apt update && apt install -y curl && curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash && source ~/.bashrc && hermes
```

The wizard asks four things — answer:

1. **Quick Setup (Nous Portal)** → Enter, log in via the link in a browser
2. Terminal backend → **Local**
3. Egress firewall → **N**
4. Telegram → skip (or Ctrl+C at this step — everything needed is saved)

The agent opens a chat — say "hi", wait for the reply, exit (Ctrl+C).

## Step 3 — everything else in one paste

Replace `YOUR-DOMAIN` on the first line, then paste the whole block:

```bash
DOMAIN="YOUR-DOMAIN"

# API server (chat)
cat >> ~/.hermes/.env <<EOF
API_SERVER_ENABLED=true
API_SERVER_PORT=8642
API_SERVER_KEY=$(openssl rand -hex 24)
EOF
hermes gateway install

# Accurate context gauge: Hermes tracks the real context fill internally but
# does not expose it over the API — add usage.context_tokens (backup lands
# next to the file; skips itself if already applied; repeat after a Hermes
# update, which overwrites the file)
HERMES_DIR=$(hermes --version | sed -n 's/^Install directory: //p') python3 - <<'PYEOF'
import os, re, pathlib
p = pathlib.Path(os.environ["HERMES_DIR"]) / "gateway/platforms/api_server.py"
src = p.read_text()
if '"context_tokens"' not in src:
    pathlib.Path(str(p) + ".bak").write_text(src)
    pat = re.compile(r'^(\\s*)("total_tokens": getattr\\(agent, "session_total_tokens", 0\\) or 0,)$', re.M)
    line = '"context_tokens": max(0, getattr(getattr(agent, "context_compressor", None), "last_prompt_tokens", 0) or 0),'
    src2, n = pat.subn(lambda m: m.group(0) + "\\n" + m.group(1) + line, src)
    if n: p.write_text(src2)
print("context patch ok")
PYEOF
hermes gateway restart

# Dashboard (files) + the one token used everywhere
DASHTOKEN=$(openssl rand -hex 24)
echo "HERMES_DASHBOARD_SESSION_TOKEN=$DASHTOKEN" >> ~/.hermes/.env
HB=$(command -v hermes)
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/hermes-dashboard.service <<EOF
[Unit]
Description=Hermes Dashboard
After=network-online.target
[Service]
ExecStart=$HB dashboard --no-open
Restart=on-failure
RestartSec=5
[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload && systemctl --user enable --now hermes-dashboard

# HTTPS (Caddy issues and renews certificates by itself)
apt install -y caddy
cat > /etc/caddy/Caddyfile <<EOF
agent.$DOMAIN {
    reverse_proxy 127.0.0.1:8642 {
        flush_interval -1
    }
    request_body {
        max_size 64MB
    }
}
dash.$DOMAIN {
    @noauth not header Authorization "Bearer $DASHTOKEN"
    respond @noauth 401
    reverse_proxy 127.0.0.1:9119 {
        header_up Host 127.0.0.1:9119
    }
    request_body {
        max_size 64MB
    }
}
EOF
systemctl reload caddy

# Teach the agent about itself
grep -q "Self-maintenance" ~/.hermes/SOUL.md 2>/dev/null || cat >> ~/.hermes/SOUL.md <<'EOF'

## Self-maintenance
You run on your own VPS with full rights — maintain yourself.
- Code: /usr/local/lib/hermes-agent; config and data: ~/.hermes
- Your services: export XDG_RUNTIME_DIR=/run/user/$(id -u), then
  systemctl --user restart hermes-gateway | hermes-dashboard;
  logs: journalctl --user -u hermes-gateway -n 50
- Install packages freely (apt, pip) — the environment is persistent.
- Do NOT update yourself unless the user explicitly asks.
EOF

# Verify and print the app values
sleep 8
echo "════════════════════════════════════════════"
curl -s https://agent.$DOMAIN/health && echo " ← should say ok"
echo "Gateway address:  https://agent.$DOMAIN"
echo "Key:              $(grep '^API_SERVER_KEY=' ~/.hermes/.env | cut -d= -f2)"
echo "Dashboard URL:    https://dash.$DOMAIN"
echo "Dashboard token:  $DASHTOKEN"
echo "════════════════════════════════════════════"
```

## Step 4 — the app

Cuate → Settings → **Hermes Agent**: paste the four values printed above →
"Check & save" → `✓ hermes-agent`. Done: the 🪽 role appears in the switcher,
sessions in the sidebar, files and images work.

---

## If something goes wrong

| Symptom | Fix |
|---|---|
| Check returns 401 right after install | warm-up — retry in 10 sec |
| `502 Bad Gateway` | the gateway is restarting — wait 30–60 sec |
| health does not answer | `systemctl --user status hermes-gateway`; DNS may not have propagated — check `dig +short agent.YOUR-DOMAIN` |
| File upload → `Unauthorized` | the app's token ≠ `HERMES_DASHBOARD_SESSION_TOKEN` in `~/.hermes/.env` |
| The agent's terminal does not work at all | egress firewall was enabled — set `proxy.enabled: false` in `~/.hermes/config.yaml` + restart the gateway |
| The agent "cannot see" files/images | Docker terminal backend is still active: set `backend: local` in config.yaml **and** delete the `TERMINAL_ENV=docker` line from `.env`, restart |
| Something broke after `hermes update` | roll back: `cd /usr/local/lib/hermes-agent && git fetch --unshallow; git checkout <previous commit> && systemctl --user restart hermes-gateway` |

## If ports 80/443 are already taken on the server

Step 3 assumes a clean server. If another web stack already owns 80/443,
Caddy will not bind; your existing proxy must provide (hand these
requirements plus this file to an LLM — the config follows from them):

- `agent.domain` → `127.0.0.1:8642`: **no buffering** (SSE),
  read timeout ≥ 3600 s, body ≤ 64 MB;
- `dash.domain` → `127.0.0.1:9119`: a Bearer gate comparing against
  `$DASHTOKEN` (in nginx put it in the location context, not the server
  context — otherwise the ACME challenge gets blocked and no certificate is
  ever issued), rewrite `Host` to `127.0.0.1:9119`, body ≤ 64 MB;
- proven for jwilder/nginx-proxy: `alpine/socat` bridge containers with
  `VIRTUAL_HOST`/`LETSENCRYPT_HOST`, gateway on `API_SERVER_HOST=0.0.0.0`
  plus `ufw allow from 172.16.0.0/12`, vhost.d configs written **only by
  full rewrite** (`cat >`), and `docker exec nginx-proxy nginx -t` before
  every reload.
"""
}
