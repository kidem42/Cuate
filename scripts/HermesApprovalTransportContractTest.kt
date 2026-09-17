import com.aispotlight.android.core.HttpClient
import com.aispotlight.android.hermes.HermesTransport
import com.aispotlight.android.hermes.HermesTransportException
import com.aispotlight.android.hermes.HermesStreamEvent

suspend fun transportContracts() {
    check(!HermesTransportException(404, "Not Found").isMissingRun)
    check(HermesTransportException(404, """{"error":{"code":"run_not_found"}}""").isMissingRun)
    check(!HermesTransportException(503, """{"error":{"code":"run_not_found"}}""").isMissingRun)
    val client = HermesTransport("https://fixture.invalid", "test-key")
    HttpClient.payload = """{"status":"waiting_for_approval","approvals":[
        {"request_id":"a","command":"first","run_id":"run"},
        {"request_id":"b","command":"second"},
        {"id":"legacy","command":"invalid"},
        {"request_id":"foreign","command":"invalid","run_id":"other"}]}"""
    val state = client.runState("run")
    check(state.isLive && !state.isTerminal && state.approvals == listOf("a" to "first", "b" to "second"))
    for (approve in listOf(true, false)) {
        val choice = if (approve) "once" else "deny"
        HttpClient.payload = """{"run_id":"run","request_id":"b","choice":"$choice","resolved":1}"""
        client.resolveApproval("run", "b", approve)
        check(HttpClient.lastBody.length() == 2)
        check(HttpClient.lastBody.getString("request_id") == "b")
        check(HttpClient.lastBody.getString("choice") == choice && HttpClient.oneShot)
    }
    HttpClient.payload = """{"run_id":"run","request_id":"other","choice":"once","resolved":1}"""
    check(runCatching { client.resolveApproval("run", "b", true) }.isFailure)
    for (status in listOf(404, 409, 503, 307)) {
        HttpClient.status = status
        val before = HttpClient.calls
        val error = runCatching { client.resolveApproval("run", "a", true) }.exceptionOrNull()
        check(error is HermesTransportException && error.status == status)
        check(HttpClient.calls == before + 1)
    }
    HttpClient.status = 200
    HttpClient.fail = true
    val before = HttpClient.calls
    check(runCatching { client.resolveApproval("run", "a", true) }.exceptionOrNull() is java.io.IOException)
    check(HttpClient.calls == before + 1)
    HttpClient.fail = false
    val event = HermesTransport.parseEvent("approval.changed", """{"run_id":"run"}""")
    check(event is HermesStreamEvent.Unknown && event.event == "approval.changed")
    println("Kotlin transport: real parsing, exact bodies, one-shot POST, HTTP errors and disconnect passed")
}
