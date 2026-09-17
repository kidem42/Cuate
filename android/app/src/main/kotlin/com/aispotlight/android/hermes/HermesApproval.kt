package com.aispotlight.android.hermes

/** Exact-request identity, never a session-wide grant. No persisted consent. */
data class HermesApproval(
    val endpoint: String,
    val sessionID: String,
    val runID: String,
    val requestID: String,
    val command: String,
) {
    val id: String get() = listOf(endpoint, sessionID, runID, requestID).joinToString("\u001f")
}

/** Immutable state makes stale reads and duplicate taps explicit on both clients. */
data class HermesApprovalLedger(
    val entries: List<Entry> = emptyList(),
    val revision: Int = 0,
) {
    enum class Phase { READY, SENDING, UNCERTAIN, ACCEPTED }
    data class Entry(val request: HermesApproval, val phase: Phase = Phase.READY)

    fun reconcile(requests: List<HermesApproval>) = copy(entries = requests.distinctBy { it.id }.map { request ->
        entries.firstOrNull { it.request == request } ?: Entry(request)
    })

    fun begin(request: HermesApproval): HermesApprovalLedger? {
        if (entries.none { it.request == request && it.phase == Phase.READY }) return null
        return copy(revision = revision + 1, entries = entries.map {
            if (it.request == request) it.copy(phase = Phase.SENDING) else it
        })
    }

    fun finish(request: HermesApproval, accepted: Boolean) = copy(revision = revision + 1, entries = entries.map {
        if (it.request == request) it.copy(phase = if (accepted) Phase.ACCEPTED else Phase.UNCERTAIN) else it
    })

    fun allowManualRetry() = copy(revision = revision + 1, entries = entries.map {
        if (it.phase == Phase.UNCERTAIN) it.copy(phase = Phase.READY) else it
    })
}
