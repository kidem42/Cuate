import Foundation
import Combine
import Carbon

/// One row of the grid: a zone, plus which city the user asked for.
///
/// The identity is the ROW, not the zone — the same zone can appear twice
/// under two different city names (San Francisco and Los Angeles keep the
/// same clock), and reordering, home and removal all have to tell those apart.
struct WorldTimeRow: Codable, Identifiable, Hashable {
    let id: UUID
    let zoneID: String
    /// English alias key from `WorldTimeCatalog` when the user picked a city
    /// that is not its zone's exemplar; `nil` means "use the zone's own
    /// exemplar city". Stored as the key, not as the finished label, so the
    /// row still follows the interface language.
    var alias: String?
}

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

    // MARK: - City list

    /// Rows of the grid, top to bottom. The home row can be anywhere in the
    /// list — the home city stays wherever the user dragged it.
    ///
    /// A ROW, not a zone: several cities share one IANA zone (San Francisco,
    /// Seattle and Los Angeles are all `America/Los_Angeles`), and someone who
    /// looks up San Francisco wants a row that says San Francisco — whether or
    /// not Los Angeles is already there. Duplicated zones are the user's call
    /// to make and to undo.
    @Published var rows: [WorldTimeRow] {
        didSet {
            if let data = try? JSONEncoder().encode(rows) {
                defaults.set(data, forKey: "worldTime.rows")
            }
        }
    }

    /// The reference row: the grid's columns are the 24 hours of the selected
    /// day in ITS zone, all other rows align to it. Identified by row rather
    /// than by zone — with two rows on the same zone, "home" has to name one
    /// of them or the house marker lands on whichever sorts first.
    @Published var homeRowID: UUID {
        didSet { defaults.set(homeRowID.uuidString, forKey: "worldTime.homeRowID") }
    }

    /// Zone of the home row — everything that does time math reads this.
    var homeZoneID: String {
        rows.first { $0.id == homeRowID }?.zoneID
            ?? rows.first?.zoneID
            ?? TimeZone.current.identifier
    }

    // MARK: - Display

    @Published var timeFormat: WorldTimeFormat {
        didSet { defaults.set(timeFormat.rawValue, forKey: "worldTime.timeFormat") }
    }

    /// Whether the grid distinguishes working hours at all. Off, the palette
    /// collapses to day vs. night — for people who only want to know whether
    /// it is the middle of someone's night, not whether it is their office
    /// hours. Defaults to on so existing setups keep the planner colouring.
    @Published var showWorkHours: Bool {
        didSet { defaults.set(showWorkHours, forKey: "worldTime.showWorkHours") }
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

    /// Keeps the panel up when focus moves to another app or window. Off by
    /// default: the panel now dismisses itself like the chat panel does, and
    /// the pin is the opt-out for people who want it parked on screen while
    /// they type elsewhere. Toggled from the panel's own top bar, so it is not
    /// mirrored in the settings tab.
    @Published var pinned: Bool {
        didSet { defaults.set(pinned, forKey: "worldTime.pinned") }
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

    /// Appends a row. No de-duplication by zone: two cities that happen to
    /// share a clock are still two cities, and silently swallowing the second
    /// one is what made picking San Francisco next to Los Angeles look broken.
    /// `alias` is the catalog's English alias key when the user picked a city
    /// that isn't its zone's exemplar; the display name is resolved from it at
    /// render time so it follows the interface language.
    func addRow(zoneID: String, alias: String? = nil) {
        rows.append(WorldTimeRow(id: UUID(), zoneID: zoneID, alias: alias))
    }

    func removeRow(_ id: UUID) {
        rows.removeAll { $0.id == id }
        // Removing the home row: the first remaining row inherits home, so the
        // grid always has a reference zone.
        if homeRowID == id, let first = rows.first {
            homeRowID = first.id
        }
    }

    // MARK: - Init

    private init() {
        // Enabled by default: fully local and free, and invisible until the
        // menu item is used — nothing changes for existing users' workflows.
        enabled = defaults.object(forKey: "worldTime.enabled") as? Bool ?? true
        let current = TimeZone.current.identifier
        // Rows, with a one-way migration from the pre-1.x list of bare zone
        // identifiers so nobody's grid resets.
        // Built into a local first: `self` is off limits until every stored
        // property is initialized.
        let restored: [WorldTimeRow]
        if let data = defaults.data(forKey: "worldTime.rows"),
           let decoded = try? JSONDecoder().decode([WorldTimeRow].self, from: data), !decoded.isEmpty {
            restored = decoded
        } else {
            let legacy = defaults.stringArray(forKey: "worldTime.zoneIDs") ?? []
            let zones = legacy.isEmpty ? [current] : legacy
            restored = zones.map { WorldTimeRow(id: UUID(), zoneID: $0, alias: nil) }
        }
        rows = restored
        // Home: the stored row if it still exists, else the row carrying the
        // legacy home zone, else the top row.
        let storedHome = defaults.string(forKey: "worldTime.homeRowID").flatMap(UUID.init(uuidString:))
        let legacyHomeZone = defaults.string(forKey: "worldTime.homeZoneID") ?? current
        homeRowID = restored.first { $0.id == storedHome }?.id
            ?? restored.first { $0.zoneID == legacyHomeZone }?.id
            ?? restored.first?.id
            ?? UUID()
        timeFormat = defaults.string(forKey: "worldTime.timeFormat")
            .flatMap(WorldTimeFormat.init(rawValue:)) ?? .system
        hotkey = defaults.data(forKey: "worldTime.hotkey")
            .flatMap { try? JSONDecoder().decode(HotkeyCombo.self, from: $0) } ?? Self.defaultHotkey
        slotVoiceInput = defaults.object(forKey: "worldTime.slotVoiceInput") as? Bool ?? true
        pinned = defaults.object(forKey: "worldTime.pinned") as? Bool ?? false
        let start = defaults.object(forKey: "worldTime.workStartHour") as? Int
        let end = defaults.object(forKey: "worldTime.workEndHour") as? Int
        // Defaults: the morning shoulder is 6–7 only, 8 am is already an
        // active (work) hour.
        workStartHour = start ?? 8
        workEndHour = end ?? 18
        // Absent for everyone who installed before the switch existed — they
        // have been looking at the working-hours palette all along.
        showWorkHours = defaults.object(forKey: "worldTime.showWorkHours") as? Bool ?? true
    }
}
