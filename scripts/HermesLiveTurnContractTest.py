#!/usr/bin/env python3
"""Exercise transcript transitions with the real Swift value types, without the app."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def declaration(path, name):
    source = (ROOT / path).read_text()
    start = source.index(f"struct {name}")
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


TEST = r'''
@main
struct Contracts {
    @MainActor static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func row(_ id: Int, _ role: String, _ text: String = "",
                 calls: [(id: String, name: String, arguments: String)] = []) -> HermesTranscriptMessage {
            HermesTranscriptMessage(id: id, role: role, content: text, toolName: nil,
                toolCallID: nil, toolCallArguments: calls, timestamp: now)
        }
        var count = 0
        func check(_ value: Bool, _ name: String) {
            guard value else { fatalError(name) }
            count += 1
            print("ok: \(name)")
        }
        let user = row(1, "user", "Research the service companies")
        let acknowledgement = row(2, "assistant", "I am collecting the results.")
        let notice = row(3, "user", "[ASYNC DELEGATION BATCH COMPLETE — example]\nResults")
        let base = [user, acknowledgement]
        let waiting = base + [notice]
        let call = row(4, "assistant", calls: [("call-1", "web_search", "{}")])
        let answer = row(5, "assistant", "Here is the consolidated report.")
        check(HermesLiveTurnDetector.detect(rows: [], now: now) == nil, "empty transcript")
        check(HermesLiveTurnDetector.detect(rows: base, now: now) == nil, "finished exchange")
        check(HermesLiveTurnDetector.detect(rows: waiting, now: now)?.source == .awaitingContinuation,
              "batch completion is waiting, not observed agent work")
        check(HermesLiveTurnDetector.detect(rows: [notice], now: now)?.source == .awaitingContinuation,
              "notice-only transcript after history truncation")
        check(HermesLiveTurnDetector.detect(rows: waiting + [call], now: now)?.source == .tail,
              "continuation tool call promotes waiting to work")
        check(HermesLiveTurnDetector.detect(rows: waiting + [call], now: now)?.steps.first?.status == .running,
              "continuation retains its running tool")
        check(HermesLiveTurnDetector.detect(rows: waiting + [answer], now: now) == nil,
              "synthesis ends waiting")
        check(HermesLiveTurnDetector.detect(rows: waiting, now: now.addingTimeInterval(1200)) == nil,
              "unanswered report expires")
        check(HermesLiveTurnDetector.detect(rows: [user], now: now)?.source == .tail,
              "ordinary unanswered message retains existing recovery")
        check(HermesLiveTurnDetector.completionPreview(rows: waiting, previousCount: 2) == nil,
              "report must not re-notify the acknowledgement")
        check(HermesLiveTurnDetector.completionPreview(rows: waiting + [call], previousCount: 3) == nil,
              "tool shell does not notify")
        check(HermesLiveTurnDetector.completionPreview(rows: waiting + [answer], previousCount: 3) == answer.content,
              "new synthesis notifies with its own text")
        check(HermesLiveTurnDetector.completionPreview(rows: waiting + [answer], previousCount: 4) == nil,
              "unchanged transcript does not notify")
        check(HermesLiveTurnDetector.completionPreview(rows: base + [row(3, "tool", "result")], previousCount: 2) == nil,
              "tool result does not notify")
        check(HermesLiveTurnDetector.completionPreview(rows: base + [row(3, "assistant", "  \n")], previousCount: 2) == nil,
              "blank assistant does not notify")
        check(HermesLiveTurnDetector.completionPreview(rows: base + [row(3, "assistant", "Checking", calls: [("c", "tool", "{}")])], previousCount: 2) == nil,
              "text with tool calls is not completion")
        let process = row(3, "user", "[Background process completed]")
        check(HermesLiveTurnDetector.detect(rows: base + [process], now: now)?.source == .awaitingContinuation,
              "background process report also waits for continuation")
        let request = HermesContinuationRequest.detect(rows: waiting, endpoint: "https://one.test", sessionID: "session-a")!
        var consent = HermesContinuationConsent()
        check(consent.needsDecision(request) && !consent.allowsAutomatically(request), "new session asks by default")
        check(HermesContinuationRequest.detect(rows: base, endpoint: "one", sessionID: "a") == nil, "ordinary answer requests no continuation")
        check(HermesContinuationRequest.detect(rows: waiting + [answer], endpoint: "one", sessionID: "a") == nil, "another client answer supersedes report")
        check(HermesContinuationRequest.detect(rows: waiting + [call], endpoint: "one", sessionID: "a") == nil, "active tool work supersedes report")
        check(HermesContinuationRequest.detect(rows: waiting + [row(6, "user", "New task")], endpoint: "one", sessionID: "a") == nil, "new human turn supersedes report")
        let oldReport = HermesTranscriptMessage(id: 3, role: "user", content: notice.content,
            toolName: nil, toolCallID: nil, toolCallArguments: [], timestamp: now.addingTimeInterval(-86400))
        check(HermesContinuationRequest.detect(rows: base + [oldReport], endpoint: "https://one.test", sessionID: "session-a") == request, "consent does not expire with live heuristic")
        consent.setAutomatic(true, scope: request.scope)
        check(consent.allowsAutomatically(request), "explicit session opt-in")
        let otherSession = HermesContinuationRequest(endpoint: request.endpoint, sessionID: "session-b", rowIDs: request.rowIDs)
        let otherGateway = HermesContinuationRequest(endpoint: "https://two.test", sessionID: request.sessionID, rowIDs: request.rowIDs)
        check(!consent.allowsAutomatically(otherSession), "approval never leaks to another session")
        check(!consent.allowsAutomatically(otherGateway), "approval never leaks to another gateway")
        consent.handle(request)
        check(!consent.needsDecision(request), "repeated poll never reissues claimed result")
        let restored = try! JSONDecoder().decode(HermesContinuationConsent.self, from: JSONEncoder().encode(consent))
        check(restored == consent && !restored.needsDecision(request), "restart preserves claim and scoped consent")
        let next = HermesContinuationRequest(endpoint: request.endpoint, sessionID: request.sessionID, rowIDs: [3, 7])
        check(consent.needsDecision(next) && consent.allowsAutomatically(next), "new delivery can continue under existing consent")
        let combined = HermesContinuationRequest.detect(rows: waiting + [row(7, "user", notice.content)], endpoint: request.endpoint, sessionID: request.sessionID)!
        check(combined == next, "multiple deliveries share one continuation")
        consent.handle(combined)
        check(!consent.needsDecision(next) && !consent.needsDecision(request), "batched claim covers all deliveries")
        consent.setAutomatic(false, scope: request.scope)
        check(!consent.allowsAutomatically(request) && !consent.needsDecision(request), "revocation retains deduplication")
        check(consent.needsDecision(otherGateway) && consent.needsDecision(otherSession), "claims isolated across gateways and sessions")
        check(HermesContinuationRequest.detect(rows: base + [process], endpoint: "one", sessionID: "a") != nil, "background process delivery also requests consent")

        func dispatch(_ json: String) -> HermesTranscriptMessage {
            HermesTranscriptMessage(id: 20, role: "tool", content: json,
                toolName: "delegate_task", toolCallID: "d", toolCallArguments: [], timestamp: now)
        }
        let dispatched = dispatch(#"{"status":"dispatched","mode":"background","count":2,"delegation_id":"deleg_batch"}"#)
        let pending = HermesBackgroundWork.detect(rows: [user, dispatched, acknowledgement])
        check(pending.count == 1 && pending.first?.count == 2, "parent acknowledgement retains background dispatch")
        check(HermesBackgroundWork.detect(rows: [dispatched, answer, user]) == pending, "later parent and human turns cannot complete children")
        check(HermesBackgroundWork.detect(rows: [dispatched, dispatched]) == pending, "duplicate dispatch is idempotent")
        let delivery = row(21, "user", "[ASYNC DELEGATION BATCH COMPLETE — deleg_batch]\nResults")
        check(HermesBackgroundWork.detect(rows: [dispatched, delivery]).isEmpty, "matching batch delivery clears work")
        check(HermesBackgroundWork.detect(rows: [dispatched, notice]) == pending, "unrelated completion retains work")
        check(HermesBackgroundWork.detect(rows: [dispatched, row(22, "assistant", delivery.content)]) == pending, "assistant prose cannot impersonate a delivery")
        check(HermesBackgroundWork.detect(rows: [dispatch("{}"), dispatch("broken"), answer]).isEmpty, "missing or malformed payload never implies background work")
        check(HermesBackgroundWork.detect(rows: [dispatch(#"{"status":"completed","mode":"background","count":2,"delegation_id":"deleg_batch"}"#)]).isEmpty, "synchronous result does not start waiting")
        check(!pending[0].isUnconfirmed(at: now.addingTimeInterval(60)), "recent dispatch animates waiting")
        check(pending[0].isUnconfirmed(at: now.addingTimeInterval(1200)), "stale dispatch exposes uncertainty instead of endless running")
        let grouped = dispatch(#"{"status":"dispatched","mode":"background","count":3,"delegation_id":"deleg_root","units":[{"delegation_id":"deleg_a","group":"a","task_indexes":[0,1]},{"delegation_id":"deleg_b","group":null,"task_indexes":[2]}]}"#)
        let units = HermesBackgroundWork.detect(rows: [grouped])
        check(units.map(\.count) == [2, 1], "latest Hermes completion units preserve their child counts")
        let firstDelivery = row(23, "user", "[ASYNC DELEGATION BATCH COMPLETE — deleg_a]\nResults")
        let lastDelivery = row(24, "user", "[ASYNC DELEGATION COMPLETE — deleg_b]\nResult")
        check(HermesBackgroundWork.detect(rows: [grouped, firstDelivery]).map(\.id) == ["deleg_b"], "partial completion keeps remaining unit visible")
        check(HermesBackgroundWork.detect(rows: [grouped, firstDelivery, lastDelivery]).isEmpty, "all unit deliveries finish background work without root delivery")
        print("\(count) Hermes transcript contracts passed")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="cuate-live-turn-") as temp:
    directory = Path(temp)
    types = directory / "Types.swift"
    types.write_text("import Foundation\n" + declaration(
        "Cuate/Addons/HermesAddon/HermesTransport.swift", "HermesTranscriptMessage"
    ) + "\n" + declaration(
        "Cuate/Addons/AgentGateway/Core/AgentSession.swift", "AgentStep"
    ))
    test = directory / "Test.swift"
    test.write_text("import Foundation\n" + TEST)
    binary = directory / "contracts"
    subprocess.run([
        "xcrun", "swiftc", "-module-cache-path", str(directory / "cache"),
        str(types), str(ROOT / "Cuate/Addons/HermesAddon/HermesServiceNotice.swift"),
        str(ROOT / "Cuate/Addons/HermesAddon/HermesLiveTurn.swift"),
        str(ROOT / "Cuate/Addons/HermesAddon/HermesContinuation.swift"),
        str(ROOT / "Cuate/Addons/HermesAddon/HermesBackgroundWork.swift"), str(test),
        "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
