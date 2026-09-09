import SwiftUI
import AppKit

/// The addon's Settings tab. Self-contained: its own grouped Form, the host
/// `ShortcutRecorderView` for the hotkey, the host's provider list for the
/// model choice.
struct TranslatorSettingsView: View {
    @ObservedObject private var settings = TranslatorSettings.shared
    @ObservedObject private var appSettings = AppSettings.shared
    @ObservedObject private var worldTime = WorldTimeSettings.shared
    @ObservedObject private var layoutFix = LayoutFixSettings.shared

    @State private var accessibilityGranted = true

    var body: some View {
        Form {
            introSection
            hotkeySection
            languagesSection
            modelSection
            behaviorSection
            if !accessibilityGranted {
                accessibilitySection
            }
        }
        .formStyle(.grouped)
        .onAppear { accessibilityGranted = TextInserter.checkAccessibility(promptIfNeeded: false) }
    }

    // MARK: - Intro

    private var introSection: some View {
        Section {
            Text(TRL("tr.footer"))
                .font(.callout)
                .foregroundColor(.secondary)
        } header: {
            Text(TRL("tr.header"))
        }
    }

    // MARK: - Hotkey

    /// Every shortcut already taken elsewhere, so the recorder rejects it.
    private var hostHotkeys: [HotkeyCombo] {
        var combos = [appSettings.togglePanelHotkey, appSettings.screenshotHotkey,
                      appSettings.areaScreenshotHotkey, appSettings.dictationHotkey,
                      appSettings.dictationTranslateHotkey]
        if worldTime.enabled { combos.append(worldTime.hotkey) }
        if layoutFix.enabled {
            combos.append(layoutFix.flipHotkey)
            if layoutFix.smartEnabled { combos.append(layoutFix.smartHotkey) }
        }
        return combos
    }

    private var hotkeySection: some View {
        Section {
            ShortcutRecorderView(
                title: TRL("tr.hotkey"),
                combo: $settings.hotkey,
                conflictingCombos: hostHotkeys
            )
            .help(TRL("tr.help.hotkey"))
            Button(L("hotkeys.reset")) {
                settings.resetHotkey()
            }
            .help(TRL("tr.help.hotkey"))
        } header: {
            Text(TRL("tr.hotkeys.header"))
        } footer: {
            Text(TRL("tr.hotkeys.footer"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Languages

    private var languagesSection: some View {
        Section {
            Picker(TRL("tr.lang.target"), selection: $settings.targetLanguage) {
                ForEach(AppSettings.dictationLanguages, id: \.self) { language in
                    Text(language).tag(language)
                }
            }
            .help(TRL("tr.help.target"))
            Picker(TRL("tr.lang.fallback"), selection: $settings.fallbackLanguage) {
                ForEach(AppSettings.dictationLanguages, id: \.self) { language in
                    Text(language).tag(language)
                }
            }
            .help(TRL("tr.help.fallback"))
        } header: {
            Text(TRL("tr.lang.header"))
        } footer: {
            Text(TRL("tr.lang.caption"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Model

    private var modelSection: some View {
        Section {
            // Only providers that can run right now, plus "same as dictation";
            // a keyless provider offered here would silently fall back.
            Picker(TRL("tr.model.provider"), selection: Binding(
                get: { settings.provider?.rawValue ?? "" },
                set: { settings.provider = ProviderID(rawValue: $0) }
            )) {
                Text(TRL("tr.model.same")).tag("")
                ForEach(appSettings.cleanupProviders) { provider in
                    Label {
                        Text(provider.displayName)
                    } icon: {
                        ProviderLogo(provider: provider, size: 14)
                    }
                    .tag(provider.rawValue)
                }
            }
            .help(TRL("tr.help.provider"))

            if let provider = settings.provider, appSettings.isCleanupProviderUsable(provider) {
                let current = settings.model(for: provider)
                let cached = appSettings.models(for: provider)
                if cached.isEmpty || provider.usesManualModelEntry {
                    TextField(TRL("tr.model.model"), text: Binding(
                        get: { settings.model(for: provider) },
                        set: { settings.setModel($0, for: provider) }
                    ), prompt: Text(appSettings.dictationCleanupModel(for: provider)))
                    .textFieldStyle(.roundedBorder)
                    .help(TRL("tr.help.model"))
                } else {
                    // A model saved earlier may be missing from the list —
                    // keep it selectable instead of switching the user silently.
                    let options = current.isEmpty || cached.contains(current) ? cached : [current] + cached
                    Picker(TRL("tr.model.model"), selection: Binding(
                        get: { current },
                        set: { settings.setModel($0, for: provider) }
                    )) {
                        ForEach(options, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .help(TRL("tr.help.model"))
                }
            }

            if let resolved = settings.resolvedModel() {
                Text("\(TRL("tr.model.runs")) \(resolved.provider.displayName) · \(resolved.model)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text(TRL("tr.model.unavailable"))
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(TRL("tr.model.header"))
        } footer: {
            Text(TRL("tr.model.caption"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Behavior

    private var behaviorSection: some View {
        Section {
            HStack {
                Text(TRL("tr.linger"))
                Slider(value: $settings.lingerSeconds, in: TranslatorSettings.lingerRange, step: 5)
                    .help(TRL("tr.help.linger"))
                Text("\(Int(settings.lingerSeconds)) \(TRL("tr.linger.unit"))")
                    .font(.system(.body).monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        } header: {
            Text(TRL("tr.behavior.header"))
        } footer: {
            Text(TRL("tr.behavior.caption"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Accessibility

    private var accessibilitySection: some View {
        Section {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(TRL("tr.access.warning"))
                    .font(.callout)
            }
            Button(TRL("tr.access.open")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            .help(TRL("tr.access.open"))
        }
    }
}

/// The addon's master switch, embedded in the app's General tab. Turning it
/// on reveals the Translator tab, the menu-bar item and the hotkey.
struct TranslatorEnableToggle: View {
    @ObservedObject private var settings = TranslatorSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: $settings.enabled) { FeatureTitle(raw: TRL("tr.general.enable")) }
                .help(TRL("tr.general.enable.caption"))
            Text(TRL("tr.general.enable.caption"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
