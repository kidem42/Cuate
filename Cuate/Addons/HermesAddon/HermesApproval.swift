import Foundation

/// Exact-request identity is scoped to the endpoint, session and run. Never
/// restore authority from a saved card; the run's pending snapshot owns it.
nonisolated struct HermesApproval: Identifiable, Equatable, Hashable {
    let endpoint: String
    let sessionID: String
    let runID: String
    let requestID: String
    let command: String
    var id: String { [endpoint, sessionID, runID, requestID].joined(separator: "\u{1f}") }

    static func parse(_ payload: [String: Any], endpoint: String, sessionID: String, runID: String) -> HermesApproval? {
        guard let id = payload["request_id"] as? String,
              !id.isEmpty, id == id.trimmingCharacters(in: .whitespacesAndNewlines), id.count <= 256,
              (payload["run_id"] as? String).map({ $0 == runID }) ?? true,
              let command = payload["command"] as? String, !command.isEmpty else { return nil }
        return HermesApproval(endpoint: endpoint, sessionID: sessionID, runID: runID, requestID: id, command: command)
    }

    static func body(requestID: String, approve: Bool) -> [String: Any] {
        ["request_id": requestID, "choice": approve ? "once" : "deny"]
    }

    static func isMissingRun(status: Int, body: String) -> Bool {
        guard status == 404, let data = body.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = payload["error"] as? [String: Any] else { return false }
        return error["code"] as? String == "run_not_found"
    }
}

nonisolated struct HermesApprovalLedger {
    enum Phase: String { case ready, sending, uncertain, accepted }
    struct Entry: Equatable {
        let request: HermesApproval
        var phase: Phase = .ready
    }
    private(set) var entries: [Entry] = []
    private(set) var revision = 0

    mutating func reconcile(_ requests: [HermesApproval]) {
        var seen = Set<String>()
        entries = requests.filter { seen.insert($0.id).inserted }.map { request in
            entries.first(where: { $0.request == request }) ?? Entry(request: request)
        }
    }

    mutating func begin(_ request: HermesApproval) -> Bool {
        guard let index = entries.firstIndex(where: { $0.request == request && $0.phase == .ready }) else { return false }
        entries[index].phase = .sending
        revision += 1
        return true
    }

    mutating func finish(_ request: HermesApproval, accepted: Bool) {
        guard let index = entries.firstIndex(where: { $0.request == request }) else { return }
        entries[index].phase = accepted ? .accepted : .uncertain
        revision += 1
    }

    /// Only an explicit refresh after a failed POST re-enables a choice.
    /// Polling never repeats a decision or turns uncertainty into consent.
    mutating func allowManualRetry() {
        for index in entries.indices where entries[index].phase == .uncertain { entries[index].phase = .ready }
        revision += 1
    }
}
