import SwiftUI

/// The addon's Settings tab (pattern: `CalendarSettingsView`). Shown only
/// while the addon is enabled — the master switch lives in the General tab.
/// Cities are managed in the World Time window itself; this tab keeps the
/// display options.
struct WorldTimeSettingsView: View {
    @ObservedObject private var settings = WorldTimeSettings.shared
    // Re-renders on interface-language changes (the L() pattern).
    @ObservedObject private var appSettings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Text(WTL("wt.intro"))
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(WTL("wt.open")) {
                    NotificationCenter.default.post(name: .openWorldTimeWindow, object: nil)
                }
            }

            Section(WTL("wt.display.header")) {
                Picker(WTL("wt.format"), selection: $settings.timeFormat) {
                    Text(WTL("wt.format.system")).tag(WorldTimeFormat.system)
                    Text(WTL("wt.format.12")).tag(WorldTimeFormat.h12)
                    Text(WTL("wt.format.24")).tag(WorldTimeFormat.h24)
                }
            }

            Section {
                Toggle(WTL("wt.work.show"), isOn: $settings.showWorkHours)
                // The range only means anything while the band is shown —
                // hidden rather than disabled, so "off" leaves nothing behind.
                if settings.showWorkHours {
                    Picker(WTL("wt.work.start"), selection: $settings.workStartHour) {
                        ForEach(5..<13, id: \.self) { Text(hourLabel($0)).tag($0) }
                    }
                    Picker(WTL("wt.work.end"), selection: $settings.workEndHour) {
                        ForEach(14..<22, id: \.self) { Text(hourLabel($0)).tag($0) }
                    }
                }
            } header: {
                Text(WTL("wt.work.header"))
            } footer: {
                Text(WTL("wt.work.caption"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func hourLabel(_ hour: Int) -> String {
        if settings.uses24Hour {
            return String(format: "%d:00", hour)
        }
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        return "\(h12) \(hour < 12 ? "am" : "pm")"
    }
}

/// Master switch for the General tab (pattern: `CalendarEnableToggle`).
struct WorldTimeEnableToggle: View {
    @ObservedObject private var settings = WorldTimeSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(WTL("wt.general.enable"), isOn: $settings.enabled)
            Text(WTL("wt.general.enable.caption"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
