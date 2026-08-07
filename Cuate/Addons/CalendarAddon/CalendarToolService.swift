import Foundation
import EventKit

/// The CalendarAddon's bridge into the agentic tool loop: builds the
/// `ToolSpec`s advertised to the model (with the live calendar inventory
/// baked into the descriptions) and executes the calls. Runs CLIENT-side
/// like `WebFetchService` — free, no key, works with every provider.
///
/// Errors are returned as plain strings (never thrown): the model reads the
/// message and either self-corrects (bad date format, ambiguous calendar
/// name) or relays it to the user.
@MainActor
enum CalendarToolService {

    private static var addon: CalendarAddon { CalendarAddon.shared }

    // MARK: - Tool names

    static let eventsToolName = "calendar_events"
    static let createEventToolName = "calendar_create_event"
    static let remindersToolName = "reminders_list"
    static let createReminderToolName = "reminder_create"

    static func canHandle(_ name: String) -> Bool {
        [eventsToolName, createEventToolName, remindersToolName, createReminderToolName].contains(name)
    }

    // MARK: - Tool specs

    /// Specs for whatever the user actually granted: calendar tools require
    /// event access, reminder tools require reminder access. Empty when the
    /// addon is off — the caller then skips the prompt hint too.
    static func toolSpecs() -> [ToolSpec] {
        guard addon.isAvailable else { return [] }
        var specs: [ToolSpec] = []

        if addon.hasEventAccess, !addon.visibleEventCalendars().isEmpty {
            specs.append(ToolSpec(
                name: eventsToolName,
                description: "List the user's calendar events in a date range, sorted by start time. Searches all calendars unless filtered. Full details (notes, attendees, links) are included when 15 or fewer events match — to inspect one event, narrow the range or use \"query\". Available calendars: \(addon.eventCalendarInventory()).",
                parameters: [
                    "type": "object",
                    "properties": [
                        "from": [
                            "type": "string",
                            "description": "Range start: YYYY-MM-DD (start of day, user's timezone) or full ISO 8601."
                        ],
                        "to": [
                            "type": "string",
                            "description": "Range end: YYYY-MM-DD (END of that day) or full ISO 8601."
                        ],
                        "query": [
                            "type": "string",
                            "description": "Optional case-insensitive filter on event title/location."
                        ],
                        "calendars": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Optional: restrict to these calendar names."
                        ]
                    ],
                    "required": ["from", "to"]
                ]
            ))
            if addon.defaultEventCalendar != nil {
                specs.append(ToolSpec(
                    name: createEventToolName,
                    description: "Create a calendar event. Omit \"calendar\" to use the default. Writable calendars: \(addon.eventCalendarInventory()).",
                    parameters: [
                        "type": "object",
                        "properties": [
                            "title": ["type": "string", "description": "Event title."],
                            "start": [
                                "type": "string",
                                "description": "Start: ISO 8601 local time, e.g. 2026-07-24T15:00:00. For all-day events use YYYY-MM-DD."
                            ],
                            "end": [
                                "type": "string",
                                "description": "Optional end (same format). Defaults to start + 1 hour."
                            ],
                            "all_day": ["type": "boolean", "description": "All-day event (default false)."],
                            "location": ["type": "string", "description": "Optional location."],
                            "notes": ["type": "string", "description": "Optional notes."],
                            "calendar": ["type": "string", "description": "Optional target calendar name."],
                            "alert_minutes_before": [
                                "type": "integer",
                                "description": "Optional: add an alert N minutes before start (0 = at start time). When set and \"end\" is omitted, the event defaults to 15 minutes long (reminder-style) instead of 1 hour."
                            ]
                        ],
                        "required": ["title", "start"]
                    ]
                ))
            }
        }

