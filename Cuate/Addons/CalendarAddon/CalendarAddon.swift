import Foundation
import EventKit

/// CalendarAddon — native calendar & reminders access for the assistant,
/// built on EventKit (the user's macOS Calendar database: iCloud, Google,
/// Exchange — whatever is already synced into the system). No OAuth, no
/// third-party bridges, no tokens: the OS did the syncing for us.
///
/// Mount points (pattern: `LayoutFixAddon`): a master switch + settings tab
/// in `SettingsView`, and tool attachment in `ChatService` via
/// `CalendarToolService`. No `start()` hook — everything here is lazy.
@MainActor
final class CalendarAddon {
    static let shared = CalendarAddon()

    let store = EKEventStore()
    private let settings = CalendarSettings.shared

    private init() {}

    // MARK: - Access (TCC)

    var eventAccessStatus: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }
    var reminderAccessStatus: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .reminder) }
    var hasEventAccess: Bool { eventAccessStatus == .fullAccess }
    var hasReminderAccess: Bool { reminderAccessStatus == .fullAccess }

    /// Tools attach only when the addon is on AND at least one domain is
    /// authorized. The prompt hint is gated on the same flag in ChatService —
    /// disabled addon means zero tools and zero prompt bytes.
    var isAvailable: Bool { settings.enabled && (hasEventAccess || hasReminderAccess) }

    /// Requests full access to events and reminders. Called from the settings
    /// UI at the moment the user flips the master switch — the TCC dialog
    /// must appear at a predictable moment, never mid-chat.
    func requestAccessIfNeeded() async {
        if eventAccessStatus == .notDetermined {
            _ = try? await store.requestFullAccessToEvents()
        }
        if reminderAccessStatus == .notDetermined {
            _ = try? await store.requestFullAccessToReminders()
        }
    }

    // MARK: - Calendars

    /// All event calendars, stable order (by account, then title).
    func allEventCalendars() -> [EKCalendar] {
        sorted(store.calendars(for: .event))
    }

    func allReminderLists() -> [EKCalendar] {
        sorted(store.calendars(for: .reminder))
    }

    /// Calendars the assistant is allowed to see (exclusions filtered out).
    func visibleEventCalendars() -> [EKCalendar] {
        allEventCalendars().filter { !settings.isExcluded($0) }
    }

    func visibleReminderLists() -> [EKCalendar] {
        allReminderLists().filter { !settings.isExcluded($0) }
    }

    /// Write target when the model does not name a calendar. Priority:
    /// the user's in-app override (addon settings) → the system default
    /// (Calendar.app) unless hidden → the first visible writable one.
    var defaultEventCalendar: EKCalendar? {
        if let override = visibleEventCalendars().first(where: {
            settings.isDefaultOverride($0) && $0.allowsContentModifications
        }) {
            return override
        }
        if let def = store.defaultCalendarForNewEvents, !settings.isExcluded(def) {
            return def
        }
        return visibleEventCalendars().first { $0.allowsContentModifications }
    }

    var defaultReminderList: EKCalendar? {
        if let def = store.defaultCalendarForNewReminders(), !settings.isExcluded(def) {
            return def
        }
        return visibleReminderLists().first { $0.allowsContentModifications }
    }

    private func sorted(_ calendars: [EKCalendar]) -> [EKCalendar] {
        calendars.sorted {
            let a = ($0.source?.title ?? "", $0.title)
            let b = ($1.source?.title ?? "", $1.title)
            return a < b
        }
    }

    // MARK: - Inventory (injected into the tool descriptions)

    /// One line the model sees inside the tool description, e.g.:
    /// `"Personal" (iCloud, default), "Work" (Google), "Holidays" (read-only)`.
    /// Only VISIBLE calendars are listed — an unchecked calendar does not
    /// exist as far as the model knows.
    func eventCalendarInventory() -> String {
        let def = defaultEventCalendar
        let parts = visibleEventCalendars().map { cal -> String in
            var tags: [String] = []
            if let source = cal.source?.title, !source.isEmpty { tags.append(source) }
            if cal == def { tags.append("default") }
            if !cal.allowsContentModifications { tags.append("read-only") }
            return "\"\(cal.title)\"" + (tags.isEmpty ? "" : " (\(tags.joined(separator: ", ")))")
        }
        return parts.joined(separator: ", ")
    }

    func reminderListInventory() -> String {
        let def = defaultReminderList
        let parts = visibleReminderLists().map { cal -> String in
            var tags: [String] = []
            if let source = cal.source?.title, !source.isEmpty { tags.append(source) }
            if cal == def { tags.append("default") }
            if !cal.allowsContentModifications { tags.append("read-only") }
            return "\"\(cal.title)\"" + (tags.isEmpty ? "" : " (\(tags.joined(separator: ", ")))")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Name resolution (for writes)

    /// Resolver miss: the message is written FOR THE MODEL — it either
    /// self-corrects or relays the question to the user.
    struct ResolveError: Error {
        let message: String
    }

    /// Maps a model-supplied calendar name onto a visible WRITABLE calendar.
    /// Exact match → case-insensitive → unique substring. Ambiguity or a miss
    /// returns `.failure` with a message the model can relay to the user —
    /// never a silent guess.
    func resolveWritable(named name: String, in candidates: [EKCalendar]) -> Result<EKCalendar, ResolveError> {
        let writable = candidates.filter { $0.allowsContentModifications }
        guard !writable.isEmpty else {
            return .failure(ResolveError(message: "No writable calendar is available."))
        }
        if let exact = writable.first(where: { $0.title == name }) {
            return .success(exact)
        }
        let lower = name.lowercased()
        let ci = writable.filter { $0.title.lowercased() == lower }
        if ci.count == 1 { return .success(ci[0]) }
        let partial = writable.filter { $0.title.lowercased().contains(lower) }
        if partial.count == 1 { return .success(partial[0]) }
        let candidatesNote = writable.map { "\"\($0.title)\"" }.joined(separator: ", ")
        if partial.count > 1 {
            let matches = partial.map { "\"\($0.title)\"" }.joined(separator: ", ")
            return .failure(ResolveError(message: "Calendar name \"\(name)\" is ambiguous — matches: \(matches). Ask the user which one to use."))
        }
        return .failure(ResolveError(message: "No calendar named \"\(name)\". Available writable calendars: \(candidatesNote). Ask the user which one to use."))
    }
}
