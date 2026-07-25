import SwiftUI
import Charts

/// Settings → Costs: local spend analytics built from the append-only
/// spend ledger. The daily chart can be sliced by provider or by model;
/// the breakdown groups everything under its provider (models + OCR/STT/
/// search/image services), and the header shows average tokens per chat
/// message split into input/output.
struct CostsSettingsView: View {
    @ObservedObject private var store = SpendStore.shared
    @ObservedObject private var settings = AppSettings.shared // re-render on language change
    @Environment(\.colorScheme) private var colorScheme

    private enum ChartDimension: String, CaseIterable, Identifiable {
        case provider, model
        var id: String { rawValue }
    }
    @State private var chartDimension: ChartDimension = .provider
    /// Provider groups the user collapsed (all expanded by default).
    @State private var collapsedGroups: Set<String> = []
    /// The series the pointer is on — a bar segment or a legend chip. The
    /// chart and the legend dim everything else while it is set.
    @State private var highlight: String?

    var body: some View {
        // Built once per render and handed down: hovering re-renders the whole
        // Form, and re-aggregating the ledger inside every computed property
        // would make the pointer feel sticky.
        let model = chartModel(colorScheme)
        Form {
            summarySection
            if store.selectedMonthRecords.isEmpty {
                Section {
                    Text(L("costs.empty"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                }
            } else {
                dailyChartSection(model)
                modelChartSection(model)
                breakdownSection(model)
            }
            budgetSection
        }
        .formStyle(.grouped)
        .onAppear { store.refresh() }
        .onChange(of: chartDimension) { highlight = nil }
    }

    // MARK: - Summary

    private var summarySection: some View {
        Section(L("costs.header")) {
            LabeledContent(L("costs.session"), value: SpendStore.usd(store.sessionUSD))
                .help(L("costs.sessionHelp"))
            LabeledContent(L("costs.today"), value: SpendStore.usd(store.todayUSD))
                .help(L("costs.todayHelp"))
            LabeledContent(L("costs.month"), value: SpendStore.usd(store.currentMonthUSD))
                .help(L("costs.monthHelp"))
            // Sub-row of "This month": always present, so the metric is
            // discoverable even before the first chat record lands.
            LabeledContent {
                Text(store.currentMonthAvg.map {
                    "\(L("costs.tokensIn")) \(compact($0.input)) · \(L("costs.tokensOut")) \(compact($0.output))"
                } ?? "—")
                .foregroundStyle(.secondary)
            } label: {
                Text(L("costs.avgPerMessage"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 16)
            .help(String(format: L("costs.avgHelp"), store.currentMonthAvg?.count ?? 0))
            if store.monthlyBudgetUSD > 0 {
                ProgressView(
                    value: min(store.currentMonthUSD, store.monthlyBudgetUSD),
                    total: store.monthlyBudgetUSD
                ) {
                    Text("\(SpendStore.usd(store.currentMonthUSD)) / \(SpendStore.usd(store.monthlyBudgetUSD))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tint(store.currentMonthUSD >= store.monthlyBudgetUSD ? .red
                      : store.currentMonthUSD >= store.monthlyBudgetUSD * 0.8 ? .orange : .accentColor)
                .help(L("costs.progressHelp"))
            }
        }
    }

    // MARK: - Month picker + daily chart

    private func dailyChartSection(_ model: ChartModel) -> some View {
        Section(L("costs.dailyChart")) {
            // Month selector lives IN the section body — form section headers
            // render it nearly invisible (small-caps, dimmed, swallows taps).
            HStack {
                Text(L("costs.period"))
                Spacer()
                monthPicker
            }
            Picker("", selection: $chartDimension) {
                Text(L("costs.byProviders")).tag(ChartDimension.provider)
                Text(L("costs.byModels")).tag(ChartDimension.model)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help(L("costs.dimensionHelp"))

            if model.slices.isEmpty {
                Text(L("costs.empty")).foregroundStyle(.secondary)
            } else {
                dailyChart(model)
                legend(model)
            }
        }
    }

    /// Both dimensions share one explicit palette. Segments are placed by hand
    /// (`yStart`/`yEnd` instead of automatic stacking) for two reasons: the
    /// stack order becomes ours — biggest series at the bottom, matching the
    /// legend — and hit-testing a hover is then exact, since every segment
    /// knows the value range it occupies.
    private func dailyChart(_ model: ChartModel) -> some View {
        Chart(model.slices) { slice in
            BarMark(
                x: .value("Day", slice.day, unit: .day),
                yStart: .value("From", slice.start),
                yEnd: .value("To", slice.end)
            )
            .foregroundStyle(by: .value("Series", slice.label))
            .opacity(isLit(slice.label) ? 1 : 0.18)
        }
        .chartForegroundStyleScale(domain: model.order, range: model.order.map { model.color($0) })
        .chartLegend(.hidden)   // replaced by `legend(_:)`, which can be hovered
        .chartXScale(domain: monthDomain)
        .chartXAxis { dayAxisMarks }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let point) = phase,
                              let plot = proxy.plotFrame else { hover(nil); return }
                        let origin = geo[plot].origin
                        guard let date = proxy.value(atX: point.x - origin.x, as: Date.self),
                              let value = proxy.value(atY: point.y - origin.y, as: Double.self)
                        else { hover(nil); return }
                        let day = Calendar.current.startOfDay(for: date)
                        hover(model.slices.first {
                            $0.day == day && value >= $0.start && value <= $0.end
                        }?.label)
                    }
            }
        }
        .frame(height: 180)
        .animation(.easeOut(duration: 0.12), value: highlight)
        .help(L("costs.dailyHelp"))
    }

    /// Hoverable legend. The built-in one can't be hovered, and hovering a
    /// series is exactly how the chart, this legend and the breakdown light up
    /// together — so the legend is drawn by hand.
    private func legend(_ model: ChartModel) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10, alignment: .leading)],
                  alignment: .leading, spacing: 3) {
            ForEach(model.order, id: \.self) { label in
                let lit = isLit(label)
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(model.color(label))
                        .frame(width: 9, height: 9)
                    Text(label)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(highlight != nil && lit ? Color.primary.opacity(0.08) : .clear)
                )
                .opacity(lit ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside { hover(label) } else if highlight == label { highlight = nil }
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: highlight)
    }

    // MARK: - Highlighting

    /// `onContinuousHover` fires on every pointer move and each assignment
    /// re-renders the Form — so only write on a real change.
    private func hover(_ label: String?) {
        if label != highlight { highlight = label }
    }

    private func isLit(_ label: String) -> Bool {
        highlight == nil || highlight == label
    }

    /// Full span of the selected month. Without a fixed domain the chart
    /// shrinks to the days that have data, which collapses the date axis
    /// (no labels at all on sparse months) and makes bar widths jump
    /// between months. Records are already month-filtered by SpendStore,
    /// so this also caps the visible range at exactly one month.
    private var monthDomain: ClosedRange<Date> {
        let start = store.selectedMonth
        let end = Calendar.current.date(byAdding: .month, value: 1, to: start) ?? start
        return start...end
    }

    /// Day-of-month numbers every few days — replaces Swift Charts' default
    /// date axis, which degrades into an hour scale on sparse data. Labels
    /// sit on their gridline (not centered: with a 5-day stride, centering
    /// would shift each label 2.5 days off its date).
    private var dayAxisMarks: some AxisContent {
        AxisMarks(values: .stride(by: .day, count: 5)) { _ in
            AxisGridLine()
            AxisValueLabel(format: .dateTime.day())
        }
    }

    private var monthPicker: some View {
        HStack(spacing: 4) {
            Button { store.stepMonth(by: -1) } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.bordered)
            .disabled(!canStepBack)
            .help(L("costs.prevMonth"))

            Text(monthTitle)
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .frame(minWidth: 110)

            Button { store.stepMonth(by: 1) } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.bordered)
            .disabled(!canStepForward)
            .help(L("costs.nextMonth"))
        }
    }

    // MARK: - Per-model chart

    private func modelChartSection(_ model: ChartModel) -> some View {
        Section(L("costs.byModel")) {
            let top = Array(modelLines.prefix(8))
            if top.isEmpty {
                Text(L("costs.empty")).foregroundStyle(.secondary)
            } else {
                Chart(top) { line in
                    BarMark(
                        x: .value("USD", line.cost),
                        y: .value("Model", line.shortLabel)
                    )
                    // Same color the model (or its provider) carries in the
                    // daily chart above and in the breakdown below.
                    .foregroundStyle(model.color(seriesKey(line.provider, line.model),
                                                 fallback: seriesFallback(line.provider, model)))
                    .annotation(position: .trailing, alignment: .leading) {
                        Text(SpendStore.usd(line.cost))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXAxis(.hidden)
                .frame(height: CGFloat(top.count) * 30 + 16)
                .help(L("costs.byModelHelp"))
            }
        }
    }

    // MARK: - Breakdown (grouped by provider)

    private func breakdownSection(_ model: ChartModel) -> some View {
        Section(L("costs.breakdown")) {
            ForEach(providerGroups) { group in
                DisclosureGroup(isExpanded: expansionBinding(group.id)) {
                    ForEach(group.chatLines) { line in
                        modelRow(line, model)
                    }
                    ForEach(group.serviceLines) { line in
                        LabeledContent {
                            Text(line.cost > 0 ? SpendStore.usd(line.cost) : "—")
                                .foregroundStyle(.secondary)
                        } label: {
                            Text("\(line.label): \(line.detail)")
                                .font(.callout)
                        }
                        .padding(.leading, 14)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(seriesFallback(group.provider, model))
                            .frame(width: 8, height: 8)
                        Text(group.label).fontWeight(.medium)
                        Spacer()
                        Text(SpendStore.usd(group.totalCost))
                            .monospacedDigit()
                    }
                    .help(L("costs.groupHelp"))
                }
            }
            if providerGroups.contains(where: { $0.hasEstimates }) {
                Text("≈ \(L("costs.estimated"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(L("costs.footer"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func modelRow(_ line: ModelLine, _ model: ChartModel) -> some View {
        LabeledContent {
            Text(line.hasPrice ? SpendStore.usd(line.cost) : L("costs.noPrice"))
                .foregroundStyle(line.hasPrice ? .primary : .secondary)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(line.shortLabel + (line.hasEstimates ? " ≈" : ""))
                    .font(.callout)
                Text("\(L("costs.tokensIn")) \(compact(line.usage.inputTokens + line.usage.cacheReadTokens + line.usage.cacheWriteTokens)) · \(L("costs.tokensOut")) \(compact(line.usage.outputTokens)) · \(L("costs.cache")) \(compact(line.usage.cacheReadTokens))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 14)
        .help(L("costs.rowHelp"))
    }

    private func expansionBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedGroups.contains(id) },
            set: { expanded in
                if expanded { collapsedGroups.remove(id) } else { collapsedGroups.insert(id) }
            }
        )
    }

    // MARK: - Budget

    private var budgetSection: some View {
        Section(L("costs.budgetHeader")) {
            LabeledContent(L("costs.budget")) {
                TextField("0", value: $store.monthlyBudgetUSD, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .multilineTextAlignment(.trailing)
            }
            .help(L("costs.budgetHelp"))
            Text(L("costs.budgetNote"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Aggregation

    /// One stacked segment. `start`/`end` are the value range it occupies, so
    /// the stack order is ours and a hover can be resolved exactly.
    private struct DaySlice: Identifiable {
        var id: String { "\(day.timeIntervalSince1970)|\(label)" }
        let day: Date
        let label: String
        let start: Double
        let end: Double
    }

    private struct ModelLine: Identifiable {
        let id: String
        let provider: String
        let model: String
        var usage = TokenUsage()
        var cost: Double = 0
        var hasPrice = false
        var hasEstimates = false

        var shortLabel: String {
            // Trim vendor prefixes ("anthropic/claude-…" → "claude-…") and
            // dated suffixes for chart legibility.
            let bare = model.split(separator: "/").last.map(String.init) ?? model
            return bare.count > 32 ? String(bare.prefix(30)) + "…" : bare
        }
    }

    private struct ServiceLine: Identifiable {
        let id: String
        let provider: String
        let model: String
        let label: String
        let detail: String
        let cost: Double
    }

    private struct ProviderGroup: Identifiable {
        let id: String
        let provider: String
        let label: String
        var totalCost: Double = 0
        var chatLines: [ModelLine] = []
        var serviceLines: [ServiceLine] = []
        var hasEstimates: Bool {
            chatLines.contains { $0.hasEstimates }
        }
    }

    /// Cost of one record for DISPLAY: what was fixed at write time, or —
    /// when the record was written without a known price (e.g. the model was
    /// added to the catalog later) — a live re-quote from the current catalog.
    private func displayCost(_ record: SpendRecordValue) -> Double? {
        if let cost = record.costUSD { return cost }
        guard record.kind == .chat || record.kind == .summary,
              let provider = ProviderID(rawValue: record.provider) else { return nil }
        return PricingCatalog.pricing(provider: provider, model: record.model)?
            .cost(for: record.usage)
    }

    /// Chat+summary records rolled up per provider+model, ordered by cost.
    private var modelLines: [ModelLine] {
        var lines: [String: ModelLine] = [:]
        for record in store.selectedMonthRecords where record.kind == .chat || record.kind == .summary {
            let key = "\(record.provider)|\(record.model)"
            var line = lines[key] ?? ModelLine(id: key, provider: record.provider, model: record.model)
            line.usage = line.usage.merged(with: record.usage)
            let cost = displayCost(record)
            line.cost += cost ?? 0
            line.hasPrice = line.hasPrice || cost != nil
            line.hasEstimates = line.hasEstimates || record.isEstimate
            lines[key] = line
        }
        return lines.values.sorted { $0.cost > $1.cost }
    }

    /// Everything in the month grouped under its provider: chat models first,
    /// then the provider's services (OCR/STT/search/images) with real units.
    private var providerGroups: [ProviderGroup] {
        var groups: [String: ProviderGroup] = [:]
        func group(_ provider: String) -> ProviderGroup {
            groups[provider] ?? ProviderGroup(id: provider, provider: provider, label: providerLabel(provider))
        }

        for line in modelLines {
            var g = group(line.provider)
            g.chatLines.append(line)
            g.totalCost += line.cost
            groups[line.provider] = g
        }

        // Services: one line per provider+kind+model, with unit counts.
        struct ServiceKey: Hashable { let provider: String; let kind: SpendKind; let model: String }
        var services: [ServiceKey: (units: Double, cost: Double)] = [:]
        for record in store.selectedMonthRecords
        where record.kind == .ocr || record.kind == .stt || record.kind == .search || record.kind == .image {
            let key = ServiceKey(provider: record.provider, kind: record.kind, model: record.model)
            var entry = services[key] ?? (0, 0)
            entry.units += record.units
            entry.cost += record.costUSD ?? 0
            services[key] = entry
        }
        for (key, entry) in services {
            var g = group(key.provider)
            let label: String
            let detail: String
            switch key.kind {
            case .ocr:
                label = L("costs.ocrLine"); detail = "\(Int(entry.units)) · \(key.model)"
            case .stt:
                label = L("costs.sttLine"); detail = String(format: "%.1f", entry.units) + " · \(key.model)"
            case .search:
                label = L("costs.searchLine"); detail = "\(Int(entry.units))"
            case .image:
                label = L("costs.imageLine"); detail = "\(Int(entry.units)) · \(key.model)"
            case .chat, .summary:
                continue
            }
            g.serviceLines.append(ServiceLine(
                id: "\(key.provider)|\(key.kind.rawValue)|\(key.model)",
                provider: key.provider, model: key.model,
                label: label, detail: detail, cost: entry.cost
            ))
            g.totalCost += entry.cost
            groups[key.provider] = g
        }

        for (key, var g) in groups {
            g.serviceLines.sort { $0.cost > $1.cost }
            groups[key] = g
        }
        return groups.values.sorted { $0.totalCost > $1.totalCost }
    }

    // MARK: - Chart model

    /// Everything the daily chart, its legend and the highlighting need,
    /// aggregated in a single pass over the month's ledger.
    private struct ChartModel {
        var slices: [DaySlice] = []
        /// Legend and stack order — biggest series first, at the bottom.
        var order: [String] = []
        /// Series label → color, for the selected dimension.
        var colors: [String: Color] = [:]
        /// Provider id → color. Kept separately from `colors` because the
        /// breakdown groups are provider-shaped whatever the chart is sliced
        /// by, so their dots must not change color when the picker flips to
        /// models. In provider mode the two maps hold the same colors.
        var providerColors: [String: Color] = [:]

        func color(_ label: String, fallback: Color = .gray) -> Color { colors[label] ?? fallback }
        func providerTint(_ id: String) -> Color? { providerColors[id] }
    }

    private struct SeriesCell { var provider: String; var cost: Double }
    private struct RankedSeries { let label: String; let cost: Double }

    /// The series a record — or a breakdown row — belongs to under the
    /// currently selected dimension.
    private func seriesKey(_ provider: String, _ model: String) -> String {
        switch chartDimension {
        case .provider:
            return providerLabel(provider)
        case .model:
            let bare = model.split(separator: "/").last.map(String.init) ?? model
            return bare.isEmpty ? providerLabel(provider) : bare
        }
    }

    private func chartModel(_ scheme: ColorScheme) -> ChartModel {
        let calendar = Calendar.current
        var totals: [String: SeriesCell] = [:]
        var perDay: [Date: [String: SeriesCell]] = [:]
        var providerTotals: [String: Double] = [:]

        for record in store.selectedMonthRecords {
            guard let cost = displayCost(record) ?? record.costUSD, cost > 0 else { continue }
            let label = seriesKey(record.provider, record.model)
            let blank = SeriesCell(provider: record.provider, cost: 0)
            totals[label, default: blank].cost += cost
            perDay[calendar.startOfDay(for: record.timestamp), default: [:]][label, default: blank].cost += cost
            providerTotals[record.provider, default: 0] += cost
        }

        var model = ChartModel()

        // Providers are coloured first and independently of the selected
        // dimension, so a provider keeps one colour across every section.
        var providers: [RankedSeries] = providerTotals.map { RankedSeries(label: $0.key, cost: $0.value) }
        // Ties broken by name so the same month always paints the same way.
        providers.sort {
            $0.cost == $1.cost ? providerLabel($0.label) < providerLabel($1.label) : $0.cost > $1.cost
        }
        for (index, entry) in providers.enumerated() {
            model.providerColors[entry.label] = Self.seriesColor(index, scheme)
        }

        var ranked: [RankedSeries] = totals.map { RankedSeries(label: $0.key, cost: $0.value.cost) }
        ranked.sort { $0.cost == $1.cost ? $0.label < $1.label : $0.cost > $1.cost }
        model.order = ranked.map(\.label)

        // One colour per series, assigned by rank and NEVER reused. In provider
        // mode the series ARE the providers, so the palette above is reused
        // verbatim rather than recomputed — the chart and the breakdown dots
        // then cannot drift apart.
        for (index, entry) in ranked.enumerated() {
            switch chartDimension {
            case .provider:
                let id = totals[entry.label]?.provider ?? entry.label
                model.colors[entry.label] = model.providerColors[id]
            case .model:
                model.colors[entry.label] = Self.seriesColor(index, scheme)
            }
        }

        for (day, cells) in perDay {
            var base = 0.0
            for label in model.order {
                guard let cell = cells[label], cell.cost > 0 else { continue }
                model.slices.append(DaySlice(day: day, label: label,
                                             start: base, end: base + cell.cost))
                base += cell.cost
            }
        }
        model.slices.sort { $0.day < $1.day }
        return model
    }

    // MARK: - Series palette

    /// The first eight series get these fixed hues: a hand-picked order,
    /// stepped separately for the two surfaces so the marks stay inside the
    /// readable lightness band in both, and validated for colour-vision
    /// deficiency on ADJACENT pairs — in a stack those are the pairs that
    /// actually touch.
    private static let categoricalLight: [Color] = [
        Color(hex: 0x2A78D6), Color(hex: 0xEB6834), Color(hex: 0x1BAF7A), Color(hex: 0xEDA100),
        Color(hex: 0xE87BA4), Color(hex: 0x008300), Color(hex: 0x4A3AA7), Color(hex: 0xE34948),
    ]
    private static let categoricalDark: [Color] = [
        Color(hex: 0x3987E5), Color(hex: 0xD95926), Color(hex: 0x199E70), Color(hex: 0xC98500),
        Color(hex: 0xD55181), Color(hex: 0x008300), Color(hex: 0x9085E9), Color(hex: 0xE66767),
    ]

    /// Color for the series ranked `index` by spend. Past the fixed hues the
    /// palette keeps generating instead of wrapping around: the hue advances by
    /// the golden angle so consecutive series land far apart on the wheel, and
    /// saturation/brightness step every full turn so even a long tail stays
    /// distinguishable. Wrapping is what made two models share a color before.
    private static func seriesColor(_ index: Int, _ scheme: ColorScheme) -> Color {
        let fixed = scheme == .dark ? categoricalDark : categoricalLight
        if index < fixed.count { return fixed[index] }
        let step = index - fixed.count
        // 0.381966 = golden angle / 360°; the offset starts the tail on a hue
        // the fixed slots don't already occupy.
        let hue = (0.07 + Double(step) * 0.381966).truncatingRemainder(dividingBy: 1)
        let ring = (step / 6) % 3
        return Color(hue: hue,
                     saturation: [0.68, 0.92, 0.48][ring],
                     brightness: scheme == .dark ? [0.86, 0.72, 0.95][ring] : [0.74, 0.60, 0.84][ring])
    }

    // MARK: - Helpers

    private func providerLabel(_ raw: String) -> String {
        ProviderID(rawValue: raw)?.displayName ?? raw.capitalized
    }

    /// The provider's color from the month's palette, or its brand color when
    /// the provider spent nothing this month and so never got a slot.
    private func seriesFallback(_ provider: String, _ model: ChartModel) -> Color {
        model.providerTint(provider) ?? providerColor(provider)
    }

    /// Brand color — the last resort for a provider outside the month's data.
    private func providerColor(_ raw: String) -> Color {
        if let id = ProviderID(rawValue: raw) { return Color(hex: id.brandColorHex) }
        switch raw {
        case "fal": return .green
        case "brave": return .orange
        case "deepgram": return .purple
        default: return .teal
        }
    }

    private var canStepBack: Bool {
        guard let earliest = store.earliestRecord,
              let earliestMonth = Calendar.current.dateInterval(of: .month, for: earliest)?.start else { return false }
        return store.selectedMonth > earliestMonth
    }

    private var canStepForward: Bool {
        guard let current = Calendar.current.dateInterval(of: .month, for: Date())?.start else { return false }
        return store.selectedMonth < current
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Localization.currentLanguage.rawValue)
        formatter.dateFormat = "LLLL yyyy"
        return formatter.string(from: store.selectedMonth).capitalized
    }

    /// 12345 → "12.3k", 1234567 → "1.2M".
    private func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.1fk", Double(n) / 1_000)
        default: return "\(n)"
        }
    }
}