        if addon.hasReminderAccess, !addon.visibleReminderLists().isEmpty {
            specs.append(ToolSpec(
                name: remindersToolName,
                description: "List the user's open (incomplete) reminders. Available lists: \(addon.reminderListInventory()).",
                parameters: [
                    "type": "object",
                    "properties": [
                        "due_before": [
                            "type": "string",
                            "description": "Optional: only reminders due before this date (YYYY-MM-DD or ISO 8601)."
                        ],
                        "lists": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Optional: restrict to these list names."
                        ]
                    ]
                ]
            ))
            if addon.defaultReminderList != nil {
                specs.append(ToolSpec(
                    name: createReminderToolName,
                    description: "Create a reminder. Omit \"list\" to use the default. Lists: \(addon.reminderListInventory()).",
                    parameters: [
                        "type": "object",
                        "properties": [
                            "title": ["type": "string", "description": "Reminder text."],
                            "due": [
                                "type": "string",
                                "description": "Optional due date: YYYY-MM-DD (date-only) or ISO 8601 local time (sets an alert)."
                            ],
                            "notes": ["type": "string", "description": "Optional notes."],
                            "list": ["type": "string", "description": "Optional target list name."]
                        ],
                        "required": ["title"]
                    ]
                ))
            }
        }

        return specs
    }

    /// Usage hint appended to the system prompt AT REQUEST TIME, and only
    /// when `toolSpecs()` is non-empty — a disabled addon adds zero prompt
    /// bytes (same contract as the web tools hint in ChatService).
    /// CACHE-CRITICAL: this string must stay stable within a day — the
    /// Anthropic prompt cache treats any system-prompt change as a full
    /// prefix invalidation (tools → system → messages), so a wall-clock
    /// timestamp here would re-bill the whole conversation at cache-write
    /// rates every single turn. Date + timezone only; the exact clock rides
    /// in every tool RESULT (fresh per turn, cache-neutral) via `nowLine()`.
    static func systemPromptHint() -> String {
        let now = Date()
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd (EEEE)"
        let tz = TimeZone.current
        let offsetMinutes = tz.secondsFromGMT(for: now) / 60
        let offset = String(format: "UTC%+03d:%02d", offsetMinutes / 60, abs(offsetMinutes) % 60)
        return """
You have calendar and reminder tools backed by the user's own macOS Calendar. Today is \(fmt.string(from: now)), timezone \(tz.identifier) (\(offset)). Always call \(eventsToolName) before answering questions about the user's schedule — never answer from memory. Every tool result starts with the exact current time ("Now: …") — when the user says a relative time ("in an hour"), call \(eventsToolName) for today first and compute from that timestamp instead of guessing the clock. All times you send and receive are the user's local time; when creating events, send ISO 8601 without a UTC offset (e.g. 2026-07-24T15:00:00). Reminders: Apple reminder lists never sync to Google — if the user asks for a reminder and their main calendar is a Google one (see the calendar inventory), prefer \(createEventToolName) with alert_minutes_before: 0 in that calendar (it stays a short 15-minute event); use \(createReminderToolName) when they want the Apple Reminders app or no Google calendar is involved. After creating an event or reminder, confirm to the user exactly what was created and in which calendar or list.
"""
    }

    /// Exact wall clock, prepended to every tool result — the cache-safe
    /// channel for "what time is it now".
    private static func nowLine() -> String {
        "Now: \(dateTimeString(Date())).\n"
    }

    /// Status line for the chat panel while a call runs.
    static func statusLine(for call: ToolCall) -> String {
        switch call.name {
        case eventsToolName: return CAL("cal.status.reading")
        case createEventToolName: return CAL("cal.status.creatingEvent")
        case remindersToolName: return CAL("cal.status.readingReminders")
        case createReminderToolName: return CAL("cal.status.creatingReminder")
        default: return CAL("cal.status.reading")
        }
    }

    // MARK: - Dispatch

    static func run(_ call: ToolCall) async -> String {
        guard addon.isAvailable else {
            return "Calendar access is not available (disabled or not authorized)."
        }
        let args = call.arguments
        switch call.name {
        case eventsToolName: return nowLine() + listEvents(args)
        case createEventToolName: return nowLine() + createEvent(args)
        case remindersToolName: return nowLine() + (await listReminders(args))
        case createReminderToolName: return nowLine() + createReminder(args)
        default: return "Unknown calendar tool: \(call.name)"
        }
    }

    // MARK: - calendar_events

    /// Hard caps: a year of range, 100 events in the answer — the tool result
    /// must not blow up the context (pattern: WebFetchService.maxChars).
    private static let maxRangeDays = 400
    private static let maxListed = 100

    private static func listEvents(_ args: [String: Any]) -> String {
        guard let fromRaw = args["from"] as? String, let from = parseDate(fromRaw) else {
            return "Missing or invalid \"from\" date. Use YYYY-MM-DD or ISO 8601."
        }
        guard let toRaw = args["to"] as? String, let to = parseDate(toRaw, dayEnd: true) else {
            return "Missing or invalid \"to\" date. Use YYYY-MM-DD or ISO 8601."
        }
        guard to > from else { return "\"to\" must be after \"from\"." }
        guard to.timeIntervalSince(from) <= Double(maxRangeDays) * 86_400 else {
            return "Date range is too large — keep it under \(maxRangeDays) days."
        }

        var calendars = addon.visibleEventCalendars()
        if let names = args["calendars"] as? [String], !names.isEmpty {
            let lower = Set(names.map { $0.lowercased() })
            let filtered = calendars.filter { lower.contains($0.title.lowercased()) }
            guard !filtered.isEmpty else {
                return "No matching calendars. Available: \(addon.eventCalendarInventory())."
            }
            calendars = filtered
        }
        guard !calendars.isEmpty else { return "No calendars are visible to the assistant." }

        let predicate = addon.store.predicateForEvents(withStart: from, end: to, calendars: calendars)
        var events = addon.store.events(matching: predicate).sorted { $0.startDate < $1.startDate }

        if let query = args["query"] as? String, !query.isEmpty {
            let q = query.lowercased()
            events = events.filter {
                ($0.title ?? "").lowercased().contains(q)
                    || ($0.location ?? "").lowercased().contains(q)
            }
        }

        guard !events.isEmpty else {
            return "No events between \(dayString(from)) and \(dayString(to))."
        }

        // Small result sets get full details (notes, attendees, links) —
        // big ones stay one-line so a busy month can't blow up the context.
        let detailed = events.count <= detailThreshold
        var lines: [String] = []
        for event in events.prefix(maxListed) {
            lines.append(format(event: event, detailed: detailed))
        }
        var result = "Events \(dayString(from)) — \(dayString(to)) (\(events.count)):\n" + lines.joined(separator: "\n")
        if events.count > maxListed {
            result += "\n[Truncated: showing first \(maxListed) of \(events.count) events — narrow the range]"
        }
        if !detailed {
            result += "\n[Notes/attendees/links omitted for large result sets — narrow the range or use \"query\" to see event details]"
        }
        return result
    }

    /// Above this many events the listing drops to one line per event.
    private static let detailThreshold = 15
    /// Per-event notes budget — enough for a Zoom invite, not a novel.
    private static let maxNotesChars = 300

    private static func format(event: EKEvent, detailed: Bool = false) -> String {
        let cal = event.calendar?.title ?? "?"
        let title = event.title ?? "(untitled)"
        var line: String
        if event.isAllDay {
            let start = dayString(event.startDate)
            // EventKit's all-day endDate points at the exclusive next
            // midnight — step back so a one-day event shows one day.
            let lastDay = dayString(event.endDate.addingTimeInterval(-1))
            line = start == lastDay
                ? "\(start) (all day) | \(title)"
                : "\(start) — \(lastDay) (all day) | \(title)"
        } else {
            let sameDay = Calendar.current.isDate(event.startDate, inSameDayAs: event.endDate)
            let end = sameDay ? timeString(event.endDate) : dateTimeString(event.endDate)
            line = "\(dateTimeString(event.startDate))–\(end) | \(title)"
        }
        line += " | [\(cal)]"
        if let location = event.location, !location.isEmpty {
            line += " | \(location)"
        }
        if event.hasRecurrenceRules {
            line += " | (repeats)"
        }
        guard detailed else { return line }

        // Detail sub-lines, indented under the event line.
        var details: [String] = []
        if let url = event.url?.absoluteString, !url.isEmpty {
            details.append("url: \(url)")
        }
        if let attendees = event.attendees, !attendees.isEmpty {
            let names = attendees.prefix(10).map { participant -> String in
                var name = participant.name ?? "?"
                if participant.participantRole == .chair || participant.isCurrentUser {
                    name += participant.isCurrentUser ? " (you)" : " (organizer)"
                }
                return name
            }
            var attendeeLine = "attendees: " + names.joined(separator: ", ")
            if attendees.count > 10 { attendeeLine += " +\(attendees.count - 10) more" }
            details.append(attendeeLine)
        }
        if let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            // Flatten so one event stays one visual block for the model.
            let flat = notes
                .replacingOccurrences(of: "\n{2,}", with: " ¶ ", options: .regularExpression)
                .replacingOccurrences(of: "\n", with: " ")
            details.append(flat.count > maxNotesChars
                ? "notes: \(flat.prefix(maxNotesChars))… [truncated]"
                : "notes: \(flat)")
        }
        for detail in details {
            line += "\n    \(detail)"
        }
        return line
    }

    // MARK: - calendar_create_event

    private static func createEvent(_ args: [String: Any]) -> String {
        guard let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return "Missing \"title\"."
        }
        guard let startRaw = args["start"] as? String, let start = parseDate(startRaw) else {
            return "Missing or invalid \"start\". Use ISO 8601 local time (2026-07-24T15:00:00) or YYYY-MM-DD for all-day."
        }

        let calendar: EKCalendar
        if let name = (args["calendar"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            switch addon.resolveWritable(named: name, in: addon.visibleEventCalendars()) {
            case .success(let resolved): calendar = resolved
            case .failure(let miss): return miss.message
            }
        } else if let def = addon.defaultEventCalendar {
            calendar = def
        } else {
            return "No writable calendar is available."
        }

        let event = EKEvent(eventStore: addon.store)
        event.calendar = calendar
        event.title = title
        // Date-only start implies all-day even if the model forgot the flag.
        let allDay = (args["all_day"] as? Bool ?? false) || isDateOnly(startRaw)
        event.isAllDay = allDay
        if allDay {
            event.startDate = Calendar.current.startOfDay(for: start)
            if let endRaw = args["end"] as? String, let end = parseDate(endRaw) {
                event.endDate = Calendar.current.startOfDay(for: end)
            } else {
                event.endDate = event.startDate
            }
        } else {
            event.startDate = start
            if let endRaw = args["end"] as? String, let end = parseDate(endRaw), end > start {
                event.endDate = end
            } else {
                // Reminder-style events (alert requested, no explicit end) stay
                // short — a "remind me to..." must not block an hour of the calendar.
                let defaultMinutes = args["alert_minutes_before"] != nil ? 15.0 : 60.0
                event.endDate = start.addingTimeInterval(defaultMinutes * 60)
            }
        }
        if let location = args["location"] as? String, !location.isEmpty { event.location = location }
        if let notes = args["notes"] as? String, !notes.isEmpty { event.notes = notes }
        // Alert: EventKit wants a negative offset (seconds before start).
        // Works for Google calendars too — CalDAV syncs VALARM.
        if let alertMinutes = args["alert_minutes_before"] as? Int {
            event.addAlarm(EKAlarm(relativeOffset: -Double(max(0, alertMinutes)) * 60))
        } else if let alertMinutes = args["alert_minutes_before"] as? Double {
            event.addAlarm(EKAlarm(relativeOffset: -max(0, alertMinutes) * 60))
        }

        do {
            try addon.store.save(event, span: .thisEvent, commit: true)
        } catch {
            return "Failed to save the event: \(error.localizedDescription)"
        }
        Diagnostics.log("calendar", "event.created calendar=\(calendar.title)")
        let when = event.isAllDay
            ? "\(dayString(event.startDate)) (all day)"
            : "\(dateTimeString(event.startDate))–\(timeString(event.endDate))"
        var confirmation = "Created event \"\(title)\" on \(when) in calendar \"\(calendar.title)\"."
        if event.hasAlarms {
            confirmation += " Alert is set."
        }
        return confirmation
    }

    // MARK: - reminders_list

    private static func listReminders(_ args: [String: Any]) async -> String {
        var lists = addon.visibleReminderLists()
        if let names = args["lists"] as? [String], !names.isEmpty {
            let lower = Set(names.map { $0.lowercased() })
            let filtered = lists.filter { lower.contains($0.title.lowercased()) }
            guard !filtered.isEmpty else {
                return "No matching reminder lists. Available: \(addon.reminderListInventory())."
            }
            lists = filtered
        }
        guard !lists.isEmpty else { return "No reminder lists are visible to the assistant." }

        let dueBefore = (args["due_before"] as? String).flatMap { parseDate($0, dayEnd: true) }
        let predicate = addon.store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: dueBefore, calendars: lists
        )
        let store = addon.store
        let reminders: [EKReminder] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { cont.resume(returning: $0 ?? []) }
        }
        guard !reminders.isEmpty else { return "No open reminders." }

        // Due-dated first (soonest on top), then the dateless tail.
        let sorted = reminders.sorted {
            let a = $0.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
            let b = $1.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
            switch (a, b) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return ($0.title ?? "") < ($1.title ?? "")
            }
        }
        var lines: [String] = []
        for reminder in sorted.prefix(maxListed) {
            var line = "• \(reminder.title ?? "(untitled)")"
            if let comps = reminder.dueDateComponents, let due = Calendar.current.date(from: comps) {
                line += comps.hour != nil
                    ? " — due \(dateTimeString(due))"
                    : " — due \(dayString(due))"
            }
            line += " [\(reminder.calendar?.title ?? "?")]"
            lines.append(line)
        }
        var result = "Open reminders (\(reminders.count)):\n" + lines.joined(separator: "\n")
        if reminders.count > maxListed {
            result += "\n[Truncated: showing first \(maxListed) of \(reminders.count)]"
        }
        return result
    }

    // MARK: - reminder_create

    private static func createReminder(_ args: [String: Any]) -> String {
        guard let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return "Missing \"title\"."
        }

        let list: EKCalendar
        if let name = (args["list"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            switch addon.resolveWritable(named: name, in: addon.visibleReminderLists()) {
            case .success(let resolved): list = resolved
            case .failure(let miss): return miss.message
            }
        } else if let def = addon.defaultReminderList {
            list = def
        } else {
            return "No writable reminder list is available."
        }

        let reminder = EKReminder(eventStore: addon.store)
        reminder.calendar = list
        reminder.title = title
        if let notes = args["notes"] as? String, !notes.isEmpty { reminder.notes = notes }

        var dueNote = ""
        if let dueRaw = args["due"] as? String, !dueRaw.isEmpty {
            guard let due = parseDate(dueRaw) else {
                return "Invalid \"due\" date. Use YYYY-MM-DD or ISO 8601 local time."
            }
            if isDateOnly(dueRaw) {
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day], from: due
                )
                dueNote = ", due \(dayString(due))"
            } else {
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: due
                )
                // A timed reminder without an alarm never fires a notification.
                reminder.addAlarm(EKAlarm(absoluteDate: due))
                dueNote = ", due \(dateTimeString(due))"
            }
        }

        do {
            try addon.store.save(reminder, commit: true)
        } catch {
            return "Failed to save the reminder: \(error.localizedDescription)"
        }
        Diagnostics.log("calendar", "reminder.created list=\(list.title)")
        return "Created reminder \"\(title)\"\(dueNote) in list \"\(list.title)\"."
    }

    // MARK: - Date parsing / formatting

    /// Accepts what models actually send: `YYYY-MM-DD`, `YYYY-MM-DDTHH:mm`,
    /// `...THH:mm:ss` (all interpreted as the USER'S timezone — that is what
    /// the person meant), and full ISO 8601 with an explicit offset.
    /// `dayEnd` maps a bare date onto the END of that day (range upper bound).
    private static func parseDate(_ raw: String, dayEnd: Bool = false) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if isDateOnly(s) {
            let fmt = localFormatter("yyyy-MM-dd")
            guard let day = fmt.date(from: s) else { return nil }
            return dayEnd
                ? Calendar.current.date(byAdding: .day, value: 1, to: day)?.addingTimeInterval(-1)
                : day
        }
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            if let date = localFormatter(pattern).date(from: s) { return date }
        }
        // Explicit offset (Z or ±hh:mm) — trust it.
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: s) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: s)
    }

    private static func isDateOnly(_ s: String) -> Bool {
        s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    private static func localFormatter(_ pattern: String) -> DateFormatter {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        fmt.dateFormat = pattern
        return fmt
    }

    // Output goes to the MODEL, not the user — a fixed unambiguous format
    // (with weekday, since models are shaky at deriving it) beats locale
    // formatting here; the model localizes its own reply.
    private static func dayString(_ date: Date) -> String {
        localFormatter("yyyy-MM-dd EEE").string(from: date)
    }

    private static func timeString(_ date: Date) -> String {
        localFormatter("HH:mm").string(from: date)
    }

    private static func dateTimeString(_ date: Date) -> String {
        localFormatter("yyyy-MM-dd EEE HH:mm").string(from: date)
    }
}
