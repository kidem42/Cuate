import Foundation
import Combine
import Carbon

extension Notification.Name {
    /// Posted when the addon's enable flag changes (the host refreshes the
    /// status-bar menu that gates on it). Kept separate from app-wide
    /// notifications.
    static let worldTimeAddonDidChange = Notification.Name("worldTimeAddonDidChange")
    /// Posted by the "Open World Time" button in the settings tab — the
    /// AppDelegate owns the panel, the settings view cannot reach it.
    static let openWorldTimeWindow = Notification.Name("openWorldTimeWindow")
    /// Posted by the panel's own close button (the AppDelegate hides it).
    static let closeWorldTimeWindow = Notification.Name("closeWorldTimeWindow")
    /// Posted by the panel view whenever its ideal content height changes
    /// (rows added/removed, busy lane appears) — userInfo["height"]: CGFloat.
    /// The AppDelegate resizes the window to fit.
    static let worldTimeContentHeight = Notification.Name("worldTimeContentHeight")
}

/// Hour-label style for the grid (the am/pm | 24 toggle).
enum WorldTimeFormat: String, CaseIterable, Identifiable {
    case system // follow the macOS locale setting
    case h12
    case h24

    var id: String { rawValue }
}

/// Persisted settings for the WorldTimeAddon. Own `UserDefaults` keys (prefix
/// `worldTime.`), nothing stored in the app's `AppSettings` — the addon stays
/// fully self-contained (pattern: `ImageAddonSettings`).
@MainActor
final class WorldTimeSettings: ObservableObject {
    static let shared = WorldTimeSettings()

    private let defaults = UserDefaults.standard

    // MARK: - Master switch

    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "worldTime.enabled")
            NotificationCenter.default.post(name: .worldTimeAddonDidChange, object: nil)
        }
    }

    // MARK: - Global hotkey (registered by the host only while enabled)

    /// ⌥⇧T by default — free of the system and browser combos (⌘⇧T is
    /// "reopen closed tab"), and lives in the same ⌥-family as dictation.
    static let defaultHotkey = HotkeyCombo(
        keyCode: UInt32(kVK_ANSI_T),
        modifiers: UInt32(optionKey | shiftKey)
    )

    @Published var hotkey: HotkeyCombo {
        didSet {
            if let data = try? JSONEncoder().encode(hotkey) {
                defaults.set(data, forKey: "worldTime.hotkey")
            }
            // The host's hotkey manager re-registers everything on this.
            NotificationCenter.default.post(name: .hotkeysDidChange, object: nil)
        }
    }

    // MARK: - City list (ordered timezone identifiers)

    /// Rows of the grid, top to bottom. The home row can be anywhere in the
    /// list — the home city stays wherever the user dragged it.
    @Published var zoneIDs: [String] {
        didSet { defaults.set(zoneIDs, forKey: "worldTime.zoneIDs") }
    }

    /// The reference zone: the grid's columns are the 24 hours of the
    /// selected day in THIS zone, all other rows align to it.
    @Published var homeZoneID: String {
        didSet { defaults.set(homeZoneID, forKey: "worldTime.homeZoneID") }
    }

    // MARK: - Display

    @Published var timeFormat: WorldTimeFormat {
        didSet { defaults.set(timeFormat.rawValue, forKey: "worldTime.timeFormat") }
    }

    /// Working-hours window used for cell coloring (work / shoulder / night).
    @Published var workStartHour: Int {
        didSet { defaults.set(workStartHour, forKey: "worldTime.workStartHour") }
    }

    @Published var workEndHour: Int {
        didSet { defaults.set(workEndHour, forKey: "worldTime.workEndHour") }
    }

    /// Slot composer input preference: microphone-first (default) or text.
    /// Flips to false the first time the user switches to typing.
    @Published var slotVoiceInput: Bool {
        didSet { defaults.set(slotVoiceInput, forKey: "worldTime.slotVoiceInput") }
    }

    /// Resolved 12/24-hour choice ("system" follows the locale).
    var uses24Hour: Bool {
        switch timeFormat {
        case .h12: return false
        case .h24: return true
        case .system:
            let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? ""
            return !format.contains("a")
        }
    }

    // MARK: - Helpers

    func addZone(_ id: String) {
        guard !zoneIDs.contains(id) else { return }
        zoneIDs.append(id)
    }

    func removeZone(_ id: String) {
        zoneIDs.removeAll { $0 == id }
        // Removing the home row: the first remaining city inherits home, so
        // the grid always has a reference zone.
        if homeZoneID == id, let first = zoneIDs.first {
            homeZoneID = first
        }
    }

    // MARK: - Init

    private init() {
        // Enabled by default: fully local and free, and invisible until the
        // menu item is used — nothing changes for existing users' workflows.
        enabled = defaults.object(forKey: "worldTime.enabled") as? Bool ?? true
        let current = TimeZone.current.identifier
        let stored = defaults.stringArray(forKey: "worldTime.zoneIDs") ?? []
        zoneIDs = stored.isEmpty ? [current] : stored
        let home = defaults.string(forKey: "worldTime.homeZoneID") ?? current
        homeZoneID = (stored.isEmpty || stored.contains(home)) ? home : (stored.first ?? current)
        timeFormat = defaults.string(forKey: "worldTime.timeFormat")
            .flatMap(WorldTimeFormat.init(rawValue:)) ?? .system
        hotkey = defaults.data(forKey: "worldTime.hotkey")
            .flatMap { try? JSONDecoder().decode(HotkeyCombo.self, from: $0) } ?? Self.defaultHotkey
        slotVoiceInput = defaults.object(forKey: "worldTime.slotVoiceInput") as? Bool ?? true
        let start = defaults.object(forKey: "worldTime.workStartHour") as? Int
        let end = defaults.object(forKey: "worldTime.workEndHour") as? Int
        // Defaults: the morning shoulder is 6–7 only, 8 am is already an
        // active (work) hour.
        workStartHour = start ?? 8
        workEndHour = end ?? 18
    }
}
