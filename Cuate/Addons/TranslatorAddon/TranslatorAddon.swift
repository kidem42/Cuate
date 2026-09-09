import AppKit

/// Translator — translates the text selected in any app into a bubble next
/// to it. Self-contained in this folder; mounted into the host through
/// `TranslatorAddon.shared.start()` at launch, a Settings tab
/// (`TranslatorSettingsView`), a master switch in General
/// (`TranslatorEnableToggle`), a status-menu item, and the
/// `.translatorOpenInChat` notification the host answers by quoting the
/// original text in the composer.
///
/// Owns its own `HotkeyManager` (identifier 903, next to LayoutFix's
/// 901/902), reads the selection with the host's `SelectionGrabber` and its
/// screen bounds with `SelectionLocator`, and translates through the
/// provider stack the dictation cleanup uses.
@MainActor
final class TranslatorAddon {
    static let shared = TranslatorAddon()

    private let settings = TranslatorSettings.shared
    private let overlay = TranslatorOverlayController()
    private var hotkeyManager: HotkeyManager?
    private var running = false

    private enum ID {
        static let translate: UInt32 = 903
    }

    private init() {}

    /// Mount point — call once from `applicationDidFinishLaunching`.
    func start() {
        overlay.prepare()
        registerHotkey()
        NotificationCenter.default.addObserver(
            forName: .translatorAddonDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.registerHotkey() }
        }
    }

    /// The status-menu entry: the same road as the hotkey.
    func translateSelection() {
        Task { await run() }
    }

    private func registerHotkey() {
        // Replacing the manager unregisters the previous shortcut (deinit).
        hotkeyManager = nil
        guard settings.enabled else { return }
        hotkeyManager = HotkeyManager(hotkeys: [
            HotkeyManager.Hotkey(
                identifier: ID.translate,
                keyCode: settings.hotkey.keyCode,
                modifiers: settings.hotkey.modifiers
            ) { [weak self] in
                Task { @MainActor in await self?.run() }
            }
        ])
    }

    private func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        Diagnostics.log("translator", "hotkey app=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")

        // The AX read and the ⌘C fallback both need the permission; the
        // system prompt is the right answer to a first press without it.
        guard TextInserter.checkAccessibility(promptIfNeeded: true) else {
            Diagnostics.log("translator", "accessibility.missing")
            return
        }

        // The bounds first, while the target app's focus is untouched; the
        // bubble is non-activating, so a bubble already on screen changes
        // nothing about who is frontmost.
        let location = SelectionLocator.locate()
        let text = await SelectionGrabber.grab()
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        Diagnostics.log("translator", "grab chars=\(trimmed.count) bounds=\(location.viaAccessibility ? "ax" : "mouse")")
        guard !trimmed.isEmpty else {
            overlay.showNothingSelected(at: location)
            return
        }
        overlay.show(text: trimmed, at: location)
    }
}
