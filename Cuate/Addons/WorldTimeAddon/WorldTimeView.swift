import SwiftUI
import AppKit
import Combine
import EventKit

/// The World Time panel: a timezone comparison grid rendered in
/// the app's liquid-glass idiom ("glass band" style). Columns are the 24
/// hours of the selected day in the HOME zone; every row shows what those
/// same instants read as in that city — one vertical slice is one moment
/// everywhere.
///
/// Presented as a Spotlight-like floating panel (borderless, glass), see
/// `AppDelegate.toggleWorldTimePanel`.
struct WorldTimeView: View {
    @ObservedObject private var settings = WorldTimeSettings.shared
    // Re-renders the panel on interface-language changes (the L() pattern:
    // views observe AppSettings.language, `Localization` itself is static).
    // Also drives live theme switches: `wt` re-resolves on settings.theme.
    @ObservedObject private var appSettings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme

    /// The chat palette (panel surface, font design) and the World Time
    /// tokens (day ramp, frames). A separate window, so both are read
    /// straight from settings — the dictation-pill pattern, not the chat's
    /// environment injection.
    private var palette: ThemePalette {
        ThemePalette.palette(for: appSettings.theme, scheme: colorScheme)
    }
    private var wt: WorldTimeTheme {
        WorldTimeTheme.tokens(for: appSettings.theme, scheme: colorScheme)
    }

    /// Midnight of the selected day in the home zone.
    @State private var dayStart: Date = .now
    @State private var selectedColumn: Int? = nil
    @State private var hoverColumn: Int? = nil
    @State private var draggingRow: UUID? = nil
    @State private var dragTranslation: CGFloat = 0
    @State private var now: Date = .now
    @State private var searchText = ""
    @State private var searchResults: [WorldTimeCity] = []
    /// Keyboard selection in the search results (↓/↑ move it, Enter adds).
    @State private var highlightIndex = 0
    @State private var showDatePicker = false
    @State private var busyBlocks: [BusyBlock] = []
    @State private var hoveredBusyID: String? = nil

    /// A half-hour slot inside the selected column: which row's cell shows
    /// the split, and which half (:00 / :30) is hovered or being composed.
    private struct SlotRef: Equatable {
        let zoneID: String
        let column: Int
        let half: Int
    }
    @State private var hoverSlot: SlotRef? = nil
    @State private var composerSlot: SlotRef? = nil

    /// The clock, alive only while the panel is on screen: the window lives
    /// for the whole app run and is merely ordered in/out, so an always-on
    /// timer kept re-rendering the grid and running a synchronous EventKit
    /// query twice a minute for a window nobody could see.
    ///
    /// A plain Foundation timer feeds this subject rather than
    /// `Timer.publish` driving the view directly: a `TimerPublisher` is
    /// one-shot — once its connection is cancelled it never emits again, even
    /// after a fresh `connect()` (measured) — so it cannot model show/hide
    /// cycles. The subject stays put as the view's stable publisher.
    private let ticks = PassthroughSubject<Date, Never>()
    @State private var ticker: Timer? = nil
    /// Mirrors `WorldTimeSettings.panelIsOnScreen` — gates the clock and the
    /// calendar-change refreshes. Every summon rebuilds state from scratch,
    /// so nothing is lost by standing still while hidden.
    @State private var isOnScreen = false

    /// Width of the row-header column; keeps hour columns aligned across rows.
    private static let headerWidth: CGFloat = 250
    private static let rowHeight: CGFloat = 46
    private static let rowSpacing: CGFloat = 8

