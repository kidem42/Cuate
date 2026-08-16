import SwiftUI
import AppKit

/// The addon's Settings tab (pattern: `CalendarSettingsView`). Shown only
/// while the addon is enabled — the master switch lives in the General tab.
struct PlaudSettingsView: View {
    @ObservedObject private var settings = PlaudSettings.shared

    enum ConnectState: Equatable {
        case idle
        case connecting
        case failed(String)
    }

    @State private var connectState = ConnectState.idle

    /// Outcome of the last grant action (see `agentGrantSection`).
    private enum GrantState: Equatable {
        case idle
        /// Asking the agent host what it holds.
        case checking
        case working
        case done
        case failed(String)
    }
    @State private var grantState = GrantState.idle
    /// What the agent host holds, as of the last check.
    @State private var grantStatus = PlaudAgentGrant.Status.absent

    var body: some View {
        Form {
            introSection
            connectionSection
            if settings.isConnected {
                exposureSection
                agentGrantSection
            }
        }
        .formStyle(.grouped)
        .onAppear { PlaudAddon.shared.refreshConnectionState() }
        // A Keychain blob is not a live session: ask Plaud. Without this the
        // card kept showing a green checkmark over an expired grant while
        // every chat tool call failed.
        .task { await PlaudAddon.shared.verifyConnection() }
    }

    // MARK: - Sections

