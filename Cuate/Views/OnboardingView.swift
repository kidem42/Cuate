import SwiftUI

/// Feature tour: shown automatically on first launch and reopenable from
/// Settings → General. Five animated scenes, one per status-bar feature;
/// hotkey chips reflect the user's current bindings.
///
/// Each scene plays a single pass of its own beat and freezes on the frame
/// that shows the result (`OnbSceneID.hold`); the step rail doubles as a
/// progress bar and replays the scene when the current step is clicked.
/// With Reduce Motion on, a scene opens straight at its result frame.
struct OnboardingView: View {
    let onDone: () -> Void
    /// Freeze every scene on its result frame (used by the dev shot export).
    var staticPreview = false

    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pageIndex: Int
    /// Wall-clock start of the current pass; the phase is derived from it.
    @State private var runStart = Date()

    init(initialPage: Int = 0, staticPreview: Bool = false, onDone: @escaping () -> Void) {
        self.onDone = onDone
        self.staticPreview = staticPreview
        _pageIndex = State(initialValue: initialPage)
    }

    private var frozen: Bool { staticPreview || reduceMotion }

    private struct Page {
        let scene: OnbSceneID
        let stepKey: String
        let titleKey: String
        let bodyKey: String
        /// (combo display string, label localization key)
        let hotkeys: [(String, String)]
    }

    private var pages: [Page] {
        let s = settings
        return [
            Page(scene: .chat, stepKey: "ob.step.chat",
                 titleKey: "ob.tour.chat.title", bodyKey: "ob.tour.chat.body",
                 hotkeys: [(s.togglePanelHotkey.displayString, "hotkeys.openPanel")]),
            Page(scene: .shot, stepKey: "ob.step.shot",
                 titleKey: "ob.tour.shot.title", bodyKey: "ob.tour.shot.body",
                 hotkeys: [(s.areaScreenshotHotkey.displayString, "hotkeys.areaShot"),
                           (s.screenshotHotkey.displayString, "hotkeys.fullShot")]),
            Page(scene: .dictation, stepKey: "ob.step.dict",
                 titleKey: "ob.tour.dict.title", bodyKey: "ob.tour.dict.body",
                 hotkeys: [(s.dictationHotkey.displayString, "hotkeys.dictate"),
                           (s.dictationTranslateHotkey.displayString, "hotkeys.dictateTranslate")]),
            Page(scene: .worldTime, stepKey: "ob.step.world",
                 titleKey: "ob.tour.world.title", bodyKey: "ob.tour.world.body",
                 hotkeys: []),
            Page(scene: .image, stepKey: "ob.step.image",
                 titleKey: "ob.tour.image.title", bodyKey: "ob.tour.image.body",
                 hotkeys: [])
        ]
    }

    var body: some View {
        let pages = self.pages
        let index = min(pageIndex, pages.count - 1)
        let page = pages[index]

        VStack(spacing: 0) {
            TimelineView(.animation(paused: frozen)) { timeline in
                let elapsed = timeline.date.timeIntervalSince(runStart)
                // One pass, then freeze on the result frame.
                let phase = frozen
                    ? page.scene.hold
                    : min(elapsed / page.scene.cycle, page.scene.hold)
                scene(page.scene, t: phase, time: max(0, elapsed))
            }
            .frame(width: OnbStyle.stage.width, height: OnbStyle.stage.height)
            .clipped()

            captions(page)

            stepRail(pages: pages, index: index)

            Divider()

            HStack(spacing: 8) {
                Button(L("ob.skip")) { onDone() }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .opacity(index == pages.count - 1 ? 0 : 1)
                    .disabled(index == pages.count - 1)

                Spacer()

                if index > 0 {
                    Button(L("ob.back")) { go(to: index - 1) }
                }

                if index < pages.count - 1 {
                    Button(L("ob.next")) { go(to: index + 1) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(L("ob.done")) { onDone() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
        }
        .frame(width: OnbStyle.stage.width, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .id(settings.language)
    }

    // MARK: Pieces

    private func scene(_ id: OnbSceneID, t: Double, time: Double) -> some View {
        // The mock UI inside a scene is drawn in light chrome (white windows,
        // dark text) — pin the scheme so Dark Mode can't invert half of it.
        sceneBody(id, t: t, time: time).environment(\.colorScheme, .light)
    }

    @ViewBuilder
    private func sceneBody(_ id: OnbSceneID, t: Double, time: Double) -> some View {
        let s = settings
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

    private func captions(_ page: Page) -> some View {
        VStack(spacing: 9) {
            // Language choice up front — switching re-renders the tour (and
            // the whole app) instantly.
            if pageIndex == 0 {
                Picker("", selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
            }

            Text(L(page.titleKey))
                .font(.system(size: 17, weight: .semibold))
                .multilineTextAlignment(.center)

            Text(L(page.bodyKey))
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 420)

            if !page.hotkeys.isEmpty {
                VStack(spacing: 7) {
                    ForEach(Array(page.hotkeys.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 9) {
                            Text(item.0)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            Text(L(item.1))
                                .font(.system(size: 12.5))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.top, 2)
            }

        }
        .padding(.vertical, 20)
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Step rail: one bar per scene, the current one filling as it plays.
    private func stepRail(pages: [Page], index: Int) -> some View {
        TimelineView(.animation(paused: frozen)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(runStart)
            let progress = frozen ? 1 : min(elapsed / pages[index].scene.cycle, 1)
            HStack(spacing: 6) {
                ForEach(Array(pages.enumerated()), id: \.offset) { k, p in
                    Button {
                        // Clicking the current step replays it.
                        go(to: k)
                    } label: {
                        VStack(spacing: 5) {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.secondary.opacity(0.15))
                                    Capsule()
                                        .fill(k < index ? Color.secondary.opacity(0.4) : Color.accentColor)
                                        .frame(width: geo.size.width * (k < index ? 1 : (k == index ? progress : 0)))
                                }
                            }
                            .frame(height: 3)
                            Text(L(p.stepKey))
                                .font(.system(size: 10, weight: k == index ? .semibold : .regular))
                                .foregroundColor(k == index ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(L(k == index ? "ob.replay" : p.stepKey))
                }
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private func go(to index: Int) {
        pageIndex = index
        runStart = Date()
    }
}
