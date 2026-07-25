import Foundation
import Combine
import AppKit
import ServiceManagement

extension Notification.Name {
    /// Posted after a custom preset is removed; object = preset name (String).
    /// ChatWindow reacts by deleting the preset's isolated chat data, if any.
    static let presetDeleted = Notification.Name("presetDeleted")
}

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

extension Notification.Name {
    /// Posted when the local-models master switch or Ollama detection changes —
    /// the status-bar menu rebuilds so its start/stop control appears/disappears.
    static let localModelsMenuDidChange = Notification.Name("localModelsMenuDidChange")
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

    // MARK: - Local models (Ollama / OpenAI-compatible endpoint)

    static let defaultLocalEndpointURL = "http://localhost:11434/v1"

    /// Master switch for local models — off by default (opt-in feature, like
    /// the addons). When on, the local provider joins the pickers and the
    /// "Local models" settings tab appears.
    @Published var localModelsEnabled: Bool {
        didSet {
            defaults.set(localModelsEnabled, forKey: "localModelsEnabled")
            if localModelsEnabled != oldValue {
                NotificationCenter.default.post(name: .localModelsMenuDidChange, object: nil)
            }
            // Облачный тумблер — вложенный пункт локальных моделей и виден
            // только при включённых локальных. Выключение родителя при
            // выключенном облаке оставило бы ноль провайдеров без видимого
            // способа это исправить — облако возвращается само.
            if !localModelsEnabled, !onlineModelsEnabled {
                onlineModelsEnabled = true
            }
        }
    }

    /// Master switch for cloud providers — on by default. Turning it off hides
    /// every cloud provider (fully local/offline posture).
    @Published var onlineModelsEnabled: Bool {
        didSet { defaults.set(onlineModelsEnabled, forKey: "onlineModelsEnabled") }
    }

    /// Base URL of the local OpenAI-compatible endpoint (Ollama's default; the
    /// user can point it at LM Studio, vLLM, llama.cpp, LocalAI, …).
    @Published var localEndpointURL: String {
        didSet { defaults.set(localEndpointURL, forKey: "localEndpointURL") }
    }

    /// Cached "the /v1 endpoint answered" flag — gates the local provider the
    /// way key-presence gates the cloud ones.
    @Published var localEndpointVerified: Bool {
        didSet { defaults.set(localEndpointVerified, forKey: "localEndpointVerified") }
    }

    /// Cached "the endpoint is actually Ollama (native /api present)" flag —
    /// gates the Ollama-only management console.
    @Published var ollamaDetected: Bool {
        didSet {
            defaults.set(ollamaDetected, forKey: "ollamaDetected")
            if ollamaDetected != oldValue {
                NotificationCenter.default.post(name: .localModelsMenuDidChange, object: nil)
            }
        }
    }

    /// Per-model capabilities for local Ollama models, from `/api/show`
    /// (vision/tools). Persisted as JSON like `openRouterCatalog`.
    @Published private(set) var ollamaCatalog: [String: ModelInfo] {
        didSet {
            if let data = try? JSONEncoder().encode(ollamaCatalog) {
                defaults.set(data, forKey: "ollamaCatalog")
            }
        }
    }

    /// Models currently loaded in memory (from `/api/ps`). Runtime only —
    /// drives the "in memory" indicators and the menu-bar status.
    @Published var ollamaLoadedModels: Set<String> = []

    /// Bytes each loaded model holds in (V)RAM (from `/api/ps`) — its real
    /// memory footprint, shown next to the "in memory" badge. Runtime only.
    @Published var ollamaLoadedVRAM: [String: Int64] = [:]

    // MARK: - OpenRouter model catalog & history

    /// Full OpenRouter model catalog (keyed by slug) with per-model capabilities,
    /// fetched from the public `/models` endpoint. Drives slug validation and
    /// per-model vision/tools/reasoning gating. Persisted as JSON.
    @Published private(set) var openRouterCatalog: [String: ModelInfo] {
        didSet {
            if let data = try? JSONEncoder().encode(openRouterCatalog) {
                defaults.set(data, forKey: "openRouterCatalog")
            }
        }
    }

    /// Slugs the user has entered, most-recent-first — shown as suggestions
    /// under the manual model field. Capped to `maxModelHistory`.
    @Published private(set) var openRouterModelHistory: [String] {
        didSet { defaults.set(openRouterModelHistory, forKey: "openRouterModelHistory") }
    }

