import SwiftUI
import AppKit
import EventKit

/// The addon's Settings tab (pattern: `ImageAddonSettingsView`). Shown only
/// while the addon is enabled — the master switch lives in the General tab.
///
/// Access status on top, then per-calendar checkboxes. A checkbox controls
/// EVERYTHING: the inventory in the tool descriptions, reads, and the write
/// resolver — an unchecked calendar simply does not exist for the assistant.
struct CalendarSettingsView: View {
    @ObservedObject private var settings = CalendarSettings.shared

    // Snapshots refreshed on appear and after TCC changes — EKCalendar is
    // not observable, so the view owns plain arrays.
    @State private var eventCalendars: [EKCalendar] = []
    @State private var reminderLists: [EKCalendar] = []
    @State private var eventStatus: EKAuthorizationStatus = .notDetermined
    @State private var reminderStatus: EKAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            introSection
            accessSection
            if eventStatus == .fullAccess {
                calendarsSection
            }
            if reminderStatus == .fullAccess {
                remindersSection
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            refresh()
        }
    }

    private func refresh() {
        let addon = CalendarAddon.shared
        eventStatus = addon.eventAccessStatus
        reminderStatus = addon.reminderAccessStatus
        eventCalendars = addon.allEventCalendars()
        reminderLists = addon.allReminderLists()
    }

    // MARK: - Sections

    private var introSection: some View {
        Section {
            Text(CAL("cal.footer"))
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accessSection: some View {
        Section(CAL("cal.access.header")) {
            accessRow(CAL("cal.access.events"), status: eventStatus, pane: "Privacy_Calendars")
            accessRow(CAL("cal.access.reminders"), status: reminderStatus, pane: "Privacy_Reminders")
        }
    }

    private func accessRow(_ title: String, status: EKAuthorizationStatus, pane: String) -> some View {
        HStack {
            Image(systemName: status == .fullAccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(status == .fullAccess ? .green : .orange)
            Text(title)
            Spacer()
            switch status {
            case .fullAccess:
                Text(CAL("cal.access.granted"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            case .notDetermined:
                Button(CAL("cal.access.request")) {
                    Task { @MainActor in
                        await CalendarAddon.shared.requestAccessIfNeeded()
                        refresh()
                    }
                }
            default:
                Button(CAL("cal.access.open")) {
                    openPrivacyPane(pane)
                }
            }
        }
    }

    private var calendarsSection: some View {
        Section {
            // Default write target: overrides Calendar.app's default without
            // touching system settings (the model sees it as "(default)").
            if !eventCalendars.isEmpty {
                Picker(CAL("cal.default.picker"), selection: Binding(
                    get: {
                        eventCalendars.first(where: { settings.isDefaultOverride($0) })?
                            .calendarIdentifier ?? "system"
                    },
                    set: { id in
                        settings.setDefaultOverride(
                            eventCalendars.first { $0.calendarIdentifier == id }
                        )
                    }
                )) {
                    Text(CAL("cal.default.system")).tag("system")
                    ForEach(eventCalendars.filter(\.allowsContentModifications),
                            id: \.calendarIdentifier) { calendar in
                        Text("\(calendar.title) — \(calendar.source?.title ?? "")")
                            .tag(calendar.calendarIdentifier)
                    }
                }
                // Where this list comes from: everything rides on the macOS
                // Calendar database — accounts, calendars, and the "system
                // default" are all managed in Calendar.app, not here.
                VStack(alignment: .leading, spacing: 5) {
                    Text(CAL("cal.source.caption"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(CAL("cal.source.openApp")) {
                        openCalendarApp()
                    }
                    .font(.caption)
                }
            }
            if eventCalendars.isEmpty {
                Text(CAL("cal.none"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(eventCalendars, id: \.calendarIdentifier) { calendar in
                    calendarRow(calendar, isDefault: calendar == CalendarAddon.shared.defaultEventCalendar)
                }
            }
        } header: {
            Text(CAL("cal.calendars.header"))
        } footer: {
            Text(CAL("cal.visible.caption"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var remindersSection: some View {
        Section(CAL("cal.reminders.header")) {
            if reminderLists.isEmpty {
                Text(CAL("cal.none"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(reminderLists, id: \.calendarIdentifier) { list in
                    calendarRow(list, isDefault: list == CalendarAddon.shared.defaultReminderList)
                }
            }
        }
    }

    private func calendarRow(_ calendar: EKCalendar, isDefault: Bool) -> some View {
        Toggle(isOn: Binding(
            get: { !settings.isExcluded(calendar) },
            set: { settings.setExcluded(!$0, calendar: calendar) }
        )) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(cgColor: calendar.cgColor ?? NSColor.systemBlue.cgColor))
                    .frame(width: 9, height: 9)
                Text(calendar.title)
                if let source = calendar.source?.title, !source.isEmpty {
                    Text(source)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if isDefault {
                    badge(CAL("cal.badge.default"))
                }
                if !calendar.allowsContentModifications {
                    badge(CAL("cal.badge.readonly"))
                }
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            .foregroundColor(.secondary)
    }

    private func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openCalendarApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// Master switch for the General tab (pattern: `ImageAddonEnableToggle`).
/// Flipping it ON requests calendar/reminder access right away — the TCC
/// dialog must appear at this predictable moment, never mid-chat.
struct CalendarEnableToggle: View {
    @ObservedObject private var settings = CalendarSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(CAL("cal.general.enable"), isOn: $settings.enabled)
                .onChange(of: settings.enabled) { _, enabled in
                    if enabled {
                        Task { @MainActor in
                            await CalendarAddon.shared.requestAccessIfNeeded()
                        }
                    }
                }
            Text(CAL("cal.general.enable.caption"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
