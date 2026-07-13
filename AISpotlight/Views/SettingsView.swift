import SwiftUI

/// App settings: provider API keys (Keychain), chat provider/model,
/// model parameters, web search, speech-to-text, and system prompt presets.
enum SettingsTab: String, Hashable {
    case chat, keys, voice, general, prompts
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

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
    @State private var isLoadingModels = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var sttModelInput = ""
    @State private var newPresetName = ""
    @State private var selectedTab = SettingsTab.chat

    var body: some View {
        TabView(selection: $selectedTab) {
            tab { chatSection; parametersSection; ocrSection }
                .tabItem { Label(L("tab.chat"), systemImage: "bubble.left.and.bubble.right") }
                .tag(SettingsTab.chat)

            tab { keysSection; webSection }
                .tabItem { Label(L("tab.keys"), systemImage: "key") }
                .tag(SettingsTab.keys)

            tab { voiceSection; dictationSection }
                .tabItem { Label(L("tab.voice"), systemImage: "mic") }
                .tag(SettingsTab.voice)

            tab { generalSection; hotkeysSection; panelSection; appearanceSection }
                .tabItem { Label(L("tab.general"), systemImage: "gearshape") }
                .tag(SettingsTab.general)

            tab { promptSection }
                .tabItem { Label(L("tab.prompts"), systemImage: "text.quote") }
                .tag(SettingsTab.prompts)
        }
        .id(settings.language) // re-render the whole tree on language change
        .onReceive(NotificationCenter.default.publisher(for: .selectSettingsTab)) { note in
            if let raw = note.object as? String, let t = SettingsTab(rawValue: raw) {
                selectedTab = t
            }
        }
        // Breathing room between the window's title bar and the tab strip —
        // without it the tabs sit flush against (and get clipped by) the edge.
        .padding(.top, 10)
        .frame(width: 560, height: 650)
        .onAppear {
            refreshMasks()
            sttModelInput = settings.sttModel(for: settings.sttProvider)
            settings.autoLoadModelsIfNeeded(for: settings.chatProvider)
            validateAllKeys()
        }
        .onChange(of: settings.chatProvider) { _, provider in
            // Load the newly selected provider's models if not cached yet.
            settings.autoLoadModelsIfNeeded(for: provider)
        }
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
                    Text(provider.displayName).tag(provider)
                }
            }

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
            if ModelCapabilities.supportsReasoningControl(provider: settings.chatProvider, model: model) {
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
        HStack {
            Text(provider.displayName)
                .frame(width: 150, alignment: .leading)

            if let masked = maskedKeys[provider] ?? nil {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(masked)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundColor(.secondary)
                        keyTestIndicator(for: provider.rawValue)
                    }
                    // Inline reason when a key is invalid.
                    if case .failed(let reason) = keyTests[provider.rawValue] {
                        Text(reason)
                            .font(.caption2)
                            .foregroundColor(.red)
                            .lineLimit(2)
                    }
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
                _ = try await ProviderRegistry.provider(for: provider).fetchModels(apiKey: key)
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
            validateKey(for: provider) // check the freshly saved key
        } else {
            statusMessage = "Failed to save the key for \(provider.displayName)."
            statusIsError = true
        }
    }

    private func refreshMasks() {
        for provider in ProviderID.allCases {
            maskedKeys[provider] = APIKeyStore.maskedKey(for: provider)
        }
        braveMasked = APIKeyStore.maskedKey(aux: .brave)
    }

    // MARK: - Web access

    private var webSection: some View {
        Section {
            Toggle(L("web.allow"), isOn: $settings.webSearchEnabled)

            HStack {
                Text(L("web.brave"))
                    .frame(width: 150, alignment: .leading)
                if let masked = braveMasked {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(masked)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundColor(.secondary)
                            keyTestIndicator(for: "brave")
                        }
                        if case .failed(let reason) = keyTests["brave"] {
                            Text(reason)
                                .font(.caption2)
                                .foregroundColor(.red)
                                .lineLimit(2)
                        }
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
                    Text(provider.displayName).tag(provider)
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
        } header: {
            Text(L("voice.header"))
        } footer: {
            Text(L("voice.footer"))
                .font(.caption)
                .foregroundColor(.secondary)
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
            LabeledContent(L("ocr.provider"), value: "Mistral OCR")

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

    private var appearanceSection: some View {
        Section(L("appearance.header")) {
            Picker(L("appearance.language"), selection: $settings.language) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
            Picker(L("appearance.theme"), selection: $settings.appearanceMode) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Button(L("ob.showTour")) {
                NotificationCenter.default.post(name: .showOnboarding, object: nil)
            }
        }
    }

    // MARK: - Panel placement

    private var generalSection: some View {
        Section {
            Toggle(L("general.launchAtLogin"), isOn: $settings.launchAtLogin)
        }
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
                .frame(minHeight: 70)

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

    private var isActivePresetBuiltIn: Bool {
        AppSettings.builtInPresets.contains { $0.name == settings.activePresetName }
    }

    private var promptIsModified: Bool {
        settings.systemPrompt != settings.presetText(named: settings.activePresetName)
    }
}
