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
    @Environment(\.themePalette) private var palette
    @Environment(\.colorScheme) private var scheme
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
                                   role: .removeBg,
                                   help: functionHelp("ia.help.removeBg", model: settings.backgroundModelInfo)) {
                        runIfKeyed(settings.backgroundModelInfo) {
                            guard let model = settings.backgroundModelInfo else { return }
                            start(function: .removeBackground, model: model)
                        }
                    }
                    functionButton(titleKey: "ia.action.cleanup",
                                   icon: "eraser",
                                   role: .cleanup,
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
            .tint(palette.isGlass ? nil : palette.accent)
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
                        runIfKeyed(model) {
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
                runIfKeyed(model) {
                    start(function: .upscale, model: model, factor: factors.first)
                }
            }
            .menuStyle(.button)
            .actionPillStyle(pillColors(.upscale), glass: palette.isGlass)
            .fixedSize()
            .disabled(runner.isRunning)
            .help(functionHelp("ia.help.upscale", model: model))
        } else {
            functionButton(titleKey: "ia.action.upscale",
                           icon: "arrow.up.backward.and.arrow.down.forward.rectangle",
                           role: .upscale,
                           help: functionHelp("ia.help.upscale", model: model)) {
                runIfKeyed(model) {
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

    private func functionButton(titleKey: String, icon: String, role: PillRole, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(IAL(titleKey), systemImage: icon)
                .font(.caption)
        }
        .actionPillStyle(pillColors(role), glass: palette.isGlass)
        .disabled(runner.isRunning)
        .help(help)
    }

    // MARK: - Themed action pills (Día: per-function marigold/teal/magenta
    // dotted pills; other themes: a single-accent dotted pill; glass keeps the
    // native bordered button). Colors are 1:1 with the design spec (§3b).

    enum PillRole { case upscale, removeBg, cleanup }

    private func pillColors(_ role: PillRole) -> ThemedPillColors {
        let dark = scheme == .dark
        if palette.themeID == .diaDeMuertos {
            switch role {
            case .upscale:
                return dark
                    ? ThemedPillColors(border: iac(255, 179, 0, 0.55), fill: iac(255, 179, 0, 0.08), fg: Color(rgb: 0xFFCE7A))
                    : ThemedPillColors(border: iac(200, 110, 0, 0.55), fill: Color.white.opacity(0.5), fg: Color(rgb: 0x9A5C00))
            case .removeBg:
                return dark
                    ? ThemedPillColors(border: iac(38, 166, 154, 0.6), fill: iac(38, 166, 154, 0.08), fg: Color(rgb: 0x7FD8CF))
                    : ThemedPillColors(border: iac(0, 137, 123, 0.55), fill: Color.white.opacity(0.5), fg: Color(rgb: 0x00695C))
            case .cleanup:
                return dark
                    ? ThemedPillColors(border: iac(236, 64, 122, 0.6), fill: iac(236, 64, 122, 0.08), fg: Color(rgb: 0xFF9DBF))
                    : ThemedPillColors(border: iac(216, 27, 96, 0.5), fill: Color.white.opacity(0.5), fg: Color(rgb: 0xAD1457))
            }
        }
        if palette.themeID == .halloween {
            // Halloween pills: solid 1px pumpkin border, same for all roles
            // (spec §3a — no per-function colors).
            return dark
                ? ThemedPillColors(border: iac(255, 140, 60, 0.4), fill: iac(255, 140, 60, 0.08),
                                   fg: Color(rgb: 0xFFB27A), dash: [], lineWidth: 1)
                : ThemedPillColors(border: iac(200, 100, 30, 0.45), fill: Color.white.opacity(0.5),
                                   fg: Color(rgb: 0x9C4A08), dash: [], lineWidth: 1)
        }
        // Generic non-glass fallback: one dotted pill in the theme's accent.
        let base = palette.accent
        return ThemedPillColors(border: base.opacity(0.55),
                                fill: dark ? base.opacity(0.08) : Color.white.opacity(0.5),
                                fg: palette.ink)
    }

    /// "Что делает · модель (цена) · слэш-альтернатива" per function.
    private func functionHelp(_ key: String, model: ImageModelInfo?) -> String {
        guard let model else { return "" }
        return String(format: IAL(key), model.name, model.priceLabel)
    }

    /// ТЗ §6: кнопки видны и без ключа; клик объясняет, куда идти. On-device
    /// providers (Apple) need no key, so the check is skipped when the target
    /// model runs locally — background removal works with no key configured.
    private func runIfKeyed(_ model: ImageModelInfo?, _ body: () -> Void) {
        if let model, !model.provider.requiresKey {
            body()
            return
        }
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

// MARK: - Themed pill styling

/// rgba (0–255 channels) — a local twin of the design helper (AppTheme's is
/// private to that file).
private func iac(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Color {
    Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
}

/// The three colors that define an action pill (dotted border, translucent
/// fill, text/icon foreground) — see the design's ImageAddon actionsbar.
/// `dash` is the border pattern: Día's dotted default, `[]` = solid 1px
/// (Halloween, spec §3a).
struct ThemedPillColors {
    let border: Color
    let fill: Color
    let fg: Color
    var dash: [CGFloat] = [1.5, 2.5]
    var lineWidth: CGFloat = 1.5
}

/// Día-style action pill: rounded rect (r6), 1.5px dotted border and a
/// translucent fill, text + SF Symbol in the pill's foreground color. Matches
/// the design's `[Апскейл ▾] [Убрать фон] [Удалить объекты]` row.
struct ThemedPillButtonStyle: ButtonStyle {
    let colors: ThemedPillColors
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11))
            .foregroundColor(colors.fg)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(colors.fill))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(colors.border, style: StrokeStyle(lineWidth: colors.lineWidth, dash: colors.dash))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(configuration.isPressed ? 0.6 : (isEnabled ? 1 : 0.45))
    }
}

private extension View {
    /// Applies the themed dotted pill (non-glass) or keeps the native small
    /// bordered button (glass / Current).
    @ViewBuilder
    func actionPillStyle(_ colors: ThemedPillColors, glass: Bool) -> some View {
        if glass {
            self.buttonStyle(.bordered).controlSize(.small)
        } else {
            self.buttonStyle(ThemedPillButtonStyle(colors: colors))
        }
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