    private static let maxModelHistory = 20

    // MARK: - Speech to text

    @Published var sttProvider: STTProviderID {
        didSet { defaults.set(sttProvider.rawValue, forKey: "sttProvider") }
    }

    @Published private(set) var sttModels: [String: String] {
        didSet { defaults.set(sttModels, forKey: "sttModels") }
    }

    // MARK: - OCR (document/image text extraction)

    /// OCR backend: Apple Vision (on-device, free — default) or Mistral (cloud).
    @Published var ocrProvider: OCRProviderID {
        didSet { defaults.set(ocrProvider.rawValue, forKey: "ocrProvider") }
    }

    /// Mistral OCR model (used only when the Mistral provider is selected).
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

    /// Reply-length cap for local (Ollama) models, separate from `maxTokens`:
    /// local tokens are free, the cap only bounds generation time. 0 = no
    /// limit — the request omits `max_tokens` and the model generates until
    /// it stops on its own (thinking models can't get truncated mid-thought).
    @Published var localMaxTokens: Int {
        didSet { defaults.set(localMaxTokens, forKey: "localMaxTokens") }
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

    /// Keep the audio input open (samples discarded) for N minutes after a
    /// dictation ends, so the next one starts with zero mic spin-up — the
    /// CoreAudio power-up costs ~100-300 ms on the built-in mic and multiple
    /// SECONDS on Bluetooth (HFP switch), losing the first words. 0 = off
    /// (default: no orange "mic in use" indicator lingering after dictation).
    @Published var dictationWarmMinutes: Int {
        didSet { defaults.set(dictationWarmMinutes, forKey: "dictationWarmMinutes") }
    }

    /// CoreAudio device UID of the microphone to dictate with; "" = the
    /// system default input. When the chosen device is not connected the
    /// capture silently falls back to the system default.
    @Published var dictationMicUID: String {
        didSet { defaults.set(dictationMicUID, forKey: "dictationMicUID") }
    }

    static let dictationLanguages = ["English", "Russian", "German", "French", "Spanish", "Italian", "Portuguese", "Chinese", "Japanese"]

    /// ISO 639-1 code shown in the dictation pill while translating.
    static func dictationISOCode(for language: String) -> String {
        let codes: [String: String] = [
            "English": "EN", "Russian": "RU", "German": "DE",
            "French": "FR", "Spanish": "ES", "Italian": "IT",
            "Portuguese": "PT", "Chinese": "ZH", "Japanese": "JA",
        ]
        return codes[language] ?? String(language.prefix(2)).uppercased()
    }

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

    // MARK: - Selection prefill

    /// Capture the frontmost app's selected text into the input field when
    /// the panel is summoned (General tab; on by default).
    @Published var prefillFromSelection: Bool {
        didSet { defaults.set(prefillFromSelection, forKey: "prefillFromSelection") }
    }

    // MARK: - Terminal commands

    /// What the ▶ button on shell code blocks does (see `TerminalCommandRunner`).
    /// Default: insert into Terminal, the user presses Enter — nothing runs
    /// without a human.
    @Published var terminalRunMode: TerminalRunMode {
        didSet { defaults.set(terminalRunMode.rawValue, forKey: "terminalRunMode") }
    }

    // MARK: - Diagnostics

    /// Opt-in local logging + hang watchdog (see `Diagnostics`).
    @Published var diagnosticsEnabled: Bool {
        didSet {
            defaults.set(diagnosticsEnabled, forKey: Diagnostics.defaultsKey)
            Diagnostics.setEnabled(diagnosticsEnabled)
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

    /// Chat-panel visual theme (Settings → Appearance). Purely presentational;
    /// read reactively by the panel via the theme palette.
    @Published var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: "appTheme") }
    }

