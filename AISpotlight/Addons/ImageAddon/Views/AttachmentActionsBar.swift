import SwiftUI
import AppKit

/// Row of image actions shown under the pending-attachment preview in the
/// chat panel (host mount: one line in `ChatWindow`):
///
///   [Апскейл ▾] [Убрать фон] [Удалить объекты]   (+ OCR остаётся в превью)
///
/// Клик по «Апскейл» — дефолтный запуск (×2 где применимо); ▾ — факторы
/// ×2/×4/×макс (недоступные по потолку модели дизейблятся) и «Улучшить
/// лица» для моделей с поддержкой. «Удалить объекты» разворачивает инлайн
/// `MaskEditorView` (кисть/текст). Renders nothing when the addon is off or
/// the attachment isn't an image, so the host call site stays unconditional.
struct ImageAttachmentActionsBar: View {
    let attachment: ChatAttachment
    let chatStore: ChatStore
    let clearAttachment: () -> Void

    @ObservedObject private var settings = ImageAddonSettings.shared
    @ObservedObject private var runner = ImageTaskRunner.shared
    @State private var showingKeyHint = false
    @State private var showingCleanupEditor = false
    @State private var faceEnhance = false

    var body: some View {
        if settings.enabled, attachment.mimeType.hasPrefix("image") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    upscaleControl
                    functionButton(titleKey: "ia.action.removeBg",
                                   icon: "person.and.background.dotted",
                                   help: functionHelp("ia.help.removeBg", model: settings.backgroundModelInfo)) {
                        runIfKeyed {
                            guard let model = settings.backgroundModelInfo else { return }
                            start(function: .removeBackground, model: model)
                        }
                    }
                    functionButton(titleKey: "ia.action.cleanup",
                                   icon: "eraser",
                                   help: functionHelp("ia.help.cleanup", model: settings.cleanupModelInfo)) {
                        if APIKeyStore.hasKey(aux: .fal) {
                            showingCleanupEditor.toggle()
                        } else {
                            showingKeyHint = true
                        }
                    }
                    Spacer()
                }

                if showingCleanupEditor {
                    MaskEditorView(
                        attachment: attachment,
                        applyMask: { mask in
                            guard let model = settings.cleanupModelInfo else { return }
                            showingCleanupEditor = false
                            start(function: .objectCleanup, model: model, maskPNG: mask)
                        },
                        applyPrompt: { prompt in
                            guard let model = settings.cleanupTextModelInfo else { return }
                            showingCleanupEditor = false
                            start(function: .objectCleanup, model: model, prompt: prompt)
                        },
                        close: { showingCleanupEditor = false }
                    )
                }
            }
            .popover(isPresented: $showingKeyHint, arrowEdge: .bottom) {
                keyHintPopover
            }
        }
    }

    // MARK: - Upscale (click = default run, ▾ = factors + face enhance)

    @ViewBuilder
    private var upscaleControl: some View {
        let model = settings.upscaleModelInfo
        let factors = availableFactors(for: model)

        if let model, !factors.isEmpty {
            Menu {
                ForEach(factors, id: \.self) { factor in
                    Button("×\(factor)\(factor == model.maxUpscaleFactor ? " (\(IAL("ia.action.factorMax")))" : "")") {
                        runIfKeyed {
                            start(function: .upscale, model: model, factor: factor)
                        }
                    }
                }
                if model.supportsFaceEnhance {
                    Divider()
                    Toggle(IAL("ia.action.faceEnhance"), isOn: $faceEnhance)
                }
            } label: {
                Label(IAL("ia.action.upscale"), systemImage: "arrow.up.backward.and.arrow.down.forward.rectangle")
                    .font(.caption)
            } primaryAction: {
                runIfKeyed {
                    start(function: .upscale, model: model, factor: factors.first)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .disabled(runner.isRunning)
            .help(functionHelp("ia.help.upscale", model: model))
        } else {
            functionButton(titleKey: "ia.action.upscale",
                           icon: "arrow.up.backward.and.arrow.down.forward.rectangle",
                           help: functionHelp("ia.help.upscale", model: model)) {
                runIfKeyed {
                    guard let model else { return }
                    start(function: .upscale, model: model)
                }
            }
        }
    }

    /// Factors offered for the current attachment: model options minus the
    /// ones whose result would exceed the model's output ceiling (ТЗ §4.4a).
    private func availableFactors(for model: ImageModelInfo?) -> [Int] {
        guard let model else { return [] }
        var options = model.factorOptions
        if let data = attachment.data,
           let size = ImageInputPreparer.pixelSize(of: data),
           let ceilingMP = model.maxOutputMP {
            let inputMP = (size.width * size.height) / 1_000_000
            options = options.filter { inputMP * Double($0 * $0) <= ceilingMP }
            // Keep at least the smallest option so the button stays usable.
            if options.isEmpty, let smallest = model.factorOptions.first {
                options = [smallest]
            }
        }
        return options
    }

    // MARK: - Shared pieces

    private func functionButton(titleKey: String, icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(IAL(titleKey), systemImage: icon)
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(runner.isRunning)
        .help(help)
    }

    /// "Что делает · модель (цена) · слэш-альтернатива" per function.
    private func functionHelp(_ key: String, model: ImageModelInfo?) -> String {
        guard let model else { return "" }
        return String(format: IAL(key), model.name, model.priceLabel)
    }

    /// ТЗ §6: кнопки видны и без ключа; клик объясняет, куда идти.
    private func runIfKeyed(_ body: () -> Void) {
        guard APIKeyStore.hasKey(aux: .fal) else {
            showingKeyHint = true
            return
        }
        body()
    }

    private func start(
        function: ImageFunction,
        model: ImageModelInfo,
        factor: Int? = nil,
        maskPNG: Data? = nil,
        prompt: String? = nil
    ) {
        let source = attachment
        clearAttachment()
        ImageOperations.run(
            function: function,
            model: model,
            source: source,
            chatStore: chatStore,
            factor: factor,
            faceEnhance: faceEnhance && model.supportsFaceEnhance,
            maskPNG: maskPNG,
            prompt: prompt
        )
    }

    private var keyHintPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(IAL("ia.action.needKey"))
                .font(.callout)
            Button(IAL("ia.action.openSettings")) {
                showingKeyHint = false
                // The host opens the Settings window; the deferred post then
                // switches it to the addon's tab (same pattern as onboarding).
                NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    NotificationCenter.default.post(name: .selectSettingsTab, object: SettingsTab.imageAddon.rawValue)
                }
            }
        }
        .padding(12)
        .frame(width: 260)
    }
}

/// Result filenames: `<исходное>-upscaled.png` / `-nobg.png` / `-cleaned.png`.
enum ImageResultNaming {
    static func filename(source: String, suffix: String, mime: String) -> String {
        let base = (source as NSString).deletingPathExtension
        let ext: String
        switch mime.lowercased() {
        case "image/jpeg": ext = "jpg"
        case "image/webp": ext = "webp"
        default: ext = "png"
        }
        return "\(base)-\(suffix).\(ext)"
    }
}
