import Foundation
import Combine
import EventKit

extension Notification.Name {
    /// Posted when the addon's enable flag changes (the host refreshes UI
    /// that gates on it). Kept separate from app-wide notifications.
    static let calendarAddonDidChange = Notification.Name("calendarAddonDidChange")
}

/// Persisted settings for the CalendarAddon. Own `UserDefaults` keys (prefix
/// `calendarAddon.`), nothing stored in the app's `AppSettings` — the addon
/// stays fully self-contained (pattern: `ImageAddonSettings`).
///
/// Calendar visibility is stored as an EXCLUSION list ("all visible except
/// the unchecked ones"): a calendar the user creates next month is visible to
/// the assistant automatically, instead of silently missing until they
/// remember this settings pane. Each exclusion keeps two keys — the EventKit
/// `calendarIdentifier` plus a `title|account` fallback — because identifiers
/// are known to change when an account fully resyncs, and a privacy exclusion
/// must not silently "unstick" (fail-open) when that happens.
@MainActor
final class CalendarSettings: ObservableObject {
    static let shared = CalendarSettings()

    private let defaults = UserDefaults.standard

    // MARK: - Master switch

    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "calendarAddon.enabled")
            NotificationCenter.default.post(name: .calendarAddonDidChange, object: nil)
        }
    }

    // MARK: - Default write calendar

    /// Overrides the system default (`defaultCalendarForNewEvents`) as the
    /// write target when the model names no calendar. `nil` = follow the
    /// system. Same `{id, key}` pair as exclusions — survives account
    /// resyncs that regenerate `calendarIdentifier`.
    @Published var defaultCalendarOverride: [String: String]? {
        didSet { defaults.set(defaultCalendarOverride, forKey: "calendarAddon.defaultCalendar") }
    }

    func isDefaultOverride(_ calendar: EKCalendar) -> Bool {
        guard let ref = defaultCalendarOverride else { return false }
        return ref["id"] == calendar.calendarIdentifier
            || ref["key"] == Self.fallbackKey(for: calendar)
    }

    func setDefaultOverride(_ calendar: EKCalendar?) {
        guard let calendar else {
            defaultCalendarOverride = nil
            return
        }
        defaultCalendarOverride = [
            "id": calendar.calendarIdentifier,
            "key": Self.fallbackKey(for: calendar),
        ]
    }

    // MARK: - Exclusions

    /// Each entry: `["id": calendarIdentifier, "key": "title|accountTitle"]`.
    @Published private(set) var exclusions: [[String: String]] {
        didSet { defaults.set(exclusions, forKey: "calendarAddon.exclusions") }
    }

    /// Identifier-independent fallback key: survives account resyncs that
    /// regenerate `calendarIdentifier`.
    nonisolated static func fallbackKey(for calendar: EKCalendar) -> String {
        "\(calendar.title)|\(calendar.source?.title ?? "")"
    }

    func isExcluded(_ calendar: EKCalendar) -> Bool {
        let key = Self.fallbackKey(for: calendar)
        return exclusions.contains {
            $0["id"] == calendar.calendarIdentifier || $0["key"] == key
        }
    }

    func setExcluded(_ excluded: Bool, calendar: EKCalendar) {
        let key = Self.fallbackKey(for: calendar)
        // Drop every entry matching either key, then re-add if excluding —
        // this also collapses stale duplicates left by identifier churn.
        var list = exclusions.filter {
            $0["id"] != calendar.calendarIdentifier && $0["key"] != key
        }
        if excluded {
            list.append(["id": calendar.calendarIdentifier, "key": key])
        }
        exclusions = list
    }

    // MARK: - Init

    private init() {
        enabled = defaults.bool(forKey: "calendarAddon.enabled")
        exclusions = defaults.array(forKey: "calendarAddon.exclusions") as? [[String: String]] ?? []
        defaultCalendarOverride = defaults.dictionary(forKey: "calendarAddon.defaultCalendar") as? [String: String]
    }
}
