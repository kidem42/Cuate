import Foundation
import Combine
import AppKit
import ServiceManagement

/// App-wide appearance override.
enum AppearanceMode: String, CaseIterable, Codable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return L("theme.auto")
        case .light: return L("theme.light")
        case .dark: return L("theme.dark")
        }
    }
}

/// How the prompt-preset switcher is rendered in the panel header.
enum PresetSwitcherStyle: String, CaseIterable, Identifiable {
    case menu
    case buttons

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .menu: return L("prompts.styleMenu")
        case .buttons: return L("prompts.styleButtons")
        }
    }
}

/// Non-secret app settings (provider choice, models, system prompt).
/// API keys are NOT stored here — they live in the Keychain (`APIKeyStore`).
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: - Chat provider & model

    @Published var chatProvider: ProviderID {
        didSet { defaults.set(chatProvider.rawValue, forKey: "chatProvider") }
    }

    /// Selected model per chat provider.
    @Published private(set) var selectedModels: [String: String] {
        didSet { defaults.set(selectedModels, forKey: "selectedModels") }
    }

    /// Cached model lists per provider (fetched from each provider's /models API).
    @Published private(set) var cachedModels: [String: [String]] {
        didSet { defaults.set(cachedModels, forKey: "cachedModels") }
    }

    // MARK: - Speech to text

    @Published var sttProvider: STTProviderID {
        didSet { defaults.set(sttProvider.rawValue, forKey: "sttProvider") }
    }

    @Published private(set) var sttModels: [String: String] {
        didSet { defaults.set(sttModels, forKey: "sttModels") }
    }

    // MARK: - OCR (document/image text extraction)

    /// OCR is Mistral-only for now; the model is configurable.
    @Published var ocrModel: String {
        didSet { defaults.set(ocrModel, forKey: "ocrModel") }
    }
    static let defaultOCRModel = "mistral-ocr-latest"

    // MARK: - Generation parameters

    @Published var reasoningMode: ReasoningMode {
        didSet { defaults.set(reasoningMode.rawValue, forKey: "reasoningMode") }
    }

    @Published var maxTokens: Int {
        didSet { defaults.set(maxTokens, forKey: "maxTokens") }
    }

    // MARK: - Web search

    @Published var webSearchEnabled: Bool {
        didSet { defaults.set(webSearchEnabled, forKey: "webSearchEnabled") }
    }

    // MARK: - Hotkeys

    @Published var togglePanelHotkey: HotkeyCombo {
        didSet {
            saveHotkey(togglePanelHotkey, forKey: "togglePanelHotkey")
            NotificationCenter.default.post(name: .hotkeysDidChange, object: nil)
        }
    }

    @Published var screenshotHotkey: HotkeyCombo {
        didSet {
            saveHotkey(screenshotHotkey, forKey: "screenshotHotkey")
            NotificationCenter.default.post(name: .hotkeysDidChange, object: nil)
        }
    }

    @Published var areaScreenshotHotkey: HotkeyCombo {
        didSet {
            saveHotkey(areaScreenshotHotkey, forKey: "areaScreenshotHotkey")
            NotificationCenter.default.post(name: .hotkeysDidChange, object: nil)
        }
    }

    @Published var dictationHotkey: HotkeyCombo {
        didSet {
            saveHotkey(dictationHotkey, forKey: "dictationHotkey")
            NotificationCenter.default.post(name: .hotkeysDidChange, object: nil)
        }
    }

    @Published var dictationTranslateHotkey: HotkeyCombo {
        didSet {
            saveHotkey(dictationTranslateHotkey, forKey: "dictationTranslateHotkey")
            NotificationCenter.default.post(name: .hotkeysDidChange, object: nil)
        }
    }

    private func saveHotkey(_ combo: HotkeyCombo, forKey key: String) {
        defaults.set(["keyCode": Int(combo.keyCode), "modifiers": Int(combo.modifiers)], forKey: key)
    }

    private static func loadHotkey(_ defaults: UserDefaults, forKey key: String, fallback: HotkeyCombo) -> HotkeyCombo {
        guard let dict = defaults.dictionary(forKey: key) as? [String: Int],
              let keyCode = dict["keyCode"], let modifiers = dict["modifiers"] else {
            return fallback
        }
        return HotkeyCombo(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
    }

    // MARK: - Dictation

    @Published var dictationEnabled: Bool {
        didSet {
            defaults.set(dictationEnabled, forKey: "dictationEnabled")
            NotificationCenter.default.post(name: .hotkeysDidChange, object: nil)
        }
    }

    /// Clean fillers/punctuation with a fast LLM pass in plain dictation mode.
    @Published var dictationCleanup: Bool {
        didSet { defaults.set(dictationCleanup, forKey: "dictationCleanup") }
    }

    @Published var dictationTargetLanguage: String {
        didSet { defaults.set(dictationTargetLanguage, forKey: "dictationTargetLanguage") }
    }

    /// Cut the recording at natural pauses and insert text phrase-by-phrase
    /// while dictation continues (pseudo-realtime, no WebSocket).
    @Published var dictationChunked: Bool {
        didSet { defaults.set(dictationChunked, forKey: "dictationChunked") }
    }

    static let dictationLanguages = ["English", "Russian", "German", "French", "Spanish", "Italian", "Portuguese", "Chinese", "Japanese"]

    // MARK: - Panel placement

    /// Open the chat panel on the screen where the mouse cursor currently is.
    @Published var panelFollowsMouse: Bool {
        didSet { defaults.set(panelFollowsMouse, forKey: "panelFollowsMouse") }
    }

    /// Whether the user has manually dragged the panel to a custom position.
    @Published var panelHasCustomPosition: Bool {
        didSet { defaults.set(panelHasCustomPosition, forKey: "panelHasCustomPosition") }
    }

    /// The panel center as a fraction of its screen's frame (reproducible on
    /// any monitor regardless of resolution).
    var panelRelativeCenter: CGPoint? {
        get {
            guard defaults.object(forKey: "panelRelCenterX") != nil else { return nil }
            return CGPoint(
                x: defaults.double(forKey: "panelRelCenterX"),
                y: defaults.double(forKey: "panelRelCenterY")
            )
        }
        set {
            if let newValue {
                defaults.set(newValue.x, forKey: "panelRelCenterX")
                defaults.set(newValue.y, forKey: "panelRelCenterY")
            } else {
                defaults.removeObject(forKey: "panelRelCenterX")
                defaults.removeObject(forKey: "panelRelCenterY")
            }
        }
    }

    // MARK: - Launch at login

    /// Registers/unregisters the app as a login item (SMAppService).
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: "launchAtLogin")
            Self.applyLaunchAtLogin(launchAtLogin)
        }
    }

    private static func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            NSLog("Launch-at-login toggle failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Language

    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: "language")
            Localization.currentLanguage = language
            NotificationCenter.default.post(name: .appLanguageDidChange, object: nil)
        }
    }

    // MARK: - Appearance

    @Published var appearanceMode: AppearanceMode {
        didSet {
            defaults.set(appearanceMode.rawValue, forKey: "appearanceMode")
            applyAppearance()
        }
    }

    func applyAppearance() {
        switch appearanceMode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: - System prompt & presets

    struct PromptPreset: Identifiable {
        let name: String
        let text: String
        let isBuiltIn: Bool
        var id: String { name }
    }

    static let builtInPresets: [PromptPreset] = [
        PromptPreset(
            name: "Assistant",
            text: """
You are a persistent personal assistant (she/her) living in a macOS Spotlight-style panel.

Tone: concise and direct, with dry humor. Slight sarcasm is fine when the user is vague or silly, but never mean-spirited. Being helpful always beats being polite. Ask direct questions when clarification is needed. Never invent facts: say "I don't know" when necessary.

Formatting: use Markdown. Prefer **bold headings** over #-style headers. Use 2-4 fitting emojis per response (at the start, in lists, or for character). Use bullet points for multiple insights.
""",
            isBuiltIn: true
        ),
        PromptPreset(
            name: "Translator",
            text: """
You are a translator between Russian and English. Detect the input language: Russian → translate to English, any other language → translate to Russian. If the user explicitly names a different target language, use it instead.

For sentences and longer text: reply with the translation only. Preserve the tone, register and formatting of the original. Add a one-line note only when something is genuinely ambiguous or untranslatable.

For a single word or a short phrase (up to ~3 words), switch to dictionary mode:
- **Headword** with IPA transcription (for English) and part of speech
- 2-4 translation variants with nuance notes (register, typical context)
- Grammar essentials: irregular verb forms (go - went - gone), Russian aspect pairs (делать/сделать), noun gender and plural where relevant
- 2-3 usage examples with translations
- Common collocations or idioms, if any

Keep dictionary entries compact. Never add meta-commentary like "Here is the translation".
""",
            isBuiltIn: true
        ),
        PromptPreset(
            name: "Translator ES",
            text: """
You are a translator specialized in Mexican Spanish. Direction: Russian or English input → translate to Spanish as spoken in Mexico; Spanish input → translate to Russian. If the user explicitly names a different target language, use it instead.

Always use Latin American / Mexican conventions: ustedes (never vosotros), Mexican vocabulary (computadora, celular, manejar, platicar, rentar), Mexican register and idioms. Avoid Peninsular Spanish forms and vocabulary.

For sentences and longer text: reply with the translation only. Preserve the tone, register and formatting of the original. Add a one-line note only when something is genuinely ambiguous.

For a single word or a short phrase (up to ~3 words), switch to dictionary mode:
- **Headword** with part of speech (and gender for nouns: el/la)
- 2-4 translation variants with nuance notes, marking Mexican colloquialisms (mex.)
- Grammar essentials: key irregular conjugations (present, preterite), plural forms
- 2-3 usage examples with translations, in a Mexican context
- Common Mexican expressions or idioms with the word, if any

Keep dictionary entries compact. Never add meta-commentary like "Here is the translation".
""",
            isBuiltIn: true
        )
    ]

    /// Mandatory rules silently appended to EVERY preset at request time
    /// (never shown in the editable prompt).
    static let mandatoryPromptRules = """
Never use the "—" character.
The app renders three tap-to-copy formats; mark anything the user is likely to reuse elsewhere:
1) `backticks` for short inline values right inside a sentence: commands, file paths, IDs, keys, emails, phone numbers, addresses, exact product/model/part names or codes (e.g. `2.0 CRDi`, `iPhone 15 Pro`), titles, and other self-contained values that answer the user's question.
2) > blockquote for any quotation, saying, poem or verbatim passage the user asked for.
3) Fenced code blocks ONLY for actual multi-line code, configs or scripts, never for emphasis.
Do not mark plain emphasis this way; use **bold** for emphasis.
"""

    /// The editable working copy of the system prompt.
    @Published var systemPrompt: String {
        didSet { defaults.set(systemPrompt, forKey: "systemPrompt") }
    }

    /// The preset the working copy was based on (reset target).
    @Published var activePresetName: String {
        didSet { defaults.set(activePresetName, forKey: "activePresetName") }
    }

    @Published private(set) var customPresets: [String: String] {
        didSet { defaults.set(customPresets, forKey: "customPresets") }
    }

    /// Per-preset emoji icons (user overrides; built-in defaults live in `builtInIcons`).
    @Published private(set) var presetIcons: [String: String] {
        didSet { defaults.set(presetIcons, forKey: "presetIcons") }
    }

    /// How the preset switcher looks in the panel header: dropdown menu or chip row.
    @Published var presetSwitcherStyle: PresetSwitcherStyle {
        didSet { defaults.set(presetSwitcherStyle.rawValue, forKey: "presetSwitcherStyle") }
    }

    private init() {
        chatProvider = ProviderID(rawValue: defaults.string(forKey: "chatProvider") ?? "") ?? .openai
        selectedModels = defaults.dictionary(forKey: "selectedModels") as? [String: String] ?? [:]
        cachedModels = defaults.dictionary(forKey: "cachedModels") as? [String: [String]] ?? [:]
        sttProvider = STTProviderID(rawValue: defaults.string(forKey: "sttProvider") ?? "") ?? .mistral
        sttModels = defaults.dictionary(forKey: "sttModels") as? [String: String] ?? [:]
        ocrModel = defaults.string(forKey: "ocrModel") ?? Self.defaultOCRModel
        reasoningMode = ReasoningMode(rawValue: defaults.string(forKey: "reasoningMode") ?? "") ?? .auto
        maxTokens = defaults.object(forKey: "maxTokens") as? Int ?? 8192
        webSearchEnabled = defaults.object(forKey: "webSearchEnabled") as? Bool ?? true
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: "appearanceMode") ?? "") ?? .system
        panelFollowsMouse = defaults.object(forKey: "panelFollowsMouse") as? Bool ?? true
        panelHasCustomPosition = defaults.bool(forKey: "panelHasCustomPosition")
        let lang = AppLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .english
        language = lang
        Localization.currentLanguage = lang
        togglePanelHotkey = Self.loadHotkey(defaults, forKey: "togglePanelHotkey", fallback: .defaultTogglePanel)
        screenshotHotkey = Self.loadHotkey(defaults, forKey: "screenshotHotkey", fallback: .defaultScreenshot)
        areaScreenshotHotkey = Self.loadHotkey(defaults, forKey: "areaScreenshotHotkey", fallback: .defaultAreaScreenshot)
        dictationHotkey = Self.loadHotkey(defaults, forKey: "dictationHotkey", fallback: .defaultDictation)
        dictationTranslateHotkey = Self.loadHotkey(defaults, forKey: "dictationTranslateHotkey", fallback: .defaultDictationTranslate)
        dictationEnabled = defaults.object(forKey: "dictationEnabled") as? Bool ?? true
        dictationCleanup = defaults.object(forKey: "dictationCleanup") as? Bool ?? true
        dictationTargetLanguage = defaults.string(forKey: "dictationTargetLanguage") ?? "English"
        dictationChunked = defaults.object(forKey: "dictationChunked") as? Bool ?? true
        customPresets = defaults.dictionary(forKey: "customPresets") as? [String: String] ?? [:]
        presetIcons = defaults.dictionary(forKey: "presetIcons") as? [String: String] ?? [:]
        presetSwitcherStyle = PresetSwitcherStyle(rawValue: defaults.string(forKey: "presetSwitcherStyle") ?? "") ?? .menu
        activePresetName = defaults.string(forKey: "activePresetName") ?? Self.builtInPresets[0].name
        systemPrompt = defaults.string(forKey: "systemPrompt") ?? Self.builtInPresets[0].text

        // Launch at login (last stored property — self is usable below).
        // First launch: enable by default (macOS notifies the user, who can
        // opt out in Settings or System Settings). Later launches: mirror the
        // real system state, so a change made in System Settings → Login
        // Items is respected instead of being re-asserted.
        let launchPrefExists = defaults.object(forKey: "launchAtLogin") is Bool
        launchAtLogin = launchPrefExists ? SMAppService.mainApp.status == .enabled : true
        defaults.set(launchAtLogin, forKey: "launchAtLogin")
        if !launchPrefExists {
            Self.applyLaunchAtLogin(true)   // didSet doesn't fire in init
        }

        // Migration: retired built-in presets (Kidem, Code Assistant) roll
        // over to the current Assistant preset — by name (the reliable key)
        // and by the old default texts. Both the active-preset name and the
        // working copy are reset together to avoid a name/text mismatch.
        let retiredNames: Set<String> = ["Kidem", "Code Assistant"]
        let retiredTexts: Set<String> = [
            "You are a helpful assistant living in a macOS Spotlight-style panel. Be concise.",
            "You are a senior software engineer. Answer with working code first, then a brief explanation. Prefer modern idioms and point out pitfalls."
        ]
        let onRetiredPreset = retiredNames.contains(activePresetName)
            || presetText(named: activePresetName) == nil
        if onRetiredPreset || retiredTexts.contains(systemPrompt) || systemPrompt.hasPrefix("You are Kidem,") {
            activePresetName = Self.builtInPresets[0].name
            systemPrompt = Self.builtInPresets[0].text
        }
        // Old one-liner Translator text upgrades in place (name stays).
        if systemPrompt.hasPrefix("You are a translator. Detect the language of the input") {
            systemPrompt = Self.builtInPresets.first { $0.name == "Translator" }?.text ?? systemPrompt
        }
    }

    // MARK: - Preset management

    var allPresets: [PromptPreset] {
        Self.builtInPresets + customPresets.keys.sorted().map {
            PromptPreset(name: $0, text: customPresets[$0] ?? "", isBuiltIn: false)
        }
    }

    func presetText(named name: String) -> String? {
        if let builtIn = Self.builtInPresets.first(where: { $0.name == name }) {
            return builtIn.text
        }
        return customPresets[name]
    }

    /// Default emoji for built-in presets (user overrides live in `presetIcons`).
    private static let builtInIcons: [String: String] = [
        "Assistant": "💬",
        "Translator": "📖",
        "Translator ES": "🌮"
    ]

    /// The emoji shown for a preset in the panel header, if any.
    func presetIcon(named name: String) -> String? {
        presetIcons[name] ?? Self.builtInIcons[name]
    }

    /// Sets (or clears) a preset's emoji; only the first grapheme is kept.
    func setPresetIcon(_ emoji: String, forPreset name: String) {
        let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            presetIcons.removeValue(forKey: name)
        } else {
            presetIcons[name] = String(trimmed.prefix(1))
        }
    }

    /// Switches to a preset, replacing the working copy.
    func applyPreset(named name: String) {
        guard let text = presetText(named: name) else { return }
        activePresetName = name
        systemPrompt = text
    }

    /// Reverts the working copy to the active preset's original text.
    func resetPromptToPreset() {
        systemPrompt = presetText(named: activePresetName) ?? Self.builtInPresets[0].text
    }

    /// Saves the current working copy under a (new or existing) custom preset name.
    func saveCurrentAsPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !Self.builtInPresets.contains(where: { $0.name == trimmed }) else { return }
        customPresets[trimmed] = systemPrompt
        activePresetName = trimmed
    }

    func deleteCustomPreset(named name: String) {
        guard customPresets[name] != nil else { return }
        customPresets.removeValue(forKey: name)
        presetIcons.removeValue(forKey: name)
        if activePresetName == name {
            applyPreset(named: Self.builtInPresets[0].name)
        }
    }

    // MARK: - Accessors

    func selectedModel(for provider: ProviderID) -> String? {
        selectedModels[provider.rawValue]
    }

    func setSelectedModel(_ model: String, for provider: ProviderID) {
        selectedModels[provider.rawValue] = model
    }

    func models(for provider: ProviderID) -> [String] {
        cachedModels[provider.rawValue] ?? []
    }

    func sttModel(for provider: STTProviderID) -> String {
        let value = sttModels[provider.rawValue] ?? ""
        return value.isEmpty ? provider.defaultModel : value
    }

    func setSTTModel(_ model: String, for provider: STTProviderID) {
        sttModels[provider.rawValue] = model
    }

    // MARK: - Model list refresh

    /// Fetches the model list for a provider from its API and caches it.
    func refreshModels(for provider: ProviderID) async throws {
        guard let apiKey = APIKeyStore.key(for: provider) else {
            throw ProviderError.missingAPIKey(provider)
        }
        let models = try await ProviderRegistry.provider(for: provider).fetchModels(apiKey: apiKey)
        cachedModels[provider.rawValue] = models
        // Auto-select a sensible default if none is selected or the selection
        // disappeared, so chat works right after a key is added.
        if let current = selectedModels[provider.rawValue], models.contains(current) {
            return
        }
        if let choice = Self.preferredDefault(for: provider, from: models) {
            selectedModels[provider.rawValue] = choice
        }
    }

    /// Picks a default model from a provider's fetched list: the first of the
    /// provider's `preferredDefaultModels` that appears — by exact match, or as
    /// the prefix of a dated snapshot id — falling back to the first model.
    static func preferredDefault(for provider: ProviderID, from models: [String]) -> String? {
        for preferred in provider.preferredDefaultModels {
            if let exact = models.first(where: { $0 == preferred }) {
                return exact
            }
            if let prefixed = models.first(where: { $0.hasPrefix(preferred) }) {
                return prefixed
            }
        }
        return models.first
    }

    /// Refreshes the model list for the active provider in the background when
    /// it hasn't been loaded yet, so the saved selection is shown and validated
    /// without the user pressing "Load Models". Best-effort — silent on failure.
    func autoLoadModelsIfNeeded(for provider: ProviderID) {
        guard models(for: provider).isEmpty, APIKeyStore.hasKey(for: provider) else { return }
        Task { try? await refreshModels(for: provider) }
    }
}

/// Maps provider IDs to their implementations.
enum ProviderRegistry {
    static func provider(for id: ProviderID) -> LLMProvider {
        switch id {
        case .anthropic: return AnthropicProvider()
        case .openai: return OpenAICompatibleProvider.openAI
        case .mistral: return OpenAICompatibleProvider.mistral
        case .deepseek: return OpenAICompatibleProvider.deepSeek
        case .gemini: return GeminiProvider()
        }
    }
}
