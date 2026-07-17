import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The addon's Settings tab (pattern: `LayoutFixSettingsView`). Shown only
/// while the addon is enabled — the master switch lives in the General tab.
///
/// The key row mirrors the host Keys tab exactly: provider glyph, masked
/// key, live validation with ✓/✗/spinner and an inline error line.
struct ImageAddonSettingsView: View {
    @ObservedObject private var settings = ImageAddonSettings.shared

    enum KeyTestState: Equatable {
        case testing
        case ok
        case failed(String)
    }

    @State private var keyInput = ""
    @State private var maskedKey: String?
    @State private var keyTest: KeyTestState?

    var body: some View {
        Form {
            introSection
            keySection
            modelSection(titleKey: "ia.upscale.header", function: .upscale, selection: $settings.upscaleModel)
            modelSection(titleKey: "ia.bg.header", function: .removeBackground, selection: $settings.backgroundModel)
            cleanupSection
            optionsSection
            saveSection
            spendSection
        }
        .formStyle(.grouped)
        .onAppear {
            refreshMask()
            if APIKeyStore.hasKey(aux: .fal) { validateKey() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .apiKeysDidChange)) { _ in
            refreshMask()
        }
    }

    // MARK: - Intro

    private var introSection: some View {
        Section {
            Text(IAL("ia.footer"))
                .font(.callout)
                .foregroundColor(.secondary)
        } header: {
            Text(IAL("ia.header"))
        }
    }

    // MARK: - fal.ai key (full Keys-tab pattern: glyph, validation, errors)

