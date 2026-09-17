import com.aispotlight.android.hermes.HermesApproval
import com.aispotlight.android.hermes.HermesApprovalLedger

fun main() = kotlinx.coroutines.runBlocking {
    val a = HermesApproval("https://gateway", "session", "run", "a", "first")
    val b = a.copy(requestID = "b", command = "second")
    var ledger = HermesApprovalLedger().reconcile(listOf(a, b, a))
    check(ledger.entries.size == 2)
    ledger = checkNotNull(ledger.begin(a))
    val revision = ledger.revision
    check(ledger.begin(a) == null)
    ledger = ledger.finish(a, false).reconcile(listOf(a, b))
    check(ledger.revision != revision)
    check(ledger.begin(a) == null)
    check(ledger.entries[0].phase == HermesApprovalLedger.Phase.UNCERTAIN)
    ledger = checkNotNull(ledger.allowManualRetry().begin(a)).finish(a, true).reconcile(listOf(a, b))
    check(ledger.begin(a) == null)
    ledger = checkNotNull(ledger.begin(b)).finish(b, false).reconcile(listOf(b))
    check(ledger.begin(a) == null)
    ledger = ledger.reconcile(emptyList())
    check(ledger.entries.isEmpty() && ledger.begin(b) == null)
    val restored = HermesApprovalLedger().reconcile(listOf(b))
    check(restored.entries[0].phase == HermesApprovalLedger.Phase.READY)
    check(restored.begin(b.copy(endpoint = "https://other")) == null)
    check(restored.begin(b.copy(runID = "other")) == null)
    runSettingsContracts()
    transportContracts()
    com.aispotlight.android.core.HttpClient.client.dispatcher.executorService.shutdown()
    println("Kotlin approvals: multiple/stale requests, disconnect, recovery, Stop and endpoint scope passed")
}
