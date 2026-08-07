import Foundation
import Combine
import SwiftData

// MARK: - Spend records
//
// Append-only cost ledger, deliberately SEPARATE from the chat store: deleting
// a conversation must not erase spend history, and the chat schema stays
// untouched. Same access pattern as ChatPersistence — one serial queue, a
// fresh ModelContext per operation, value types across the boundary.

/// What a spend record paid for.
enum SpendKind: String, CaseIterable {
    case chat      // a model turn in the panel (incl. agentic tool loop)
    case summary   // context-compression summarization call
    case ocr       // Mistral OCR (per page)
    case stt       // speech-to-text (per minute)
    case search    // Brave web search (per query; billed by plan, cost 0)
    case image     // ImageAddon cloud operation (fal.ai)
}

@Model
final class SDSpendRecord {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var kindRaw: String
    var provider: String
    var model: String
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int
    var reasoningTokens: Int
    /// Non-token quantity: OCR pages, STT minutes, search queries, images.
    var units: Double
    /// nil = tokens recorded but no price known for the model at write time.
    var costUSD: Double?
    /// true when the stream ended without provider usage (cancel/error) and
    /// the tokens are a script-aware estimate, not an API-reported count.
    var isEstimate: Bool

    init(id: UUID = UUID(), timestamp: Date = Date(), kindRaw: String,
         provider: String, model: String,
         inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0,
         cacheWriteTokens: Int = 0, reasoningTokens: Int = 0,
         units: Double = 0, costUSD: Double? = nil, isEstimate: Bool = false) {
        self.id = id
        self.timestamp = timestamp
        self.kindRaw = kindRaw
        self.provider = provider
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
        self.units = units
        self.costUSD = costUSD
        self.isEstimate = isEstimate
    }
}

/// Value-type snapshot of a record (crosses the queue boundary; feeds charts).
struct SpendRecordValue: Identifiable {
    let id: UUID
    let timestamp: Date
    let kind: SpendKind
    let provider: String
    let model: String
    let usage: TokenUsage
    let units: Double
    let costUSD: Double?
    let isEstimate: Bool
}

// MARK: - Ledger (persistence)