    var body: some View {
        // A single glass surface for the whole panel (pattern: ChatWindow).
        AdaptiveGlassContainer(spacing: 24) {
            VStack(spacing: 10) {
                DragHandle()
                    .frame(height: 16)
                    .accessibilityHidden(true)
                // The measured block: everything with intrinsic height. Its
                // ideal height drives the window's auto-fit (AppDelegate).
                VStack(spacing: 10) {
                    // The date strip shares a row with the search field (the
                    // row's right edge holds the calendar controls, links and gear).
                    topBar
                    if !busyBlocks.isEmpty {
                        busyLane
                    }
                    grid
                }
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                    }
                )
                .onPreferenceChange(ContentHeightKey.self) { height in
                    NotificationCenter.default.post(
                        name: .worldTimeContentHeight, object: nil,
                        userInfo: ["height": height]
                    )
                }
                // Everything below the rows is a window-drag area, like the
                // strip at the top (`isMovableByWindowBackground` is off —
                // it fought the row-reorder gesture).
                DragHandle()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minHeight: 0)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
            .padding(.top, 4)
            .frame(minWidth: 1000)
            // Same surface stack as the chat panel (glass stays resident on
            // macOS 26 — never branch around it). Decorations run in their
            // calmer .worldTime variant (mockup: on Yule/Aurora/Café the time
            // panel carries its own elements along the edges; the older
            // holiday themes keep the board clean). Blueprint's grid fades out
            // where the data field begins (variant A "clean field"): full on
            // the row-header column and the top bar, gone over the hours.
            .themedPanelSurface(palette, cornerRadius: 18,
                                decorationContext: .worldTime,
                                patternMask: PatternFadeMask(solidWidth: Self.headerWidth,
                                                             fadeWidth: 60,
                                                             solidHeight: 80,
                                                             fadeHeight: 30))
        }
        // Terminal → monospaced, Pastel → rounded (the chat panel's rule).
        .fontDesign(palette.fontDesign)
        .onAppear {
            resetToNow()
            setOnScreen(WorldTimeSettings.panelIsOnScreen)
        }
        .onDisappear { setOnScreen(false) }
        .onReceive(NotificationCenter.default.publisher(for: .worldTimeDidSummon)) { _ in
            resetToNow()
            setOnScreen(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .worldTimeDidHide)) { _ in
            setOnScreen(false)
        }
        .onReceive(ticks) { tick in
            // A pinned panel can sit open across midnight: if it was showing
            // "today", follow the calendar over. A day the user deliberately
            // browsed to stays put.
            let wasToday = homeCalendar.isDate(dayStart, inSameDayAs: now)
            now = tick
            if wasToday, !homeCalendar.isDate(dayStart, inSameDayAs: now) {
                dayStart = homeCalendar.startOfDay(for: now)
                selectedColumn = nowColumn ?? 12
            }
            refreshBusy() // events change while the panel sits open
        }
        .onChange(of: settings.homeZoneID) { _, _ in
            // Re-anchor the day to the new reference zone's midnight.
            dayStart = homeCalendar.startOfDay(for: dayStart.addingTimeInterval(12 * 3600))
        }
        .onChange(of: dayStart) { _, _ in refreshBusy() }
        // Calendar changes are picked up on the next summon when hidden —
        // `resetToNow` re-reads the day anyway.
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            if isOnScreen { refreshBusy() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .calendarAddonDidChange)) { _ in
            if isOnScreen { refreshBusy() }
        }
    }

    // MARK: - Zones & calendars

    private var homeZone: TimeZone {
        TimeZone(identifier: settings.homeZoneID) ?? .current
    }

    private var homeCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = homeZone
        return cal
    }

    /// The instant a grid column represents. `byAdding:.hour` keeps DST days
    /// honest (a 23/25-hour day still yields correct wall-clock instants).
    private func instant(forColumn index: Int) -> Date {
        homeCalendar.date(byAdding: .hour, value: index, to: dayStart) ?? dayStart
    }

    /// Half-hour slot creation is offered only with the CalendarAddon on,
    /// event access granted, and a writable calendar to land in — otherwise
    /// the grid stays a pure clock.
    private var slotCreationAvailable: Bool {
        CalendarSettings.shared.enabled
            && CalendarAddon.shared.hasEventAccess
            && CalendarAddon.shared.defaultEventCalendar != nil
    }

    /// Column of "right now", when the selected day contains it.
    private var nowColumn: Int? {
        guard let end = homeCalendar.date(byAdding: .day, value: 1, to: dayStart),
              now >= dayStart, now < end else { return nil }
        return homeCalendar.dateComponents([.hour], from: dayStart, to: now).hour
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            // Close on the LEFT — the macOS window convention.
            Button {
                NotificationCenter.default.post(name: .closeWorldTimeWindow, object: nil)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(wt.isGlass ? AnyShapeStyle(.secondary) : AnyShapeStyle(wt.secondary))
            }
            .buttonStyle(.borderless)
            .help("Esc")
            // Next to close, because both are window controls: the panel now
            // dismisses itself on focus loss like the chat panel, and this is
            // the opt-out for keeping it parked while you work elsewhere.
            Button {
                settings.pinned.toggle()
            } label: {
                Image(systemName: settings.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 13))
                    .foregroundStyle(
                        settings.pinned
                            ? AnyShapeStyle(wt.link)
                            : (wt.isGlass ? AnyShapeStyle(.secondary) : AnyShapeStyle(wt.secondary))
                    )
            }
            .buttonStyle(.borderless)
            .help(WTL(settings.pinned ? "wt.unpin" : "wt.pin"))
            searchField
            dateStrip
                .padding(.leading, 4)
            Spacer()
            // Jump to the Apple Calendar app — the created slots live there.
            // A text link, not an icon.
            Button {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                }
            } label: {
                Text(WTL("wt.openCalendar"))
                    .font(.system(size: 11, weight: .medium))
                    .underline()
                    .foregroundStyle(wt.link)
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            formatToggle
            // Straight to this panel's own settings tab — zones and working
            // hours were only reachable through the status-bar menu.
            // Themed, unlike the chat panel's grey one: this panel dresses
            // every control in the active theme's ink, and a grey gear was the
            // one element standing outside it. (The "esc closes" caption used
            // to live here — the ✕ in the corner says the same thing.)
            SettingsGearButton(
                tab: .worldTime,
                color: wt.isGlass ? .secondary : wt.link,
                size: 13,
                help: WTL("wt.settingsHelp")
            )
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(wt.isGlass ? AnyShapeStyle(.secondary) : AnyShapeStyle(wt.secondary))
            TextField(WTL("wt.search.placeholder"), text: $searchText)
                .textFieldStyle(.plain)
                .frame(width: 230)
                // Type, arrow down, Enter — without leaving the keyboard.
                // The arrows would otherwise just walk the caret through the
                // text, which in a field holding a city name is useless.
                .onKeyPress(.downArrow) { moveHighlight(by: 1); return .handled }
                .onKeyPress(.upArrow) { moveHighlight(by: -1); return .handled }
                .onSubmit {
                    if searchResults.indices.contains(highlightIndex) {
                        add(searchResults[highlightIndex])
                    }
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(wt.capsule, in: Capsule())
        .onChange(of: searchText) { _, text in
            searchResults = WorldTimeCatalog.search(text)
            highlightIndex = 0 // a new query starts from the top again
        }
        .popover(isPresented: Binding(
            get: { !searchText.isEmpty },
            set: { if !$0 { searchText = "" } }
        ), arrowEdge: .bottom) {
            searchResultsList
        }
    }

    private var searchResultsList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if searchResults.isEmpty {
                Text(WTL("wt.search.noResults"))
                    .foregroundStyle(.secondary)
                    .padding(8)
            } else {
                // Index-keyed: an aliased city carries the SAME zone id as its
                // host (San Francisco and Los Angeles are both
                // America/Los_Angeles), and two rows sharing an identity make
                // a ForEach drop one of them.
                ForEach(Array(searchResults.enumerated()), id: \.offset) { index, city in
                    Button {
                        add(city)
                    } label: {
                        HStack {
                            Text(city.name)
                            // For an alias, name the zone it actually rides on
                            // — otherwise picking "San Francisco" and getting a
                            // row labelled "Los Angeles" looks like a bug.
                            if let host = city.aliasOf {
                                Text(host).foregroundStyle(.secondary)
                            } else if !city.country.isEmpty {
                                Text(city.country).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(offsetLabel(for: city.zoneID) ?? "")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(index == highlightIndex
                                  ? (wt.isGlass ? Color.primary.opacity(0.10) : wt.link.opacity(0.16))
                                  : .clear)
                    )
                }
            }
        }
        .padding(6)
        .frame(width: 300)
    }

    private func add(_ city: WorldTimeCity) {
        // An aliased pick stores its alias key, so the row carries the name the
        // user searched for. Two rows on one zone are allowed on purpose: the
        // user decides whether San Francisco next to Los Angeles is redundant.
        settings.addRow(zoneID: city.zoneID, alias: city.aliasOf == nil ? nil : city.aliasKey)
        searchText = ""
        searchResults = []
    }

    /// Moves the keyboard highlight through the results, stopping at the ends
    /// rather than wrapping — wrapping past the last hit reads as a glitch.
    private func moveHighlight(by delta: Int) {
        guard !searchResults.isEmpty else { return }
        highlightIndex = min(max(highlightIndex + delta, 0), searchResults.count - 1)
    }

    /// 12/24-hour segmented toggle. The glass theme keeps the system
    /// segmented picker; themed panels get a matching capsule pair — the
    /// system control's material look is alien on a themed background.
    @ViewBuilder
    private var formatToggle: some View {
        if wt.isGlass {
            Picker("", selection: Binding(
                get: { settings.uses24Hour },
                set: { settings.timeFormat = $0 ? .h24 : .h12 }
            )) {
                Text(verbatim: "AM/PM").tag(false)
                Text(verbatim: "24").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } else {
            HStack(spacing: 0) {
                themedSegment("AM/PM", is24: false)
                themedSegment("24", is24: true)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(wt.sep, lineWidth: 1))
        }
    }

    private func themedSegment(_ label: String, is24: Bool) -> some View {
        let active = settings.uses24Hour == is24
        return Button {
            settings.timeFormat = is24 ? .h24 : .h12
        } label: {
            Text(verbatim: label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(active ? wt.text : wt.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(active ? wt.chip : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Busy lane (CalendarAddon integration)

    /// One event from the user's visible calendars, clipped to the shown day.
    private struct BusyBlock: Identifiable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let color: Color
    }

    /// Reads the selected day's events from the calendars the CalendarAddon
    /// is allowed to see. Empty (lane hidden) when the addon is off, access
    /// is missing, or the day is free. All-day events are skipped — they'd
    /// paint the whole lane and say nothing about meeting slots.
    private func refreshBusy() {
        guard CalendarSettings.shared.enabled, CalendarAddon.shared.hasEventAccess else {
            if !busyBlocks.isEmpty { busyBlocks = [] }
            return
        }
        let dayEnd = instant(forColumn: 24)
        let calendars = CalendarAddon.shared.visibleEventCalendars()
        guard !calendars.isEmpty else {
            if !busyBlocks.isEmpty { busyBlocks = [] }
            return
        }
        let store = CalendarAddon.shared.store
        let predicate = store.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: calendars)
        busyBlocks = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .compactMap { event -> BusyBlock? in
                guard let start = event.startDate, let end = event.endDate, end > start,
                      end > dayStart, start < dayEnd else { return nil }
                // Recurring events share an identifier — the occurrence date
                // keeps ForEach ids unique.
                let id = (event.eventIdentifier ?? UUID().uuidString) + "@\(start.timeIntervalSince1970)"
                let color = event.calendar.flatMap { cal in
                    cal.cgColor.map { Color(cgColor: $0) }
                } ?? Color.red
                return BusyBlock(id: id,
                                 title: event.title ?? "",
                                 start: max(start, dayStart),
                                 end: min(end, dayEnd),
                                 color: color)
            }
            .sorted { $0.start < $1.start }
    }

    /// The thin busy track above the grid, aligned with the hour columns.
    /// Blocks are exact intervals (not snapped to hours), tinted with the
    /// calendar's own color. Hover grows the block and reveals the title.
    private var busyLane: some View {
        HStack(spacing: 0) {
            Text(WTL("wt.busy.caption"))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(wt.isGlass ? AnyShapeStyle(.tertiary) : AnyShapeStyle(wt.secondary.opacity(0.7)))
                .frame(width: Self.headerWidth - 12, alignment: .trailing)
                .padding(.trailing, 12)
            GeometryReader { geo in
                let total = instant(forColumn: 24).timeIntervalSince(dayStart)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(wt.rail)
                        .frame(height: 3)
                    ForEach(busyBlocks) { block in
                        let x = geo.size.width * block.start.timeIntervalSince(dayStart) / total
                        let width = max(6, geo.size.width * block.end.timeIntervalSince(block.start) / total)
                        let hovered = hoveredBusyID == block.id
                        Capsule()
                            .fill(block.color)
                            .frame(width: width, height: hovered ? 12 : 8)
                            // Halo ring in the theme's text color: the block's
                            // fill is the CALENDAR's color (data — never
                            // re-tinted), so on same-hued themes (blue on
                            // Blueprint, green on Terminal) the ring is what
                            // keeps it visible.
                            .overlay {
                                if !wt.isGlass {
                                    Capsule().stroke(wt.text.opacity(0.55), lineWidth: 1)
                                }
                            }
                            .shadow(color: .black.opacity(hovered ? 0.3 : 0.15), radius: hovered ? 3 : 1, y: 1)
                            .offset(x: x)
                            .onHover { hoveredBusyID = $0 ? block.id : (hoveredBusyID == block.id ? nil : hoveredBusyID) }
                    }
                    // Floating label of the hovered block — its own capsule,
                    // NOT clipped to the block's width (a 30-minute meeting
                    // is a sliver, its name is not). Clamped into the lane.
                    if let block = busyBlocks.first(where: { $0.id == hoveredBusyID }) {
                        let startX = geo.size.width * block.start.timeIntervalSince(dayStart) / total
                        let width = max(6, geo.size.width * block.end.timeIntervalSince(block.start) / total)
                        let center = min(max(startX + width / 2, 90), geo.size.width - 90)
                        // Title capped in code (SwiftUI can't hug-and-cap in
                        // one frame): ~40 chars covers a lane-sized capsule.
                        let title = block.title.isEmpty ? "•" : String(block.title.prefix(40))
                            + (block.title.count > 40 ? "…" : "")
                        Text("\(title) · \(timeRangeLabel(block))")
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().stroke(block.color, lineWidth: 1))
                            .position(x: center, y: -13)
                            .zIndex(2)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.12), value: hoveredBusyID)
    }

    /// "14:30–15:30" in home-zone wall time (the lane lives on the home axis).
    private func timeRangeLabel(_ block: BusyBlock) -> String {
        let fmt = cachedFormatter(settings.uses24Hour ? "H:mm" : "h:mm a", zone: homeZone)
        return "\(fmt.string(from: block.start))–\(fmt.string(from: block.end))"
    }

    // MARK: - Date strip

    private var dateStrip: some View {
        HStack(spacing: 4) {
            Button {
                showDatePicker = true
            } label: {
                Image(systemName: "calendar")
            }
            .buttonStyle(.borderless)
            .help(WTL("wt.pickDate"))
            .popover(isPresented: $showDatePicker, arrowEdge: .bottom) {
                DatePicker(
                    "",
                    selection: Binding(
                        get: { dayStart },
                        set: { select(day: $0); showDatePicker = false }
                    ),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .environment(\.timeZone, homeZone)
                .labelsHidden()
                .padding(8)
            }

            ForEach(stripDays, id: \.self) { day in
                stripButton(for: day)
            }

            if nowColumn == nil {
                Button(WTL("wt.today")) {
                    select(day: .now)
                    selectedColumn = nowColumn
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .tint(wt.isGlass ? nil : wt.link)
            }
        }
    }

    /// A week of tabs around today (yesterday .. +5 days).
    private var stripDays: [Date] {
        let todayStart = homeCalendar.startOfDay(for: now)
        let anchor = homeCalendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
        return (0..<7).compactMap { homeCalendar.date(byAdding: .day, value: $0, to: anchor) }
    }

    private func stripButton(for day: Date) -> some View {
        let isSelected = homeCalendar.isDate(day, inSameDayAs: dayStart)
        let isWeekend = homeCalendar.isDateInWeekend(day)
        let fmt = cachedFormatter(isSelected ? "MMMd" : "d", zone: homeZone)
        return Button {
            select(day: day)
        } label: {
            Text(fmt.string(from: day))
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? wt.text : (isWeekend ? wt.weekend : wt.secondary))
                .padding(.horizontal, isSelected ? 10 : 7)
                .padding(.vertical, 4)
                .background {
                    if isSelected {
                        Capsule().fill(wt.daySel)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private func select(day: Date) {
        dayStart = homeCalendar.startOfDay(for: day)
    }

    /// Starts or stops the 30s clock with the panel's visibility. Idempotent —
    /// summon fires both `onAppear` (first render) and the notification.
    private func setOnScreen(_ visible: Bool) {
        isOnScreen = visible
        ticker?.invalidate() // never leave one scheduled on the run loop
        ticker = nil
        guard visible else { return }
        let ticks = self.ticks
        let timer = Timer(timeInterval: 30, repeats: true) { _ in ticks.send(Date()) }
        // Slack lets macOS coalesce the wake-up with other work — invisible on
        // a clock this coarse, and the point of the exercise is energy.
        timer.tolerance = 5
        // `.common` so the clock keeps running through menu tracking and live
        // resize, as it did before.
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    /// Brings the panel back to the present: today in the home zone, the
    /// current hour highlighted, transient UI (date popover, slot composer,
    /// search) dropped. Runs on first appearance and on every summon.
    private func resetToNow() {
        now = .now
        dayStart = homeCalendar.startOfDay(for: now)
        selectedColumn = nowColumn ?? 12
        hoverColumn = nil
        hoverSlot = nil
        composerSlot = nil
        showDatePicker = false
        searchText = ""
        searchResults = []
        refreshBusy()
    }

    // MARK: - Grid

    private var grid: some View {
        Group {
            if settings.rows.isEmpty {
                VStack {
                    Spacer()
                    Text(WTL("wt.empty"))
                        .foregroundStyle(wt.isGlass ? AnyShapeStyle(.secondary) : AnyShapeStyle(wt.secondary))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                // No ScrollView: the grid takes exactly its content height
                // (a flexible sibling below it was stealing half the space
                // and forcing a scrollbar). The panel window resizes instead.
                VStack(spacing: Self.rowSpacing) {
                    ForEach(settings.rows) { row in
                        cityRow(row)
                    }
                }
                // The column frame: one rectangle through ALL rows,
                // following the hover and marking the selection.
                .overlay { columnFrames }
                .padding(.vertical, 4)
                .onHover { if !$0 { hoverColumn = nil } }
            }
        }
    }

    /// Hover + selection frames spanning the full grid height (the black
    /// column outline). Drawn once over the rows so the gaps between
    /// bands are framed too. Hovering a busy block projects its exact
    /// interval down through every row the same way.
    private var columnFrames: some View {
        GeometryReader { geo in
            let bandWidth = geo.size.width - Self.headerWidth
            let cellWidth = bandWidth / 24
            if let block = busyBlocks.first(where: { $0.id == hoveredBusyID }) {
                let total = instant(forColumn: 24).timeIntervalSince(dayStart)
                let x = Self.headerWidth + bandWidth * block.start.timeIntervalSince(dayStart) / total
                let width = max(4, bandWidth * block.end.timeIntervalSince(block.start) / total)
                RoundedRectangle(cornerRadius: 6)
                    .fill(block.color.opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(block.color.opacity(0.75), lineWidth: 1.5)
                    )
                    // Same halo story as the lane blocks: the projection is
                    // drawn in the calendar's color, so themed panels get a
                    // text-colored glow to lift it off a same-hued ramp.
                    .shadow(color: wt.isGlass ? .clear : wt.text.opacity(0.45), radius: 2)
                    .frame(width: width, height: geo.size.height + 6)
                    .position(x: x + width / 2, y: geo.size.height / 2)
            }
            if let hover = hoverColumn, hover != selectedColumn {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(wt.hoverStroke, style: StrokeStyle(lineWidth: 1.2, dash: wt.selDash))
                    .frame(width: cellWidth + 4, height: geo.size.height + 6)
                    .position(x: Self.headerWidth + cellWidth * (CGFloat(hover) + 0.5),
                              y: geo.size.height / 2)
            }
            if let sel = selectedColumn {
                RoundedRectangle(cornerRadius: 9)
                    .fill(wt.selFill)
                    .frame(width: cellWidth + 4, height: geo.size.height + 6)
                    .position(x: Self.headerWidth + cellWidth * (CGFloat(sel) + 0.5),
                              y: geo.size.height / 2)
                // Blueprint's frame is dashed [4,3] (its bubble-stroke
                // signature); Terminal/Synthwave/Halloween/Día dark add a
                // neon glow around it.
                RoundedRectangle(cornerRadius: 9)
                    .stroke(wt.selStroke, style: StrokeStyle(lineWidth: 2, dash: wt.selDash))
                    .frame(width: cellWidth + 4, height: geo.size.height + 6)
                    .position(x: Self.headerWidth + cellWidth * (CGFloat(sel) + 0.5),
                              y: geo.size.height / 2)
                    .shadow(color: wt.selGlow ?? .clear, radius: wt.selGlow == nil ? 0 : 6)
                // (No half-hour divider: the two hoverable halves already show
                // where the hour splits, and a dashed rule down the full
                // column was one line too many over an otherwise calm grid.)
            }
        }
        .allowsHitTesting(false)
    }

    /// Vertical distance from one row's top to the next.
    private var rowStride: CGFloat { Self.rowHeight + Self.rowSpacing }

    /// Live offset of a row while another row is being dragged over it:
    /// the dragged row follows the cursor, its neighbors slide out of the
    /// way by exactly one stride.
    private func rowOffset(for rowID: UUID) -> CGFloat {
        guard let dragging = draggingRow,
              let from = settings.rows.firstIndex(where: { $0.id == dragging }),
              let index = settings.rows.firstIndex(where: { $0.id == rowID }) else { return 0 }
        if rowID == dragging { return dragTranslation }
        let shift = Int((dragTranslation / rowStride).rounded())
        let to = max(0, min(settings.rows.count - 1, from + shift))
        if from < to, index > from, index <= to { return -rowStride }
        if to < from, index >= to, index < from { return rowStride }
        return 0
    }

    private func finishRowDrag() {
        defer {
            draggingRow = nil
            dragTranslation = 0
        }
        guard let dragging = draggingRow,
              let from = settings.rows.firstIndex(where: { $0.id == dragging }) else { return }
        let shift = Int((dragTranslation / rowStride).rounded())
        let to = max(0, min(settings.rows.count - 1, from + shift))
        guard to != from else { return }
        settings.rows.move(fromOffsets: IndexSet(integer: from),
                           toOffset: to > from ? to + 1 : to)
    }

    private func cityRow(_ row: WorldTimeRow) -> some View {
        let zone = TimeZone(identifier: row.zoneID) ?? .current
        let isHome = row.id == settings.homeRowID
        let isDragging = draggingRow == row.id
        return HStack(spacing: 0) {
            rowHeader(row: row, zone: zone, isHome: isHome)
                .frame(width: Self.headerWidth, alignment: .leading)
                .contentShape(Rectangle())
                // Rows are dragged by their header — a manual
                // DragGesture, not system drag-and-drop: the NSItemProvider
                // route never delivers dropEntered reliably on macOS here.
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            draggingRow = row.id
                            dragTranslation = value.translation.height
                        }
                        .onEnded { _ in finishRowDrag() }
                )
                // Double-click the header = make this the home city (the
                // context menu has the same action for discoverability).
                .onTapGesture(count: 2) { settings.homeRowID = row.id }
            hourBand(zone: zone)
        }
        .frame(height: Self.rowHeight)
        .opacity(isDragging ? 0.75 : 1)
        .offset(y: rowOffset(for: row.id))
        .zIndex(isDragging ? 2 : 0)
        // The dragged row tracks the cursor raw; its neighbors animate as
        // they make room.
        .animation(isDragging ? nil : .easeInOut(duration: 0.14), value: rowOffset(for: row.id))
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                settings.homeRowID = row.id
            } label: {
                Label(WTL("wt.row.setHome"), systemImage: "house")
            }
            .disabled(isHome)
            Divider()
            Button(role: .destructive) {
                settings.removeRow(row.id)
            } label: {
                Label(WTL("wt.row.remove"), systemImage: "trash")
            }
        }
    }

    // MARK: - Row header

    private func rowHeader(row: WorldTimeRow, zone: TimeZone, isHome: Bool) -> some View {
        let zoneID = row.zoneID
        let city = WorldTimeCatalog.city(for: zoneID)
        // The row is labelled with the city the user actually picked: someone
        // who looked up San Francisco gets "San Francisco", not the zone's
        // exemplar "Los Angeles".
        let title = row.alias.map { WorldTimeCatalog.aliasDisplayName($0) } ?? city.name
        // No hover buttons on the left edge — home/remove live in the
        // right-click menu (and double-click sets home), so the header
        // starts right at the offset column.
        return HStack(spacing: 8) {
            // Offset from home (or the home marker itself).
            Group {
                if isHome {
                    Image(systemName: "house.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(wt.isGlass ? AnyShapeStyle(.secondary) : AnyShapeStyle(wt.secondary))
                } else {
                    Text(offsetLabel(for: zoneID) ?? "")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(wt.isGlass ? AnyShapeStyle(.secondary) : AnyShapeStyle(wt.secondary))
                }
            }
            .frame(width: 36, alignment: .trailing)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    // The name wins the space fight — the clock and badge
                    // compress before "Москва" becomes "Мос…".
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(wt.isGlass ? AnyShapeStyle(.primary) : AnyShapeStyle(wt.text))
                        .lineLimit(1)
                        .layoutPriority(2)
                    if let abbr = zone.abbreviation(for: instant(forColumn: selectedColumn ?? 12)) {
                        Text(abbr)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(wt.chip))
                            .foregroundStyle(wt.isGlass ? AnyShapeStyle(.secondary) : AnyShapeStyle(wt.secondary))
                    }
                }
                if !city.country.isEmpty {
                    Text(city.country)
                        .font(.caption2)
                        .foregroundStyle(wt.isGlass ? AnyShapeStyle(.secondary) : AnyShapeStyle(wt.secondary))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            // Live wall clock of that city (ticks every 30 s).
            VStack(alignment: .trailing, spacing: 1) {
                Text(cachedFormatter(settings.uses24Hour ? "H:mm" : "h:mm a", zone: zone).string(from: now))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(wt.isGlass ? AnyShapeStyle(.primary) : AnyShapeStyle(wt.text))
                    .monospacedDigit()
                Text(cachedFormatter("EEE, MMM d", zone: zone).string(from: now))
                    .font(.caption2)
                    .foregroundStyle(wt.isGlass ? AnyShapeStyle(.secondary) : AnyShapeStyle(wt.secondary))
            }
            .padding(.trailing, 10)
        }
    }

    /// "+7" / "−3.5" — the zone's offset relative to home at the selected
    /// instant (so DST transitions show the offset that actually applies).
    private func offsetLabel(for zoneID: String) -> String? {
        guard let zone = TimeZone(identifier: zoneID) else { return nil }
        let at = instant(forColumn: selectedColumn ?? 12)
        let seconds = zone.secondsFromGMT(for: at) - homeZone.secondsFromGMT(for: at)
        if seconds == 0 { return "0" }
        let hours = Double(seconds) / 3600
        let text = hours == hours.rounded()
            ? String(Int(abs(hours)))
            : String(format: "%.1f", abs(hours))
        return (seconds > 0 ? "+" : "−") + text
    }

    // MARK: - Hour band (the "glass band" of variant B)

    /// One continuous capsule per city: 24 cells with no gaps, translucent
    /// period tints, hairline separators. Rounded only at the band's ends.
    private func hourBand(zone: TimeZone) -> some View {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return HStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { index in
                hourCell(index: index, zone: zone, calendar: cal)
                    .frame(maxWidth: .infinity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: wt.bandRadius))
        .overlay(
            RoundedRectangle(cornerRadius: wt.bandRadius)
                .stroke(wt.bandStroke, lineWidth: 0.5)
        )
    }

    private func hourCell(index: Int, zone: TimeZone, calendar: Calendar) -> some View {
        let date = instant(forColumn: index)
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        let hour = comps.hour ?? 0
        let minute = comps.minute ?? 0
        let isMidnight = hour == 0 && minute == 0
        let isNow = nowColumn == index
        let kind = cellKind(hour: hour)
        let onDark = isMidnight || kind == .night

        return VStack(spacing: 0) {
            if isMidnight {
                // Local midnight: the date chip, three stacked levels —
                // weekday / day number / month ("ПТ / 24 / ИЮЛ") — same
                // width as an hour cell so columns stay aligned.
                Text(cachedFormatter("EEE", zone: zone).string(from: date).uppercased())
                    .font(.system(size: 7.5, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(cachedFormatter("d", zone: zone).string(from: date))
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
                    .lineLimit(1)
                // Russian "июл." keeps its abbreviation dot — drop it, the
                // chip is cramped enough.
                Text(cachedFormatter("MMM", zone: zone).string(from: date)
                    .replacingOccurrences(of: ".", with: "").uppercased())
                    .font(.system(size: 7.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else {
                // Hours only — no minutes (half-hour zones show them, they
                // have to: "9:30"). 12h mode adds the small am/pm.
                let displayHour = settings.uses24Hour ? hour : (hour % 12 == 0 ? 12 : hour % 12)
                Text(minute == 0 ? "\(displayHour)" : String(format: "%d:%02d", displayHour, minute))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                if !settings.uses24Hour {
                    Text(hour < 12 ? "am" : "pm")
                        .font(.system(size: 8))
                        .opacity(0.7)
                }
            }
        }
        .foregroundStyle(onDark ? wt.cellDarkText : (wt.isGlass ? Color.primary : wt.text))
        .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
        .background(cellFill(kind: kind, isMidnight: isMidnight))
        .overlay {
            // Día's signature dotted border around the midnight date chip.
            if isMidnight, let stroke = wt.midnightStroke {
                Rectangle()
                    .strokeBorder(stroke, style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
            }
        }
        .overlay(alignment: .leading) {
            // Hairline separator between cells inside the band.
            if index > 0 {
                Rectangle()
                    .fill(wt.isGlass ? Color.white.opacity(0.22) : wt.sep)
                    .frame(width: 0.5)
                    .padding(.vertical, 6)
            }
        }
        .overlay {
            // "Right now" marker: a dashed underline inside the cell (Día:
            // dotted [1,3], the theme's papel-picado rhythm).
            if isNow && !isMidnight {
                VStack {
                    Spacer()
                    Rectangle()
                        .fill(.clear)
                        .frame(height: 1)
                        .overlay(
                            Line()
                                .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: wt.nowDash))
                                .foregroundStyle(wt.isGlass
                                                 ? (onDark ? Color.white.opacity(0.8) : Color.primary.opacity(0.5))
                                                 : wt.now)
                        )
                        .padding(.horizontal, 8)
                        .padding(.bottom, 5)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selectedColumn = index }
        .onHover { hoverColumn = $0 ? index : (hoverColumn == index ? nil : hoverColumn) }
        // Inside the SELECTED column (and only with the CalendarAddon live):
        // each hour offers its :00 and :30 halves; clicking a half opens the
        // slot composer right there.
        .overlay {
            if slotCreationAvailable && selectedColumn == index {
                slotSplitOverlay(zoneID: zone.identifier, column: index)
            }
        }
        .popover(isPresented: Binding(
            get: { composerSlot?.zoneID == zone.identifier && composerSlot?.column == index },
            set: { if !$0 { composerSlot = nil } }
        ), arrowEdge: .bottom) {
            if let slot = composerSlot {
                WorldTimeSlotComposer(
                    slot: instant(forColumn: slot.column).addingTimeInterval(Double(slot.half) * 1800),
                    rowZoneID: slot.zoneID,
                    homeZoneID: settings.homeZoneID,
                    onClose: { composerSlot = nil }
                )
            }
        }
    }

    /// The half-hour picker drawn over a selected-column cell: the hovered
    /// half gently highlighted with a "+" (the dashed divider itself runs
    /// through the whole column — see `columnFrames`).
    private func slotSplitOverlay(zoneID: String, column: Int) -> some View {
        GeometryReader { geo in
            let half = (hoverSlot?.zoneID == zoneID && hoverSlot?.column == column) ? hoverSlot?.half : nil
            ZStack {
                // Full-size base layer: without it an empty ZStack collapses
                // to zero size and the hover region vanishes with it.
                Color.clear
                if let half {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(wt.isGlass ? Color.primary.opacity(0.13) : wt.selFill)
                        .frame(width: geo.size.width / 2 - 3, height: geo.size.height - 6)
                        .position(x: half == 0 ? geo.size.width / 4 : geo.size.width * 3 / 4,
                                  y: geo.size.height / 2)
                    Image(systemName: "plus")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(wt.isGlass ? Color.primary.opacity(0.65) : wt.text.opacity(0.65))
                        .position(x: half == 0 ? geo.size.width / 4 : geo.size.width * 3 / 4,
                                  y: geo.size.height / 2)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { hoverPhase in
                switch hoverPhase {
                case .active(let point):
                    hoverSlot = SlotRef(zoneID: zoneID, column: column,
                                        half: point.x < geo.size.width / 2 ? 0 : 1)
                case .ended:
                    if hoverSlot?.zoneID == zoneID && hoverSlot?.column == column {
                        hoverSlot = nil
                    }
                }
            }
            .onTapGesture {
                guard let slot = hoverSlot, slot.zoneID == zoneID, slot.column == column else { return }
                composerSlot = slot
            }
        }
    }

    /// Cell fill from the theme's day ramp (`current` resolves to the
    /// original hardcoded colors — see WorldTimeTheme).
    @ViewBuilder
    private func cellFill(kind: CellKind, isMidnight: Bool) -> some View {
        if isMidnight {
            wt.midnight
        } else {
            switch kind {
            case .night: wt.night
            case .shoulder: wt.shoulder
            case .work: wt.work
            }
        }
    }

    private enum CellKind { case night, shoulder, work }

    /// Cell coloring: dark night, pale shoulder, light working hours — the
    /// classic day-planner palette translated into glass tints. With working
    /// hours switched off it collapses to two states: the whole daylight band
    /// takes the LIGHT tint and only night stays dark. The point of switching
    /// the band off is to stop caring which hours are office hours — leaving
    /// the shoulder wash on would have kept exactly that distinction on screen.
    private func cellKind(hour: Int) -> CellKind {
        if hour < 6 || hour >= 22 { return .night }
        guard settings.showWorkHours else { return .work }
        if hour >= settings.workStartHour && hour < settings.workEndHour { return .work }
        return .shoulder
    }

    // MARK: - Formatter cache

    /// DateFormatters are expensive; the grid asks for the same few
    /// (template × zone × language) combinations every render.
    private static var formatterCache: [String: DateFormatter] = [:]

    private func cachedFormatter(_ template: String, zone: TimeZone) -> DateFormatter {
        let lang = Localization.currentLanguage.rawValue
        let key = "\(template)|\(zone.identifier)|\(lang)"
        if let cached = Self.formatterCache[key] { return cached }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: lang)
        formatter.timeZone = zone
        if template == "H:mm" || template == "h:mm a" {
            formatter.dateFormat = template // fixed layout, not a template
        } else {
            formatter.setLocalizedDateFormatFromTemplate(template)
        }
        Self.formatterCache[key] = formatter
        return formatter
    }
}

/// Ideal height of the panel's fixed-height content (everything above the
/// window-drag filler) — read by the AppDelegate to auto-fit the window.
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A horizontal line shape (for the dashed "now" underline).
private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}


