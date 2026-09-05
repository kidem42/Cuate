package com.aispotlight.android.hermes

/**
 * Mid-turn follow-ups (steer) — the cross-device text contract.
 *
 * A message typed while an agent turn runs rides INTO the running turn
 * (`POST /v1/runs/{id}/steer`, or the patched session route). Hermes appends
 * the text to the last tool result of its next completed tool batch, wrapped
 * in the out-of-band markers from `agent/prompt_builder.py`, and its system
 * prompt tells the model to treat the marker as a direct user instruction
 * "with the same authority as the original request" and to "adjust course
 * accordingly" — nothing says the task in progress is still the task, and
 * the model pivots to the follow-up (live 2026-09-04 on the desktop).
 *
 * Cuate's contract: everything typed mid-turn is an ADDITION to the cycle in
 * progress — the addition itself may well redirect the work ("stop that, do
 * this instead"), so the frame says only which cycle it belongs to and
 * leaves the rest to the user's words. The wire text carries that in a
 * tagged addendum block ahead of the words; the local bubble
 * shows only the words, and the mirror strips the block when the marker
 * comes back inside a tool row ([texts]). A steer the agent never read
 * (`pending_steer` on `run.completed`) is unframed and re-sent as a turn.
 *
 * Pure Kotlin: covered by the unit test `HermesSteerTest`.
 * Twin: `HermesSteer` on the desktop (`Addons/HermesAddon/HermesSteer.swift`)
 * — keep in sync; both are checked against `shared/fixtures/steer-frame.json`.
 */
object HermesSteer {
    /**
     * Hermes' own markers around a steer inside a tool result. The open
     * marker's bracket text may evolve between versions, so matching is
     * anchored on its stable prefix; the close marker is exact.
     */
    const val OPEN_PREFIX = "[OUT-OF-BAND USER MESSAGE"
    const val CLOSE_MARKER = "[/OUT-OF-BAND USER MESSAGE]"

    const val FRAME_OPEN = "<cuate-addendum>"
    const val FRAME_CLOSE = "</cuate-addendum>"

    /**
     * English regardless of the UI language, like the briefing: it talks to
     * the agent, whose system prompt is English. Byte-identical on the
     * desktop (the fixture pins it).
     */
    val FRAME: String = FRAME_OPEN + "\n" +
        "The user is adding to the request you are working on right now: " +
        "take the addition below into account in the current cycle.\n" +
        FRAME_CLOSE

    /** The wire text of a mid-turn send. */
    fun framed(text: String): String = FRAME + "\n\n" + text

    /**
     * The user's own words of a wire text, one piece per addendum block.
     * Hermes joins steers accepted before one drain point with a newline,
     * so a single marker — or a single `pending_steer` — may carry several
     * framed sends. Text outside any block (a steer from a device without
     * the frame, the CLI's `/steer`) is a piece of its own; an unclosed open
     * tag is literal text. Pieces are trimmed; empty ones drop.
     */
    fun pieces(text: String): List<String> {
        val result = mutableListOf<String>()
        var cursor = 0
        fun flush(end: Int) {
            val piece = text.substring(cursor, end).trim()
            if (piece.isNotEmpty()) result.add(piece)
        }
        while (true) {
            val open = text.indexOf(FRAME_OPEN, cursor)
            if (open < 0) break
            val close = text.indexOf(FRAME_CLOSE, open + FRAME_OPEN.length)
            if (close < 0) break
            flush(open)
            cursor = close + FRAME_CLOSE.length
        }
        flush(text.length)
        return result
    }

    /**
     * The user's own words of a wire text as one string (what a replayed
     * `pending_steer` sends as the next turn).
     */
    fun unframed(text: String): String = pieces(text).joinToString("\n\n")

    /**
     * The steered texts inside one tool row's content, in order — the
     * user's words only, addendum blocks stripped.
     */
    fun texts(toolContent: String): List<String> {
        if (!toolContent.contains(OPEN_PREFIX)) return emptyList()
        val result = mutableListOf<String>()
        var cursor = 0
        while (true) {
            val open = toolContent.indexOf(OPEN_PREFIX, cursor)
            if (open < 0) break
            // End of the open marker's bracket, then the payload up to close.
            val bracket = toolContent.indexOf(']', open + OPEN_PREFIX.length)
            if (bracket < 0) break
            val close = toolContent.indexOf(CLOSE_MARKER, bracket + 1)
            if (close < 0) break
            result.addAll(pieces(toolContent.substring(bracket + 1, close)))
            cursor = close + CLOSE_MARKER.length
        }
        return result
    }
}
