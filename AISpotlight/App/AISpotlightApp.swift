import SwiftUI
import Combine
import AppKit
import Carbon

@main
struct AISpotlightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var chatWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var worldTimeWindow: NSWindow? // WorldTimeAddon (Addons/WorldTimeAddon)
    private var hotkeyManager: HotkeyManager?
    private var statusItem: NSStatusItem?
    /// Status-bar submenu listing local models with per-model load/unload
    /// toggles — repopulated live in `menuNeedsUpdate` so its status stays fresh.
    private weak var localModelsSubmenu: NSMenu?
    private let appState = AppState()
    private enum HotkeyIdentifier: UInt32 {
        case togglePanel = 1
        case captureScreenshot = 2
        case captureArea = 3
        case dictate = 4
        case dictateTranslate = 5
        case worldTime = 6 // WorldTimeAddon panel toggle
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
#if DEBUG
        // Dev-only: --onboarding-shots <dir> renders the tour and exits.
        OnboardingShotExport.runIfRequested()
#endif

        // Opt-in logging + hang watchdog — first, so launch events are captured.
        Diagnostics.startIfEnabled()
        Diagnostics.log("app", "launch")

        // Hide dock icon - app will run in background
        NSApp.setActivationPolicy(.accessory)

        // Apply the saved appearance override (Auto/Light/Dark)
        AppSettings.shared.applyAppearance()

        // Seasonal auto-themes (Halloween, Día de Muertos) — checks today's
        // date and watches for day rollovers / manual overrides.
        HolidayThemeManager.shared.start()

        // Drop TCC entries stuck on an older build's signature (one shot per
        // version) so macOS can re-ask instead of silently failing.
        PermissionHealer.healIfNeeded()

        // Warm up the active provider's model list so the saved selection is
        // available immediately (otherwise it looks "reset" until Load Models).
        AppSettings.shared.autoLoadModelsIfNeeded(for: AppSettings.shared.chatProvider)

        // Setup chat window
        setupChatWindow()

        // Setup hotkey manager
        setupHotkeys()

        // LayoutFix addon — self-contained; all code lives in Addons/LayoutFix.
        LayoutFixAddon.shared.start()

        // ImageAddon — self-contained; all code lives in Addons/ImageAddon.
        ImageAddon.shared.start()

        // Re-register global shortcuts when the user rebinds them in Settings
        NotificationCenter.default.addObserver(forName: .hotkeysDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.setupHotkeys()
                self?.setupStatusItem() // refresh shortcut hints in the menu
            }
        }

        // Rebuild the status-bar menu when the interface language changes
        NotificationCenter.default.addObserver(forName: .appLanguageDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setupStatusItem() }
        }

        // Refresh the menu when the LayoutFix addon toggles (enable / auto).
        NotificationCenter.default.addObserver(forName: .layoutFixHotkeysDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setupStatusItem() }
        }

        // WorldTimeAddon: its menu item and global hotkey appear/disappear
        // with the master switch; the settings tab's "Open" button routes
        // through here too.
        NotificationCenter.default.addObserver(forName: .worldTimeAddonDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.setupHotkeys()
                self?.setupStatusItem()
            }
        }
        NotificationCenter.default.addObserver(forName: .openWorldTimeWindow, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.showWorldTimePanel() }
        }
        NotificationCenter.default.addObserver(forName: .closeWorldTimeWindow, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.worldTimeWindow?.orderOut(nil) }
        }
        // Auto-fit the panel's height to its rows (grow on add, shrink on
        // remove), clamped to the screen. Width stays the user's.
        NotificationCenter.default.addObserver(forName: .worldTimeContentHeight, object: nil, queue: .main) { [weak self] note in
            let height = (note.userInfo?["height"] as? CGFloat) ?? 0
            Task { @MainActor in self?.fitWorldTimePanel(contentHeight: height) }
        }

        // Rebuild the menu when local models toggle on/off or Ollama is (un)detected,
        // so the local model start/stop control appears/disappears promptly.
        NotificationCenter.default.addObserver(forName: .localModelsMenuDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setupStatusItem() }
        }

        // Opening the Settings window must work from anywhere (e.g. the
        // ImageAddon "no key" hint in the panel). The sender follows up with
        // a .selectSettingsTab post for the tab itself.
        NotificationCenter.default.addObserver(forName: .openSettingsWindow, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.openSettings(nil) }
        }

        // "Reset Panel Position" in Settings: recenter immediately
        NotificationCenter.default.addObserver(forName: .panelPositionDidReset, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let window = self.chatWindow else { return }
                self.isProgrammaticMove = true
                defer { self.isProgrammaticMove = false }
                let screen = (AppSettings.shared.panelFollowsMouse ? self.screenUnderMouse() : window.screen)
                    ?? NSScreen.main ?? NSScreen.screens[0]
                self.spotlightCenter(window, on: screen)
                window.saveFrame(usingName: Self.panelFrameName)
            }
        }

        // Setup status bar (menu bar) icon
        setupStatusItem()

        // First-run feature tour
        if !UserDefaults.standard.bool(forKey: "didOnboard") {
            showOnboarding()
        }

        // Reopen the tour from Settings
        NotificationCenter.default.addObserver(forName: .showOnboarding, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.showOnboarding() }
        }
    }

    @MainActor
    private func showOnboarding() {
        NSApp.activate(ignoringOtherApps: true)
        if onboardingWindow == nil {
            let hosting = NSHostingController(rootView: OnboardingView { [weak self] in
                let firstTime = !UserDefaults.standard.bool(forKey: "didOnboard")
                UserDefaults.standard.set(true, forKey: "didOnboard")
                self?.onboardingWindow?.orderOut(nil)
                self?.onboardingWindow = nil
                // After the first run, drop the user straight into API Keys.
                // Deferred so the window closes first, then Settings comes up front.
                if firstTime {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self?.openSettings(nil)
                        NotificationCenter.default.post(name: .selectSettingsTab, object: SettingsTab.keys.rawValue)
                    }
                }
            })
            let window = NSWindow(contentViewController: hosting)
            window.title = "AISpotlight"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.center()
            window.level = .floating
            onboardingWindow = window
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    private func setupStatusItem() {
        if let existingItem = statusItem {
            NSStatusBar.system.removeStatusItem(existingItem)
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            if let symbolImage = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: "AI Assistant") {
                button.image = symbolImage
                button.image?.isTemplate = true
                button.title = ""
            } else {
                button.image = nil
                button.title = "AI"
                button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            }
        }

        // Build menu with actions
        let menu = NSMenu()

        let settings = AppSettings.shared
        let openItem = NSMenuItem(
            title: "\(L("menu.open")) (\(settings.togglePanelHotkey.displayString))",
            action: #selector(toggleChatWindowFromStatusItem(_:)),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        let screenshotItem = NSMenuItem(
            title: "\(L("menu.fullShot")) (\(settings.screenshotHotkey.displayString))",
            action: #selector(captureScreenshotFromStatusItem(_:)),
            keyEquivalent: ""
        )
        screenshotItem.target = self
        menu.addItem(screenshotItem)

        let areaItem = NSMenuItem(
            title: "\(L("menu.areaShot")) (\(settings.areaScreenshotHotkey.displayString))",
            action: #selector(captureAreaFromStatusItem(_:)),
            keyEquivalent: ""
        )
        areaItem.target = self
        menu.addItem(areaItem)

        // WorldTimeAddon — timezone comparison grid (shown when enabled).
        if WorldTimeSettings.shared.enabled {
            menu.addItem(NSMenuItem.separator())
            let worldTimeItem = NSMenuItem(
                title: "\(WTL("wt.menu.open")) (\(WorldTimeSettings.shared.hotkey.displayString))",
                action: #selector(openWorldTime(_:)),
                keyEquivalent: ""
            )
            worldTimeItem.target = self
            menu.addItem(worldTimeItem)
        }

        // Dictation shortcuts (shown when the feature is enabled)
        if settings.dictationEnabled {
            menu.addItem(NSMenuItem.separator())

            let dictateItem = NSMenuItem(
                title: "\(L("menu.dictate")) (\(settings.dictationHotkey.displayString))",
                action: #selector(startDictation(_:)),
                keyEquivalent: ""
            )
            dictateItem.target = self
            menu.addItem(dictateItem)

            let dictateTranslateItem = NSMenuItem(
                title: "\(L("menu.dictateTranslate")) (\(settings.dictationTranslateHotkey.displayString))",
                action: #selector(startDictationTranslate(_:)),
                keyEquivalent: ""
            )
            dictateTranslateItem.target = self
            menu.addItem(dictateTranslateItem)

            menu.addItem(NSMenuItem.separator())
        }

        // LayoutFix addon — AutoSwitcher controls (shown when enabled).
        if LayoutFixSettings.shared.enabled {
            menu.addItem(NSMenuItem.separator())

            let autoItem = NSMenuItem(
                title: LFL("lf.menu.auto"),
                action: #selector(toggleLayoutAuto(_:)),
                keyEquivalent: ""
            )
            autoItem.target = self
            autoItem.state = LayoutFixSettings.shared.autoEnabled ? .on : .off
            menu.addItem(autoItem)

            let layoutSettingsItem = NSMenuItem(
                title: LFL("lf.menu.openSettings"),
                action: #selector(openLayoutSettings(_:)),
                keyEquivalent: ""
            )
            layoutSettingsItem.target = self
            menu.addItem(layoutSettingsItem)

            menu.addItem(NSMenuItem.separator())
        }

        // Local models — nested submenu: each installed model with a load/unload
        // toggle (checkmark = in memory) and its footprint (Ollama only).
        localModelsSubmenu = nil
        if settings.localModelsEnabled, settings.ollamaDetected,
           !settings.models(for: .ollama).isEmpty {
            menu.addItem(NSMenuItem.separator())

            let parent = NSMenuItem(title: L("tab.localModels"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.delegate = self
            rebuildLocalModelsSubmenu(submenu)
            parent.submenu = submenu
            localModelsSubmenu = submenu
            menu.addItem(parent)

            menu.addItem(NSMenuItem.separator())
        }

        let settingsItem = NSMenuItem(title: L("menu.settings"), action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Panel placement toggle
        let followMouseItem = NSMenuItem(
            title: L("menu.followMouse"),
            action: #selector(togglePanelFollowsMouse(_:)),
            keyEquivalent: ""
        )
        followMouseItem.target = self
        followMouseItem.state = settings.panelFollowsMouse ? .on : .off
        menu.addItem(followMouseItem)

        // Appearance submenu (Auto / Light / Dark)
        let appearanceItem = NSMenuItem(title: L("menu.appearance"), action: nil, keyEquivalent: "")
        let appearanceMenu = NSMenu()
        for mode in AppearanceMode.allCases {
            let item = NSMenuItem(title: mode.displayName, action: #selector(selectAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = AppSettings.shared.appearanceMode == mode ? .on : .off
            appearanceMenu.addItem(item)
        }
        appearanceItem.submenu = appearanceMenu
        menu.addItem(appearanceItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: L("menu.quit"), action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        item.menu = menu

        self.statusItem = item
    }

    /// (Re)fills the local-models submenu: one item per installed model, a
    /// checkmark when it's in memory, and its footprint. Safe to call on an open
    /// submenu (that's what `menuNeedsUpdate` is for).
    private func rebuildLocalModelsSubmenu(_ submenu: NSMenu) {
        let settings = AppSettings.shared
        submenu.removeAllItems()
        for model in settings.models(for: .ollama) {
            let loaded = settings.ollamaLoadedModels.contains(model)
            var title = model
            if loaded, let vram = settings.ollamaLoadedVRAM[model], vram > 0 {
                title += "  ·  " + ByteCountFormatter.string(fromByteCount: vram, countStyle: .file)
            }
            let item = NSMenuItem(title: title,
                                  action: #selector(toggleLocalModelItem(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.state = loaded ? .on : .off   // checkmark = loaded/running
            item.representedObject = model
            submenu.addItem(item)
        }
        if submenu.items.isEmpty {
            let empty = NSMenuItem(title: L("local.noModels"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
    }

    /// Before the local-models submenu shows, fill it from cache instantly, then
    /// refresh the loaded state and refill so the checkmarks/memory are live.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === localModelsSubmenu else { return }
        rebuildLocalModelsSubmenu(menu)
        let settings = AppSettings.shared
        let admin = OllamaAdminService(endpointURL: settings.localEndpointURL)
        Task { @MainActor in
            await settings.refreshOllamaLoaded(using: admin)
            rebuildLocalModelsSubmenu(menu)
        }
    }

    /// Toggle a local model's load/unload from the submenu. Reads the LIVE
    /// loaded state (not the item's checkmark, which can lag), so the action is
    /// never inverted.
    @objc private func toggleLocalModelItem(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? String else { return }
        let wasLoaded = AppSettings.shared.ollamaLoadedModels.contains(model)
        Task { @MainActor in
            let admin = OllamaAdminService(endpointURL: AppSettings.shared.localEndpointURL)
            if wasLoaded { try? await admin.unload(model: model) }
            else { try? await admin.load(model: model) }
            // Wait for /api/ps to actually reflect the change (it lags the response).
            await AppSettings.shared.refreshOllamaLoadedUntil(model: model, loaded: !wasLoaded, using: admin)
        }
    }

    private func setupHotkeys() {
        let settings = AppSettings.shared

        let toggleHotkey = HotkeyManager.Hotkey(
            identifier: HotkeyIdentifier.togglePanel.rawValue,
            keyCode: settings.togglePanelHotkey.keyCode,
            modifiers: settings.togglePanelHotkey.modifiers
        ) { [weak self] in
            self?.toggleChatWindow()
        }

        let screenshotHotkey = HotkeyManager.Hotkey(
            identifier: HotkeyIdentifier.captureScreenshot.rawValue,
            keyCode: settings.screenshotHotkey.keyCode,
            modifiers: settings.screenshotHotkey.modifiers
        ) { [weak self] in
            self?.captureScreenshotAndShowPanel()
        }

        let areaHotkey = HotkeyManager.Hotkey(
            identifier: HotkeyIdentifier.captureArea.rawValue,
            keyCode: settings.areaScreenshotHotkey.keyCode,
            modifiers: settings.areaScreenshotHotkey.modifiers
        ) { [weak self] in
            self?.captureAreaAndShowPanel()
        }

        var hotkeys = [toggleHotkey, screenshotHotkey, areaHotkey]

        // WorldTimeAddon panel — registered only while the addon is on.
        if WorldTimeSettings.shared.enabled {
            hotkeys.append(HotkeyManager.Hotkey(
                identifier: HotkeyIdentifier.worldTime.rawValue,
                keyCode: WorldTimeSettings.shared.hotkey.keyCode,
                modifiers: WorldTimeSettings.shared.hotkey.modifiers
            ) { [weak self] in
                self?.openWorldTime(nil)
            })
        }

        // System-wide dictation (Superwhisper-style) — optional feature
        if settings.dictationEnabled {
            hotkeys.append(HotkeyManager.Hotkey(
                identifier: HotkeyIdentifier.dictate.rawValue,
                keyCode: settings.dictationHotkey.keyCode,
                modifiers: settings.dictationHotkey.modifiers
            ) {
                Task { @MainActor in DictationService.shared.toggle(mode: .transcribe) }
            })
            hotkeys.append(HotkeyManager.Hotkey(
                identifier: HotkeyIdentifier.dictateTranslate.rawValue,
                keyCode: settings.dictationTranslateHotkey.keyCode,
                modifiers: settings.dictationTranslateHotkey.modifiers
            ) {
                Task { @MainActor in DictationService.shared.toggle(mode: .translate) }
            })
        }

        // Replacing the manager unregisters the previous shortcuts (deinit).
        hotkeyManager = nil
        hotkeyManager = HotkeyManager(hotkeys: hotkeys)
    }

    @objc private func togglePanelFollowsMouse(_ sender: NSMenuItem) {
        AppSettings.shared.panelFollowsMouse.toggle()
        setupStatusItem() // refresh checkmark
    }

    // LayoutFix addon — menu-bar controls.
    @objc private func toggleLayoutAuto(_ sender: NSMenuItem) {
        // didSet posts .layoutFixHotkeysDidChange → the addon starts/stops the
        // monitor and the menu refreshes (checkmark) via the observer above.
        LayoutFixSettings.shared.autoEnabled.toggle()
    }

    @objc private func openLayoutSettings(_ sender: Any?) {
        openSettings(sender)
        NotificationCenter.default.post(name: .selectSettingsTab, object: SettingsTab.layoutFix.rawValue)
    }

    @objc private func selectAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = AppearanceMode(rawValue: raw) else { return }
        AppSettings.shared.appearanceMode = mode
        setupStatusItem() // refresh checkmarks
    }

    // MARK: - Settings

    @objc private func openSettings(_ sender: Any?) {
        // Show a Dock icon + app-switcher entry while Settings is open, so the
        // window can be raised again in one click (Dock or ⌘-Tab) even after
        // switching to another app. Reverted to menu-bar-only on close.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "AISpotlight Settings"
            // Sidebar layout (NavigationSplitView): resizable window, titlebar
            // blended into the content so the sidebar runs edge-to-edge — the
            // System Settings look. The split view supplies the toolbar.
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            // No visible title: the section name already shows in the sidebar
            // and the form headers — a third copy in the toolbar is noise.
            // `window.title` stays set for the Dock / ⌘-Tab switcher.
            window.titleVisibility = .hidden
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.allowsToolTipsWhenApplicationIsInactive = true
            window.delegate = self
            // Remember size/position across opens and launches.
            if !window.setFrameUsingName(Self.settingsFrameName) {
                window.setContentSize(NSSize(width: 760, height: 650))
                window.center()
            }
            window.setFrameAutosaveName(Self.settingsFrameName)
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // "v2": the sidebar redesign needs a wider default — don't inherit the
    // old 560-wide TabView frame saved under the previous name.
    private static let settingsFrameName = "AISpotlightSettingsWindow.v2"

    // MARK: - World Time (Addons/WorldTimeAddon)

    private static let worldTimeFrameName = "AISpotlightWorldTimePanel"

    /// The menu item toggles the panel: visible → hide, hidden → summon.
    @objc private func openWorldTime(_ sender: Any?) {
        if let window = worldTimeWindow, window.isVisible {
            window.orderOut(nil)
        } else {
            showWorldTimePanel()
        }
    }

    /// Summons the timezone grid as a Spotlight-like floating panel: glass,
    /// borderless, above other windows, on the screen under the cursor
    /// (pattern: the chat panel). Esc or its close button hides it; unlike
    /// the chat panel it stays up on focus loss — it's a reference board you
    /// glance at while writing elsewhere.
    private func showWorldTimePanel() {
        if worldTimeWindow == nil {
            let hostingView = NSHostingView(rootView: WorldTimeView())
            hostingView.sizingOptions = []
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor

            let container = NSView()
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.clear.cgColor
            container.layer?.cornerRadius = 18
            container.layer?.masksToBounds = true
            container.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: container.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])

            let window = FloatingPanelWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1120, height: 340),
                styleMask: [.borderless, .resizable],
                backing: .buffered,
                defer: false
            )
            window.minSize = NSSize(width: 1000, height: 260)
            window.preservesContentDuringLiveResize = true
            window.isOpaque = false
            window.backgroundColor = .clear
            // NOT movable-by-background: AppKit would drag the window along
            // with the row-reorder DragGesture (the gesture looks like
            // "background" to it) and the rows jitter. Dragging goes through
            // explicit DragHandle regions in the view instead.
            window.isMovableByWindowBackground = false
            window.level = .floating
            window.hasShadow = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.hidesOnDeactivate = false
            window.allowsToolTipsWhenApplicationIsInactive = true
            window.contentView = container
            window.setFrameAutosaveName(Self.worldTimeFrameName)
            worldTimeWindow = window

            // Esc closes the panel (borderless windows get no close button).
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53, // Esc
                   let panel = self?.worldTimeWindow, panel.isKeyWindow {
                    panel.orderOut(nil)
                    return nil
                }
                return event
            }
        }

        guard let window = worldTimeWindow else { return }
        // First show (no saved frame): Spotlight-centered on the screen
        // under the cursor. Afterwards: wherever the user left it.
        if !window.setFrameUsingName(Self.worldTimeFrameName, force: true) {
            let screen = screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens[0]
            spotlightCenter(window, on: screen)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Chrome around the panel's measured content block: top padding (4) +
    /// drag strip (16) + two VStack spacings (10+10) + bottom padding (14).
    private static let worldTimeChromeHeight: CGFloat = 54

    /// Resizes the panel so the grid fits exactly: the top edge stays put,
    /// the bottom follows the content; clamped into the screen's visible
    /// area. Skipped mid-user-resize so we never fight the drag.
    private func fitWorldTimePanel(contentHeight: CGFloat) {
        guard contentHeight > 0,
              let window = worldTimeWindow, !window.inLiveResize else { return }
        let desired = contentHeight + Self.worldTimeChromeHeight
        var frame = window.frame
        let delta = desired - frame.height
        guard abs(delta) > 2 else { return }
        frame.origin.y -= delta // keep the TOP edge anchored
        frame.size.height = desired
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            if frame.height > visible.height {
                frame.size.height = visible.height
            }
            if frame.minY < visible.minY {
                frame.origin.y = visible.minY
            }
            if frame.maxY > visible.maxY {
                frame.origin.y = visible.maxY - frame.height
            }
        }
        window.setFrame(frame, display: true, animate: true)
    }

    /// Clicking the Dock icon while Settings is open brings it back to front.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow?.makeKeyAndOrderFront(nil)
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === settingsWindow || window === worldTimeWindow else { return }
        // Once every regular window is gone, drop back to a menu-bar-only
        // agent (no Dock icon). Deferred so the window has actually closed
        // before we re-check visibility.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let stillOpen = (self.settingsWindow?.isVisible ?? false)
                || (self.onboardingWindow?.isVisible ?? false)
                || (self.worldTimeWindow?.isVisible ?? false)
            if !stillOpen {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func toggleChatWindowFromStatusItem(_ sender: Any?) {
        toggleChatWindow()
    }

    @objc private func captureScreenshotFromStatusItem(_ sender: Any?) {
        captureScreenshotAndShowPanel()
    }

    @objc private func captureAreaFromStatusItem(_ sender: Any?) {
        captureAreaAndShowPanel()
    }

    @objc private func startDictation(_ sender: Any?) {
        DictationService.shared.toggle(mode: .transcribe)
    }

    @objc private func startDictationTranslate(_ sender: Any?) {
        DictationService.shared.toggle(mode: .translate)
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private static let panelFrameName = "AISpotlightChatPanel"

    private func setupChatWindow() {
        let contentView = ChatWindow()
            .environmentObject(appState)

        // Create a transparent window with a full-size content view (Spotlight-like).
        // `.resizable` on a borderless window enables invisible resize edges.
        let window = FloatingPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 420),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 480, height: 320)
        window.maxSize = NSSize(width: 1000, height: 850)
        window.preservesContentDuringLiveResize = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = false
        window.level = .floating
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        // Accessory apps activated cooperatively (macOS 14+) may stay
        // formally "inactive" even while the panel is key — and AppKit
        // suppresses ALL tooltips for inactive apps by default. This flag is
        // why .help() tooltips never appeared anywhere in the panel.
        window.allowsToolTipsWhenApplicationIsInactive = true

        // Embed SwiftUI content directly and let SwiftUI render Liquid Glass.
        // Empty sizingOptions: the window dictates the size, SwiftUI adapts —
        // otherwise the hosting view's constraints fight user resizing.
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        // Assign as window content and pin to edges
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.layer?.cornerRadius = 18
        container.layer?.masksToBounds = true
        container.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        window.contentView = container
        window.delegate = self

        // Restore the saved frame (size + position, multi-monitor aware).
        // `force: true` is required for borderless windows to restore the size.
        window.setFrameAutosaveName(Self.panelFrameName)
        if !window.setFrameUsingName(Self.panelFrameName, force: true) {
            window.center() // first launch
        }
        window.orderOut(nil)
        self.chatWindow = window
    }

    // MARK: - Panel placement

    private var isProgrammaticMove = false

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }

    /// Places the panel before showing it:
    /// - "Follow cursor" ON: on the screen under the mouse — Spotlight-centered,
    ///   or at the user's remembered relative position on that screen.
    /// - OFF: wherever the user left it (autosaved); Spotlight-centered until
    ///   the user ever drags it.
    private func positionPanelForShow(_ window: NSWindow) {
        let settings = AppSettings.shared
        isProgrammaticMove = true
        defer { isProgrammaticMove = false }

        if settings.panelFollowsMouse {
            guard let screen = screenUnderMouse() ?? NSScreen.main else { return }
            if settings.panelHasCustomPosition, let rel = settings.panelRelativeCenter {
                place(window, relativeCenter: rel, on: screen)
            } else {
                spotlightCenter(window, on: screen)
            }
        } else if !settings.panelHasCustomPosition {
            spotlightCenter(window, on: window.screen ?? NSScreen.main ?? NSScreen.screens[0])
        }
        // OFF + custom position: leave the autosaved frame untouched.
    }

    /// Spotlight-style placement: horizontally centered, slightly above the
    /// vertical center of the screen.
    private func spotlightCenter(_ window: NSWindow, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let size = window.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.minY + visible.height * 0.62 - size.height / 2
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Re-applies the remembered relative position on the given screen,
    /// clamped into its visible area.
    private func place(_ window: NSWindow, relativeCenter rel: CGPoint, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let size = window.frame.size
        var x = visible.minX + visible.width * rel.x - size.width / 2
        var y = visible.minY + visible.height * rel.y - size.height / 2
        x = min(max(x, visible.minX), visible.maxX - size.width)
        y = min(max(y, visible.minY), visible.maxY - size.height)
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // Safety net: `performDrag`-based moves of a borderless window don't
    // always trigger the frame autosave, so persist explicitly. A user drag
    // (not our own positioning) also records the custom relative position.
    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === chatWindow else { return }
        window.saveFrame(usingName: Self.panelFrameName)

        guard !isProgrammaticMove, window.isVisible, let screen = window.screen else { return }
        let visible = screen.visibleFrame
        let frame = window.frame
        AppSettings.shared.panelHasCustomPosition = true
        AppSettings.shared.panelRelativeCenter = CGPoint(
            x: (frame.midX - visible.minX) / visible.width,
            y: (frame.midY - visible.minY) / visible.height
        )
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === chatWindow else { return }
        window.saveFrame(usingName: Self.panelFrameName)
    }

    private func toggleChatWindow() {
        guard let window = chatWindow else { return }

        if window.isVisible {
            window.orderOut(nil)
        } else {
            showChatWindow(grabSelection: AppSettings.shared.prefillFromSelection)
        }
    }

    /// Summons the panel. When `grabSelection` is set, the selection capture
    /// (AX read + ⌘C fallback) must run while the *other* app is still
    /// frontmost — so we put the window on screen WITHOUT activating first
    /// (instant, never blocked on the grab), capture, then take key focus.
    /// The composer picks up `pendingInputText` reactively, so the quote can
    /// land a beat after the window without holding up its appearance.
    private func showChatWindow(grabSelection: Bool = false) {
        guard let window = chatWindow else { return }

        Diagnostics.log("ui", "panel.show active=\(NSApp.isActive) grab=\(grabSelection)")
        positionPanelForShow(window)

        guard grabSelection else {
            activatePanel(window)
            return
        }

        // Visible immediately, but NOT key: the frontmost app keeps focus so
        // the AX read / synthesized ⌘C target it, never our own panel.
        window.orderFrontRegardless()
        Task { @MainActor in
            if let text = await SelectionGrabber.grab() {
                appState.pendingInputText = text
            }
            activatePanel(window)
        }
    }

    /// Takes key focus for the already-positioned panel and tells the composer
    /// to focus its input.
    private func activatePanel(_ window: NSWindow) {
        // Cooperative activation (macOS 14+) can be silently DENIED for an
        // accessory app summoned by a global hotkey — the panel still gets
        // key status and accepts typing, but the app stays formally inactive
        // and AppKit/SwiftUI suppress every tooltip. Force the legacy path
        // when cooperation didn't (or won't) succeed.
        NSRunningApplication.current.activate()
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)

        // Notify ChatWindow to focus the input field. Deferred one runloop
        // tick so first-responder is requested after the window is key.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .chatWindowDidBecomeVisible, object: nil)
            Diagnostics.log("ui", "panel.shown active=\(NSApp.isActive) key=\(window.isKeyWindow)")
        }
    }

    private func captureScreenshotAndShowPanel() {
        guard #available(macOS 14.0, *) else {
            showAlert(title: "Not Supported", message: "Screenshots via ScreenCaptureKit require macOS 14 or newer.")
            return
        }

        Task { @MainActor in
            do {
                Diagnostics.log("ui", "screenshot.full")
                let screenshotData = try await ScreenshotCapturer.captureActiveDisplay()
                appState.setScreenshot(data: screenshotData)
                showChatWindow()
            } catch {
                showAlert(title: "Screenshot Failed", message: error.localizedDescription)
            }
        }
    }

    /// Area-selection screenshot: hides the panel, shows the native crosshair
    /// selection UI, then attaches the captured area and opens the panel.
    private func captureAreaAndShowPanel() {
        guard #available(macOS 14.0, *) else {
            showAlert(title: "Not Supported", message: "Screenshots require macOS 14 or newer.")
            return
        }

        Task { @MainActor in
            hideChatWindow() // don't capture our own panel
            do {
                Diagnostics.log("ui", "screenshot.area")
                guard let data = try await ScreenshotCapturer.captureInteractiveArea() else {
                    return // user pressed Esc
                }
                appState.setScreenshot(data: data)
                showChatWindow()
            } catch {
                showAlert(title: "Screenshot Failed", message: error.localizedDescription)
            }
        }
    }

    // Hide window when app or window loses focus
    func applicationDidResignActive(_ notification: Notification) {
        hideChatWindow()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Only auto-hide the chat panel, never the settings window
        guard let window = notification.object as? NSWindow, window === chatWindow else { return }
        hideChatWindow()
    }

    private func hideChatWindow() {
        guard let window = chatWindow, window.isVisible else { return }
        // Keep the panel visible while the user works in Settings
        if let settingsWindow, settingsWindow.isKeyWindow { return }
        // A system dialog (Open/Save) presented as the panel's sheet takes
        // key status — that must not count as "the user left the panel".
        if window.attachedSheet != nil { return }
        Diagnostics.log("ui", "panel.hide")
        window.orderOut(nil)
    }
}
