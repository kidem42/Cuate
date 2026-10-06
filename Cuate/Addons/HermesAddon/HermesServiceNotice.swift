import Foundation


// MARK: - Gateway service notifications (delegation results, process reports)
//
// The gateway injects background-event reports into the conversation as
// `role == "user"` turns (LLM APIs only have user/assistant, so harness
// events ride the user role): async-delegation completions from
// `_format_async_delegation` and background-process notifications from
// `format_process_notification` (hermes-agent `tools/process_registry.py`).
// Mirrored verbatim they rendered as messages the USER supposedly sent —
// a wall of `[ASYNC DELEGATION BATCH COMPLETE …]` in the outgoing bubble
// (2026-08-11). They are really the AGENT's side of the story, and often
// long, so the mirror shows them as a collapsed service card on the
// assistant side: one summary line closed, the full structured report
// (per-task disclosures for a fan-out) on demand.
//
// Detection is by the stable content markers, same approach as
// `HermesCompaction` — the gateway's own metadata never crosses the wire.

/// Parsed model of one service notification. `parse` is tolerant by design:
/// anything it cannot break into structure stays in `body` and still renders
/// (the card must never eat content — the user checks delegation results
/// through it).
nonisolated struct HermesServiceNotice {

    enum Kind {
        /// Async delegation: a fan-out batch or a single subagent completion.
        case delegation
        /// Background process completion / watch-pattern report.
        case process
    }

    /// One subagent's slice of a fan-out report (or the single RESULT block).
    struct TaskItem: Identifiable {
        let id: Int
        let ok: Bool
        /// "1/3" — position label; empty for the single-delegation result.
        let label: String
        /// The dispatched goal, verbatim.
        let goal: String
        /// Raw stats tail: "status=completed, api_calls=10, 94.23s".
        let stats: String?
        /// Everything under the header, markdown-rendered on expand.
        let body: String
    }

    let kind: Kind
    /// Header lines shown when the card expands (Dispatched/Role/Model…).
    let metaLines: [String]
    let tasks: [TaskItem]
    /// Free-form remainder (single-result payload, process output, batch
    /// error). nil when everything parsed into tasks.
    let body: String?
    let okCount: Int
    let failCount: Int
    /// Compact duration for the collapsed line ("2m07s"), when the report
    /// carried one.
    let durationText: String?
    /// Process reports: "exit 0"-style capsule for the collapsed line.
    let exitText: String?

    // MARK: Detection

    /// Every async-delegation report opens with this (COMPLETE, BATCH
    /// COMPLETE, and the early TASK FAILED warning since Hermes 0.21.5).
    private static let delegationMarker = "[ASYNC DELEGATION "
    private static let batchMarker = "[ASYNC DELEGATION BATCH COMPLETE"
    private static let singleMarker = "[ASYNC DELEGATION COMPLETE"
    private static let taskFailedMarker = "[ASYNC DELEGATION TASK FAILED"
    private static let processMarkers = [
        "[IMPORTANT: Background process",
        "[Background process",
    ]

    /// The gateway's consolidation header (Hermes 0.21.5): several reports
    /// delivered as one row, `[IMPORTANT: N background subagent delegations
    /// completed…]` or `[IMPORTANT: N background processes completed…]`,
    /// followed by the individual reports.
    private static func consolidatedKind(_ head: Substring) -> Kind? {
        let prefix = "[IMPORTANT: "
        guard head.hasPrefix(prefix) else { return nil }
        let rest = head.dropFirst(prefix.count)
        let digits = rest.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        let tail = rest.dropFirst(digits.count)
        if tail.hasPrefix(" background subagent delegations completed") { return .delegation }
        if tail.hasPrefix(" background processes completed") { return .process }
        return nil
    }

    /// Whether a transcript row's content is a gateway service notification.
    /// Cheap prefix check — safe to call per row per sync.
    static func isNotice(_ text: String) -> Bool {
        let head = text.drop(while: \.isWhitespace)
        return head.hasPrefix(delegationMarker)
            || processMarkers.contains(where: { head.hasPrefix($0) })
            || consolidatedKind(head) != nil
    }

    // MARK: Parse (memoized — MessageRow bodies re-evaluate on hover etc.)

    private final class Box {
        let value: HermesServiceNotice?
        init(_ value: HermesServiceNotice?) { self.value = value }
    }
    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 128
        return cache
    }()

    static func cached(_ text: String) -> HermesServiceNotice? {
        let key = text as NSString
        if let boxed = cache.object(forKey: key) { return boxed.value }
        let parsed = parse(text)
        cache.setObject(Box(parsed), forKey: key)
        return parsed
    }

    static func parse(_ text: String) -> HermesServiceNotice? {
        let trimmed = String(text.drop(while: \.isWhitespace))
        switch consolidatedKind(trimmed[...]) {
        case .delegation?: return parseConsolidated(trimmed, kind: .delegation)
        case .process?: return parseConsolidated(trimmed, kind: .process)
        case nil: break
        }
        if trimmed.hasPrefix(delegationMarker) { return parseDelegation(trimmed) }
        if processMarkers.contains(where: { trimmed.hasPrefix($0) }) {
            return parseProcess(trimmed)
        }
        return nil
    }

    private static func parseDelegation(_ text: String) -> HermesServiceNotice {
        if text.hasPrefix(batchMarker) { return parseBatch(text) }
        if text.hasPrefix(taskFailedMarker) { return parseTaskFailed(text) }
        if text.hasPrefix(singleMarker) { return parseSingle(text) }
        // A delegation report this build does not know: whole text, no tally.
        let body = text.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return HermesServiceNotice(kind: .delegation, metaLines: [], tasks: [],
                                   body: body.isEmpty ? text : body, okCount: 0, failCount: 0,
                                   durationText: nil, exitText: nil)
    }

    /// The consolidation header plus its reports: each report starts on a
    /// line with its own marker. Every report becomes task rows of one card
    /// (a process report is one row: headline as the goal, exit as stats).
    private static func parseConsolidated(_ text: String, kind: Kind) -> HermesServiceNotice {
        let starts = kind == .delegation ? [delegationMarker] : processMarkers
        var blocks: [[String]] = []
        for line in text.components(separatedBy: "\n").dropFirst() {
            if starts.contains(where: { line.hasPrefix($0) }) {
                blocks.append([line])
            } else if !blocks.isEmpty {
                blocks[blocks.count - 1].append(line)
            }
        }
        var tasks: [TaskItem] = []
        var bodies: [String] = []
        var ok = 0
        var failed = 0
        for block in blocks {
            let report = block.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let notice = kind == .delegation ? parseDelegation(report) : parseProcess(report)
            ok += notice.okCount
            failed += notice.failCount
            if kind == .process {
                tasks.append(TaskItem(id: tasks.count, ok: notice.failCount == 0, label: "",
                                      goal: notice.metaLines.first ?? "", stats: notice.exitText,
                                      body: notice.body ?? ""))
                continue
            }
            for task in notice.tasks {
                tasks.append(TaskItem(id: tasks.count, ok: task.ok, label: task.label, goal: task.goal,
                                      stats: task.stats, body: task.body))
            }
            if let body = notice.body, !body.isEmpty { bodies.append(body) }
        }
        return HermesServiceNotice(
            kind: kind, metaLines: [], tasks: tasks,
            body: bodies.isEmpty ? nil : bodies.joined(separator: "\n\n"),
            okCount: ok, failCount: failed, durationText: nil, exitText: nil
        )
    }

    /// Early warning from a fan-out still running (Hermes 0.21.5):
    /// `[ASYNC DELEGATION TASK FAILED — deleg_…, task 2/3]`, then `Task:`,
    /// `Status:`, `Error:` and transcript lines.
    private static func parseTaskFailed(_ text: String) -> HermesServiceNotice {
        let lines = text.components(separatedBy: "\n")
        var label = ""
        if let title = lines.first, let range = title.range(of: ", task ", options: .backwards) {
            label = String(title[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "] "))
        }
        var goal = ""
        var metaLines: [String] = []
        var body: [String] = []
        for line in lines.dropFirst(2) {
            if line.hasPrefix("Task:") {
                goal = String(line.dropFirst("Task:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Status:") {
                metaLines.append(line)
            } else {
                body.append(line)
            }
        }
        let task = TaskItem(id: 0, ok: false, label: label, goal: goal, stats: metaLines.first,
                            body: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        return HermesServiceNotice(kind: .delegation, metaLines: metaLines, tasks: [task], body: nil,
                                   okCount: 0, failCount: 1,
                                   durationText: duration(inMetaLines: metaLines), exitText: nil)
    }

    /// Header lines worth surfacing in the expanded meta block. The fixed
    /// explanatory prose ("A background fan-out of…") is agent-facing and
    /// stays out.
    private static let metaPrefixes = [
        "Dispatched:", "Original goal:", "Context you provided:",
        "Toolsets:", "Role:", "Status:",
    ]

    private static func parseBatch(_ text: String) -> HermesServiceNotice {
        let lines = text.components(separatedBy: "\n")

        // Task headers: `--- ✓ TASK 1/3: goal  (status=…) ---`; ⚠ marks a
        // task cut off at max_iterations — its work may be incomplete.
        func taskHeader(_ line: String) -> (ok: Bool, rest: String)? {
            if line.hasPrefix("--- ✓ TASK ") { return (true, String(line.dropFirst("--- ✓ TASK ".count))) }
            if line.hasPrefix("--- ✗ TASK ") { return (false, String(line.dropFirst("--- ✗ TASK ".count))) }
            if line.hasPrefix("--- ⚠ TASK ") { return (false, String(line.dropFirst("--- ⚠ TASK ".count))) }
            return nil
        }

        var metaLines: [String] = []
        var tasks: [TaskItem] = []
        var errorBody: [String] = []
        var inError = false
        var current: (ok: Bool, label: String, goal: String, stats: String?)?
        var currentBody: [String] = []

        func flushTask() {
            guard let task = current else { return }
            tasks.append(TaskItem(
                id: tasks.count, ok: task.ok, label: task.label, goal: task.goal,
                stats: task.stats,
                body: currentBody.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            ))
            current = nil
            currentBody = []
        }

        for line in lines.dropFirst() { // drop the [MARKER] line
            if let header = taskHeader(line) {
                flushTask()
                inError = false
                // rest = "1/3: goal  (status=…) ---"
                var rest = header.rest
                if rest.hasSuffix("---") {
                    rest = String(rest.dropLast(3)).trimmingCharacters(in: .whitespaces)
                }
                var label = ""
                var goal = rest
                if let colon = rest.range(of: ": ") {
                    label = String(rest[..<colon.lowerBound])
                    goal = String(rest[colon.upperBound...])
                }
                var stats: String?
                if let open = goal.range(of: "(status=", options: .backwards) {
                    var tail = String(goal[open.lowerBound...])
                    goal = String(goal[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
                    tail = tail.trimmingCharacters(in: .whitespaces)
                    if tail.hasPrefix("(") { tail = String(tail.dropFirst()) }
                    if tail.hasSuffix(")") { tail = String(tail.dropLast()) }
                    stats = tail
                }
                current = (header.ok, label, goal, stats)
                continue
            }
            if current != nil {
                currentBody.append(line)
                continue
            }
            if line == "--- ERROR ---" { inError = true; continue }
            if inError { errorBody.append(line); continue }
            if metaPrefixes.contains(where: { line.hasPrefix($0) }) {
                metaLines.append(line)
            }
        }
        flushTask()

        let error = errorBody.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return HermesServiceNotice(
            kind: .delegation,
            metaLines: metaLines,
            tasks: tasks,
            body: error.isEmpty ? nil : error,
            okCount: tasks.filter(\.ok).count,
            failCount: tasks.filter { !$0.ok }.count,
            durationText: duration(inMetaLines: metaLines),
            exitText: nil
        )
    }

    private static func parseSingle(_ text: String) -> HermesServiceNotice {
        let lines = text.components(separatedBy: "\n")
        var metaLines: [String] = []
        var resultBody: [String] = []
        var inResult = false
        var goal = ""
        var ok = true
        for line in lines.dropFirst() {
            if inResult { resultBody.append(line); continue }
            if line == "--- RESULT ---" { inResult = true; continue }
            if metaPrefixes.contains(where: { line.hasPrefix($0) }) {
                metaLines.append(line)
                if line.hasPrefix("Original goal:") {
                    goal = String(line.dropFirst("Original goal:".count))
                        .trimmingCharacters(in: .whitespaces)
                }
                if line.hasPrefix("Status:") {
                    let status = line.lowercased()
                    ok = status.contains("completed") || status.contains("success")
                }
            }
        }
        let body = resultBody.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // One pseudo-task keeps the card's shape uniform with the batch.
        let task = TaskItem(id: 0, ok: ok, label: "", goal: goal,
                            stats: nil, body: body)
        return HermesServiceNotice(
            kind: .delegation,
            metaLines: metaLines,
            tasks: goal.isEmpty && body.isEmpty ? [] : [task],
            body: goal.isEmpty && body.isEmpty ? body : nil,
            okCount: ok ? 1 : 0,
            failCount: ok ? 0 : 1,
            durationText: duration(inMetaLines: metaLines),
            exitText: nil
        )
    }

    private static func parseProcess(_ text: String) -> HermesServiceNotice {
        // Strip the outer [IMPORTANT: … ] / [ … ] envelope (tolerate a
        // missing close bracket — truncation upstream).
        var content = text
        if content.hasPrefix("[") { content = String(content.dropFirst()) }
        if content.hasPrefix("IMPORTANT:") {
            content = String(content.dropFirst("IMPORTANT:".count))
        }
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.hasSuffix("]") { content = String(content.dropLast()) }

        let lines = content.components(separatedBy: "\n")
        let headline = lines.first ?? ""
        let body = lines.dropFirst().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var exitText: String?
        if let range = headline.range(of: "exit code ") {
            let tail = headline[range.upperBound...]
            let code = tail.prefix(while: { $0 == "-" || $0.isNumber })
            if !code.isEmpty { exitText = "exit \(code)" }
        }
        let failed = (exitText != nil && exitText != "exit 0")
            || headline.contains("failed to start")
            || headline.contains("terminated")
        return HermesServiceNotice(
            kind: .process,
            metaLines: [headline],
            tasks: [],
            body: body.isEmpty ? nil : body,
            okCount: failed ? 0 : 1,
            failCount: failed ? 1 : 0,
            durationText: nil,
            exitText: exitText
        )
    }

    /// "Total duration: 127.26s" / "Duration: 94.23s" → "2m07s".
    private static func duration(inMetaLines lines: [String]) -> String? {
        for line in lines {
            guard let range = line.range(of: "uration: ") else { continue }
            let tail = line[range.upperBound...]
            let number = tail.prefix(while: { $0.isNumber || $0 == "." })
            guard let seconds = Double(number), seconds > 0 else { continue }
            let total = Int(seconds.rounded())
            if total < 60 { return "\(total)s" }
            return String(format: "%dm%02ds", total / 60, total % 60)
        }
        return nil
    }
}
