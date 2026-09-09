import Foundation
import Combine
import Carbon

extension Notification.Name {
    /// Posted when the addon's master switch or hotkey changes so the addon
    /// re-registers its global shortcut and the host rebuilds its menu.
    static let translatorAddonDidChange = Notification.Name("translatorAddonDidChange")
    /// Posted by the bubble's chat button with the original text as
    /// `object`: the host summons the panel with it quoted in the composer.
    static let translatorOpenInChat = Notification.Name("translatorOpenInChat")
}

/// Persisted settings for the Translator addon. Own `UserDefaults` keys
/// (prefixed `translator.`), nothing in `AppSettings`; the host's
/// `HotkeyCombo` and the dictation language list are the only things reused.
@MainActor
final class TranslatorSettings: ObservableObject {
    static let shared = TranslatorSettings()

    private let defaults = UserDefaults.standard

    /// ⌃⌥T: the ⌃⌥ letter chords are rarely claimed by apps (LayoutFix
    /// holds ⌃⌥F and ⌃⌥G on the same reasoning).
    static let defaultHotkey = HotkeyCombo(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey))
    static let lingerRange: ClosedRange<Double> = 5...120
    static let defaultLinger: Double = 30

    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "translator.enabled")
            NotificationCenter.default.post(name: .translatorAddonDidChange, object: nil)
        }
    }

    @Published var hotkey: HotkeyCombo {
        didSet {
            Self.save(hotkey, forKey: "translator.hotkey", in: defaults)
            NotificationCenter.default.post(name: .translatorAddonDidChange, object: nil)
        }
    }

    /// The language the selection is translated into.
    @Published var targetLanguage: String {
        didSet { defaults.set(targetLanguage, forKey: "translator.targetLanguage") }
    }

    /// Where a text that already is in the target goes.
    @Published var fallbackLanguage: String {
        didSet { defaults.set(fallbackLanguage, forKey: "translator.fallbackLanguage") }
    }

    /// nil = the dictation cleanup choice (Settings → Voice), which is a
    /// small fast model by construction — the right default for a pass
    /// that runs on every hotkey press.
    @Published var provider: ProviderID? {
        didSet { defaults.set(provider?.rawValue ?? "", forKey: "translator.provider") }
    }

    /// Model override per provider (`provider.rawValue` → model id).
    @Published private(set) var models: [String: String] {
        didSet { defaults.set(models, forKey: "translator.models") }
    }

    /// How long the bubble stays after the translation is complete.
    @Published var lingerSeconds: Double {
        didSet { defaults.set(lingerSeconds, forKey: "translator.lingerSeconds") }
    }

    private init() {
        // Off by default: the user opts in from General, so the addon
        // registers no global hotkey until explicitly enabled.
        enabled = defaults.object(forKey: "translator.enabled") as? Bool ?? false
        hotkey = Self.load(forKey: "translator.hotkey", fallback: Self.defaultHotkey, in: defaults)

        // First run: the dictation's translate target is the language this
        // user already translates into; the app's UI language is the one they
        // read, so it is where a text already in the target should go.
        let app = AppSettings.shared
        let target = defaults.string(forKey: "translator.targetLanguage") ?? app.dictationTargetLanguage
        targetLanguage = target
        let uiLanguage: String
        switch Localization.currentLanguage {
        case .russian: uiLanguage = "Russian"
        case .spanish: uiLanguage = "Spanish"
        case .english: uiLanguage = "English"
        }
        let pair = uiLanguage == target ? (target == "English" ? "Russian" : "English") : uiLanguage
        fallbackLanguage = defaults.string(forKey: "translator.fallbackLanguage") ?? pair

        // "" (and a missing value) means "same as dictation".
        provider = ProviderID(rawValue: defaults.string(forKey: "translator.provider") ?? "")
        models = defaults.dictionary(forKey: "translator.models") as? [String: String] ?? [:]
        let linger = defaults.object(forKey: "translator.lingerSeconds") as? Double ?? Self.defaultLinger
        lingerSeconds = min(max(linger, Self.lingerRange.lowerBound), Self.lingerRange.upperBound)
    }

    // MARK: - Model resolution

    func model(for provider: ProviderID) -> String {
        let stored = models[provider.rawValue] ?? ""
        return stored.isEmpty ? AppSettings.shared.dictationCleanupModel(for: provider) : stored
    }

    func setModel(_ model: String, for provider: ProviderID) {
        models[provider.rawValue] = model
    }

    /// The provider and model that will ACTUALLY translate, or nil when
    /// nothing can (no keys, local models off). The Settings caption and
    /// the run both go through here, so what the tab promises is what runs.
    func resolvedModel() -> (provider: ProviderID, model: String)? {
        let app = AppSettings.shared
        if let chosen = provider, app.isCleanupProviderUsable(chosen) {
            let model = model(for: chosen)
            if !model.isEmpty { return (chosen, model) }
        }
        return app.resolvedDictationCleanup()
    }

    func resetHotkey() {
        hotkey = Self.defaultHotkey
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
