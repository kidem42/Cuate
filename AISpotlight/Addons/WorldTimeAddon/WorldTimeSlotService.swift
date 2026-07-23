import Foundation
import EventKit

/// Creates the slot's calendar entry DIRECTLY via EventKit — no LLM call:
/// the slot gives the exact start, the spoken/typed text is the title, the
/// duration is fixed at 30 minutes. The event lands in the CalendarAddon's
/// default calendar (iCloud, Google — whatever the user's setup syncs), and
/// that account's own notification machinery does the reminding.
@MainActor
enum WorldTimeSlotService {

    enum SlotError: LocalizedError {
        case noCalendar
        var errorDescription: String? { WTL("wt.slot.err.noCalendar") }
    }

    static let slotDuration: TimeInterval = 30 * 60

    /// Creates a 30-minute event titled with the user's words at the slot.
    /// Returns a one-line confirmation for the composer.
    static func create(title rawTitle: String, slot: Date, homeZoneID: String) throws -> String {
        let addon = CalendarAddon.shared
        guard addon.hasEventAccess, let calendar = addon.defaultEventCalendar else {
            throw SlotError.noCalendar
        }

        // STT niceties: trim, drop a trailing period, capitalize the start.
        var title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        while title.hasSuffix(".") { title.removeLast() }
        if let first = title.first {
            title = first.uppercased() + title.dropFirst()
        }
        guard !title.isEmpty else { throw SlotError.noCalendar }

        let event = EKEvent(eventStore: addon.store)
        event.calendar = calendar
        event.title = title
        event.startDate = slot
        event.endDate = slot.addingTimeInterval(Self.slotDuration)
        // An alert at start time — the "reminder" part, regardless of the
        // account's per-calendar alert defaults.
        event.addAlarm(EKAlarm(relativeOffset: 0))
        try addon.store.save(event, span: .thisEvent, commit: true)
        Diagnostics.log("worldtime", "slot.created calendar=\(calendar.title)")

        let zone = TimeZone(identifier: homeZoneID) ?? .current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Localization.currentLanguage.rawValue)
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate(
            WorldTimeSettings.shared.uses24Hour ? "EEEdMMM HHmm" : "EEEdMMM hmm a")
        let endFormatter = DateFormatter()
        endFormatter.locale = formatter.locale
        endFormatter.timeZone = zone
        endFormatter.dateFormat = WorldTimeSettings.shared.uses24Hour ? "H:mm" : "h:mm a"
        return "\(title) · \(formatter.string(from: slot))–\(endFormatter.string(from: event.endDate)) · \(calendar.title)"
    }
}
