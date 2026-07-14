import AppKit
import Carbon

/// LayoutFix — a self-contained keyboard-layout auto-switcher
/// that lives entirely in this folder and mounts into the host app through two
/// tiny hooks: `LayoutFixAddon.shared.start()` (called once at launch) and a
/// Settings tab (`LayoutFixSettingsView`).
///
/// It owns its *own* `HotkeyManager` instance (reused from the host) with
/// identifiers 901/902 that never collide with the app's 1–5, and it reads the
/// selection / pastes the fix with the same clipboard-based technique the app's
/// `TextInserter` uses.
@MainActor
final class LayoutFixAddon {
    static let shared = LayoutFixAddon()

    private let settings = LayoutFixSettings.shared
    private var hotkeyManager: HotkeyManager?
    private let autoSwitcher = AutoSwitcher()
    private var isBusy = false

    private enum ID {
        static let flip: UInt32 = 901
        static let smart: UInt32 = 902
    }

    private init() {}

    /// Mount point #1 — call once from `applicationDidFinishLaunching`.
    func start() {
        registerHotkeys()
        reconcileAuto()
        NotificationCenter.default.addObserver(
            forName: .layoutFixHotkeysDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.registerHotkeys()
                self?.reconcileAuto()
            }
        }
    }

    // MARK: - Automatic mode

    /// Starts/stops the real-time keystroke monitor to match the settings and
    /// pushes the current config into it.
    private func reconcileAuto() {
        autoSwitcher.config = AutoSwitcher.Config(
            switchSystemLayout: settings.autoSwitchSystemLayout,
            minWordLength: 1,   // singles (z→я, ш→i) are gated by frequency bounds
            earlySwitch: settings.autoEarlySwitch,
            autoCapitalize: settings.autoCapitalize,
            debug: settings.debugLogging
        )
        let shouldRun = settings.enabled && settings.autoEnabled
        if shouldRun {
            if !autoSwitcher.isRunning {
                _ = TextInserter.checkAccessibility(promptIfNeeded: true)
                if !autoSwitcher.start() {
                    // Tap couldn't be created — almost always missing Accessibility.
                    NSSound.beep()
                }
            }
        } else {
            autoSwitcher.stop()
        }
        settings.autoMonitorActive = autoSwitcher.isRunning
    }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        // Replacing the manager unregisters the previous shortcuts (deinit).
        hotkeyManager = nil
        guard settings.enabled else { return }

        var hotkeys: [HotkeyManager.Hotkey] = [
            HotkeyManager.Hotkey(
                identifier: ID.flip,
                keyCode: settings.flipHotkey.keyCode,
                modifiers: settings.flipHotkey.modifiers
            ) { [weak self] in
                Task { @MainActor in await self?.fixSelection(smart: false) }
            }
        ]

        if settings.smartEnabled {
            hotkeys.append(HotkeyManager.Hotkey(
                identifier: ID.smart,
                keyCode: settings.smartHotkey.keyCode,
                modifiers: settings.smartHotkey.modifiers
            ) { [weak self] in
                Task { @MainActor in await self?.fixSelection(smart: true) }
            })
        }

        hotkeyManager = HotkeyManager(hotkeys: hotkeys)
    }

    // MARK: - The fix action

    /// Grabs the selection (or the last word), converts it, and pastes it back.
    private func fixSelection(smart: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        Diagnostics.log("layoutfix", "fix.begin smart=\(smart)")

        guard TextInserter.checkAccessibility(promptIfNeeded: true) else {
            NSSound.beep()
            return
        }

        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)

        // Let the trigger chord (⌃⌥…) physically release before we synthesize
        // ⌘C, so its modifiers don't bleed into the copy.
        try? await Task.sleep(nanoseconds: 90_000_000)

        guard let original = await copySelection() else {
            restoreClipboard(saved)
            NSSound.beep()
            return
        }

        let fixed: String
        if smart {
            fixed = (try? await LayoutSmartFixer.fix(original)) ?? LayoutConverter.flip(original)
        } else {
            fixed = LayoutConverter.flip(original)
        }

        guard !fixed.isEmpty, fixed != original else {
            restoreClipboard(saved)
            return
        }

        pasteboard.clearContents()
        pasteboard.setString(fixed, forType: .string)
        postKey(kVK_ANSI_V, flags: .maskCommand)   // paste replaces the selection

        // Restore the user's clipboard once the paste has landed.
        try? await Task.sleep(nanoseconds: 250_000_000)
        restoreClipboard(saved)
    }

    /// Copies the current selection to the clipboard and returns it. If nothing
    /// is selected and `autoSelectWord` is on, selects the word before the
    /// cursor (⌥⇧←) and copies that. A unique sentinel distinguishes "copied
    /// nothing" from "copied an empty string".
    private func copySelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let sentinel = "‹layoutfix-\(pasteboard.changeCount)›"

        func attemptCopy() async -> String? {
            pasteboard.clearContents()
            pasteboard.setString(sentinel, forType: .string)
            postKey(kVK_ANSI_C, flags: .maskCommand)
            try? await Task.sleep(nanoseconds: 120_000_000)
            let value = pasteboard.string(forType: .string)
            return (value == sentinel) ? nil : value
        }

        if let text = await attemptCopy(), !text.isEmpty {
            return text
        }

        guard settings.autoSelectWord else { return nil }

        // Nothing selected — grab the word right before the cursor.
        postKey(kVK_LeftArrow, flags: [.maskAlternate, .maskShift])
        try? await Task.sleep(nanoseconds: 70_000_000)

        if let text = await attemptCopy(), !text.isEmpty {
            return text
        }
        return nil
    }

    private func restoreClipboard(_ saved: String?) {
        guard let saved else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(saved, forType: .string)
    }

    // MARK: - Synthesized keystrokes

    private func postKey(_ keyCode: Int, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

// MARK: - Smart (AI) fix

/// Optional LLM pass: fixes layout AND typos in context. Reuses the host's
/// provider stack exactly like `DictationService.postProcess` — Mistral small
/// when a Mistral key exists, otherwise the active chat provider/model.
enum LayoutSmartFixer {
    @MainActor
    static func fix(_ text: String) async throws -> String {
        let settings = AppSettings.shared

        let provider: LLMProvider
        let model: String
        let apiKey: String
        if let mistralKey = APIKeyStore.key(for: .mistral) {
            provider = OpenAICompatibleProvider.mistral
            model = "mistral-small-latest"
            apiKey = mistralKey
        } else if let chatKey = APIKeyStore.key(for: settings.chatProvider),
                  let chatModel = settings.selectedModel(for: settings.chatProvider) {
            provider = ProviderRegistry.provider(for: settings.chatProvider)
            model = chatModel
            apiKey = chatKey
        } else {
            // No key: caller falls back to the offline flip.
            return LayoutConverter.flip(text)
        }

        let prompt = """
The text below was typed with the keyboard in the wrong layout (Russian ЙЦУКЕН vs English QWERTY got mixed up), possibly with typos. Reconstruct what the user actually meant to type and return it in the correct language. Fix only the layout and obvious typos; do not translate, rephrase, or add anything. Output ONLY the corrected text, with no quotes or commentary.

\(text)
"""

        var result = ""
        let stream = provider.streamChat(
            messages: [LLMMessage(role: .user, text: prompt)],
            model: model,
            systemPrompt: nil,
            options: ChatRequestOptions(maxTokens: 1024, reasoning: .fast),
            apiKey: apiKey
        )
        for try await event in stream {
            if case .text(let chunk) = event { result += chunk }
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? LayoutConverter.flip(text) : trimmed
    }
}
