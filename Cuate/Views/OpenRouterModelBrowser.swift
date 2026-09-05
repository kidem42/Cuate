import SwiftUI
import AppKit

/// The OpenRouter catalog inside the app: search, filters, descriptions and
/// prices from the cached `/models` payload — no trip to the website. A row
/// click shows the details; "Select" hands the slug to the model field.
struct OpenRouterModelBrowser: View {
    @ObservedObject var settings: AppSettings
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var filterVision = false
    @State private var filterFiles = false
    @State private var filterTools = false
    @State private var filterReasoning = false
    @State private var filterFree = false
    /// Hide models the account's privacy settings leave no endpoint for.
    @State private var filterAllowed = true
    @State private var sort: Sort = .newest
    @State private var selectedID: String?
    @State private var refreshing = false

    enum Sort: String, CaseIterable, Identifiable {
        case newest, cheapest, name
        var id: String { rawValue }
        var label: String {
            switch self {
            case .newest: return L("or.sort.newest")
            case .cheapest: return L("or.sort.cheapest")
            case .name: return L("or.sort.name")
            }
        }
    }

    private var models: [ModelInfo] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var list = settings.openRouterCatalog.values.filter { info in
            if filterVision && !info.supportsVision { return false }
            if filterFiles && info.supportsFiles != true { return false }
            if filterTools && !info.supportsTools { return false }
            if filterReasoning && !info.supportsReasoning { return false }
            if filterFree && !info.isFree { return false }
            if filterAllowed, let allowed = settings.openRouterAllowedModels, !allowed.contains(info.id) { return false }
            guard !needle.isEmpty else { return true }
            return info.id.lowercased().contains(needle)
                || (info.name ?? "").lowercased().contains(needle)
                || (info.summary ?? "").lowercased().contains(needle)
        }
        switch sort {
        case .newest:
            list.sort { ($0.createdAt ?? 0) > ($1.createdAt ?? 0) }
        case .cheapest:
            list.sort { Self.pricePair($0) < Self.pricePair($1) }
        case .name:
            list.sort { ($0.name ?? $0.id).localizedCaseInsensitiveCompare($1.name ?? $1.id) == .orderedAscending }
        }
        return list
    }

    private var selected: ModelInfo? {
        selectedID.flatMap { settings.openRouterCatalog[$0] }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                list
                    .frame(minWidth: 500, idealWidth: 560)
                detail
                    .frame(minWidth: 340)
            }
            Divider()
            footer
        }
        .frame(minWidth: 940, idealWidth: 1020, minHeight: 560, idealHeight: 640)
    }

    // MARK: - Header (search, filters, sort, refresh)

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("or.browserTitle")).font(.headline)
                Spacer()
                Text(String(format: L("or.count"), models.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            TextField(L("or.search"), text: $query)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 6) {
                filterChip(L("or.filter.vision"), $filterVision)
                filterChip(L("or.filter.files"), $filterFiles)
                filterChip(L("or.filter.tools"), $filterTools)
                filterChip(L("or.filter.reasoning"), $filterReasoning)
                filterChip(L("or.filter.free"), $filterFree)
                if settings.openRouterAllowedModels != nil {
                    filterChip(L("or.filter.allowed"), $filterAllowed)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Picker("", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                Spacer()
                Button {
                    refreshing = true
                    Task {
                        try? await settings.refreshOpenRouterCatalog()
                        refreshing = false
                    }
                } label: {
                    if refreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(refreshing)
                .help(L("or.refreshHelp"))
            }
        }
        .padding(12)
    }

    private func filterChip(_ label: String, _ on: Binding<Bool>) -> some View {
        Button {
            on.wrappedValue.toggle()
        } label: {
            Text(label)
                .font(.caption)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(on.wrappedValue ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12))
                )
                .overlay(Capsule().stroke(on.wrappedValue ? Color.accentColor : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - List

    private var list: some View {
        List(models, id: \.id, selection: $selectedID) { info in
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(info.name ?? info.id)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(Self.priceLabel(info))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                        .fixedSize()
                }
                HStack(spacing: 8) {
                    Text(info.id)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    if let context = info.contextLength {
                        Text(Self.compact(context))
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                            .fixedSize()
                    }
                    capabilityIcons(info)
                }
            }
            .padding(.vertical, 3)
            .opacity(isAllowed(info) ? 1 : 0.45)
            .tag(info.id)
        }
        .listStyle(.inset)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let info = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(info.name ?? info.id).font(.title3.weight(.semibold))
                    HStack(spacing: 6) {
                        Text(info.id)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(info.id, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc").font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help(L("or.copy"))
                    }
                    HStack(spacing: 6) {
                        if info.supportsVision { chip(L("cap.vision")) }
                        if info.supportsFiles == true { chip(L("cap.documents")) }
                        if info.supportsTools { chip(L("cap.tools")) }
                        if info.supportsReasoning { chip(L("cap.reasoning")) }
                        if info.isFree { chip(L("or.filter.free")) }
                    }
                    if !isAllowed(info) {
                        Text(L("or.notAllowedDetail"))
                            .font(.caption)
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(info.summary?.isEmpty == false ? info.summary! : L("or.noDescription"))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow {
                            Text(L("or.per1M")).foregroundColor(.secondary)
                            Text(Self.priceLabel(info)).monospacedDigit()
                        }
                        if let context = info.contextLength {
                            GridRow {
                                Text(L("or.context")).foregroundColor(.secondary)
                                Text(Self.compact(context)).monospacedDigit()
                            }
                        }
                        if let maxOut = info.maxCompletionTokens {
                            GridRow {
                                Text(L("or.maxOutput")).foregroundColor(.secondary)
                                Text(Self.compact(maxOut)).monospacedDigit()
                            }
                        }
                        if let created = info.createdAt {
                            GridRow {
                                Text(L("or.added")).foregroundColor(.secondary)
                                Text(Date(timeIntervalSince1970: created), style: .date)
                            }
                        }
                    }
                    .font(.callout)
                    if let url = URL(string: "https://openrouter.ai/\(info.id)") {
                        Link(L("or.openPage"), destination: url).font(.caption)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack {
                Spacer()
                Text(L("or.pickHint"))
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button(L("local.cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L("or.select")) {
                if let id = selectedID { onSelect(id) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedID == nil)
        }
        .padding(12)
    }

    // MARK: - Helpers

    /// Unknown (no key) counts as allowed — nothing to grey out.
    private func isAllowed(_ info: ModelInfo) -> Bool {
        settings.openRouterAllowedModels?.contains(info.id) ?? true
    }

    private func chip(_ label: String) -> some View {
        Text(label)
            .font(.caption2)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundColor(.secondary)
    }

    /// Capabilities as small glyphs — they never wrap; the words live in the
    /// detail pane and in each glyph's tooltip.
    private func capabilityIcons(_ info: ModelInfo) -> some View {
        HStack(spacing: 5) {
            if info.supportsVision { capabilityIcon("photo", L("cap.vision")) }
            if info.supportsFiles == true { capabilityIcon("doc.text", L("cap.documents")) }
            if info.supportsTools { capabilityIcon("wrench.and.screwdriver", L("cap.tools")) }
            if info.supportsReasoning { capabilityIcon("brain", L("cap.reasoning")) }
            if info.isFree { capabilityIcon("gift", L("or.filter.free")) }
        }
        .fixedSize()
    }

    private func capabilityIcon(_ symbol: String, _ label: String) -> some View {
        Image(systemName: symbol)
            .font(.caption2)
            .foregroundColor(.secondary)
            .frame(width: 14)
            .help(label)
    }

    /// "$2.00 / $10.00" per 1M tokens; "free" when both are zero.
    static func priceLabel(_ info: ModelInfo) -> String {
        if info.isFree { return L("or.filter.free").lowercased() }
        let input = (info.promptPricePerToken ?? 0) * 1_000_000
        let output = (info.completionPricePerToken ?? 0) * 1_000_000
        return "\(Self.money(input)) / \(Self.money(output))"
    }

    private static func money(_ value: Double) -> String {
        value < 1 ? String(format: "$%.3f", value) : String(format: "$%.2f", value)
    }

    private static func pricePair(_ info: ModelInfo) -> Double {
        (info.promptPricePerToken ?? 0) + (info.completionPricePerToken ?? 0)
    }

    /// 1000000 → "1M", 128000 → "128K".
    static func compact(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            let m = Double(tokens) / 1_000_000
            return m == m.rounded() ? "\(Int(m))M" : String(format: "%.1fM", m)
        }
        if tokens >= 1_000 { return "\(tokens / 1_000)K" }
        return "\(tokens)"
    }
}
