import SwiftUI
import AppKit

/// The addon's Settings tab. Self-contained: it renders its own grouped Form,
/// reuses the host `ShortcutRecorderView`, and reads the app's real hotkeys
/// only to warn about conflicts.
struct LayoutFixSettingsView: View {
    @ObservedObject private var settings = LayoutFixSettings.shared
    @ObservedObject private var appSettings = AppSettings.shared

    @State private var previewInput = ""
    @State private var accessibilityGranted = true

    // The tab itself is only shown while the addon is enabled (the master
    // switch lives in the General tab), so this view goes straight to settings.
    var body: some View {
        Form {
            introSection
            autoSection
            hotkeysSection
            optionsSection
            // smartSection — AI smart fix hidden from the UI for now (kept in code).
            previewSection
            if !accessibilityGranted {
                accessibilitySection
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshAccessibility() }
    }

    // MARK: - Intro

    private var introSection: some View {
        Section {
            Text(LFL("lf.footer"))
                .font(.callout)
                .foregroundColor(.secondary)
        } header: {
            Text(LFL("lf.header"))
        }
    }

    // MARK: - Automatic mode

    private var autoSection: some View {
        Section {
            Toggle(LFL("lf.auto.enable"), isOn: $settings.autoEnabled)
            if settings.autoEnabled {
                // Status right under the master toggle — it reflects THIS
                // toggle (the keystroke monitor), not the options below it.
                Label(
                    settings.autoMonitorActive ? LFL("lf.monitor.active") : LFL("lf.monitor.inactive"),
                    systemImage: settings.autoMonitorActive ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundColor(settings.autoMonitorActive ? .green : .orange)

                Toggle(LFL("lf.auto.switchLayout"), isOn: $settings.autoSwitchSystemLayout)
                Toggle(LFL("lf.auto.early"), isOn: $settings.autoEarlySwitch)
                Toggle(LFL("lf.auto.capitalize"), isOn: $settings.autoCapitalize)
                Toggle(LFL("lf.debug.toggle"), isOn: $settings.debugLogging)

                Label(LFL("lf.auto.undoHint"), systemImage: "arrow.uturn.backward")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Label(LFL("lf.auto.privacy"), systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text(LFL("lf.auto.header"))
        } footer: {
            Text(LFL("lf.auto.footer"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Hotkeys

    /// The app's own shortcuts + the addon's other shortcut — so the recorder
    /// rejects a combination that's already taken anywhere.
    private var hostHotkeys: [HotkeyCombo] {
        [appSettings.togglePanelHotkey, appSettings.screenshotHotkey,
         appSettings.areaScreenshotHotkey, appSettings.dictationHotkey,
         appSettings.dictationTranslateHotkey]
    }

    private var hotkeysSection: some View {
        Section {
            ShortcutRecorderView(
                title: LFL("lf.hotkey.flip"),
                combo: $settings.flipHotkey,
                conflictingCombos: hostHotkeys + [settings.smartHotkey]
            )
            // Smart-fix (AI) hotkey hidden from the UI for now (kept in code).
            Button(L("hotkeys.reset")) {
                settings.resetHotkeys()
            }
        } header: {
            Text(LFL("lf.hotkeys.header"))
        } footer: {
            Text(LFL("lf.hotkeys.footer"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Options

    private var optionsSection: some View {
        Section {
            Toggle(LFL("lf.autoWord"), isOn: $settings.autoSelectWord)
            // Exceptions row hidden — the learning feature is disabled for now.
        } header: {
            Text(LFL("lf.options.header"))
        } footer: {
            Text(LFL("lf.autoWord.footer"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Smart (AI)

    private var smartSection: some View {
        Section {
            Toggle(LFL("lf.smart.enable"), isOn: $settings.smartEnabled)
        } header: {
            Text(LFL("lf.smart.header"))
        } footer: {
            Text(LFL("lf.smart.footer"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Live preview

    private var previewSection: some View {
        Section {
            TextField(LFL("lf.preview.placeholder"), text: $previewInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            LabeledContent(LFL("lf.preview.result")) {
                Text(previewInput.isEmpty ? "—" : LayoutConverter.flip(previewInput))
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(previewInput.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        } header: {
            Text(LFL("lf.preview.header"))
        }
    }

    // MARK: - Accessibility

    private var accessibilitySection: some View {
        Section {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(LFL("lf.access.warning"))
                    .font(.callout)
            }
            Button(LFL("lf.access.open")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func refreshAccessibility() {
        accessibilityGranted = TextInserter.checkAccessibility(promptIfNeeded: false)
    }
}

/// The addon's master on/off switch, designed to be embedded in the app's
/// General tab. Turning it on reveals the Layout tab and the menu-bar controls.
struct LayoutFixEnableToggle: View {
    @ObservedObject private var settings = LayoutFixSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: $settings.enabled) { FeatureTitle(raw: LFL("lf.general.enable")) }
            Text(LFL("lf.general.enable.caption"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
