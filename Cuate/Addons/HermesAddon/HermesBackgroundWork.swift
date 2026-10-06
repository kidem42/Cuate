import Foundation

/// A confirmed background dispatch awaiting its matching delivery. Separate
/// from a live parent run: it must not route composer messages through steer.
nonisolated struct HermesBackgroundWork: Equatable, Identifiable {
    let id: String
    let count: Int
    let dispatchedAt: Date?

    func isUnconfirmed(at now: Date) -> Bool {
        guard let dispatchedAt else { return true }
        return now.timeIntervalSince(dispatchedAt) >= 20 * 60
    }

    /// Wire contracts: delegate_tool_dispatch.py and
    /// process_registry_notifications.py (v2026.9.7 through v2026.9.24).
    /// A unit is delivered by its COMPLETE / BATCH COMPLETE report, which
    /// since 0.21.5 may sit inside the gateway's consolidated row; the early
    /// `TASK FAILED` warning delivers nothing — its siblings still run.
    @MainActor static func detect(rows: [HermesTranscriptMessage]) -> [Self] {
        var pending: [String: Self] = [:]
        var delivered: Set<String> = []
        for row in rows {
            if row.role == "user", HermesServiceNotice.isNotice(row.content) {
                for line in row.content.split(separator: "\n")
                where line.hasPrefix("[ASYNC DELEGATION COMPLETE")
                    || line.hasPrefix("[ASYNC DELEGATION BATCH COMPLETE") {
                    if let match = line.range(of: #"deleg_[A-Za-z0-9_-]+"#, options: .regularExpression) {
                        delivered.insert(String(line[match]))
                    }
                }
            }
            guard row.role == "tool", row.toolName == "delegate_task",
                  let data = row.content.data(using: .utf8),
                  let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  result["status"] as? String == "dispatched",
                  result["mode"] as? String == "background",
                  let id = result["delegation_id"] as? String, !id.isEmpty,
                  let count = result["count"] as? Int, count > 0 else { continue }
            // Newer Hermes can deliver each group independently. The root
            // handle is not a completion ID when `units` is present.
            if let units = result["units"] as? [[String: Any]], !units.isEmpty {
                for unit in units {
                    guard let unitID = unit["delegation_id"] as? String, !unitID.isEmpty,
                          let indexes = unit["task_indexes"] as? [Int], !indexes.isEmpty else { continue }
                    pending[unitID] = Self(id: unitID, count: indexes.count, dispatchedAt: row.timestamp)
                }
            } else {
                pending[id] = Self(id: id, count: count, dispatchedAt: row.timestamp)
            }
        }
        return pending.values.filter { !delivered.contains($0.id) }.sorted { $0.id < $1.id }
    }
}