nonisolated enum SpendLedger {

    static let container: ModelContainer = {
        let schema = Schema([SDSpendRecord.self])
        let url = ChatStore.baseDirectory.appendingPathComponent("CuateSpend.store")
        let config = ModelConfiguration(schema: schema, url: url)
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            // Same corrupt-store fallback ladder as ChatPersistence: never
            // brick launch over analytics data.
            let aside = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: aside)
            if let retried = try? ModelContainer(for: schema, configurations: config) {
                return retried
            }
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: memory)
        }
    }()

    private static let queue = DispatchQueue(label: "Cuate.SpendLedger", qos: .utility)

    /// Appends one record. Fire-and-forget from any thread.
    static func append(kind: SpendKind, provider: String, model: String,
                       usage: TokenUsage = TokenUsage(), units: Double = 0,
                       costUSD: Double?, isEstimate: Bool = false) {
        queue.async {
            let ctx = ModelContext(container)
            ctx.insert(SDSpendRecord(
                kindRaw: kind.rawValue, provider: provider, model: model,
                inputTokens: usage.inputTokens, outputTokens: usage.outputTokens,
                cacheReadTokens: usage.cacheReadTokens, cacheWriteTokens: usage.cacheWriteTokens,
                reasoningTokens: usage.reasoningTokens,
                units: units, costUSD: costUSD, isEstimate: isEstimate
            ))
            try? ctx.save()
            Diagnostics.log("spend", "append kind=\(kind.rawValue) provider=\(provider) model=\(model) cost=\(costUSD.map { String(format: "%.6f", $0) } ?? "nil") est=\(isEstimate)")
        }
    }

    /// Fetches records in [from, to) as value types; completion runs on the
    /// ledger queue — callers hop to main themselves.
    ///
    /// Hermes agent records are excluded here, at the single point every
    /// Costs aggregate reads through: the gateway pays for its own model
    /// calls, and its run-cumulative usage frames (every tool-loop call
    /// re-counts the whole prompt) drowned the token stats. New agent turns
    /// are no longer recorded at all; this filter hides the ones already in
    /// the ledger.
    static func fetch(from: Date, to: Date, completion: @escaping ([SpendRecordValue]) -> Void) {
        queue.async {
            let ctx = ModelContext(container)
            let hermes = ProviderID.hermes.rawValue
            let predicate = #Predicate<SDSpendRecord> {
                $0.timestamp >= from && $0.timestamp < to && $0.provider != hermes
            }
            let descriptor = FetchDescriptor<SDSpendRecord>(
                predicate: predicate,
                sortBy: [SortDescriptor(\.timestamp)]
            )
            let rows = (try? ctx.fetch(descriptor)) ?? []
            completion(rows.map { row in
                SpendRecordValue(
                    id: row.id, timestamp: row.timestamp,
                    kind: SpendKind(rawValue: row.kindRaw) ?? .chat,
                    provider: row.provider, model: row.model,
                    usage: TokenUsage(
                        inputTokens: row.inputTokens, outputTokens: row.outputTokens,
                        cacheReadTokens: row.cacheReadTokens, cacheWriteTokens: row.cacheWriteTokens,
                        reasoningTokens: row.reasoningTokens
                    ),
                    units: row.units, costUSD: row.costUSD, isEstimate: row.isEstimate
                )
            })
        }
    }

    /// Timestamp of the oldest record (bounds the month picker), nil if empty.
    /// Same Hermes exclusion as `fetch` — an all-agent month would otherwise
    /// extend the picker into months that render empty.
    static func earliestTimestamp(completion: @escaping (Date?) -> Void) {
        queue.async {
            let ctx = ModelContext(container)
            let hermes = ProviderID.hermes.rawValue
            var descriptor = FetchDescriptor<SDSpendRecord>(
                predicate: #Predicate { $0.provider != hermes },
                sortBy: [SortDescriptor(\.timestamp)]
            )
            descriptor.fetchLimit = 1
            completion((try? ctx.fetch(descriptor))?.first?.timestamp)
        }
    }
}

// MARK: - UI-facing store

/// Main-actor aggregates for the Costs tab + the soft monthly budget. The
/// heavy lifting (fetch) happens on the ledger queue; this object only holds
/// published snapshots. Follows the ImageAddonSettings singleton pattern.
@MainActor
final class SpendStore: ObservableObject {
    static let shared = SpendStore()
    private let defaults = UserDefaults.standard

    /// Average tokens per chat message (current calendar month).
    struct AvgStats {
        let input: Int
        let output: Int
        let count: Int
    }

    /// Spend since app launch (all kinds), not persisted.
    @Published private(set) var sessionUSD: Double = 0
    /// Current-calendar-month totals (kept fresh by record()/refresh()).
    @Published private(set) var currentMonthUSD: Double = 0
    @Published private(set) var todayUSD: Double = 0
    /// Ø input/output tokens per chat message this month (nil until data).
    @Published private(set) var currentMonthAvg: AvgStats?
    /// Records of the month the Costs tab is looking at.
    @Published var selectedMonth: Date
    @Published private(set) var selectedMonthRecords: [SpendRecordValue] = []
    @Published private(set) var earliestRecord: Date?

    /// Soft monthly budget in USD; 0 = off. Warns, never blocks.
    @Published var monthlyBudgetUSD: Double {
        didSet { defaults.set(monthlyBudgetUSD, forKey: "spend.monthlyBudgetUSD") }
    }

    private init() {
        monthlyBudgetUSD = defaults.double(forKey: "spend.monthlyBudgetUSD")
        selectedMonth = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
        refresh()
    }

    // MARK: Recording façade

