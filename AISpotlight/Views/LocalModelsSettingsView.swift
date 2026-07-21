import SwiftUI

// MARK: - Master toggles (rendered in the General section)

/// Master switch for local models — off by default (opt-in). Mirrors the addon
/// enable-toggle shape, but binds to `AppSettings` (local models are core).
struct LocalModelsEnableToggle: View {
    @ObservedObject private var settings = AppSettings.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(L("local.enable"), isOn: $settings.localModelsEnabled)
            Text(L("local.enable.caption"))
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Master switch for cloud providers — on by default. Off = fully local/offline.
struct OnlineModelsEnableToggle: View {
    @ObservedObject private var settings = AppSettings.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(L("local.online.enable"), isOn: $settings.onlineModelsEnabled)
            Text(L("local.online.enable.caption"))
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Local models console (Settings tab)

/// Connection + full Ollama management (list / pull / delete / start-stop).
/// The management sections show only when the endpoint is detected as Ollama;
/// other OpenAI-compatible servers get a read-only model list.
struct LocalModelsSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    enum ConnState: Equatable { case unknown, testing, ollama, generic, failed }

    @State private var connState: ConnState = .unknown
    @State private var installed: [OllamaAdminService.InstalledModel] = []
    @State private var pullName = ""
    @State private var pullStatus: String?
    @State private var pullFraction: Double = 0
    @State private var pullTask: Task<Void, Never>?
    @State private var busyModel: String?      // model currently loading/unloading/deleting
    @State private var pendingDelete: String?
    @State private var errorText: String?
    /// Guards the first-appear model fetch so it can't re-fire in a loop.
    @State private var didInitialLoad = false

    private var admin: OllamaAdminService {
        OllamaAdminService(endpointURL: settings.localEndpointURL)
    }