    private var introSection: some View {
        Section {
            HStack(spacing: 10) {
                // Official PLAUD wordmark — original mark, template-tinted to
                // the label color so it adapts to light/dark like their own UI.
                Image("Plaud-wordmark")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(height: 16)
                    .foregroundStyle(.primary)
                Text("×")
                    .font(.system(size: 14, weight: .light))
                    .foregroundColor(.secondary)
                Text("Cuate")
                    .font(.system(size: 15, weight: .semibold))
            }
            .padding(.vertical, 2)
            Text(PLL("plaud.footer"))
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connectionSection: some View {
        Section(PLL("plaud.connection.header")) {
            if settings.isConnected {
                connectedCard
            } else if settings.needsReauth {
                expiredCard
            } else {
                disconnectedCard
            }
            if case .failed(let message) = connectState {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            Button(PLL("plaud.openApp")) {
                PlaudAddon.openInPlaud()
            }
            .font(.caption)
        }
    }

    private var connectedCard: some View {
        HStack(spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(settings.accountName ?? PLL("plaud.connected"))
                    .fontWeight(.medium)
                if let email = settings.accountEmail {
                    Text(email)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            Button(PLL("plaud.disconnect")) {
                Task { @MainActor in
                    await PlaudAddon.shared.disconnect()
                    connectState = .idle
                }
            }
        }
    }

    private var disconnectedCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(PLL("plaud.notConnected"))
                .font(.callout)
                .foregroundColor(.secondary)
            connectControls(title: PLL("plaud.connect"))
            Text(PLL("plaud.connect.hint"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    /// Plaud rejected the stored grant (its refresh token dies on a ~week
    /// clock, and access can be revoked in the Plaud app). Naming the account
    /// and the single fix beats the neutral "not connected" card — the user
    /// did not disconnect anything and would otherwise wonder what broke.
    private var expiredCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(PLL("plaud.expired"))
                        .fontWeight(.medium)
                    if let email = settings.accountEmail ?? settings.accountName {
                        Text(email)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            connectControls(title: PLL("plaud.reconnect"))
            Text(PLL("plaud.expired.hint"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    /// Connect/Reconnect button plus everything the OAuth wait needs — one
    /// copy shared by the "never connected" and "session expired" cards.
    @ViewBuilder
    private func connectControls(title: String) -> some View {
        HStack(spacing: 8) {
            Button {
                connect()
            } label: {
                if connectState == .connecting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(PLL("plaud.connecting"))
                    }
                } else {
                    Text(title)
                }
            }
            .disabled(connectState == .connecting)
            if connectState == .connecting {
                Button(PLL("plaud.cancel")) {
                    PlaudAddon.shared.cancelConnect()
                }
            }
        }
        if connectState == .connecting, let url = settings.pendingAuthURL {
            // The sign-in opened in the DEFAULT browser; the user's Plaud
            // session may live in another one — hand them the link.
            HStack(spacing: 8) {
                Button(PLL("plaud.copyLink")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
                .font(.caption)
                Text(PLL("plaud.copyLink.hint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    /// Hands the connected Hermes agent its own copy of the grant, so it can
    /// read the library on every surface it has — not just inside this app.
    /// Only shown once both accounts are connected: without an agent there is
    /// nowhere to send it, and without Plaud there is nothing to send.
    @ViewBuilder
    private var agentGrantSection: some View {
        if PlaudAddon.shared.isAvailable, HermesSettings.shared.enabled {
            Section {
                // What the agent host holds right now — asked on appearance
                // and after every action, so the row is never a guess.
                HStack(spacing: 8) {
                    Image(systemName: grantStatusIcon)
                        .foregroundColor(grantStatusColor)
                    Text(grantStatusText)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if grantState == .checking { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(PLL("plaud.grant.recheck")) {
                        Task { await refreshGrantStatus() }
                    }
                    .disabled(grantState == .working || grantState == .checking)
                }

                HStack(spacing: 10) {
                    Button(PLL("plaud.grant.action")) {
                        Task { await grantAgentAccess() }
                    }
                    .disabled(grantState == .working || grantState == .checking)
                    if grantStatus != .absent {
                        Button(PLL("plaud.grant.revoke"), role: .destructive) {
                            Task { await revokeAgentAccess() }
                        }
                        .disabled(grantState == .working || grantState == .checking)
                    }
                    switch grantState {
                    case .idle, .checking:
                        EmptyView()
                    case .working:
                        ProgressView().controlSize(.small)
                    case .done:
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    case .failed(let message):
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        Text(message)
                            .font(.callout).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text(PLL("plaud.grant.header"))
            } footer: {
                Text(PLL("plaud.grant.caption"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Asked when the section appears: the row otherwise shows whatever
            // the last visit left in @State, which reads as a stale "granted"
            // long after the grant is gone.
            .task { await refreshGrantStatus() }
        }
    }

    private func grantAgentAccess() async {
        grantState = .working
        do {
            try await PlaudAgentGrant.grant()
            grantState = .done
        } catch {
            grantState = .failed(error.localizedDescription)
        }
        await refreshGrantStatus()
    }

    private func revokeAgentAccess() async {
        grantState = .working
        do {
            try await PlaudAgentGrant.revoke()
            grantState = .done
        } catch {
            grantState = .failed(error.localizedDescription)
        }
        await refreshGrantStatus()
    }

    private func refreshGrantStatus() async {
        let previous = grantState
        grantState = .checking
        grantStatus = await PlaudAgentGrant.status()
        // A finished action keeps its checkmark; a plain re-check goes quiet.
        grantState = (previous == .working) ? .done : .idle
    }

    private var grantStatusText: String {
        switch grantStatus {
        case .absent: return PLL("plaud.grant.status.absent")
        case .current: return PLL("plaud.grant.status.current")
        case .stale: return PLL("plaud.grant.status.stale")
        case .present: return PLL("plaud.grant.status.present")
        case .unknown(let detail): return PLL("plaud.grant.status.unknown") + " " + detail
        }
    }

    private var grantStatusIcon: String {
        switch grantStatus {
        case .absent: return "lock.fill"
        case .current: return "checkmark.seal.fill"
        case .stale: return "exclamationmark.triangle.fill"
        case .present: return "questionmark.circle.fill"
        case .unknown: return "wifi.exclamationmark"
        }
    }

    private var grantStatusColor: Color {
        switch grantStatus {
        case .absent: return .secondary
        case .current: return .green
        case .stale: return .orange
        case .present, .unknown: return .secondary
        }
    }

    private var exposureSection: some View {
        Section {
            Toggle(PLL("plaud.exposure.always"), isOn: $settings.alwaysAvailable)
        } header: {
            Text(PLL("plaud.exposure.header"))
        } footer: {
            Text(PLL("plaud.exposure.caption"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let urlString = settings.accountAvatarURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                avatarFallback
            }
            .frame(width: 28, height: 28)
            .clipShape(Circle())
        } else {
            avatarFallback
        }
    }

    private var avatarFallback: some View {
        Image("Provider-plaud")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: 16, height: 16)
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .background(Circle().fill(Color.secondary.opacity(0.15)))
    }

    private func connect() {
        connectState = .connecting
        Task { @MainActor in
            do {
                try await PlaudAddon.shared.connect()
                connectState = .idle
            } catch {
                // A user-initiated cancel is not an error — reset quietly.
                if let plaudError = error as? PlaudClient.PlaudError, plaudError.isCancellation {
                    connectState = .idle
                } else {
                    connectState = .failed(error.localizedDescription)
                }
            }
        }
    }
}

/// Master switch for the General tab (pattern: `CalendarEnableToggle`).
struct PlaudEnableToggle: View {
    @ObservedObject private var settings = PlaudSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: $settings.enabled) { FeatureTitle(raw: PLL("plaud.general.enable")) }
            Text(PLL("plaud.general.enable.caption"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
