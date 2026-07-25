#if DEBUG
import SwiftUI
import AppKit

/// Dev-only: renders every onboarding scene at a few phases straight to PNGs,
/// so the animation can be reviewed frame by frame without screen recording.
///
///     Cuate --onboarding-shots /tmp/shots [--onboarding-lang en]
///
/// Writes `<scene>-<phase>.png` and exits.
enum OnboardingShotExport {
    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--onboarding-shots"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Touch settings first: its init pushes the stored language into
        // `Localization`, which would otherwise clobber the override below.
        _ = AppSettings.shared
        if let j = args.firstIndex(of: "--onboarding-lang"), j + 1 < args.count,
           let lang = AppLanguage(rawValue: args[j + 1]) {
            Localization.currentLanguage = lang
        }

        let phases: [Double] = [0.15, 0.30, 0.45, 0.60, 0.75, 0.90]
        for id in OnbSceneID.allCases {
            for p in phases {
                let t = min(p, id.hold)
                let view = sceneView(id, t: t, time: t * id.cycle)
                    .environment(\.colorScheme, .light)
                    .frame(width: OnbStyle.stage.width, height: OnbStyle.stage.height)
                let renderer = ImageRenderer(content: AnyView(view))
                renderer.scale = 2
                guard let img = renderer.nsImage,
                      let tiff = img.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { continue }
                let name = String(format: "%@-%02d.png", label(id), Int(p * 100))
                try? png.write(to: dir.appendingPathComponent(name))
            }
        }

        // The whole window, at the frame each scene freezes on.
        for (k, id) in OnbSceneID.allCases.enumerated() {
            let view = OnboardingView(initialPage: k, staticPreview: true, onDone: {})
            let renderer = ImageRenderer(content: AnyView(view))
            renderer.scale = 2
            if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("window-\(label(id)).png"))
            }
        }
        exit(0)
    }

    private static func label(_ id: OnbSceneID) -> String {
        switch id {
        case .chat: return "1-chat"
        case .shot: return "2-shot"
        case .dictation: return "3-dictation"
        case .worldTime: return "4-worldtime"
        case .image: return "5-image"
        }
    }

    @ViewBuilder
    private static func sceneView(_ id: OnbSceneID, t: Double, time: Double) -> some View {
        let s = AppSettings.shared
        switch id {
        case .chat:
            OnbSceneChat(t: t, time: time, hotkey: s.togglePanelHotkey.displayString)
        case .shot:
            OnbSceneShot(t: t, time: time, hotkey: s.areaScreenshotHotkey.displayString)
        case .dictation:
            OnbSceneDictation(t: t, time: time, hotkey: s.dictationTranslateHotkey.displayString)
        case .worldTime:
            OnbSceneWorldTime(
                t: t, time: time,
                menuHotkeys: (panel: s.togglePanelHotkey.displayString,
                              shot: s.screenshotHotkey.displayString,
                              area: s.areaScreenshotHotkey.displayString,
                              dictate: s.dictationHotkey.displayString,
                              translate: s.dictationTranslateHotkey.displayString))
        case .image:
            OnbSceneImage(t: t, time: time)
        }
    }
}
#endif