    /// Auto-switch to the Halloween / Día de Muertos themes on their dates and
    /// back afterwards (HolidayThemeManager). Settings → Appearance → Themes.
    @Published var holidayThemes: Bool {
        didSet { defaults.set(holidayThemes, forKey: "holidayThemes") }
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
In USER messages, lines starting with "> " are quoted external text the user captured (e.g. a text selection); the rest of the message is the instruction about it. When the message contains only the quote, apply the current task to the quoted text. Never echo the "> " markers back in your reply.
Interactive HTML: when the user asks for an interactive demo, visualization, simulation, mini-app or web page, reply with ONE complete self-contained HTML document (inline CSS/JS; CDN libraries allowed; include a <title>) inside a single ```html fenced block. The app renders it as a card the user can open as a live interactive preview, save, or view in the browser. Keep commentary around the block brief; never split the document across multiple blocks.
Diagrams: when structure is best shown as a diagram (architecture, flow, sequence, state machine, ER model, org chart, timeline, pie shares), emit mermaid source in a ```mermaid fenced block; the app renders it as a native diagram with export. Mermaid validity rules: first line is the diagram type (flowchart TD, sequenceDiagram, stateDiagram-v2, erDiagram, gantt, pie); one statement per line; keep node labels short; wrap any label containing punctuation, parentheses, slashes or non-Latin text in double quotes, e.g. A["Оплата (карта)"]; never use HTML tags or <br/> inside labels; no markdown emphasis inside the block. For charts of numeric data (bar, line, scatter) prefer an interactive ```html page with inline SVG/JS instead.
Markdown documents: when the user asks for a document as a deliverable file (README, article, report, spec, notes), put the FULL document inside a single ````markdown fenced block (four backticks, so code samples inside the document keep their own ``` fences). Start the document with a # heading — it becomes the card title. The app shows it as a card with a rendered preview and save. Ordinary answers stay plain markdown in the reply, NOT fenced.
Revising a document: when the user asks for changes to an HTML page or Markdown document you produced earlier, re-emit the COMPLETE updated document in the same fenced format with the same title (unless asked to rename) — never reply with only the changed fragment or a diff. Each reply's card is a full standalone version; earlier versions stay openable in the chat above.
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

    /// Presets excluded from the panel's switcher (menu and chip row alike).
    /// The active preset is always offered regardless — see `switcherPresets`.
    @Published private(set) var hiddenPresets: Set<String> {
        didSet { defaults.set(Array(hiddenPresets), forKey: "hiddenPresets") }
    }

    /// Presets whose activation switches the panel to a dedicated, separately
    /// persisted conversation (Settings → Prompts, "Own chat" toggle).
    /// Turning the flag off keeps the history dormant on disk.
    @Published private(set) var isolatedPresets: Set<String> {
        didSet { defaults.set(Array(isolatedPresets), forKey: "isolatedPresets") }
    }

