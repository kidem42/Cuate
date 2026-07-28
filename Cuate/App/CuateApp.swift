import SwiftUI
import Combine
import AppKit
import Carbon

/// Entry point exists only to get the rename carry-over in before ANY app code
/// touches the defaults. `AppSettings.shared` writes its properties back as it
/// initializes, and it is built while the delegate is constructed — earlier
/// than `applicationDidFinishLaunching`. Run the carry-over from there and the
/// new domain already holds this build's defaults, so every setting that has a
/// default (system prompt, active preset, webhook) is skipped and silently
/// resets. `App.main()` is called explicitly instead of putting `@main` on the
/// App itself, which is the only hook that runs before its stored properties.
@main
enum AppLauncher {
    static func main() {
        LegacyRenameMigration.runIfNeeded()
        CuateApp.main()
    }
}

struct CuateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var chatWindow: NSWindow?
    /// Agent sidebar — a child window docked left of the chat panel (see
    /// `setAgentSidebarVisible`); nil until the first show.
    private var agentSidebarWindow: FloatingPanelWindow?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var worldTimeWindow: NSWindow? // WorldTimeAddon (Addons/WorldTimeAddon)
    private var hotkeyManager: HotkeyManager?
    private var statusItem: NSStatusItem?
    /// Keeps the pending-approval → status-item subscription alive.
    private var agentApprovalObserver: AnyCancellable?
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

        // Read the Keychain ONCE, off the main thread, before anything asks for
        // a key: every read is a securityd IPC that BLOCKS its thread, and after
        // an update (each build is re-signed) it blocks on an authorization
        // dialog — which is what froze launch and every message send. Off-main
        // the dialog is answered with the app fully responsive, and the store
        // rewrites the item afterwards so it is never asked again.
        // Then warm the model list so the saved selection isn't shown as "reset".
        Task { @MainActor in
            await APIKeyStore.warmIfNeeded()
            AppSettings.shared.resolveKeyDependentDefaults()
            AppSettings.shared.autoLoadModelsIfNeeded(for: AppSettings.shared.chatProvider)
        }

        // Setup chat window
        setupChatWindow()

        // Setup hotkey manager
        setupHotkeys()

        // LayoutFix addon — self-contained; all code lives in Addons/LayoutFix.
        LayoutFixAddon.shared.start()

        // ImageAddon — self-contained; all code lives in Addons/ImageAddon.
        ImageAddon.shared.start()

        // Agent notifications (AgentGateway addons): categories must register
        // before the first banner or its buttons don't render. Permission is
        // NOT requested here — that happens when an agent addon is enabled.
        NotificationService.shared.activate()

        // HermesAddon: refresh the gateway state (role list, connection dot)
        // once the key cache is warm — silent, best-effort. The background
        // poll then watches bound sessions for activity we didn't start
        // (§7.1 — Hermes has no push channel, so we ask).
        Task { @MainActor in
            await APIKeyStore.warmIfNeeded()
            if HermesAddon.shared.isAvailable {
                await HermesAddon.shared.probe()
            }
            // The addon being ON is the user's standing opt-in — ask for
            // notification permission here too, not only on the toggle flip
            // (an already-enabled addon never showed the dialog and every
            // banner died on the authorized-guard; e2e 2026-07-25).
            if HermesSettings.shared.enabled {
                NotificationService.shared.requestPermissionIfNeeded()
            }
            HermesAddon.shared.startBackgroundPolling()
        }
        // warmIfNeeded returns EARLY when another warm is already in flight
        // (the key task above), and the sidebar's own probe can fire BEFORE
        // the keys are warm — a keyless 401 then parked the state on
        // "disconnected" and nothing retried until the settings tab
        // (e2e 2026-07-25, twice). The real "keys are ready" signal is this
        // notification: re-probe on it whenever we are not connected yet.
        NotificationCenter.default.addObserver(forName: .apiKeysDidChange, object: nil, queue: .main) { _ in
            Task { @MainActor in
                if HermesAddon.shared.isAvailable,
                   HermesAddon.shared.connectionState != .connected {
                    await HermesAddon.shared.probe()
                }
            }
        }

        // Banner click → summon the panel on the role's conversation.
        NotificationCenter.default.addObserver(forName: .agentNotificationOpened, object: nil, queue: .main) { [weak self] note in
            let roleID = note.userInfo?["roleID"] as? String
            Task { @MainActor in
                if let roleID {
                    AppSettings.shared.activeAgentRoleID = roleID
                }
                self?.showChatWindow()
            }
        }

        // Pending-approval fallback indicator in the menu bar (rebuilds the
        // status item when the count crosses zero).
        agentApprovalObserver = NotificationService.shared.$pendingApprovalCount
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.setupStatusItem() }
            }

        // Agent sidebar ⇆ window frame: the CHAT column's size is sacred
        // (e2e 2026-07-25) — when the column appears, the window grows LEFT
        // by exactly its width (right edge fixed, the chat doesn't move or
        // resize); when it hides, the same delta comes back off.
        NotificationCenter.default.addObserver(forName: .agentSidebarVisibilityChanged, object: nil, queue: .main) { [weak self] note in
            let visible = note.userInfo?["visible"] as? Bool ?? false
            Task { @MainActor in self?.setAgentSidebarVisible(visible) }
        }

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
            window.title = "Cuate"
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
            // Pending agent approval + notifications denied → the menu-bar
            // icon is the fallback indicator (badge symbol; §7.1 degradation
            // rule: approvals must not get lost to a TCC refusal).
            let pendingApproval = NotificationService.shared.pendingApprovalCount > 0
                && NotificationService.shared.authorized != true
            let symbolName = pendingApproval ? "exclamationmark.bubble" : "brain.head.profile"
            if let symbolImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "AI Assistant") {
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
            window.title = "Cuate Settings"
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
    private static let settingsFrameName = "CuateSettingsWindow.v2"

    // MARK: - World Time (Addons/WorldTimeAddon)

    private static let worldTimeFrameName = "CuateWorldTimePanel"

    /// The menu item / hotkey toggles the panel — but "visible" alone is not
    /// enough to mean "hide": a pinned panel stays visible BEHIND other apps,
    /// and summoning must then raise it, not order it out. Hide only when the
    /// user is actually in it (key); otherwise (re-)summon to the front.
    @objc private func openWorldTime(_ sender: Any?) {
        if let window = worldTimeWindow, window.isVisible, window.isKeyWindow {
            window.orderOut(nil)
        } else {
            showWorldTimePanel()
        }
    }

    /// Summons the timezone grid as a Spotlight-like floating panel: glass,
    /// borderless, above other windows, on the screen under the cursor
    /// (pattern: the chat panel). Esc or its close button hides it, and so
    /// does focus moving elsewhere — same as the chat panel. The pin in its
    /// top bar (`WorldTimeSettings.pinned`) opts out, for using it as a
    /// reference board while writing in another app.
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
            window.role = .worldTime
            window.contentView = container
            // Never set before, which is why `windowWillClose` below could not
            // see this panel either — closing it left the Dock icon behind.
            window.delegate = self
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
        // Same raising dance as the chat panel (`activatePanel`): cooperative
        // activation can be silently denied for an accessory app summoned by
        // a global hotkey, and without an actual activation
        // makeKeyAndOrderFront only orders the window front WITHIN this app —
        // it stays behind other apps' (and fullscreen) windows.
        window.orderFrontRegardless()
        NSRunningApplication.current.activate()
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
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

    private static let panelFrameName = "CuateChatPanel"

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
        // NO system shadow: on a TRANSPARENT window WindowServer re-derives
        // the shadow from content alpha when the content changes — while
        // scrolling that is every frame over the whole panel area, and the
        // compositor drops to half refresh (profiled 2026-07-28: WindowServer
        // 70–92%, scroll pinned at ~30fps on every theme). Native chat apps
        // sidestep this class of cost with opaque windows; our panel's edge
        // definition comes from the themed border/glass instead of a shadow.
        // (`defaults write com.getcuate.Cuate CuateDebugPanelShadow -bool
        // YES` brings the old shadow back for comparison.)
        window.hasShadow = UserDefaults.standard.bool(forKey: "CuateDebugPanelShadow")
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

        window.role = .chat
        window.contentView = container
        window.delegate = self

        // Restore the saved frame (size + position, multi-monitor aware).
        // `force: true` is required for borderless windows to restore the size.
        window.setFrameAutosaveName(Self.panelFrameName)
        if !window.setFrameUsingName(Self.panelFrameName, force: true) {
            window.center() // first launch
        }
        // Migrate frames saved by the in-window sidebar era: the column's
        // width used to be baked INTO the panel frame — shave it back off
        // once (the sidebar is its own child window now, the chat panel
        // keeps its pure width).
        if UserDefaults.standard.bool(forKey: Self.sidebarDeltaKey) {
            var frame = window.frame
            frame.origin.x += AgentSidebarLayout.width
            frame.size.width = max(480, frame.size.width - AgentSidebarLayout.width)
            window.setFrame(frame, display: false)
            UserDefaults.standard.set(false, forKey: Self.sidebarDeltaKey)
        }
        window.orderOut(nil)
        self.chatWindow = window
    }

    // MARK: - Agent sidebar: child window

    /// Legacy flag from the in-window sidebar era (only read once at launch
    /// to migrate the autosaved frame back to the pure chat width).
    private static let sidebarDeltaKey = "agentSidebarWidthApplied"

    /// Gap between the sidebar panel and the chat panel — the column reads
    /// as its own docked panel, which it is.
    private static let sidebarGap: CGFloat = 8

    /// Whether the sidebar should be on screen right now (role active and
    /// not collapsed for that role) — the summon path re-asserts this.
    private var agentSidebarShouldShow: Bool {
        guard let role = AppSettings.shared.activeAgentRole else { return false }
        return !HermesSettings.shared.isSidebarCollapsed(roleID: role.id)
    }

    /// Shows/hides the agent column as a CHILD window docked to the panel's
    /// left edge. The old approach resized the chat window itself (grow
    /// left, then SwiftUI squeezed the transcript, then the frame animation
    /// raced it back) — every toggle re-laid the whole chat out and the
    /// slide-out looked like the window was glitching. A child window slides
    /// out on its own: the chat panel's frame and layout are never touched,
    /// and dragging the panel carries the column along for free.
    @MainActor
    private func setAgentSidebarVisible(_ visible: Bool) {
        guard let parent = chatWindow else { return }
        if visible {
            // Panel off screen: nothing to dock to — the summon re-asserts.
            guard parent.isVisible, let role = AppSettings.shared.activeAgentRole else { return }
            let sidebar = agentSidebarWindow ?? makeAgentSidebarWindow(role: role)
            agentSidebarWindow = sidebar
            // Fresh root every show: the ROLE may have changed since last.
            (sidebar.contentView as? NSHostingView<AgentSidebarPanelRoot>)?
                .rootView = AgentSidebarPanelRoot(role: role)
            // No room at the screen's left edge → the parent shifts right
            // (it may move, it never resizes).
            let wanted = agentSidebarFrame(for: parent)
            if let bounds = (parent.screen ?? NSScreen.main)?.visibleFrame,
               wanted.minX < bounds.minX {
                var parentFrame = parent.frame
                parentFrame.origin.x += bounds.minX - wanted.minX
                isProgrammaticMove = true
                parent.setFrame(parentFrame, display: true, animate: true)
                isProgrammaticMove = false
            }
            let final = agentSidebarFrame(for: parent)
            if sidebar.isVisible, parent.childWindows?.contains(sidebar) == true {
                // Already out (summon re-assert / role switch): just re-glue.
                sidebar.setFrame(final, display: true)
                sidebar.alphaValue = 1
                return
            }
            var start = final
            start.origin.x += 44 // slides out from under the panel's edge
            sidebar.alphaValue = 0
            sidebar.setFrame(start, display: false)
            parent.addChildWindow(sidebar, ordered: .below)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                sidebar.animator().alphaValue = 1
                sidebar.animator().setFrame(final, display: true)
            }
        } else if let sidebar = agentSidebarWindow {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                sidebar.animator().alphaValue = 0
            }, completionHandler: {
                parent.removeChildWindow(sidebar)
                sidebar.orderOut(nil)
            })
        }
    }

    /// The column's frame: docked to the panel's left edge, full height.
    private func agentSidebarFrame(for parent: NSWindow) -> NSRect {
        NSRect(x: parent.frame.minX - AgentSidebarLayout.width - Self.sidebarGap,
               y: parent.frame.minY,
               width: AgentSidebarLayout.width,
               height: parent.frame.height)
    }

    private func makeAgentSidebarWindow(role: AgentRole) -> FloatingPanelWindow {
        let window = FloatingPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: AgentSidebarLayout.width, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false // same policy as the chat panel (perf)
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = false
        window.role = .agentSidebar
        window.delegate = self
        let host = NSHostingView(rootView: AgentSidebarPanelRoot(role: role))
        host.sizingOptions = []
        window.contentView = host
        return window
    }

    /// Keeps the docked column glued to the panel during a live resize
    /// (moves are free — child windows follow their parent).
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === chatWindow,
              let sidebar = agentSidebarWindow, sidebar.isVisible else { return }
        sidebar.setFrame(agentSidebarFrame(for: window), display: true)
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
        // The docked agent column re-appears with the panel (it is a child
        // window — hiding the panel took it down too).
        setAgentSidebarVisible(agentSidebarShouldShow)

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
        hideWorldTimePanel()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Auto-hide the two floating panels, never the settings window.
        guard let window = notification.object as? NSWindow else { return }
        if window === chatWindow { hideChatWindow() }
        // Focus leaving the docked agent column counts as leaving the panel
        // (the same auto-hide the chat window itself has).
        if window === agentSidebarWindow { hideChatWindow() }
        if window === worldTimeWindow { hideWorldTimePanel() }
    }

    private func hideChatWindow() {
        // The pin (panel header) opts out of auto-hide entirely — same
        // escape hatch the World Time panel has.
        guard !AppSettings.shared.panelPinned else { return }
        guard let window = chatWindow, window.isVisible else { return }
        // Deferred ONE tick: at resign time the next key window has not
        // settled yet, so "did key stay within the panel family?" cannot be
        // answered here. (Checking NSApp.currentEvent instead was a bug: it
        // returns the last event OUR app processed, so a click into another
        // app still pointed at the panel — auto-hide died and the panel
        // lingered as an inactive zombie; e2e 2026-07-28.)
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.chatWindow, window.isVisible else { return }
            guard !AppSettings.shared.panelPinned else { return }
            // Key stayed in the family: the panel itself, its docked agent
            // column, or Settings — the user never left.
            if window.isKeyWindow { return }
            if let sidebar = self.agentSidebarWindow, sidebar.isVisible, sidebar.isKeyWindow { return }
            if let settingsWindow = self.settingsWindow, settingsWindow.isKeyWindow { return }
            // A system dialog (Open/Save) presented as the panel's sheet
            // takes key status — not "the user left the panel".
            if window.attachedSheet != nil { return }
            Diagnostics.log("ui", "panel.hide")
            window.orderOut(nil)
        }
    }

    /// Same dismissal rules as the chat panel, with one extra escape hatch:
    /// the pin. The Settings and attached-sheet guards matter more here than
    /// on the chat panel — this panel's own gear opens Settings, and its city
    /// search and slot composer put windows on screen, all of which take key
    /// status without the user having actually left the panel.
    private func hideWorldTimePanel() {
        guard !WorldTimeSettings.shared.pinned else { return }
        guard let window = worldTimeWindow, window.isVisible else { return }
        if let settingsWindow, settingsWindow.isKeyWindow { return }
        if window.attachedSheet != nil { return }
        Diagnostics.log("ui", "worldTime.hide")
        window.orderOut(nil)
    }
}
