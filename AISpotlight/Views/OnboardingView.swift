import SwiftUI

/// Feature tour: shown automatically on first launch and reopenable from
/// Settings → General. Hotkey chips reflect the user's current bindings.
struct OnboardingView: View {
    let onDone: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @State private var pageIndex = 0

    private struct Page {
        let scene: OnboardingScene
        let titleKey: String
        let bodyKey: String
        /// (combo display string, label localization key)
        let hotkeys: [(String, String)]
        /// Optional highlighted note (e.g. minimum required keys).
        var noteKey: String? = nil
    }

    private var pages: [Page] {
        let s = settings
        return [
            Page(
                scene: .panel,
                titleKey: "ob.p1.title", bodyKey: "ob.p1.body",
                hotkeys: [(s.togglePanelHotkey.displayString, "hotkeys.openPanel")]
            ),
            Page(
                scene: .keys,
                titleKey: "ob.p2.title", bodyKey: "ob.p2.body",
                hotkeys: [],
                noteKey: "ob.p2.note"
            ),
            Page(
                scene: .selection,
                titleKey: "ob.selection.title", bodyKey: "ob.selection.body",
                hotkeys: [(s.togglePanelHotkey.displayString, "hotkeys.openPanel")]
            ),
            Page(
                scene: .screenshot,
                titleKey: "ob.p3.title", bodyKey: "ob.p3.body",
                hotkeys: [
                    (s.screenshotHotkey.displayString, "hotkeys.fullShot"),
                    (s.areaScreenshotHotkey.displayString, "hotkeys.areaShot")
                ]
            ),
            Page(
                scene: .voice,
                titleKey: "ob.p4.title", bodyKey: "ob.p4.body",
                hotkeys: []
            ),
            Page(
                scene: .dictation,
                titleKey: "ob.p5.title", bodyKey: "ob.p5.body",
                hotkeys: [
                    (s.dictationHotkey.displayString, "hotkeys.dictate"),
                    (s.dictationTranslateHotkey.displayString, "hotkeys.dictateTranslate")
                ]
            ),
            Page(
                scene: .layoutfix,
                titleKey: "ob.layoutfix.title", bodyKey: "ob.layoutfix.body",
                hotkeys: [
                    (LayoutFixSettings.shared.flipHotkey.displayString, "ob.layoutfix.flip"),
                    (LayoutFixSettings.shared.smartHotkey.displayString, "ob.layoutfix.smart")
                ]
            ),
            Page(
                scene: .tips,
                titleKey: "ob.p6.title", bodyKey: "ob.p6.body",
                hotkeys: []
            )
        ]
    }

    var body: some View {
        let pages = self.pages
        let page = pages[min(pageIndex, pages.count - 1)]

        VStack(spacing: 0) {
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
                .padding(.top, 16)
            }

            Spacer(minLength: 16)

            OnboardingIllustration(scene: page.scene)

            Text(L(page.titleKey))
                .font(.title2.bold())
                .padding(.top, 14)

            Text(L(page.bodyKey))
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 420)
                .padding(.top, 8)
                .padding(.horizontal, 24)

            if !page.hotkeys.isEmpty {
                VStack(spacing: 8) {
                    ForEach(Array(page.hotkeys.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 10) {
                            Text(item.0)
                                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 11)
                                .padding(.vertical, 5)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                            Text(L(item.1))
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.top, 16)
            }

            Spacer(minLength: 16)

            // Page dots
            HStack(spacing: 7) {
                ForEach(0..<pages.count, id: \.self) { index in
                    Circle()
                        .fill(index == pageIndex ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.bottom, 14)

            Divider()

            HStack {
                Button(L("ob.skip")) { onDone() }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .opacity(pageIndex == pages.count - 1 ? 0 : 1)

                Spacer()

                if pageIndex > 0 {
                    Button(L("ob.back")) {
                        withAnimation { pageIndex -= 1 }
                    }
                }

                if pageIndex < pages.count - 1 {
                    Button(L("ob.next")) {
                        withAnimation { pageIndex += 1 }
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(L("ob.done")) { onDone() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
        }
        .frame(width: 540, height: 540)
        .id(settings.language)
    }
}
