import Foundation
import Combine
import Carbon

extension Notification.Name {
    /// Posted when a LayoutFix hotkey / enable flag changes so the addon
    /// re-registers its global shortcuts. Kept separate from the app's
    /// `.hotkeysDidChange` so the two hotkey managers never interfere.
    static let layoutFixHotkeysDidChange = Notification.Name("layoutFixHotkeysDidChange")
}

/// Persisted settings for the LayoutFix addon. Uses its own `UserDefaults`
/// keys (prefixed `layoutFix.`) so it stores nothing in the app's `AppSettings`
/// and stays fully self-contained. Reuses the host `HotkeyCombo` type only.
@MainActor
final class LayoutFixSettings: ObservableObject {
    static let shared = LayoutFixSettings()

    private let defaults = UserDefaults.standard

    /// Sensible defaults: ⌃⌥ letter chords are rarely claimed by apps, so they
    /// make safe system-wide hotkeys.
    static let defaultFlip = HotkeyCombo(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(controlKey | optionKey))
    static let defaultSmart = HotkeyCombo(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(controlKey | optionKey))

    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "layoutFix.enabled")
            NotificationCenter.default.post(name: .layoutFixHotkeysDidChange, object: nil)
        }
    }

    @Published var flipHotkey: HotkeyCombo {
        didSet {
            Self.save(flipHotkey, forKey: "layoutFix.flipHotkey", in: defaults)
            NotificationCenter.default.post(name: .layoutFixHotkeysDidChange, object: nil)
        }
    }

    @Published var smartEnabled: Bool {
        didSet {
            defaults.set(smartEnabled, forKey: "layoutFix.smartEnabled")
            NotificationCenter.default.post(name: .layoutFixHotkeysDidChange, object: nil)
        }
    }

    @Published var smartHotkey: HotkeyCombo {
        didSet {
            Self.save(smartHotkey, forKey: "layoutFix.smartHotkey", in: defaults)
            NotificationCenter.default.post(name: .layoutFixHotkeysDidChange, object: nil)
        }
    }

    /// When nothing is selected, select+convert the word before the cursor.
    @Published var autoSelectWord: Bool {
        didSet { defaults.set(autoSelectWord, forKey: "layoutFix.autoSelectWord") }
    }

    // MARK: - Automatic mode (real-time, deterministic, system-aware)

    /// Full auto-switch: watches typing system-wide and fixes
    /// wrong-layout words on the fly. Off by default — it monitors keystrokes,
    /// so the user opts in explicitly. Posts a change so the addon starts/stops
    /// the keystroke monitor.
    @Published var autoEnabled: Bool {
        didSet {
            defaults.set(autoEnabled, forKey: "layoutFix.autoEnabled")
            NotificationCenter.default.post(name: .layoutFixHotkeysDidChange, object: nil)
        }
    }

    /// Also switch the active system input source when a word is corrected
    /// (so subsequent typing continues in the right layout).
    @Published var autoSwitchSystemLayout: Bool {
        didSet {
            defaults.set(autoSwitchSystemLayout, forKey: "layoutFix.autoSwitchSystemLayout")
            NotificationCenter.default.post(name: .layoutFixHotkeysDidChange, object: nil)
        }
    }

    /// Mid-word switch: fix as soon as the typed prefix becomes impossible in
    /// its layout, without waiting for the word to end.
    @Published var autoEarlySwitch: Bool {
        didSet {
            defaults.set(autoEarlySwitch, forKey: "layoutFix.autoEarlySwitch")
            NotificationCenter.default.post(name: .layoutFixHotkeysDidChange, object: nil)
        }
    }

    /// Capitalize the first letter after ". " (and after Enter).
    @Published var autoCapitalize: Bool {
        didSet {
            defaults.set(autoCapitalize, forKey: "layoutFix.autoCapitalize")
            NotificationCenter.default.post(name: .layoutFixHotkeysDidChange, object: nil)
        }
    }

    /// Emit per-word decision logs to Console (`[LayoutFix] …`) for tuning.
    @Published var debugLogging: Bool {
        didSet {
            defaults.set(debugLogging, forKey: "layoutFix.debugLogging")
            NotificationCenter.default.post(name: .layoutFixHotkeysDidChange, object: nil)
        }
    }

    /// Runtime status (not persisted): whether the keystroke monitor's event
    /// tap is actually installed. Surfaced in the tab so a missing Accessibility
    /// grant is visible instead of silent.
    @Published var autoMonitorActive = false

    // MARK: - Learned exceptions (Q2)

    /// Words the user reverted (Backspace after a correction). Auto-mode never
    /// converts these again. Stored lowercased, capped to the most recent ones.
    @Published private(set) var exceptions: [String]
    private static let maxExceptions = 500

    func isException(_ word: String) -> Bool {
        exceptions.contains(word.lowercased())
    }

    func addException(_ word: String) {
        let key = word.lowercased()
        guard !key.isEmpty, !exceptions.contains(key) else { return }
        exceptions.append(key)
        if exceptions.count > Self.maxExceptions {
            exceptions.removeFirst(exceptions.count - Self.maxExceptions)
        }
        defaults.set(exceptions, forKey: "layoutFix.exceptions")
    }

    func clearExceptions() {
        exceptions = []
        defaults.set(exceptions, forKey: "layoutFix.exceptions")
    }

    private init() {
        // Off by default — the user opts in from the Layout tab, so the addon
        // registers no global hotkeys until explicitly enabled.
        enabled = defaults.object(forKey: "layoutFix.enabled") as? Bool ?? false
        smartEnabled = defaults.object(forKey: "layoutFix.smartEnabled") as? Bool ?? false
        autoSelectWord = defaults.object(forKey: "layoutFix.autoSelectWord") as? Bool ?? true
        autoEnabled = defaults.object(forKey: "layoutFix.autoEnabled") as? Bool ?? false
        autoSwitchSystemLayout = defaults.object(forKey: "layoutFix.autoSwitchSystemLayout") as? Bool ?? true
        autoEarlySwitch = defaults.object(forKey: "layoutFix.autoEarlySwitch") as? Bool ?? true
        autoCapitalize = defaults.object(forKey: "layoutFix.autoCapitalize") as? Bool ?? true
        debugLogging = defaults.object(forKey: "layoutFix.debugLogging") as? Bool ?? false
        exceptions = defaults.stringArray(forKey: "layoutFix.exceptions") ?? []
        flipHotkey = Self.load(forKey: "layoutFix.flipHotkey", fallback: Self.defaultFlip, in: defaults)
        smartHotkey = Self.load(forKey: "layoutFix.smartHotkey", fallback: Self.defaultSmart, in: defaults)
    }

    func resetHotkeys() {
        flipHotkey = Self.defaultFlip
        smartHotkey = Self.defaultSmart
    }

    // MARK: - HotkeyCombo persistence (mirrors AppSettings' storage shape)

    private static func save(_ combo: HotkeyCombo, forKey key: String, in defaults: UserDefaults) {
        defaults.set(["keyCode": Int(combo.keyCode), "modifiers": Int(combo.modifiers)], forKey: key)
    }

    private static func load(forKey key: String, fallback: HotkeyCombo, in defaults: UserDefaults) -> HotkeyCombo {
        guard let dict = defaults.dictionary(forKey: key) as? [String: Int],
              let keyCode = dict["keyCode"], let modifiers = dict["modifiers"] else {
            return fallback
        }
        return HotkeyCombo(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
    }
}
