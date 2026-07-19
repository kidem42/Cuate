import SwiftUI
import AVFoundation

/// App settings: provider API keys (Keychain), chat provider/model,
/// model parameters, web search, speech-to-text, and system prompt presets.
enum SettingsTab: String, Hashable {
    case chat, keys, voice, general, appearance, prompts
    case layoutFix // LayoutFix addon (Addons/LayoutFix)
    case imageAddon // ImageAddon (Addons/ImageAddon)
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var layoutFix = LayoutFixSettings.shared // addon: gates its tab
    @ObservedObject private var imageAddon = ImageAddonSettings.shared // addon: gates its tab

    enum KeyTestState: Equatable {
        case testing
        case ok
        case failed(String)
    }

    @State private var keyInput: [ProviderID: String] = [:]
    @State private var maskedKeys: [ProviderID: String?] = [:]
    @State private var keyTests: [String: KeyTestState] = [:]
    @State private var braveKeyInput = ""
    @State private var braveMasked: String?
    @State private var deepgramKeyInput = ""
    @State private var deepgramMasked: String?
    @State private var isLoadingModels = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var sttModelInput = ""
    @State private var newPresetName = ""
    @State private var selectedTab = SettingsTab.chat
    // Prompt editor height: user-resizable via the grip below the field,
    // persisted so a tall editor stays tall on the next open.
    @AppStorage("settings.promptEditorHeight") private var promptEditorHeight: Double = 140
    @State private var promptDragBase: Double?
    @State private var accessibilityGranted = true
    @State private var screenGranted = true
    @State private var micGranted = true

    var body: some View {
        // System Settings-style layout: translucent sidebar with the sections,
        // grouped forms in the detail pane floating on a behind-window blur —
        // the settings-window take on the panel's Liquid Glass language.
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .id(settings.language) // re-render the whole tree on language change
        .onReceive(NotificationCenter.default.publisher(for: .selectSettingsTab)) { note in
            if let raw = note.object as? String, let t = SettingsTab(rawValue: raw) {
                selectedTab = t
            }
        }
        // Addon tabs disappear with their master switch — bounce the selection
        // back to General so the detail pane never shows an orphaned tab.
        .onChange(of: layoutFix.enabled) { _, enabled in
            if !enabled && selectedTab == .layoutFix { selectedTab = .general }
        }
        .onChange(of: imageAddon.enabled) { _, enabled in
            if !enabled && selectedTab == .imageAddon { selectedTab = .general }
        }
        .frame(minWidth: 720, minHeight: 560)
        .onAppear {
            refreshMasks()
            sttModelInput = settings.sttModel(for: settings.sttProvider)
            settings.autoLoadModelsIfNeeded(for: settings.chatProvider)
            validateAllKeys()
            refreshPermissions()
        }
        // Re-check when the user comes back from System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
        .onChange(of: settings.chatProvider) { _, provider in
            // Load the newly selected provider's models (or OpenRouter catalog).
            settings.autoLoadModelsIfNeeded(for: provider)
        }
    }

    // MARK: - Sidebar & detail

    private var sidebar: some View {
        List(selection: Binding<SettingsTab?>(
            get: { selectedTab },
            set: { if let tab = $0 { selectedTab = tab } }
        )) {
            sidebarRow(L("tab.chat"), systemImage: "bubble.left.and.bubble.right.fill", color: .blue)
                .tag(SettingsTab.chat)
            sidebarRow(L("tab.keys"), systemImage: "key.fill", color: .orange)
                .tag(SettingsTab.keys)
            sidebarRow(L("tab.voice"), systemImage: "mic.fill", color: .red)
                .tag(SettingsTab.voice)
            sidebarRow(L("tab.general"), systemImage: "gearshape.fill", color: .gray)
                .tag(SettingsTab.general)
            sidebarRow(L("tab.appearance"), systemImage: "paintbrush.fill", color: .pink)
                .tag(SettingsTab.appearance)
            sidebarRow(L("tab.prompts"), systemImage: "text.quote", color: .purple)
                .tag(SettingsTab.prompts)

            // Addon rows appear only while the addon is enabled
            // (master switches live in the General section).
            if layoutFix.enabled || imageAddon.enabled {
                Section(L("sidebar.addons")) {
                    if layoutFix.enabled {
                        sidebarRow(LFL("lf.tab"), systemImage: "keyboard.fill", color: .indigo)
                            .tag(SettingsTab.layoutFix)
                    }
                    if imageAddon.enabled {
                        sidebarRow(IAL("ia.tab"), systemImage: "photo.fill", color: .green)
                            .tag(SettingsTab.imageAddon)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 176, ideal: 192, max: 240)
    }

    /// System Settings-style row: white glyph in a colored rounded square.
    private func sidebarRow(_ title: String, systemImage: String, color: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 21, height: 21)
                .background(RoundedRectangle(cornerRadius: 5.5).fill(color.gradient))
        }
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            switch selectedTab {
            case .chat: tab { chatSection; parametersSection; ocrSection }
            case .keys: tab { keysSection; speechKeysSection; webSection }
            case .voice: tab { voiceSection; dictationSection }
            case .general: tab { generalSection; permissionsSection; hotkeysSection; panelSection; diagnosticsSection }
            case .appearance: tab { appearanceSection }
            case .prompts: tab { switcherSection; promptSection }
            case .layoutFix: LayoutFixSettingsView()   // brings its own Form
            case .imageAddon: ImageAddonSettingsView() // brings its own Form
            }
        }
        // The "glass" part: hide the forms' opaque scroll background (the
        // section cards keep their own fill, so legibility holds) and let a
        // behind-window blur show the desktop through, like the chat panel.
        .scrollContentBackground(.hidden)
        .background(BehindWindowBlur().ignoresSafeArea())
        // No .navigationTitle: the section name already shows in the sidebar
        // and the form headers — the toolbar copy was the third one.
    }