    var body: some View {
        Form {
            introSection
            connectionSection
            if settings.ollamaDetected {
                installedSection
                pullSection
            } else if settings.localEndpointVerified {
                genericSection
            }
            if let errorText {
                Section {
                    Text(errorText).font(.callout).foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            L("local.delete.confirm"),
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(L("local.delete"), role: .destructive) {
                if let name = pendingDelete { deleteModel(name) }
                pendingDelete = nil
            }
            Button(L("local.cancel"), role: .cancel) { pendingDelete = nil }
        }
        .onAppear {
            if settings.localEndpointVerified {
                connState = settings.ollamaDetected ? .ollama : .generic
                if settings.ollamaDetected && !didInitialLoad {
                    didInitialLoad = true
                    Task { await reloadInstalled() }
                }
            }
        }
    }

    // MARK: Intro

    private var introSection: some View {
        Section {
            Text(L("local.compat"))
                .font(.callout).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("local.installHint"))
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link(L("local.install"), destination: ProviderID.ollama.apiKeyURL)
        } header: {
            Text(L("local.header"))
        }
    }

    // MARK: Connection

    private var connectionSection: some View {
        Section {
            HStack {
                TextField(L("local.endpoint"), text: $settings.localEndpointURL)
                    .textFieldStyle(.roundedBorder)
                Button(L("local.reset")) {
                    settings.localEndpointURL = AppSettings.defaultLocalEndpointURL
                }
            }
            HStack {
                Button(connState == .testing ? L("local.testing") : L("local.test")) {
                    testConnection()
                }
                .disabled(connState == .testing)
                Spacer()
                connectionStatus
            }
        } header: {
            Text(L("local.connection"))
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch connState {
        case .unknown, .testing:
            EmptyView()
        case .ollama:
            Label(L("local.status.ok"), systemImage: "checkmark.circle.fill")
                .foregroundColor(.green).font(.callout)
        case .generic:
            Label(L("local.status.okGeneric"), systemImage: "checkmark.circle")
                .foregroundColor(.secondary).font(.callout)
        case .failed:
            Label(L("local.status.fail"), systemImage: "xmark.circle.fill")
                .foregroundColor(.red).font(.callout)
        }
    }

    // MARK: Installed models (Ollama only)

    private var installedSection: some View {
        Section {
            if installed.isEmpty {
                Text(L("local.noModels")).font(.callout).foregroundColor(.secondary)
            } else {
                ForEach(installed) { model in
                    modelRow(model)
                }
            }
            Button(L("local.refresh")) { Task { await reloadInstalled() } }
        } header: {
            Text(L("local.installed"))
        }
    }

    private func modelRow(_ model: OllamaAdminService.InstalledModel) -> some View {
        let loaded = settings.ollamaLoadedModels.contains(model.name)
        let info = settings.ollamaCatalog[model.name]
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name).font(.callout)
                HStack(spacing: 6) {
                    Text(byteString(model.sizeBytes))
                    if info?.supportsVision == true { capBadge(L("local.vision")) }
                    if info?.supportsTools == true { capBadge(L("local.tools")) }
                    if loaded {
                        Label(loadedLabel(model.name), systemImage: "memorychip")
                            .foregroundColor(.green)
                    }
                }
                .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if busyModel == model.name {
                ProgressView().controlSize(.small)
            } else {
                Button(loaded ? L("local.stop") : L("local.start")) {
                    toggleLoad(model.name, loaded: loaded)
                }
                .buttonStyle(.borderless)
                Button(L("local.delete"), role: .destructive) {
                    pendingDelete = model.name
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func capBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
    }

    // MARK: Pull (Ollama only)

    private var pullSection: some View {
        Section {
            HStack {
                TextField(L("local.pull.placeholder"), text: $pullName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(pullTask != nil)
                if pullTask == nil {
                    Button(L("local.download")) { startPull() }
                        .disabled(pullName.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    Button(L("local.cancel"), role: .cancel) { cancelPull() }
                }
            }
            if let pullStatus {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: pullFraction)
                    Text(pullStatus).font(.caption).foregroundColor(.secondary)
                }
            }
        } header: {
            Text(L("local.pull"))
        }
    }

    // MARK: Generic (non-Ollama) endpoint — read-only list

    private var genericSection: some View {
        Section {
            let models = settings.models(for: .ollama)
            if models.isEmpty {
                Text(L("local.noModels")).font(.callout).foregroundColor(.secondary)
            } else {
                ForEach(models, id: \.self) { Text($0).font(.callout) }
            }
            Text(L("local.manageExternally")).font(.caption).foregroundColor(.secondary)
        } header: {
            Text(L("local.installed"))
        }
    }

    // MARK: Actions

    private func testConnection() {
        connState = .testing
        errorText = nil
        Task {
            let ok = await settings.verifyLocalEndpoint()
            connState = !ok ? .failed : (settings.ollamaDetected ? .ollama : .generic)
            if settings.ollamaDetected { await reloadInstalled() }
        }
    }

    private func reloadInstalled() async {
        do {
            // Sort by name to match the status-bar submenu, which lists
            // `models(for: .ollama)` (already alphabetically sorted).
            installed = (try await admin.tags()).sorted { $0.name < $1.name }
            // Keep the app-wide model list (chat dropdown + status-bar submenu)
            // in sync — otherwise a deleted/pulled model lingers there, since
            // those read `models(for:)`/cachedModels, not this view's `installed`.
            try? await settings.refreshModels(for: .ollama)
            await settings.refreshOllamaLoaded(using: admin)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func toggleLoad(_ name: String, loaded: Bool) {
        busyModel = name
        errorText = nil
        Task {
            do {
                if loaded { try await admin.unload(model: name) }
                else { try await admin.load(model: name) }
                // Wait for /api/ps to actually reflect the change (it lags the
                // response), so the row's status can't stay stale after one click.
                await settings.refreshOllamaLoadedUntil(model: name, loaded: !loaded, using: admin)
            } catch {
                errorText = error.localizedDescription
                await settings.refreshOllamaLoaded(using: admin)
            }
            busyModel = nil
        }
    }

    private func deleteModel(_ name: String) {
        busyModel = name
        errorText = nil
        Task {
            do {
                try await admin.delete(model: name)
            } catch {
                errorText = error.localizedDescription
            }
            await reloadInstalled()
            busyModel = nil
        }
    }

    private func startPull() {
        let name = pullName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        errorText = nil
        pullStatus = ""
        pullFraction = 0
        pullTask = Task {
            do {
                for try await progress in admin.pull(model: name) {
                    pullStatus = progress.status
                    if progress.total > 0 { pullFraction = progress.fraction }
                }
                await reloadInstalled()
                await settings.verifyLocalEndpoint()
            } catch is CancellationError {
                // user cancelled — silent
            } catch {
                errorText = error.localizedDescription
            }
            pullStatus = nil
            pullTask = nil
        }
    }

    private func cancelPull() {
        pullTask?.cancel()
        pullTask = nil
        pullStatus = nil
    }

    /// "In memory" plus the model's live RAM footprint from /api/ps, when known.
    private func loadedLabel(_ name: String) -> String {
        if let vram = settings.ollamaLoadedVRAM[name], vram > 0 {
            return "\(L("local.loaded")) · \(byteString(vram))"
        }
        return L("local.loaded")
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