    /// Central entry point every spend site calls: appends to the ledger,
    /// updates the live counters, kicks the weekly price refresh, and returns
    /// the budget-warning text to surface (nil when no threshold was crossed).
    @discardableResult
    func record(kind: SpendKind, provider: String, model: String,
                usage: TokenUsage = TokenUsage(), units: Double = 0,
                costUSD: Double?, isEstimate: Bool = false) -> String? {
        SpendLedger.append(kind: kind, provider: provider, model: model,
                           usage: usage, units: units, costUSD: costUSD, isEstimate: isEstimate)
        PricingCatalog.refreshIfStale()

        let cost = costUSD ?? 0
        sessionUSD += cost
        let before = currentMonthUSD
        currentMonthUSD += cost
        todayUSD += cost
        return budgetWarning(before: before, after: currentMonthUSD)
    }

    /// One warning per threshold per month: 80% and 100% of the budget.
    private func budgetWarning(before: Double, after: Double) -> String? {
        guard monthlyBudgetUSD > 0 else { return nil }
        let monthKey = Self.monthKey(Date())
        for (fraction, keySuffix, textKey) in [(1.0, "100", "costs.budgetHit"), (0.8, "80", "costs.budgetNear")] {
            let threshold = monthlyBudgetUSD * fraction
            guard after >= threshold, before < threshold else { continue }
            let flag = "spend.warned\(keySuffix).\(monthKey)"
            guard !defaults.bool(forKey: flag) else { return nil }
            defaults.set(true, forKey: flag)
            return String(format: L(textKey), Self.usd(after), Self.usd(monthlyBudgetUSD))
        }
        return nil
    }

    // MARK: Aggregation

    /// Reloads the live counters and the selected month's records.
    func refresh() {
        let calendar = Calendar.current
        let now = Date()
        guard let month = calendar.dateInterval(of: .month, for: now),
              let day = calendar.dateInterval(of: .day, for: now) else { return }

        SpendLedger.fetch(from: month.start, to: month.end) { records in
            let total = records.reduce(0) { $0 + ($1.costUSD ?? 0) }
            let today = records.filter { $0.timestamp >= day.start }
                .reduce(0) { $0 + ($1.costUSD ?? 0) }
            // Ø tokens per chat message, current month (summary row scope —
            // deliberately NOT the picker-selected month).
            let chats = records.filter { $0.kind == .chat }
            let avg: AvgStats? = chats.isEmpty ? nil : AvgStats(
                input: chats.reduce(0) { $0 + $1.usage.inputTokens + $1.usage.cacheReadTokens + $1.usage.cacheWriteTokens } / chats.count,
                output: chats.reduce(0) { $0 + $1.usage.outputTokens } / chats.count,
                count: chats.count
            )
            DispatchQueue.main.async {
                self.currentMonthUSD = total
                self.todayUSD = today
                self.currentMonthAvg = avg
            }
        }
        SpendLedger.earliestTimestamp { earliest in
            DispatchQueue.main.async { self.earliestRecord = earliest }
        }
        reloadSelectedMonth()
    }

    func reloadSelectedMonth() {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .month, for: selectedMonth) else { return }
        SpendLedger.fetch(from: interval.start, to: interval.end) { records in
            DispatchQueue.main.async { self.selectedMonthRecords = records }
        }
    }

    func stepMonth(by delta: Int) {
        let calendar = Calendar.current
        guard let next = calendar.date(byAdding: .month, value: delta, to: selectedMonth) else { return }
        // Clamp between the first recorded month and the current month.
        let lower = earliestRecord.flatMap { calendar.dateInterval(of: .month, for: $0)?.start }
            ?? selectedMonth
        let upper = calendar.dateInterval(of: .month, for: Date())?.start ?? selectedMonth
        selectedMonth = min(max(next, lower), upper)
        reloadSelectedMonth()
    }

    // MARK: Formatting helpers

    nonisolated static func usd(_ value: Double) -> String {
        value < 0.01 && value > 0
            ? String(format: "$%.4f", value)
            : String(format: "$%.2f", value)
    }

    nonisolated static func monthKey(_ date: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month], from: date)
        return "\(comps.year ?? 0)-\(comps.month ?? 0)"
    }
}