    private var keySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    HStack(spacing: 6) {
                        ProviderGlyph(name: "fal", fallbackLetter: "F", size: 14)
                        Text("fal.ai")
                    }
                    .frame(width: 150, alignment: .leading)
                    if let masked = maskedKey {
                        HStack(spacing: 6) {
                            Text(masked)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundColor(.secondary)
                            keyTestIndicator
                        }
                        Spacer()
                        Button(L("keys.recheck")) {
                            validateKey()
                        }
                        .disabled(keyTest == .testing)
                        Button(L("keys.remove")) {
                            APIKeyStore.remove(aux: .fal)
                            keyTest = nil
                            refreshMask()
                        }
                    } else {
                        SecureField(L("keys.paste"), text: $keyInput)
                            .textFieldStyle(.roundedBorder)
                        Link(destination: URL(string: "https://fal.ai/dashboard/keys")!) {
                            Text(L("keys.get"))
                                .font(.caption)
                        }
                        Button(L("keys.save")) {
                            if APIKeyStore.set(keyInput, aux: .fal) {
                                keyInput = ""
                                refreshMask()
                                validateKey()
                            }
                        }
                        .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if case .failed(let message) = keyTest {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text(IAL("ia.keys.header"))
        } footer: {
            Text(IAL("ia.keys.footer"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// ✓ / ✗ / spinner next to the saved key (same look as the Keys tab).
    @ViewBuilder
    private var keyTestIndicator: some View {
        switch keyTest {
        case .testing:
            ProgressView().controlSize(.small)
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .help(L("keys.valid"))
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
                .help(L("keys.checkFailed"))
        case nil:
            EmptyView()
        }
    }

    /// No-cost live check of the stored key (auth probe, see FalImageProvider).
    private func validateKey() {
        keyTest = .testing
        Task {
            do {
                guard let key = APIKeyStore.key(aux: .fal) else {
                    throw ImageAddonError.missingKey
                }
                try await FalImageProvider.validateKey(key)
                keyTest = .ok
            } catch {
                keyTest = .failed(error.localizedDescription)
            }
        }
    }

    private func refreshMask() {
        maskedKey = APIKeyStore.maskedKey(aux: .fal)
    }

    // MARK: - Model pickers (ТЗ §3.1a: имя + бейдж + подпись + цена)

    private func modelSection(titleKey: String, function: ImageFunction, selection: Binding<String>) -> some View {
        Section {
            ImageModelPicker(models: ImageProviderRegistry.models(for: function), selection: selection)
        } header: {
            Text(IAL(titleKey))
        }
    }

    /// Cleanup has two lanes: mask model (picker) + fixed by-text model.
    private var cleanupSection: some View {
        Section {
            ImageModelPicker(
                models: ImageProviderRegistry.models(for: .objectCleanup).filter { !$0.cleanupByText },
                selection: $settings.cleanupModel
            )
            if let textModel = settings.cleanupTextModelInfo {
                ImageModelRow(model: textModel, isSelected: true, showsCheckmark: false) {}
            }
        } header: {
            Text(IAL("ia.cleanup.header"))
        } footer: {
            Text(IAL("ia.cleanup.footer"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Options (ТЗ §4.5)

    private var optionsSection: some View {
        Section {
            Picker(IAL("ia.options.outputFormat"), selection: $settings.outputFormat) {
                ForEach(ImageOutputFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.segmented)
            Toggle(IAL("ia.options.autoCopy"), isOn: $settings.autoCopyResult)
            Picker(IAL("ia.options.maxInput"), selection: $settings.maxInputMegapixels) {
                ForEach([12.0, 25.0, 50.0], id: \.self) { mp in
                    Text(String(format: IAL("ia.options.mp"), Int(mp))).tag(mp)
                }
            }
        } header: {
            Text(IAL("ia.options.header"))
        } footer: {
            Text(IAL("ia.options.footer"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Save folder (Downloads by default, custom via picker)

    private var saveSection: some View {
        Section {
            LabeledContent(IAL("ia.save.folder")) {
                HStack(spacing: 8) {
                    Text(settings.saveFolderPath == nil
                         ? IAL("ia.save.downloads")
                         : abbreviatedPath(settings.saveFolderURL))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(settings.saveFolderURL.path)
                    Button(IAL("ia.save.choose")) { chooseFolder() }
                    if settings.saveFolderPath != nil {
                        Button(IAL("ia.save.reset")) { settings.saveFolderPath = nil }
                    }
                }
            }
        } header: {
            Text(IAL("ia.save.header"))
        } footer: {
            Text(IAL("ia.save.footer"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func abbreviatedPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.saveFolderURL
        // The Settings window is a regular window (no auto-hide), so a
        // modal open panel is safe here.
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveFolderPath = url.path
        }
    }

    // MARK: - Spending (local estimates)

    private var spendSection: some View {
        Section {
            LabeledContent(IAL("ia.spend.session"), value: Self.usd(settings.sessionSpentUSD))
            LabeledContent(IAL("ia.spend.month"), value: Self.usd(settings.spentMonthUSD))
        } header: {
            Text(IAL("ia.spend.header"))
        } footer: {
            Text(IAL("ia.spend.footer"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    static func usd(_ value: Double) -> String {
        String(format: "$%.3f", value)
    }
}

// MARK: - Rich model picker (ТЗ §3.1a)

/// Radio-style list: each row shows the model name, its class badge
/// (Бюджет/Стандарт/…), the price, and a one-line caption — so the user
/// understands HOW to choose, not just what the names are.
struct ImageModelPicker: View {
    let models: [ImageModelInfo]
    @Binding var selection: String

    var body: some View {
        ForEach(models) { model in
            ImageModelRow(model: model, isSelected: model.id == selection, showsCheckmark: true) {
                selection = model.id
            }
        }
    }
}

struct ImageModelRow: View {
    let model: ImageModelInfo
    let isSelected: Bool
    /// false — informational row (single fixed model), no selection UI.
    let showsCheckmark: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if showsCheckmark {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isSelected ? .accentColor : .secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(model.name)
                            .fontWeight(isSelected && showsCheckmark ? .medium : .regular)
                        tierBadge
                        Spacer()
                        Text(model.priceLabel)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text(model.caption)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var tierBadge: some View {
        Text(model.tier.label)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(badgeColor.opacity(0.18)))
            .foregroundColor(badgeColor)
    }

    private var badgeColor: Color {
        switch model.tier {
        case .budget: return .green
        case .standard: return .blue
        case .quality: return .teal
        case .premium: return .purple
        case .smart: return .orange
        case .freedom: return .pink
        }
    }
}

/// The addon's master on/off switch, embedded in the app's General tab
/// (pattern: `LayoutFixEnableToggle`). Turning it on reveals the Images tab.
struct ImageAddonEnableToggle: View {
    @ObservedObject private var settings = ImageAddonSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(IAL("ia.general.enable"), isOn: $settings.enabled)
            Text(IAL("ia.general.enable.caption"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
