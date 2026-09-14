import Foundation

/// Client-owned consent for a stateless gateway's completed background deliveries.
/// No message content is persisted in this ledger. Approval never covers tools.
nonisolated struct HermesContinuationRequest: Equatable, Identifiable {
    let endpoint: String
    let sessionID: String
    let rowIDs: [Int]
    var scope: String { Self.scope(endpoint: endpoint, sessionID: sessionID) }
    var id: String { scope + ":" + rowIDs.map(String.init).joined(separator: ",") }

    static func scope(endpoint: String, sessionID: String) -> String {
        // Length framing prevents collisions and keeps different gateways isolated.
        "\(endpoint.utf8.count):\(endpoint)\(sessionID)"
    }

    /// Only an unconsumed suffix of service deliveries requests continuation.
    /// Any later user/assistant/tool activity supersedes this request. Unlike
    /// the live-turn heuristic, a human decision has no twenty-minute expiry.
    @MainActor static func detect(rows: [HermesTranscriptMessage], endpoint: String,
                       sessionID: String) -> Self? {
        let tail = rows.reversed().prefix {
            $0.role == "user" && HermesServiceNotice.isNotice($0.content)
        }
        guard !tail.isEmpty else { return nil }
        return Self(endpoint: endpoint, sessionID: sessionID,
                    rowIDs: tail.reversed().map(\.id))
    }
}

nonisolated struct HermesContinuationConsent: Codable, Equatable {
    var automaticScopes: Set<String> = []
    var handledRows: [String: Set<Int>] = [:]

    func allowsAutomatically(_ request: HermesContinuationRequest) -> Bool {
        automaticScopes.contains(request.scope)
    }
    func needsDecision(_ request: HermesContinuationRequest) -> Bool {
        !Set(request.rowIDs).isSubset(of: handledRows[request.scope] ?? [])
    }
    mutating func handle(_ request: HermesContinuationRequest) {
        handledRows[request.scope, default: []].formUnion(request.rowIDs)
    }
    mutating func setAutomatic(_ allowed: Bool, scope: String) {
        if allowed { automaticScopes.insert(scope) }
        else { automaticScopes.remove(scope) }
    }
}