    private init() {
        chatProvider = ProviderID(rawValue: defaults.string(forKey: "chatProvider") ?? "") ?? .openai
        selectedModels = defaults.dictionary(forKey: "selectedModels") as? [String: String] ?? [:]
        cachedModels = defaults.dictionary(forKey: "cachedModels") as? [String: [String]] ?? [:]
        localModelsEnabled = defaults.object(forKey: "localModelsEnabled") as? Bool ?? false
        onlineModelsEnabled = defaults.object(forKey: "onlineModelsEnabled") as? Bool ?? true
        localEndpointURL = defaults.string(forKey: "localEndpointURL") ?? Self.defaultLocalEndpointURL
        localEndpointVerified = defaults.object(forKey: "localEndpointVerified") as? Bool ?? false
        ollamaDetected = defaults.object(forKey: "ollamaDetected") as? Bool ?? false
        ollamaCatalog = (defaults.data(forKey: "ollamaCatalog")
            .flatMap { try? JSONDecoder().decode([String: ModelInfo].self, from: $0) }) ?? [:]
        openRouterCatalog = (defaults.data(forKey: "openRouterCatalog")
            .flatMap { try? JSONDecoder().decode([String: ModelInfo].self, from: $0) }) ?? [:]
        openRouterModelHistory = defaults.stringArray(forKey: "openRouterModelHistory") ?? []
        sttProvider = STTProviderID(rawValue: defaults.string(forKey: "sttProvider") ?? "") ?? .mistral
        sttModels = defaults.dictionary(forKey: "sttModels") as? [String: String] ?? [:]
        // OCR provider: honor a saved choice. On the first launch of this
        // version there is no saved value — and OCR used to be Mistral-only, so
        // a user with a Mistral key was already using Mistral. Keep them on it
        // (don't silently flip established setups); only genuinely fresh users
        // (no Mistral key) get the free on-device Apple default.
        if let storedOCR = defaults.string(forKey: "ocrProvider"),
           let provider = OCRProviderID(rawValue: storedOCR) {
            ocrProvider = provider
        } else {
            ocrProvider = APIKeyStore.hasKey(for: .mistral) ? .mistral : .apple
        }
        ocrModel = defaults.string(forKey: "ocrModel") ?? Self.defaultOCRModel
        reasoningMode = ReasoningMode(rawValue: defaults.string(forKey: "reasoningMode") ?? "") ?? .auto
        // 16k default: artifacts (full HTML pages) regularly exceed 8k output
        // tokens, and on OpenAI /responses the reasoning tokens draw from the
        // same budget. Users who explicitly set a value keep it.
        maxTokens = defaults.object(forKey: "maxTokens") as? Int ?? 16384
        localMaxTokens = defaults.object(forKey: "localMaxTokens") as? Int ?? 0
        webSearchEnabled = defaults.object(forKey: "webSearchEnabled") as? Bool ?? true
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: "appearanceMode") ?? "") ?? .system
        theme = AppTheme(rawValue: defaults.string(forKey: "appTheme") ?? "") ?? .current
        holidayThemes = defaults.object(forKey: "holidayThemes") as? Bool ?? true
        panelFollowsMouse = defaults.object(forKey: "panelFollowsMouse") as? Bool ?? true
        prefillFromSelection = defaults.object(forKey: "prefillFromSelection") as? Bool ?? true
        terminalRunMode = TerminalRunMode(rawValue: defaults.string(forKey: "terminalRunMode") ?? "") ?? .insert
        diagnosticsEnabled = defaults.bool(forKey: Diagnostics.defaultsKey)
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
        dictationWarmMinutes = defaults.object(forKey: "dictationWarmMinutes") as? Int ?? 0
        dictationMicUID = defaults.string(forKey: "dictationMicUID") ?? ""
        customPresets = defaults.dictionary(forKey: "customPresets") as? [String: String] ?? [:]
        presetIcons = defaults.dictionary(forKey: "presetIcons") as? [String: String] ?? [:]
        presetSwitcherStyle = PresetSwitcherStyle(rawValue: defaults.string(forKey: "presetSwitcherStyle") ?? "") ?? .menu
        hiddenPresets = Set(defaults.stringArray(forKey: "hiddenPresets") ?? [])
        isolatedPresets = Set(defaults.stringArray(forKey: "isolatedPresets") ?? [])
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

    /// Presets the panel switcher offers: the non-hidden ones, plus the active
    /// preset — the panel must always be able to display its current state.
    var switcherPresets: [PromptPreset] {
        allPresets.filter { !hiddenPresets.contains($0.name) || $0.name == activePresetName }
    }

    /// Whether a preset appears in the panel switcher (menu or chip row).
    func isPresetShownInSwitcher(named name: String) -> Bool {
        !hiddenPresets.contains(name)
    }

    func setPresetShownInSwitcher(_ shown: Bool, named name: String) {
        if shown {
            hiddenPresets.remove(name)
        } else {
            hiddenPresets.insert(name)
        }
    }

    /// Whether the preset keeps its own isolated conversation.
    func isPresetIsolated(named name: String) -> Bool {
        isolatedPresets.contains(name)
    }

    func setPresetIsolated(_ isolated: Bool, named name: String) {
        if isolated {
            isolatedPresets.insert(name)
        } else {
            isolatedPresets.remove(name)
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
        hiddenPresets.remove(name)
        isolatedPresets.remove(name)
        if activePresetName == name {
            applyPreset(named: Self.builtInPresets[0].name)
        }
        // Unconditional: a dormant chat file may remain from a previously
        // enabled isolation toggle. ChatWindow deletes the file + its media.
        NotificationCenter.default.post(name: .presetDeleted, object: name)
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
        let apiKey = try resolvedAPIKey(for: provider)
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
    /// Settled once the key cache is warm (see `APIKeyStore.warm`). `init` runs
    /// long before the Keychain has been read, and key lookups are cache-only,
    /// so a first-launch default derived from "does the user have a Mistral
    /// key" would always resolve to "no" there — silently moving an existing
    /// Mistral user to on-device OCR. Only ever fills in a default that has
    /// never been stored, so an explicit choice is never touched.
    func resolveKeyDependentDefaults() {
        guard defaults.string(forKey: "ocrProvider") == nil else { return }
        let resolved: OCRProviderID = APIKeyStore.hasKey(for: .mistral) ? .mistral : .apple
        if resolved != ocrProvider { ocrProvider = resolved }
    }

    func autoLoadModelsIfNeeded(for provider: ProviderID) {
        // Manual-entry providers (OpenRouter) have no list to auto-select from;
        // loading their list here would clobber the user-typed slug. Route them
        // to the capability catalog instead.
        if provider.usesManualModelEntry {
            autoLoadOpenRouterCatalogIfNeeded()
            return
        }
        // Local providers load without a key (gated on the master switch);
        // cloud ones need a key present.
        let ready = provider.isLocal ? localModelsEnabled : APIKeyStore.hasKey(for: provider)
        guard models(for: provider).isEmpty, ready else { return }
        Task { try? await refreshModels(for: provider) }
    }

    // MARK: - Local model availability & endpoint

    /// The key handed to a provider's request. Cloud providers must have one;
    /// local providers get an empty string (their server ignores auth).
    func resolvedAPIKey(for provider: ProviderID) throws -> String {
        if let key = APIKeyStore.key(for: provider) { return key }
        if provider.requiresAPIKey { throw ProviderError.missingAPIKey(provider) }
        return ""
    }

    /// Whether the provider's class is switched on (cloud vs local master
    /// toggle). Used by config pickers, where a key may not be entered yet.
    func isProviderClassEnabled(_ provider: ProviderID) -> Bool {
        provider.isLocal ? localModelsEnabled : onlineModelsEnabled
    }

    /// Whether the provider is actually ready to send: class enabled AND
    /// reachable (local endpoint verified) / keyed (cloud). Used by the panel
    /// provider switcher and the send guard.
    func isAvailable(_ provider: ProviderID) -> Bool {
        guard isProviderClassEnabled(provider) else { return false }
        return provider.isLocal ? localEndpointVerified : APIKeyStore.hasKey(for: provider)
    }

    /// Verifies the local endpoint: refreshes the `/v1` model list (sets
    /// `localEndpointVerified`), probes whether it's Ollama (`ollamaDetected`),
    /// and — if so — refreshes per-model capabilities into `ollamaCatalog`.
    /// Best-effort; returns whether `/v1` answered.
    @discardableResult
    func verifyLocalEndpoint() async -> Bool {
        do {
            try await refreshModels(for: .ollama)
            localEndpointVerified = true
        } catch {
            localEndpointVerified = false
            ollamaDetected = false
            ollamaLoadedModels = []
            return false
        }
        let admin = OllamaAdminService(endpointURL: localEndpointURL)
        ollamaDetected = await admin.detect()
        if ollamaDetected {
            await refreshOllamaCatalog(using: admin)
            await refreshOllamaLoaded(using: admin)
        }
        return true
    }

    /// Populates `ollamaCatalog` (vision/tools per model) from `/api/show`.
    func refreshOllamaCatalog(using admin: OllamaAdminService) async {
        var catalog = ollamaCatalog
        for model in models(for: .ollama) {
            if let info = try? await admin.show(model: model) {
                catalog[model] = info
            }
        }
        ollamaCatalog = catalog
    }

    /// Refreshes which Ollama models are currently loaded in memory (`/api/ps`).
    /// Polls `/api/ps` until `model`'s loaded state settles to `expected`, or a
    /// ~1.5s timeout. Ollama's `/api/ps` lags ~100ms behind the load/unload
    /// response (the llama-server subprocess is still tearing down), so a single
    /// immediate refresh reads the stale state — the UI then looks like the
    /// action didn't work until the next poll.
    func refreshOllamaLoadedUntil(model: String, loaded expected: Bool,
                                  using admin: OllamaAdminService) async {
        for attempt in 0..<10 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 150_000_000) }
            await refreshOllamaLoaded(using: admin)
            if ollamaLoadedModels.contains(model) == expected { return }
        }
    }

    func refreshOllamaLoaded(using admin: OllamaAdminService) async {
        guard let loaded = try? await admin.ps() else { return }
        // Assign only on change: a @Published Set/Dictionary fires objectWillChange
        // on every assignment even when equal, and an unconditional assign here
        // re-renders the settings tree → re-fires the view's onAppear refresh →
        // a tight tags/ps polling loop. Equality-gating breaks that feedback.
        let names = Set(loaded.map(\.name))
        if names != ollamaLoadedModels { ollamaLoadedModels = names }
        let vram = Dictionary(loaded.map { ($0.name, $0.sizeVRAM) },
                              uniquingKeysWith: { first, _ in first })
        if vram != ollamaLoadedVRAM { ollamaLoadedVRAM = vram }
    }

    // MARK: - OpenRouter catalog & manual model entry

    /// Fetches OpenRouter's full model catalog (public endpoint; the key is
    /// sent when present but not required) and caches it for slug validation
    /// and per-model capability gating.
    func refreshOpenRouterCatalog() async throws {
        let key = APIKeyStore.key(for: .openrouter)
        let catalog = try await OpenAICompatibleProvider.openRouter.fetchModelCatalog(apiKey: key)
        var dict: [String: ModelInfo] = [:]
        for info in catalog { dict[info.id] = info }
        openRouterCatalog = dict
    }

    /// Loads the OpenRouter catalog in the background if it hasn't been fetched
    /// yet, so the manual model field can validate slugs. Best-effort, silent.
    func autoLoadOpenRouterCatalogIfNeeded() {
        guard openRouterCatalog.isEmpty else { return }
        Task { try? await refreshOpenRouterCatalog() }
    }

    var isOpenRouterCatalogLoaded: Bool { !openRouterCatalog.isEmpty }

    func openRouterModelInfo(for slug: String) -> ModelInfo? {
        openRouterCatalog[slug.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    /// Whether a slug is present in the fetched catalog. Only meaningful once
    /// the catalog is loaded (`isOpenRouterCatalogLoaded`).
    func isKnownOpenRouterModel(_ slug: String) -> Bool {
        openRouterModelInfo(for: slug) != nil
    }

    /// Records a chosen OpenRouter slug: selects it and moves it to the front
    /// of the usage history (deduped, capped).
    func recordOpenRouterModel(_ slug: String) {
        let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        setSelectedModel(trimmed, for: .openrouter)
        var history = openRouterModelHistory.filter { $0 != trimmed }
        history.insert(trimmed, at: 0)
        if history.count > Self.maxModelHistory {
            history = Array(history.prefix(Self.maxModelHistory))
        }
        openRouterModelHistory = history
    }

    func removeOpenRouterModelFromHistory(_ slug: String) {
        openRouterModelHistory.removeAll { $0 == slug }
    }

    func clearOpenRouterModelHistory() {
        openRouterModelHistory = []
    }

    // MARK: - Per-model capability resolution

    /// Whether the model accepts image input. Per-provider for most; per-model
    /// (from the catalog) for OpenRouter. Unknown OpenRouter slugs are treated
    /// optimistically as vision-capable (most flagship models are).
    func modelSupportsVision(provider: ProviderID, model: String) -> Bool {
        if provider == .openrouter {
            return openRouterModelInfo(for: model)?.supportsVision ?? true
        }
        // Local: real capabilities from Ollama's /api/show (optimistic until cached).
        if provider == .ollama {
            return ollamaCatalog[model]?.supportsVision ?? true
        }
        return provider.supportsVision
    }

    /// Whether the model supports function tools (web search). Per-model for
    /// OpenRouter; the dedicated providers all support tools.
    func modelSupportsTools(provider: ProviderID, model: String) -> Bool {
        if provider == .openrouter {
            return openRouterModelInfo(for: model)?.supportsTools ?? true
        }
        if provider == .ollama {
            return ollamaCatalog[model]?.supportsTools ?? true
        }
        return true
    }

    /// Whether the reasoning selector has any effect. Catalog-driven for
    /// OpenRouter, heuristic for the dedicated providers.
    func modelSupportsReasoningControl(provider: ProviderID, model: String) -> Bool {
        if provider == .openrouter {
            return openRouterModelInfo(for: model)?.supportsReasoning ?? false
        }
        return ModelCapabilities.supportsReasoningControl(provider: provider, model: model)
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
        case .openrouter: return OpenAICompatibleProvider.openRouter
        case .kimi: return OpenAICompatibleProvider.kimi
        case .ollama:
            // Base URL is user-configurable; read straight from UserDefaults so
            // this stays nonisolated (no @MainActor AppSettings.shared hop).
            let raw = UserDefaults.standard.string(forKey: "localEndpointURL")
                ?? AppSettings.defaultLocalEndpointURL
            let url = URL(string: raw) ?? URL(string: AppSettings.defaultLocalEndpointURL)!
            return OpenAICompatibleProvider(providerID: .ollama, baseURL: url)
        }
    }
}
