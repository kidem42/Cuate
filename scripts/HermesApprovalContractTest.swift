import Foundation

@main struct ApprovalTests {
    static func main() {
        let a = HermesApproval(endpoint: "https://gateway", sessionID: "session", runID: "run", requestID: "a", command: "first")
        let b = HermesApproval(endpoint: a.endpoint, sessionID: a.sessionID, runID: a.runID, requestID: "b", command: "second")
        var ledger = HermesApprovalLedger()
        ledger.reconcile([a, b, a])
        precondition(ledger.entries.count == 2)
        precondition(ledger.begin(a))
        let revision = ledger.revision
        precondition(!ledger.begin(a)) // double tap
        ledger.finish(a, accepted: false) // timeout before or after POST arrival
        precondition(ledger.revision != revision) // older poll must be discarded
        ledger.reconcile([a, b])
        precondition(!ledger.begin(a)) // polling cannot repeat a decision
        precondition(ledger.entries[0].phase == .uncertain)
        ledger.allowManualRetry()
        precondition(ledger.begin(a)) // explicit refresh + a new human choice
        ledger.finish(a, accepted: true)
        ledger.reconcile([a, b]) // pre-settle server snapshot
        precondition(!ledger.begin(a))
        precondition(ledger.begin(b))
        ledger.finish(b, accepted: false)
        ledger.reconcile([b]) // resolved elsewhere, first request disappears
        precondition(!ledger.begin(a)) // stale request never addresses b
        ledger.reconcile([]) // Stop/terminal/timeout
        precondition(ledger.entries.isEmpty)
        precondition(!ledger.begin(b))
        var restored = HermesApprovalLedger()
        restored.reconcile([b]) // reopen from GET, not from cached consent
        precondition(restored.entries[0].phase == .ready)
        let foreign = HermesApproval(endpoint: "https://other", sessionID: b.sessionID, runID: b.runID, requestID: b.requestID, command: b.command)
        precondition(!restored.begin(foreign))
        let approve = HermesApproval.body(requestID: "a", approve: true)
        precondition(approve["choice"] as? String == "once" && approve["request_id"] as? String == "a" && approve.count == 2)
        precondition(HermesApproval.body(requestID: "a", approve: false)["choice"] as? String == "deny")
        precondition(HermesApproval.parse(["id": "a", "command": "x"], endpoint: a.endpoint, sessionID: a.sessionID, runID: a.runID) == nil)
        precondition(HermesApproval.parse(["request_id": "a", "run_id": "wrong", "command": "x"], endpoint: a.endpoint, sessionID: a.sessionID, runID: a.runID) == nil)
        var post = URLRequest(url: URL(string: "https://fixture.invalid/v1/runs/run/approval")!)
        post.httpMethod = "POST"
        post.httpBody = try! JSONSerialization.data(withJSONObject: approve)
        let single = HermesApprovalHTTP.oneShot(post)
        precondition(single.httpBody == nil && single.httpBodyStream != nil)
        precondition(single.value(forHTTPHeaderField: "Content-Length") == String(post.httpBody!.count))
        let policy = HermesApprovalHTTP()
        let task = HermesApprovalHTTP.session.dataTask(with: single) // never resumed
        policy.urlSession(HermesApprovalHTTP.session, task: task, needNewBodyStream: { precondition($0 == nil) })
        policy.urlSession(HermesApprovalHTTP.session, task: task,
            willPerformHTTPRedirection: HTTPURLResponse(url: post.url!, statusCode: 307, httpVersion: nil, headerFields: nil)!,
            newRequest: post, completionHandler: { precondition($0 == nil) })
        task.cancel()
        print("Swift approvals: exact choice, multiple/stale requests, disconnect, recovery, Stop and endpoint scope passed")
    }
}
