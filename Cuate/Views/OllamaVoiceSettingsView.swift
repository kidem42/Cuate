import SwiftUI

/// Kept outside SettingsView's large form; reads the same catalog as the console.
struct OllamaVoiceSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var refreshing = false
    @State private var failed = false

    var body: some View {
        let selected = settings.sttModel(for: .ollama)
        let models = settings.ollamaTranscriptionModels
        Picker(L("voice.sttModel"), selection: Binding(
            get: { settings.sttModel(for: .ollama) },
            set: { settings.setSTTModel($0, for: .ollama) }
        )) {
            if !models.contains(selected) {
                Text(selected.isEmpty ? L("voice.ollama.choose") : selected + " — " + L("voice.ollama.missing"))
                    .tag(selected)
            }
            ForEach(models, id: \.self) { Text($0).tag($0) }
        }
        .disabled(models.isEmpty)
        .help(L("voice.ollama.modelHelp"))

        HStack {
            Button(L("local.refresh")) { Task { await refresh() } }
                .disabled(refreshing || !settings.localModelsEnabled)
                .help(L("voice.ollama.refreshHelp"))
            if refreshing { ProgressView().controlSize(.small) }
            Spacer()
            Button(L("voice.ollama.configure")) {
                NotificationCenter.default.post(name: .selectSettingsTab,
                    object: (settings.localModelsEnabled ? SettingsTab.localModels : .general).rawValue)
            }
            .help(L("voice.ollama.configureHelp"))
        }
        if !settings.localModelsEnabled {
            Text(L("voice.ollama.enable")).font(.caption).foregroundColor(.orange)
        } else if failed {
            Text(L("voice.ollama.connectionError")).font(.caption).foregroundColor(.orange)
        } else if !refreshing && !settings.localTranscriptionAvailable {
            Text(L("voice.ollama.unavailable")).font(.caption).foregroundColor(.orange)
        }
        Text(L("voice.ollama.caption"))
            .font(.caption).foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .task { if settings.localModelsEnabled { await refresh() } }
    }

    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        failed = !(await settings.verifyLocalEndpoint())
        refreshing = false
    }
}
