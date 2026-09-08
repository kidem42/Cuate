import SwiftUI
import AppKit
import EventKit

/// Details of one busy-lane block, opened by clicking its pill: the meeting
/// in every grid zone, the call link as a button, place, people and notes,
/// plus the other events sharing its time so a crowded lane never hides one.
/// System styling like the slot composer — a popover, not a themed surface.
struct WorldTimeEventPopover: View {
    /// A grid row to show the meeting in — the row's own label (an alias
    /// keeps its city name) and the zone it rides on.
    struct Zone: Identifiable {
        let id: UUID
        let label: String
        let zoneID: String
    }

    /// A meeting sharing this event's capsule on the lane (this one
    /// included), in start order — the chips under the header.
    struct Sibling: Identifiable {
        let id: String
        let title: String
        let color: Color
    }

    let event: CalendarEventSnapshot
    let color: Color
    /// Grid rows, home first; rows that duplicate the home zone are folded
    /// by the caller.
    let zones: [Zone]
    let homeZoneID: String
    /// Empty when the event has the capsule to itself.
    let siblings: [Sibling]
    var onSelectSibling: (String) -> Void
    var onOpenCalendar: () -> Void

    @ObservedObject private var settings = WorldTimeSettings.shared
    @State private var copied = false

    private static let maxNames = 6
    private static let maxNotesChars = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !siblings.isEmpty {
                siblingChips
            }
            zoneRows
            if let conference = event.conference {
                joinRow(conference)
            }
            detailRows
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    // MARK: - Header (calendar, title, the home-zone day line)

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(event.calendarTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if event.repeats {
                    Image(systemName: "repeat")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(WTL("wt.event.repeats"))
                }
                if let status = event.currentUserStatus, let badge = statusBadge(status) {
                    Text(badge.text)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(badge.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(badge.color.opacity(0.16), in: Capsule())
                        .help(WTL("wt.event.status.help"))
                }
            }
            Text(event.title.isEmpty ? WTL("wt.event.untitled") : event.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Text(dayLine)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func statusBadge(_ status: EKParticipantStatus) -> (text: String, color: Color)? {
        switch status {
        case .accepted: (WTL("wt.event.status.accepted"), .green)
        case .declined: (WTL("wt.event.status.declined"), .red)
        case .tentative: (WTL("wt.event.status.tentative"), .orange)
        case .pending: (WTL("wt.event.status.pending"), .secondary)
        default: nil
        }
    }

    // MARK: - The meeting in every other grid zone

    @ViewBuilder
    private var zoneRows: some View {
        let others = zones.filter { $0.zoneID != homeZoneID }
        if !others.isEmpty {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                ForEach(others) { zone in
                    GridRow {
                        Text(zone.label)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(timeRange(zoneID: zone.zoneID))
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
        }
    }

    // MARK: - Join

    private func joinRow(_ link: ConferenceLink) -> some View {
        HStack(spacing: 8) {
            Button {
                Diagnostics.log("worldtime", "busy.join service=\(link.service.rawValue)")
                NSWorkspace.shared.open(link.url)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "video.fill")
                    Text("\(WTL("wt.event.join")) · \(link.serviceName)")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .help(WTL("wt.event.join.help"))
            Button {
                copy(link.url)
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .frame(width: 14)
            }
            .buttonStyle(.bordered)
            .help(copied ? WTL("wt.event.copied") : WTL("wt.event.copyLink"))
        }
    }

    private func copy(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }

    // MARK: - Place, link, people, notes

    @ViewBuilder
    private var detailRows: some View {
        let conferenceString = event.conference?.url.absoluteString
        // Google writes the Meet link into the location — the join button
        // already carries it, so the row would only repeat the URL.
        if let location = event.location,
           !(conferenceString.map { location.contains($0) } ?? false) {
            detailRow(icon: "mappin.and.ellipse", text: location)
        }
        if let url = event.url, url.absoluteString != conferenceString {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                detailRow(icon: "link", text: url.host ?? url.absoluteString, tint: .accentColor)
            }
            .buttonStyle(.plain)
            .help(WTL("wt.event.openLink"))
        }
        if !event.attendees.isEmpty {
            attendeesRow
        }
        if let notes = event.notes {
            notesRow(notes)
        }
    }

    private func detailRow(icon: String, text: String, tint: Color? = nil, lines: Int = 2) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                .lineLimit(lines)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var attendeesRow: some View {
        let names = event.attendees.prefix(Self.maxNames).map { attendee -> String in
            if attendee.isCurrentUser { return "\(attendee.name) (\(WTL("wt.event.you")))" }
            if attendee.isOrganizer { return "\(attendee.name) (\(WTL("wt.event.organizer")))" }
            return attendee.name
        }
        var line = names.joined(separator: ", ")
        let rest = event.attendees.count - names.count
        if rest > 0 {
            line += ", " + String(format: WTL("wt.event.more"), rest)
        }
        return VStack(alignment: .leading, spacing: 2) {
            caption("\(WTL("wt.event.attendees")) · \(event.attendees.count)")
            Text(line)
                .font(.system(size: 11))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func notesRow(_ notes: String) -> some View {
        let flat = notes.replacingOccurrences(of: "\n{2,}", with: "\n", options: .regularExpression)
        let excerpt = flat.count > Self.maxNotesChars
            ? String(flat.prefix(Self.maxNotesChars)) + "…"
            : flat
        return detailRow(icon: "note.text", text: excerpt, lines: 5)
    }

    // MARK: - The capsule's meetings as chips

    /// One chip per meeting in the capsule, the shown one filled; a click
    /// swaps the popover's content in place (same anchor, same popover).
    private var siblingChips: some View {
        ChipFlow(spacing: 6) {
            ForEach(siblings) { sibling in
                let current = sibling.id == event.id
                Button {
                    onSelectSibling(sibling.id)
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(sibling.color)
                            .frame(width: 7, height: 7)
                        Text(sibling.title.isEmpty ? WTL("wt.event.untitled") : sibling.title)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .frame(maxWidth: 180)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .foregroundStyle(current ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
                    .background(current ? AnyShapeStyle(.primary) : AnyShapeStyle(.clear), in: Capsule())
                    .overlay(Capsule().stroke(.primary.opacity(current ? 0 : 0.22), lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(current)
                .help(WTL("wt.event.sameTime.help"))
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(WTL("wt.event.openCalendar")) {
                onOpenCalendar()
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .help(WTL("wt.event.openCalendar.help"))
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    // MARK: - Formatting

    private func formatter(zoneID: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Localization.currentLanguage.rawValue)
        formatter.timeZone = TimeZone(identifier: zoneID) ?? .current
        return formatter
    }

    private func range(_ start: Date, _ end: Date, zoneID: String) -> String {
        let formatter = formatter(zoneID: zoneID)
        formatter.dateFormat = settings.uses24Hour ? "H:mm" : "h:mm a"
        return "\(formatter.string(from: start))–\(formatter.string(from: end))"
    }

    /// "Fri 24 Jul · 14:30–15:30" in the home zone.
    private var dayLine: String {
        let formatter = formatter(zoneID: homeZoneID)
        formatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return "\(formatter.string(from: event.start)) · \(range(event.start, event.end, zoneID: homeZoneID))"
    }

    /// The meeting in another zone; when that zone is on a different
    /// calendar day than home, its weekday follows ("23:30–0:30 · Sat").
    private func timeRange(zoneID: String) -> String {
        var text = range(event.start, event.end, zoneID: zoneID)
        let dayKey = formatter(zoneID: zoneID)
        dayKey.dateFormat = "yyyyMMdd"
        let homeKey = formatter(zoneID: homeZoneID)
        homeKey.dateFormat = "yyyyMMdd"
        if dayKey.string(from: event.start) != homeKey.string(from: event.start) {
            let weekday = formatter(zoneID: zoneID)
            weekday.setLocalizedDateFormatFromTemplate("EEE")
            text += " · " + weekday.string(from: event.start)
        }
        return text
    }
}

/// Chips laid out left to right, wrapping when the popover's width runs
/// out — SwiftUI's stacks either clip or scroll, neither is a chip row.
private struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 292
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
