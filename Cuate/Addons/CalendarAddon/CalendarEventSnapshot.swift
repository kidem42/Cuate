import Foundation
import EventKit

/// A value copy of one event occurrence, taken while the `EKEvent` is in
/// hand. UI that outlives a store change (the World Time busy lane keeps
/// its blocks between `EKEventStoreChanged` refreshes, a popover stays open
/// across one) must not hold `EKEvent` references — the store invalidates
/// them behind its back.
struct CalendarEventSnapshot: Identifiable {
    struct Attendee {
        let name: String
        let isCurrentUser: Bool
        let isOrganizer: Bool
        let status: EKParticipantStatus
    }

    /// `eventIdentifier` plus the occurrence's start: recurring events share
    /// one identifier and a day can show two occurrences of the same one.
    let id: String
    let eventIdentifier: String?
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarTitle: String
    let calendarColor: CGColor?
    let location: String?
    let notes: String?
    let url: URL?
    let attendees: [Attendee]
    /// The user's own reply when the event has attendees and one is them.
    let currentUserStatus: EKParticipantStatus?
    let repeats: Bool
    /// The online-meeting link, when one of the fields carries a known one.
    let conference: ConferenceLink?

    init(event: EKEvent) {
        let start = event.startDate ?? .distantPast
        id = (event.eventIdentifier ?? UUID().uuidString) + "@\(start.timeIntervalSince1970)"
        eventIdentifier = event.eventIdentifier
        title = event.title ?? ""
        self.start = start
        end = event.endDate ?? start
        isAllDay = event.isAllDay
        calendarTitle = event.calendar?.title ?? ""
        calendarColor = event.calendar?.cgColor
        location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        url = event.url
        attendees = (event.attendees ?? []).map { participant in
            Attendee(name: participant.name ?? "?",
                     isCurrentUser: participant.isCurrentUser,
                     isOrganizer: participant.participantRole == .chair,
                     status: participant.participantStatus)
        }
        currentUserStatus = event.attendees?.first { $0.isCurrentUser }?.participantStatus
        repeats = event.hasRecurrenceRules
        conference = Self.conferenceLink(of: event)
    }

    /// The meeting link of an event: URL field, then location, then notes.
    static func conferenceLink(of event: EKEvent) -> ConferenceLink? {
        ConferenceLinkDetector.detect(url: event.url, texts: [event.location, event.notes])
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
