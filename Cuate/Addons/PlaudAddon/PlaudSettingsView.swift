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

    var body: some View {
        Form {
            introSection
            connectionSection
            if settings.isConnected {
                exposureSection
            }
        }
        .formStyle(.grouped)
        .onAppear { PlaudAddon.shared.refreshConnectionState() }
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
                        Text(PLL("plaud.connect"))
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
            Text(PLL("plaud.connect.hint"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
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
