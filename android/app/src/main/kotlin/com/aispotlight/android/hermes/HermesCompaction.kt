package com.aispotlight.android.hermes

/**
 * Context-compaction artifacts in gateway transcripts.
 *
 * When a Hermes session overflows its context window, the gateway's
 * ContextCompressor rewrites history into a summary and persists it as a
 * `role == "user"` transcript row (strict providers require valid
 * user/assistant alternation). Mirrored verbatim, that row renders as a
 * message the USER supposedly sent (2026-08-01). The gateway's
 * `_compressed_summary` metadata never crosses the wire — underscore keys
 * are stripped by its sanitizers — so clients detect by the stable content
 * markers, the same way the gateway's own WebUI (SessionsPage.tsx) and
 * `ContextCompressor._is_synthetic_compression_user_turn` do.
 *
 * Keep the constants in sync with hermes-agent `agent/context_compressor.py`
 * (SUMMARY_PREFIX / LEGACY_SUMMARY_PREFIX / _SUMMARY_END_MARKER / _MERGED_* /
 * COMPRESSION_CONTINUATION_USER_CONTENT) and `tools/todo_tool.py`
 * (TODO_INJECTION_HEADER). Mirrors the desktop `HermesCompaction`.
 */
object HermesCompaction {

    /** Head shared by the current handoff prefix, its ASCII-hyphen variant
     *  and every historical one — they all open with this exact text. */
    private const val SUMMARY_PREFIX_HEAD = "[CONTEXT COMPACTION"
    private const val LEGACY_SUMMARY_PREFIX = "[CONTEXT SUMMARY]:"
    private const val END_MARKER =
        "--- END OF CONTEXT SUMMARY — respond to the message below, not the summary above ---"
    private const val MERGED_DELIMITER = "[END OF PRIOR CONTEXT — COMPACTION SUMMARY BELOW]"
    private const val PRIOR_HEADER = "[PRIOR CONTEXT — for reference only; not a new message]"
    private const val TODO_HEADER =
        "[Your active task list was preserved across context compression]"
    private val CONTINUATION_SENTINELS = setOf(
        "Continue from the compressed conversation context above. " +
            "This marker exists because no human user turn was available.",
        "Continue from the compressed conversation context above. " +
            "This marker exists because the compacted transcript contained " +
            "no preserved user turn.",
    )

    private fun startsWithSummaryPrefix(text: String): Boolean =
        text.startsWith(SUMMARY_PREFIX_HEAD) || text.startsWith(LEGACY_SUMMARY_PREFIX)

    /**
     * The user-authored part of a `role == "user"` transcript row, or null
     * when the row is entirely synthetic and must not become a bubble.
     * Merge-into-tail rows (a summary glued onto a REAL user message) return
     * the real part alone.
     */
    fun visibleUserText(content: String): String? {
        val text = content.trimStart()
        if (startsWithSummaryPrefix(text)) {
            // Standalone summary — unless real content was merged in after
            // the end marker (the WebUI splits this shape the same way).
            val markerIdx = text.indexOf(END_MARKER)
            if (markerIdx < 0) return null
            return text.substring(markerIdx + END_MARKER.length).trim().ifEmpty { null }
        }
        val delimiterIdx = text.indexOf(MERGED_DELIMITER)
        if (delimiterIdx >= 0 &&
            startsWithSummaryPrefix(text.substring(delimiterIdx + MERGED_DELIMITER.length).trimStart())
        ) {
            // Merged-into-tail: the REAL preserved turn sits before the
            // delimiter under a "prior context" header.
            return text.substring(0, delimiterIdx)
                .replace(PRIOR_HEADER, "").trim().ifEmpty { null }
        }
        val trimmed = text.trim()
        if (trimmed in CONTINUATION_SENTINELS) return null
        if (trimmed.startsWith(TODO_HEADER)) return null
        return content
    }
}
