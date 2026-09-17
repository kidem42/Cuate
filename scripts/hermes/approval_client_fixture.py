"""Compile real Swift control methods with a scripted transport boundary."""
from pathlib import Path


def swift_fixture(root):
    root = Path(root)
    transport = (root / "Cuate/Addons/HermesAddon/HermesTransport.swift").read_text()
    methods = transport.split("    struct RunState {", 1)[1].split("    // MARK: Chat stream", 1)[0]
    addon = (root / "Cuate/Addons/HermesAddon/HermesAddon.swift").read_text()
    control = addon.split("    @Published private(set) var approvalLedgers", 1)[1].split("    // MARK: - Stopping a run", 1)[0]
    control = "    private(set) var approvalLedgers" + control.replace("@Published ", "")
    settings = (root / "Cuate/Addons/HermesAddon/HermesSettings.swift").read_text()
    scope_methods = "    func activeRun(forSession" + settings.split("    func activeRun(forSession", 1)[1].split("    // MARK: - Sends held", 1)[0]
    scope_migration = '        if defaults.dictionary(forKey: "hermes.activeRunEndpoints") == nil {' + settings.split('        if defaults.dictionary(forKey: "hermes.activeRunEndpoints") == nil {', 1)[1].split("\n        }", 1)[0] + "\n        }"
    scope_fixture = """@MainActor final class TestDefaults {
+    var values: [String: Any] = [:]
+    func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
+    func set(_ value: Any, forKey key: String) { values[key] = value }
+}
+@MainActor final class ScopedSettings {
+    let defaults = TestDefaults()
+    var endpointURL = "https://original"
+    var activeRunBySession = ["session": "existing-run"]
+    init() {
+""".replace("\n+", "\n") + scope_migration + "\n    }\n" + scope_methods + "\n}\n"
    return scope_fixture + '''import Foundation
enum HermesTransportError: Error { case http(status: Int, body: String) }
@MainActor final class HermesTransport {
    var replies: [Result<[String: Any], Error>] = []
    var posts: [[String: Any]] = []
    func json(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        if method == "POST" { posts.append(body ?? [:]) }
        guard !replies.isEmpty else { fatalError("unexpected HTTP call") }
        return try replies.removeFirst().get()
    }
    struct RunState {''' + methods + '''
}
@MainActor final class Settings {
    var endpointURL = "https://gateway"
    var run: String? = "run"
    func activeRun(forSession: String) -> String? { run }
    func setActiveRun(_ id: String?, forSession: String) { run = id }
}
enum Diagnostics { static func log(_ category: String, _ message: String) {} }
@MainActor final class Addon {
    let settings = Settings()
    let client = HermesTransport()
    var stopTasks: [String: Bool] = [:]
    func transport() -> HermesTransport { client }
    func markTailDead(sessionID: String) {}
''' + control + '''
}
@main struct Integration {
    @MainActor static func main() async {
        let scoped = ScopedSettings()
        precondition(scoped.activeRun(forSession: "session") == "existing-run")
        scoped.endpointURL = "https://other"
        precondition(scoped.activeRun(forSession: "session") == nil)
        precondition(scoped.activeRunBySession["session"] == "existing-run")
        scoped.endpointURL = "https://original"
        precondition(scoped.activeRun(forSession: "session") == "existing-run")
        scoped.setActiveRun("new-run", forSession: "new-session")
        precondition(scoped.activeRun(forSession: "new-session") == "new-run")
        let addon = Addon()
        let client = addon.client
        client.replies = [.failure(HermesTransportError.http(status: 404, body: "Not Found"))]
        if case .unreachable = await client.runProbe(runID: "run") {} else { preconditionFailure("route 404 lost a run") }
        client.replies = [.failure(HermesTransportError.http(status: 404, body: #"{"error":{"code":"run_not_found"}}"#))]
        if case .gone = await client.runProbe(runID: "run") {} else { preconditionFailure("missing run not recognized") }
        let pending: [String: Any] = ["status": "waiting_for_approval", "approvals": [
            ["request_id": "a", "run_id": "run", "command": "first"],
            ["request_id": "b", "run_id": "run", "command": "second"]]]
        client.replies = [.success(pending)]
        await addon.refreshApprovals(sessionID: "session")
        precondition(addon.settings.run == "run")
        let a = addon.approvalLedgers["session"]!.entries[0].request
        let b = addon.approvalLedgers["session"]!.entries[1].request
        client.replies = [.success(pending), .failure(URLError(.networkConnectionLost)), .success(pending)]
        await addon.resolveApproval(a, approve: true)
        precondition(client.posts.count == 1)
        precondition(client.posts[0]["request_id"] as? String == "a" && client.posts[0]["choice"] as? String == "once")
        precondition(addon.approvalLedgers["session"]!.entries[0].phase == .uncertain)
        await addon.resolveApproval(a, approve: true) // duplicate tap: no HTTP calls
        precondition(client.posts.count == 1)
        client.replies = [.failure(URLError(.notConnectedToInternet))]
        await addon.refreshApprovals(sessionID: "session", manual: true)
        precondition(addon.approvalLedgers["session"]!.entries[0].phase == .uncertain)
        precondition(addon.settings.run == "run")
        addon.stopTasks["run"] = true
        await addon.resolveApproval(b, approve: false) // Stop wins before POST
        precondition(client.posts.count == 1)
        addon.stopTasks.removeAll()
        client.replies = [.success(pending)]
        await addon.refreshApprovals(sessionID: "session", manual: true)
        let onlyA: [String: Any] = ["status": "waiting_for_approval", "approvals": Array((pending["approvals"] as! [[String: Any]]).prefix(1))]
        client.replies = [.success(pending), .success(["run_id":"run", "request_id":"b", "choice":"deny", "resolved":1]), .success(onlyA)]
        await addon.resolveApproval(b, approve: false)
        precondition(client.posts.count == 2 && client.posts[1]["choice"] as? String == "deny")
        precondition(addon.approvalLedgers["session"]!.entries.count == 1)
        await addon.resolveApproval(b, approve: true) // stale card
        precondition(client.posts.count == 2)
        client.replies = [.success(["status":"stopping"])]
        await addon.refreshApprovals(sessionID: "session")
        precondition(addon.settings.run == "run" && addon.approvalLedgers["session"]!.entries.isEmpty)
        client.replies = [.success(["status":"cancelled"])]
        await addon.refreshApprovals(sessionID: "session")
        precondition(addon.settings.run == nil)
        print("Swift integration: real status/resolve methods, disconnected POST, manual refresh, stale request and Stop passed")
    }
}
'''


