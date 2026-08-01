import Foundation

/// Context-compaction artifacts in gateway transcripts.
///
/// When a Hermes session overflows its context window, the gateway's
/// ContextCompressor rewrites history into a summary and persists it as a
/// `role == "user"` transcript row (strict providers require valid
/// user/assistant alternation). Mirrored verbatim, that row renders as a
/// message the USER supposedly sent (2026-08-01, first seen on Android).
/// The gateway's `_compressed_summary` metadata never crosses the wire —
/// underscore keys are stripped by its sanitizers — so clients detect by
/// the stable content markers, the same way the gateway's own WebUI
/// (SessionsPage.tsx) and `ContextCompressor._is_synthetic_compression_user_turn`
/// do.
///
/// Keep the constants in sync with hermes-agent `agent/context_compressor.py`
/// (SUMMARY_PREFIX / LEGACY_SUMMARY_PREFIX / _SUMMARY_END_MARKER / _MERGED_* /
/// COMPRESSION_CONTINUATION_USER_CONTENT) and `tools/todo_tool.py`
/// (TODO_INJECTION_HEADER). Mirrors the Android `HermesCompaction`.
enum HermesCompaction {

    /// Head shared by the current handoff prefix, its ASCII-hyphen variant
    /// and every historical one — they all open with this exact text.
    private static let summaryPrefixHead = "[CONTEXT COMPACTION"
    private static let legacySummaryPrefix = "[CONTEXT SUMMARY]:"
    private static let endMarker =
        "--- END OF CONTEXT SUMMARY — respond to the message below, not the summary above ---"
    private static let mergedDelimiter = "[END OF PRIOR CONTEXT — COMPACTION SUMMARY BELOW]"
    private static let priorHeader = "[PRIOR CONTEXT — for reference only; not a new message]"
    private static let todoHeader =
        "[Your active task list was preserved across context compression]"
    private static let continuationSentinels: Set<String> = [
        "Continue from the compressed conversation context above. "
            + "This marker exists because no human user turn was available.",
        "Continue from the compressed conversation context above. "
            + "This marker exists because the compacted transcript contained "
            + "no preserved user turn.",
    ]

    private static func startsWithSummaryPrefix(_ text: String) -> Bool {
        text.hasPrefix(summaryPrefixHead) || text.hasPrefix(legacySummaryPrefix)
    }

    /// The user-authored part of a `role == "user"` transcript row, or nil
    /// when the row is entirely synthetic and must not become a bubble.
    /// Merge-into-tail rows (a summary glued onto a REAL user message)
    /// return the real part alone.
    static func visibleUserText(_ content: String) -> String? {
        let text = String(content.drop(while: \.isWhitespace))
        if startsWithSummaryPrefix(text) {
            // Standalone summary — unless real content was merged in after
            // the end marker (the WebUI splits this shape the same way).
            guard let marker = text.range(of: endMarker) else { return nil }
            let remainder = text[marker.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return remainder.isEmpty ? nil : remainder
        }
        if let delimiter = text.range(of: mergedDelimiter),
           startsWithSummaryPrefix(String(text[delimiter.upperBound...].drop(while: \.isWhitespace))) {
            // Merged-into-tail: the REAL preserved turn sits before the
            // delimiter under a "prior context" header.
            let prior = String(text[..<delimiter.lowerBound])
                .replacingOccurrences(of: priorHeader, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return prior.isEmpty ? nil : prior
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if continuationSentinels.contains(trimmed) { return nil }
        if trimmed.hasPrefix(todoHeader) { return nil }
        return content
    }
}
