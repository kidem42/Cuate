package com.aispotlight.android.data

/** Denominators stay explicit: a displayed answer can contain several billed requests. */
object SpendAnalytics {
    data class Average(val input: Int, val output: Int, val count: Int)
    private fun average(groups: Collection<List<SpendRecordEntity>>): Average? {
        val complete = groups.filter { rows -> rows.all { it.usageState == null || it.usageState == "complete" } }
        if (complete.isEmpty()) return null
        return Average(
            (complete.sumOf { rows -> rows.sumOf { it.inputTokens.toLong() + it.cacheReadTokens + it.cacheWriteTokens } } / complete.size).toInt(),
            (complete.sumOf { rows -> rows.sumOf { it.outputTokens.toLong() } } / complete.size).toInt(),
            complete.size,
        )
    }
    fun perAnswer(records: List<SpendRecordEntity>): Average? = average(
        records.filter { it.kind == SpendKind.CHAT.raw }.groupBy { it.operationID ?: it.id }.values
    )
    /** Legacy aggregate rows cannot truthfully be presented as single HTTP requests. */
    fun perRequest(records: List<SpendRecordEntity>): Average? = average(
        records.filter { it.kind == SpendKind.CHAT.raw && it.usageState != null }.map { listOf(it) }
    )
}