def kotlin_settings_fixture(root):
    source = (Path(root) / "android/app/src/main/kotlin/com/aispotlight/android/settings/AppSettings.kt").read_text()
    methods = "    private val _hermesActiveRuns" + source.split("    private val _hermesActiveRuns", 1)[1].split("    /**", 1)[0]
    return '''import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
class ScopedRunSettings {
    private val maps = mutableMapOf("hermesActiveRuns" to mapOf("session" to "existing-run"))
    private val _hermesEndpoint = MutableStateFlow("https://original")
    private val prefs = object { fun contains(key: String) = maps.containsKey(key) }
    private fun readStringMap(key: String): Map<String, String> = maps[key].orEmpty()
    private fun writeStringMap(key: String, value: Map<String, String>) { maps[key] = value }
    fun endpoint(value: String) { _hermesEndpoint.value = value }
''' + methods + '''
}
fun runSettingsContracts() {
    val settings = ScopedRunSettings()
    check(settings.hermesActiveRun("session") == "existing-run")
    settings.endpoint("https://other")
    check(settings.hermesActiveRun("session") == null)
    check(settings.hermesActiveRuns.value["session"] == "existing-run")
    settings.endpoint("https://original")
    check(settings.hermesActiveRun("session") == "existing-run")
    settings.setHermesActiveRun("new-session", "new-run")
    check(settings.hermesActiveRun("new-session") == "new-run")
}
'''
