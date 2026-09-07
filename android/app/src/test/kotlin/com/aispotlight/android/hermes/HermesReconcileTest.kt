package com.aispotlight.android.hermes

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * [HermesChatService.undeliveredSteers], the pure half: which texts
 * steered into a run the transcript never shows once the run is over.
 * A delivered steer rides a tool row verbatim inside Hermes' out-of-band
 * markers; a missing one was never read by the agent.
 */
class HermesReconcileTest {

    private fun row(id: Int, role: String, content: String, at: Long?) =
        HermesTranscriptMessage(
            id = id, role = role, content = content, toolName = null,
            toolCallID = null, toolCallArguments = emptyList(), timestampMs = at,
        )

    private val t0 = 1_700_000_000_000L

    @Test
    fun `a steer inside a tool row after it was sent counts as delivered`() {
        val rows = listOf(
            row(1, "user", "make the table", t0),
            row(2, "tool", "ok\n[OUT-OF-BAND USER MESSAGE from the user]\n" +
                HermesSteer.framed("add a totals row") + "\n[/OUT-OF-BAND USER MESSAGE]", t0 + 5_000),
            row(3, "assistant", "Done.", t0 + 9_000),
        )
        val lost = HermesChatService.undeliveredSteers(rows, listOf(t0 + 3_000 to "add a totals row"))
        assertEquals(emptyList<String>(), lost)
    }

    @Test
    fun `a steer no row carries is undelivered`() {
        val rows = listOf(
            row(1, "user", "make the table", t0),
            row(2, "assistant", "Done.", t0 + 9_000),
        )
        val lost = HermesChatService.undeliveredSteers(rows, listOf(t0 + 3_000 to "add a totals row"))
        assertEquals(listOf("add a totals row"), lost)
    }

    @Test
    fun `an earlier identical message does not vouch for a later steer`() {
        val rows = listOf(
            row(1, "user", "add a totals row", t0 - 3 * 60 * 60_000L),
            row(2, "assistant", "Added.", t0 - 3 * 60 * 60_000L + 4_000),
            row(3, "user", "make the table", t0),
            row(4, "assistant", "Done.", t0 + 9_000),
        )
        val lost = HermesChatService.undeliveredSteers(rows, listOf(t0 + 3_000 to "add a totals row"))
        assertEquals(listOf("add a totals row"), lost)
    }

    @Test
    fun `a row without a timestamp is still checked for the text`() {
        val rows = listOf(row(1, "tool", "…\n[OUT-OF-BAND USER MESSAGE]\nadd a totals row\n[/OUT-OF-BAND USER MESSAGE]", null))
        val lost = HermesChatService.undeliveredSteers(rows, listOf(t0 to "add a totals row"))
        assertEquals(emptyList<String>(), lost)
    }

    @Test
    fun `duplicates collapse and delivered ones drop`() {
        val rows = listOf(
            row(1, "tool", "[OUT-OF-BAND USER MESSAGE]\nfirst\n[/OUT-OF-BAND USER MESSAGE]", t0 + 1_000),
        )
        val lost = HermesChatService.undeliveredSteers(
            rows, listOf(t0 to "first", t0 + 2_000 to "second", t0 + 4_000 to "second"),
        )
        assertEquals(listOf("second"), lost)
    }
}