    /// Wraps a tab's sections in a Form and appends the shared status line.
    @ViewBuilder
    private func tab<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Form {
            content()
            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.callout)
                        .foregroundColor(statusIsError ? .red : .secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Chat provider & model

    private var chatSection: some View {
        Section(L("chat.header")) {
            Picker(L("chat.provider"), selection: $settings.chatProvider) {
                ForEach(ProviderID.allCases) { provider in
                    Label {
                        Text(provider.displayName)
                    } icon: {
                        ProviderLogo(provider: provider, size: 14)
                    }
                    .tag(provider)
                }
            }

            if settings.chatProvider.usesManualModelEntry {
                OpenRouterModelField(settings: settings)
            } else {
                let models = settings.models(for: settings.chatProvider)
                if models.isEmpty {
                    Text(L("chat.noModels"))
                        .font(.callout)
                        .foregroundColor(.secondary)
                } else {
                    Picker(L("chat.model"), selection: Binding(
                        get: { settings.selectedModel(for: settings.chatProvider) ?? models.first ?? "" },
                        set: { settings.setSelectedModel($0, for: settings.chatProvider) }
                    )) {
                        ForEach(models, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                }

                HStack {
                    Button(isLoadingModels ? L("chat.loading") : L("chat.loadModels")) {
                        loadModels()
                    }
                    .disabled(isLoadingModels || !APIKeyStore.hasKey(for: settings.chatProvider))

                    if !APIKeyStore.hasKey(for: settings.chatProvider) {
                        Text(L("chat.addKeyFirst"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private func loadModels() {
        isLoadingModels = true
        statusMessage = nil
        let provider = settings.chatProvider
        Task {
            do {
                try await settings.refreshModels(for: provider)
                statusMessage = "Loaded \(settings.models(for: provider).count) models for \(provider.displayName)."
                statusIsError = false
            } catch {
                statusMessage = error.localizedDescription
                statusIsError = true
            }
            isLoadingModels = false
        }
    }

    // MARK: - Model parameters (capability-aware)

    private var parametersSection: some View {
        Section {
            let model = settings.selectedModel(for: settings.chatProvider) ?? ""
            if settings.modelSupportsReasoningControl(provider: settings.chatProvider, model: model) {
                Picker(L("params.reasoning"), selection: $settings.reasoningMode) {
                    ForEach(ReasoningMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } else {
                LabeledContent(L("params.reasoning")) {
                    Text(reasoningUnavailableHint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Stepper(value: $settings.maxTokens, in: 1024...32768, step: 1024) {
                LabeledContent(L("params.maxTokens"), value: "\(settings.maxTokens)")
            }
        } header: {
            Text(L("params.header"))
        } footer: {
            Text(L("params.footer"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var reasoningUnavailableHint: String {
        switch settings.chatProvider {
        case .deepseek: return L("params.reasoning.deepseek")
        case .mistral: return L("params.reasoning.mistral")
        case .openrouter: return L("params.reasoning.openrouter")
        default: return L("params.reasoning.na")
        }
    }

    // MARK: - API keys

    private var keysSection: some View {
        Section {
            ForEach(ProviderID.allCases) { provider in
                keyRow(for: provider)
            }
        } header: {
            Text(L("keys.header"))
        } footer: {
            Text(L("keys.footer"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func keyRow(for provider: ProviderID) -> some View {
        VStack(alignment: .leading, spacing: 4) {
        HStack {
            HStack(spacing: 6) {
                ProviderLogo(provider: provider, size: 14)
                Text(provider.displayName)
            }
            .frame(width: 150, alignment: .leading)

            if let masked = maskedKeys[provider] ?? nil {
                HStack(spacing: 6) {
                    Text(masked)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundColor(.secondary)
                    keyTestIndicator(for: provider.rawValue)
                }
                Spacer()
                Button(L("keys.recheck")) {
                    validateKey(for: provider)
                }
                .disabled(keyTests[provider.rawValue] == .testing)
                Button(L("keys.remove")) {
                    APIKeyStore.remove(for: provider)
                    keyTests[provider.rawValue] = nil
                    refreshMasks()
                }
            } else {
                SecureField(L("keys.paste"), text: Binding(
                    get: { keyInput[provider] ?? "" },
                    set: { keyInput[provider] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                Link(destination: provider.apiKeyURL) {
                    Text(L("keys.get"))
                        .font(.caption)
                }
                .help(provider.apiKeyURL.absoluteString)
                Button(L("keys.save")) {
                    saveKey(for: provider)
                }
                .disabled((keyInput[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        // Full-width error line below the row — squeezing it into the row
        // truncated the message beyond usefulness.
        keyErrorLine(for: provider.rawValue)
        }
    }

    /// The full validation-failure reason, wrapping across the section width;
    /// selectable so it can be copied into a search or bug report.
    @ViewBuilder
    private func keyErrorLine(for id: String) -> some View {
        if case .failed(let reason) = keyTests[id] {
            Text(reason)
                .font(.caption)
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .help(reason)
        }
    }

    /// ✓ / ✗ / spinner shown next to a saved key.
    @ViewBuilder
    private func keyTestIndicator(for id: String) -> some View {
        switch keyTests[id] {
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

    /// Validates every stored key concurrently (called on open).
    private func validateAllKeys() {
        for provider in ProviderID.allCases where APIKeyStore.hasKey(for: provider) {
            validateKey(for: provider)
        }
        if APIKeyStore.key(aux: .brave) != nil {
            validateBraveKey()
        }
        if APIKeyStore.key(aux: .deepgram) != nil {
            validateDeepgramKey()
        }
    }

    /// Validates a chat provider key with a cheap live call (model list),
    /// surfacing the failure reason inline.
    private func validateKey(for provider: ProviderID) {
        keyTests[provider.rawValue] = .testing
        Task {
            do {
                guard let key = APIKeyStore.key(for: provider) else {
                    throw ProviderError.missingAPIKey(provider)
                }
                try await ProviderRegistry.provider(for: provider).validateKey(apiKey: key)
                // Keep the OpenRouter catalog fresh so slug validation works.
                if provider == .openrouter { try? await settings.refreshOpenRouterCatalog() }
                keyTests[provider.rawValue] = .ok
            } catch {
                keyTests[provider.rawValue] = .failed(error.localizedDescription)
            }
        }
    }

    private func saveKey(for provider: ProviderID) {
        guard let raw = keyInput[provider] else { return }
        if APIKeyStore.set(raw, for: provider) {
            keyInput[provider] = ""   // wipe the field — key now lives only in the Keychain
            refreshMasks()
            statusMessage = "Key for \(provider.displayName) saved to Keychain."
            statusIsError = false
            // If the active chat provider has no usable key, switch to the one
            // just configured so chat works without hunting through the tabs.
            if !APIKeyStore.hasKey(for: settings.chatProvider) {
                settings.chatProvider = provider
            }
            loadModelsAfterKeySave(for: provider) // fetch models, auto-select a default, and validate
        } else {
            statusMessage = "Failed to save the key for \(provider.displayName)."
            statusIsError = true
        }
    }

    /// After a key is saved, fetch the provider's models and auto-select a
    /// sensible default (so chat is usable immediately). Doubles as a key check.
    private func loadModelsAfterKeySave(for provider: ProviderID) {
        keyTests[provider.rawValue] = .testing
        Task {
            do {
                if provider == .openrouter {
                    // OpenRouter models are user-typed, so there is no list to
                    // auto-select from: validate the key and load the catalog
                    // (for slug validation) instead.
                    guard let key = APIKeyStore.key(for: provider) else {
                        throw ProviderError.missingAPIKey(provider)
                    }
                    try await ProviderRegistry.provider(for: provider).validateKey(apiKey: key)
                    try? await settings.refreshOpenRouterCatalog()
                } else {
                    try await settings.refreshModels(for: provider)
                }
                keyTests[provider.rawValue] = .ok
            } catch {
                keyTests[provider.rawValue] = .failed(error.localizedDescription)
            }
        }
    }

    private func refreshMasks() {
        for provider in ProviderID.allCases {
            maskedKeys[provider] = APIKeyStore.maskedKey(for: provider)
        }
        braveMasked = APIKeyStore.maskedKey(aux: .brave)
        deepgramMasked = APIKeyStore.maskedKey(aux: .deepgram)
    }

    // MARK: - Web access

    private var webSection: some View {
        Section {
            Toggle(L("web.allow"), isOn: $settings.webSearchEnabled)

            VStack(alignment: .leading, spacing: 4) {
            HStack {
                HStack(spacing: 6) {
                    ProviderGlyph(name: "brave", fallbackLetter: "B", size: 14)
                    Text(L("web.brave"))
                }
                .frame(width: 150, alignment: .leading)
                if let masked = braveMasked {
                    HStack(spacing: 6) {
                        Text(masked)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundColor(.secondary)
                        keyTestIndicator(for: "brave")
                    }
                    Spacer()
                    Button(L("keys.recheck")) {
                        validateBraveKey()
                    }
                    .disabled(keyTests["brave"] == .testing)
                    Button(L("keys.remove")) {
                        APIKeyStore.remove(aux: .brave)
                        keyTests["brave"] = nil
                        refreshMasks()
                    }
                } else {
                    SecureField(L("web.pasteBrave"), text: $braveKeyInput)
                        .textFieldStyle(.roundedBorder)
                    Link(destination: URL(string: "https://api-dashboard.search.brave.com/app/keys")!) {
                        Text(L("keys.get"))
                            .font(.caption)
                    }
                    Button(L("keys.save")) {
                        if APIKeyStore.set(braveKeyInput, aux: .brave) {
                            braveKeyInput = ""
                            refreshMasks()
                            validateBraveKey()
                        }
                    }
                    .disabled(braveKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            keyErrorLine(for: "brave")
            }
        } header: {
            Text(L("web.header"))
        } footer: {
            Text(L("web.footer"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// Validates the Brave key with a minimal live search.
    private func validateBraveKey() {
        keyTests["brave"] = .testing
        Task {
            do {
                _ = try await BraveSearchService.search(query: "test", count: 1)
                keyTests["brave"] = .ok
            } catch {
                keyTests["brave"] = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Voice

    private var voiceSection: some View {
        Section {
            Picker(L("voice.transcription"), selection: $settings.sttProvider) {
                ForEach(STTProviderID.allCases) { provider in
                    Label {
                        Text(provider.displayName)
                    } icon: {
                        STTProviderLogo(provider: provider, size: 14)
                    }
                    .tag(provider)
                }
            }
            .onChange(of: settings.sttProvider) { _, newValue in
                sttModelInput = settings.sttModel(for: newValue)
            }

            TextField(L("voice.sttModel"), text: $sttModelInput, prompt: Text(settings.sttProvider.defaultModel))
                .textFieldStyle(.roundedBorder)
                .onChange(of: sttModelInput) { _, newValue in
                    settings.setSTTModel(newValue, for: settings.sttProvider)
                }

            // Parameter tabs hold pickers only; keys live in the API Keys tab.
            if !settings.sttProvider.hasKey {
                Text(L("voice.needKey"))
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        } header: {
            Text(L("voice.header"))
        } footer: {
            Text(L("voice.footer"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Speech-to-text key (API Keys tab)

    /// Deepgram is STT-only (no chat), so it isn't part of `keysSection`'s
    /// chat-provider list — it gets its own section, like Brave for web.
    private var speechKeysSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
            HStack {
                HStack(spacing: 6) {
                    STTProviderLogo(provider: .deepgram, size: 14)
                    Text("Deepgram")
                }
                .frame(width: 150, alignment: .leading)
                if let masked = deepgramMasked {
                    HStack(spacing: 6) {
                        Text(masked)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundColor(.secondary)
                        keyTestIndicator(for: "deepgram")
                    }
                    Spacer()
                    Button(L("keys.recheck")) {
                        validateDeepgramKey()
                    }
                    .disabled(keyTests["deepgram"] == .testing)
                    Button(L("keys.remove")) {
                        APIKeyStore.remove(aux: .deepgram)
                        keyTests["deepgram"] = nil
                        refreshMasks()
                    }
                } else {
                    SecureField(L("keys.paste"), text: $deepgramKeyInput)
                        .textFieldStyle(.roundedBorder)
                    Link(destination: STTProviderID.deepgram.apiKeyURL) {
                        Text(L("keys.get"))
                            .font(.caption)
                    }
                    Button(L("keys.save")) {
                        if APIKeyStore.set(deepgramKeyInput, aux: .deepgram) {
                            deepgramKeyInput = ""
                            refreshMasks()
                            validateDeepgramKey()
                        }
                    }
                    .disabled(deepgramKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            keyErrorLine(for: "deepgram")
            }
        } header: {
            Text(L("voice.header"))
        }
    }

    /// Validates the Deepgram key with a cheap authenticated call.
    private func validateDeepgramKey() {
        guard let key = APIKeyStore.key(aux: .deepgram) else { return }
        keyTests["deepgram"] = .testing
        Task {
            do {
                var request = URLRequest(url: URL(string: "https://api.deepgram.com/v1/projects")!)
                request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
                _ = try await HTTPClient.json(request)
                keyTests["deepgram"] = .ok
            } catch {
                keyTests["deepgram"] = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Hotkeys

    private var allHotkeys: [HotkeyCombo] {
        [settings.togglePanelHotkey, settings.screenshotHotkey, settings.areaScreenshotHotkey,
         settings.dictationHotkey, settings.dictationTranslateHotkey]
    }

    private func others(_ combo: HotkeyCombo) -> [HotkeyCombo] {
        allHotkeys.filter { $0 != combo }
    }

    private var hotkeysSection: some View {
        Section {
            ShortcutRecorderView(
                title: L("hotkeys.openPanel"),
                combo: $settings.togglePanelHotkey,
                conflictingCombos: others(settings.togglePanelHotkey)
            )
            ShortcutRecorderView(
                title: L("hotkeys.fullShot"),
                combo: $settings.screenshotHotkey,
                conflictingCombos: others(settings.screenshotHotkey)
            )
            ShortcutRecorderView(
                title: L("hotkeys.areaShot"),
                combo: $settings.areaScreenshotHotkey,
                conflictingCombos: others(settings.areaScreenshotHotkey)
            )
            if settings.dictationEnabled {
                ShortcutRecorderView(
                    title: L("hotkeys.dictate"),
                    combo: $settings.dictationHotkey,
                    conflictingCombos: others(settings.dictationHotkey)
                )
                ShortcutRecorderView(
                    title: L("hotkeys.dictateTranslate"),
                    combo: $settings.dictationTranslateHotkey,
                    conflictingCombos: others(settings.dictationTranslateHotkey)
                )
            }
            Button(L("hotkeys.reset")) {
                settings.togglePanelHotkey = .defaultTogglePanel
                settings.screenshotHotkey = .defaultScreenshot
                settings.areaScreenshotHotkey = .defaultAreaScreenshot
                settings.dictationHotkey = .defaultDictation
                settings.dictationTranslateHotkey = .defaultDictationTranslate
            }
        } header: {
            Text(L("hotkeys.header"))
        } footer: {
            Text(L("hotkeys.footer"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - OCR

    private var ocrSection: some View {
        Section {
            LabeledContent(L("ocr.provider")) {
                HStack(spacing: 6) {
                    ProviderLogo(provider: .mistral, size: 14)
                    Text("Mistral OCR")
                }
            }

            TextField(L("ocr.model"), text: $settings.ocrModel, prompt: Text(AppSettings.defaultOCRModel))
                .textFieldStyle(.roundedBorder)

            if !APIKeyStore.hasKey(for: .mistral) {
                Text(L("ocr.needKey"))
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        } header: {
            Text(L("ocr.header"))
        } footer: {
            Text(L("ocr.footer"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Dictation

    private var dictationSection: some View {
        Section {
            Toggle(L("dictation.enable"), isOn: $settings.dictationEnabled)

            if settings.dictationEnabled {
                Toggle(L("dictation.cleanup"), isOn: $settings.dictationCleanup)

                Toggle(L("dictation.chunked"), isOn: $settings.dictationChunked)

                Picker(L("dictation.translateTo"), selection: $settings.dictationTargetLanguage) {
                    ForEach(AppSettings.dictationLanguages, id: \.self) { lang in
                        Text(lang).tag(lang)
                    }
                }
            }
        } header: {
            Text(L("dictation.header"))
        } footer: {
            Text(L("dictation.footer"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Appearance & language

    @ViewBuilder
    private var appearanceSection: some View {
        Section(L("appearance.header")) {
            Picker(L("appearance.language"), selection: $settings.language) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
            Picker(L("appearance.mode"), selection: $settings.appearanceMode) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Button(L("ob.showTour")) {
                NotificationCenter.default.post(name: .showOnboarding, object: nil)
            }
        }
        // Chat-panel visual theme (Blueprint, Terminal, Synthwave, …) —
        // a grid of clickable mini-previews in its own block.
        Section(L("appearance.themes.header")) {
            ThemeGridPicker(selection: $settings.theme)
            VStack(alignment: .leading, spacing: 3) {
                Toggle(L("appearance.holidayThemes"), isOn: $settings.holidayThemes)
                Text(L("appearance.holidayThemes.caption"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Panel placement

    private var generalSection: some View {
        Section {
            Toggle(L("general.launchAtLogin"), isOn: $settings.launchAtLogin)
            VStack(alignment: .leading, spacing: 3) {
                Toggle(L("general.prefillSelection"), isOn: $settings.prefillFromSelection)
                    .help(L("general.prefillSelection.help"))
                Text(L("general.prefillSelection.caption"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LayoutFixEnableToggle() // LayoutFix addon master switch (Addons/LayoutFix)
            ImageAddonEnableToggle() // ImageAddon master switch (Addons/ImageAddon)
        }
    }

    // MARK: - Permissions (always-visible status indicators)

    private var permissionsSection: some View {
        Section {
            permissionRow(L("perm.accessibility"), granted: accessibilityGranted) {
                // The system request adds the app to the list; the pane opens
                // so the user can flip the switch right away.
                _ = TextInserter.checkAccessibility(promptIfNeeded: true)
                openPrivacyPane("Privacy_Accessibility")
            }
            permissionRow(L("perm.screen"), granted: screenGranted) {
                if !CGRequestScreenCaptureAccess() {
                    openPrivacyPane("Privacy_ScreenCapture")
                }
            }
            permissionRow(L("perm.mic"), granted: micGranted) {
                if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in
                        DispatchQueue.main.async { refreshPermissions() }
                    }
                } else {
                    openPrivacyPane("Privacy_Microphone")
                }
            }
        } header: {
            Text(L("perm.header"))
        } footer: {
            Text(L("perm.footer"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func permissionRow(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(granted ? .green : .orange)
            Text(title)
            Spacer()
            if granted {
                Text(L("perm.granted"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Button(L("perm.grant")) { action() }
            }
        }
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshPermissions() {
        accessibilityGranted = TextInserter.checkAccessibility(promptIfNeeded: false)
        screenGranted = CGPreflightScreenCaptureAccess()
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private var panelSection: some View {
        Section {
            Toggle(L("panel.followMouse"), isOn: $settings.panelFollowsMouse)

            Button(L("panel.resetPosition")) {
                settings.panelHasCustomPosition = false
                settings.panelRelativeCenter = nil
                // Recenter the panel right away (Spotlight-style)
                NotificationCenter.default.post(name: .panelPositionDidReset, object: nil)
            }
        } header: {
            Text(L("panel.header"))
        } footer: {
            Text(L("panel.footer"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        Section {
            Toggle(L("diag.enable"), isOn: $settings.diagnosticsEnabled)

            HStack {
                Button(L("diag.export")) { exportLogs() }
                Button(L("diag.open")) { Diagnostics.openLogsFolder() }
            }
        } header: {
            Text(L("diag.header"))
        } footer: {
            Text(L("diag.footer"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// Zips logs into ~/Downloads off the main thread (ditto + file copies).
    private func exportLogs() {
        statusMessage = nil
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try Diagnostics.exportToDownloads()
                }.value
                statusMessage = "\(L("diag.exported")): \(url.lastPathComponent)"
                statusIsError = false
            } catch {
                statusMessage = error.localizedDescription
                statusIsError = true
            }
        }
    }

    // MARK: - Panel switcher (style + per-preset visibility)

    private var switcherSection: some View {
        Section {
            Picker(L("switcher.style"), selection: $settings.presetSwitcherStyle) {
                ForEach(PresetSwitcherStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.segmented)

            // Column captions for the two per-preset switches.
            HStack {
                Spacer()
                Text(L("switcher.colShow"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 64)
                Text(L("switcher.colChat"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 64)
            }

            // Per preset: visibility in the panel switcher + isolated chat.
            ForEach(settings.allPresets) { preset in
                HStack(spacing: 6) {
                    if let icon = settings.presetIcon(named: preset.name) {
                        Text(icon)
                    }
                    Text(preset.isBuiltIn ? preset.name : "\(preset.name) (\(L("prompts.custom")))")
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { settings.isPresetShownInSwitcher(named: preset.name) },
                        set: { settings.setPresetShownInSwitcher($0, named: preset.name) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .frame(width: 64)
                    Toggle("", isOn: Binding(
                        get: { settings.isPresetIsolated(named: preset.name) },
                        set: { settings.setPresetIsolated($0, named: preset.name) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .frame(width: 64)
                    .help(L("switcher.isolatedHelp"))
                }
            }
        } header: {
            Text(L("switcher.header"))
        } footer: {
            Text(L("switcher.footer") + "\n\n" + L("switcher.isolatedFooter"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - System prompt & presets

    private var promptSection: some View {
        Section {
            // Preset picker + explicit delete
            HStack {
                Picker(L("prompts.preset"), selection: Binding(
                    get: { settings.activePresetName },
                    set: { settings.applyPreset(named: $0) }
                )) {
                    ForEach(settings.allPresets) { preset in
                        Text(preset.isBuiltIn ? preset.name : "\(preset.name) (\(L("prompts.custom")))").tag(preset.name)
                    }
                }

                // Emoji icon of the active preset (shown as a chip in the panel).
                EmojiIconPicker(
                    icon: settings.presetIcon(named: settings.activePresetName),
                    onPick: { settings.setPresetIcon($0, forPreset: settings.activePresetName) }
                )

                Button(role: .destructive) {
                    settings.deleteCustomPreset(named: settings.activePresetName)
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(isActivePresetBuiltIn)
                .help(isActivePresetBuiltIn ? L("prompts.builtInNoDelete") : L("prompts.deleteThis"))
            }

            TextEditor(text: $settings.systemPrompt)
                .font(.system(size: 12))
                .frame(height: promptEditorHeight)
            promptResizeGrip

            // Unsaved-changes marker + actions
            if promptIsModified {
                HStack {
                    Label(L("prompts.edited"), systemImage: "pencil")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Spacer()
                    Button("\(L("prompts.revertTo")) “\(settings.activePresetName)”") {
                        settings.resetPromptToPreset()
                    }
                }
            }

            HStack {
                TextField(L("prompts.savePlaceholder"), text: $newPresetName)
                    .textFieldStyle(.roundedBorder)
                Button(L("prompts.savePreset")) {
                    settings.saveCurrentAsPreset(named: newPresetName)
                    newPresetName = ""
                }
                .disabled(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text(L("prompts.header"))
        } footer: {
            Text(L("prompts.footer"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// Drag handle under the prompt editor: pull down for more room.
    /// Clamped so the editor can't collapse or swallow the window.
    private var promptResizeGrip: some View {
        Capsule()
            .fill(.tertiary)
            .frame(width: 36, height: 4)
            .frame(maxWidth: .infinity) // centered; the whole row is grabbable
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = promptDragBase ?? promptEditorHeight
                        promptDragBase = base
                        promptEditorHeight = min(600, max(70, base + value.translation.height))
                    }
                    .onEnded { _ in promptDragBase = nil }
            )
            .onHover { hovering in
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .help(L("prompts.resizeHelp"))
    }

    private var isActivePresetBuiltIn: Bool {
        AppSettings.builtInPresets.contains { $0.name == settings.activePresetName }
    }

    private var promptIsModified: Bool {
        settings.systemPrompt != settings.presetText(named: settings.activePresetName)
    }
}

/// Button showing the active preset's emoji icon. Clicking focuses an
/// (invisible until focused) text field and opens the NATIVE macOS emoji
/// palette (the ⌃⌘Space one) targeting it — the picked emoji lands in the
/// field and is applied immediately. Right-click resets the icon. An outline
/// smiley (SF Symbol) marks the "no icon" state so it can't be mistaken for
/// a chosen emoji.
private struct EmojiIconPicker: View {
    let icon: String?
    let onPick: (String) -> Void

    /// One-shot: set true to focus the capture field and open the palette.
    @State private var trigger = false

    var body: some View {
        ZStack {
            // Invisible AppKit field the palette inserts into. The visible
            // layer never depends on its focus, so no state can "stick".
            EmojiCaptureField(trigger: $trigger, onPick: onPick)
                .frame(width: 28, height: 22)
                .opacity(0.02)

            Button {
                trigger = true
            } label: {
                Group {
                    if let icon {
                        Text(icon).font(.system(size: 14))
                    } else {
                        Image(systemName: "face.smiling")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 28, height: 22)
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            Button(L("prompts.iconClear")) { onPick("") }
        }
        .help(L("prompts.iconHelp"))
    }
}

/// Hidden NSTextField that receives the system emoji palette's insertion.
/// AppKit first-responder handling is reliable here, unlike SwiftUI
/// @FocusState which desyncs when the palette takes key status.
private struct EmojiCaptureField: NSViewRepresentable {
    @Binding var trigger: Bool
    let onPick: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .center
        field.font = .systemFont(ofSize: 14)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.onPick = onPick   // keep the latest preset binding
        if trigger {
            DispatchQueue.main.async {
                trigger = false
                field.stringValue = ""
                field.window?.makeFirstResponder(field)
                NSApp.orderFrontCharacterPalette(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onPick: (String) -> Void
        init(onPick: @escaping (String) -> Void) { self.onPick = onPick }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let last = trimmed.last else { return }
            onPick(String(last))   // last grapheme = the newly inserted emoji
            field.stringValue = ""
            field.window?.makeFirstResponder(nil)
        }
    }
}

/// Free-text model chooser for OpenRouter: the user pastes a `vendor/model`
/// slug (there are 300+ models, so no dropdown). The slug is validated against
/// the cached `/models` catalog, previously used slugs are offered as
/// suggestions on focus, and the current value is kept as the selected model.
private struct OpenRouterModelField: View {
    @ObservedObject var settings: AppSettings
    @State private var text: String = ""
    @State private var hoveringSuggestions = false
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Recent slugs, filtered by the current text (excluding an exact match).
    private var suggestions: [String] {
        let q = trimmed.lowercased()
        let history = settings.openRouterModelHistory
        guard !q.isEmpty else { return history }
        return history.filter { $0.lowercased().contains(q) && $0.lowercased() != q }
    }

    private var showSuggestions: Bool {
        (focused || hoveringSuggestions) && !suggestions.isEmpty
    }

    private var info: ModelInfo? { settings.openRouterModelInfo(for: trimmed) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent {
                HStack(spacing: 6) {
                    TextField(L("or.placeholder"), text: $text)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                        .autocorrectionDisabled(true)
                        .focused($focused)
                        .onSubmit { commit(trimmed) }
                    validationIndicator
                }
            } label: {
                Text(L("chat.model"))
            }

            // Capabilities of a recognized model, or a "not found" caption.
            if let info {
                capabilityChips(info)
            } else if !trimmed.isEmpty, settings.isOpenRouterCatalogLoaded {
                Text(L("or.notFound"))
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            HStack {
                if let url = settings.chatProvider.modelCatalogURL {
                    Link(destination: url) {
                        Text(L("or.browse")).font(.caption)
                    }
                    .help(url.absoluteString)
                }
                Spacer()
                if !APIKeyStore.hasKey(for: .openrouter) {
                    Text(L("chat.addKeyFirst"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if showSuggestions {
                suggestionsBox
            }
        }
        .onAppear {
            text = settings.selectedModel(for: .openrouter) ?? ""
            settings.autoLoadOpenRouterCatalogIfNeeded()
        }
        // Keep the selected model in sync as the user types (history is only
        // appended on an explicit commit — Enter or picking a suggestion).
        .onChange(of: text) { _, newValue in
            settings.setSelectedModel(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: .openrouter)
        }
    }

    @ViewBuilder
    private var validationIndicator: some View {
        if trimmed.isEmpty {
            EmptyView()
        } else if !settings.isOpenRouterCatalogLoaded {
            ProgressView().controlSize(.small)
        } else if info != nil {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .help(L("or.valid"))
        } else {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .help(L("or.notFound"))
        }
    }

    @ViewBuilder
    private func capabilityChips(_ info: ModelInfo) -> some View {
        HStack(spacing: 6) {
            if info.supportsVision { chip(L("cap.vision")) }
            if info.supportsTools { chip(L("cap.tools")) }
            if info.supportsReasoning { chip(L("cap.reasoning")) }
        }
    }

    private func chip(_ label: String) -> some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundColor(.secondary)
    }

    private var suggestionsBox: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("or.recent"))
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 2)
            ForEach(suggestions, id: \.self) { slug in
                Button {
                    commit(slug)
                } label: {
                    HStack {
                        Text(slug)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            Divider()
            Button {
                settings.clearOpenRouterModelHistory()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                    Text(L("or.clear"))
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        // Keep the list up while the pointer is over it, so clicking a row
        // isn't cut off by the field losing focus first.
        .onHover { hoveringSuggestions = $0 }
    }

    private func commit(_ slug: String) {
        let s = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        text = s
        settings.recordOpenRouterModel(s)
        focused = false
        hoveringSuggestions = false
    }
}
