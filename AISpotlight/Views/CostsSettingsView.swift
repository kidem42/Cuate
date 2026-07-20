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

    private enum ChartDimension: String, CaseIterable, Identifiable {
        case provider, model
        var id: String { rawValue }
    }
    @State private var chartDimension: ChartDimension = .provider
    /// Provider groups the user collapsed (all expanded by default).
    @State private var collapsedGroups: Set<String> = []

    var body: some View {
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
                dailyChartSection
                modelChartSection
                breakdownSection
            }
            budgetSection
        }
        .formStyle(.grouped)
        .onAppear { store.refresh() }
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

    private var dailyChartSection: some View {
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

            if chartDimension == .provider {
                Chart(dailySlices) { slice in
                    BarMark(
                        x: .value("Day", slice.day, unit: .day),
                        y: .value("USD", slice.cost)
                    )
                    .foregroundStyle(by: .value("Provider", slice.label))
                }
                .chartForegroundStyleScale(domain: sliceLabels, range: sliceColors)
                .chartLegend(position: .bottom, spacing: 6)
                .chartXAxis { dayAxisMarks }
                .frame(height: 180)
                .help(L("costs.dailyHelp"))
            } else {
                // Model palette is automatic — model sets vary too much for a
                // fixed brand mapping.
                Chart(dailySlices) { slice in
                    BarMark(
                        x: .value("Day", slice.day, unit: .day),
                        y: .value("USD", slice.cost)
                    )
                    .foregroundStyle(by: .value("Model", slice.label))
                }
                .chartLegend(position: .bottom, spacing: 6)
                .chartXAxis { dayAxisMarks }
                .frame(height: 180)
                .help(L("costs.dailyHelp"))
            }
        }
    }

    /// Day-of-month numbers every few days — replaces Swift Charts' default
    /// date axis, which degrades into an hour scale on sparse data.
    private var dayAxisMarks: some AxisContent {
        AxisMarks(values: .stride(by: .day, count: 5)) { _ in
            AxisGridLine()
            AxisValueLabel(format: .dateTime.day(), centered: true)
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

    private var modelChartSection: some View {
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
                    .foregroundStyle(providerColor(line.provider))
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

    private var breakdownSection: some View {
        Section(L("costs.breakdown")) {
            ForEach(providerGroups) { group in
                DisclosureGroup(isExpanded: expansionBinding(group.id)) {
                    ForEach(group.chatLines) { line in
                        modelRow(line)
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
                        Circle().fill(providerColor(group.provider)).frame(width: 8, height: 8)
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

    private func modelRow(_ line: ModelLine) -> some View {
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

    private struct DaySlice: Identifiable {
        let id = UUID()
        let day: Date
        let label: String
        let provider: String
        let cost: Double
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

    /// Per-day slices for the stacked bar chart, keyed by the selected
    /// dimension (provider or model). All kinds included.
    private var dailySlices: [DaySlice] {
        let calendar = Calendar.current
        var buckets: [String: (day: Date, label: String, provider: String, cost: Double)] = [:]
        for record in store.selectedMonthRecords {
            guard let cost = displayCost(record) ?? record.costUSD, cost > 0 else { continue }
            let day = calendar.startOfDay(for: record.timestamp)
            let label: String
            switch chartDimension {
            case .provider: label = providerLabel(record.provider)
            case .model:
                let bare = record.model.split(separator: "/").last.map(String.init) ?? record.model
                label = bare.isEmpty ? providerLabel(record.provider) : bare
            }
            let key = "\(day.timeIntervalSince1970)|\(label)"
            var bucket = buckets[key] ?? (day, label, record.provider, 0)
            bucket.cost += cost
            buckets[key] = bucket
        }
        return buckets.values.map {
            DaySlice(day: $0.day, label: $0.label, provider: $0.provider, cost: $0.cost)
        }
        .sorted { $0.day < $1.day }
    }

    private var sliceLabels: [String] {
        var seen = Set<String>()
        return dailySlices.compactMap { seen.insert($0.label).inserted ? $0.label : nil }
    }

    private var sliceColors: [Color] {
        var seen = Set<String>()
        return dailySlices.compactMap { seen.insert("c\($0.label)").inserted ? providerColor($0.provider) : nil }
    }

    // MARK: - Helpers

    private func providerLabel(_ raw: String) -> String {
        ProviderID(rawValue: raw)?.displayName ?? raw.capitalized
    }

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
