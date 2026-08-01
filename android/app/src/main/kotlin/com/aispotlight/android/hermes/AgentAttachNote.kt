package com.aispotlight.android.hermes

/**
 * THE cross-device contract for attachment delivery in agent chats — the
 * Kotlin twin of the desktop `AgentAttachNote.swift`, kept in lockstep;
 * `shared/fixtures/attach-note.json` is the executable source of truth
 * (run `scripts/test-attach-note.sh` after touching either side).
 *
 * The Hermes gateway stores only text (no pixels, no metadata channel), so
 * the note woven into an outgoing message — "header\n- path" — is the sole
 * carrier that lets ANOTHER device render what was attached. Writers emit
 * ONE canonical English form on every platform; readers accept every form
 * any writer ever produced, and tolerate the gateway's trailing media
 * placeholders (`[screenshot]` appended after the note for inline image
 * parts). Each platform inventing its own wording is exactly how a
 * phone-sent photo reached the desktop as raw text (2026-08-01).
 *
 * PURE stdlib on purpose: the contract test exercises this object without
 * any Android framework on the classpath.
 */
object AgentAttachNote {

    // MARK: Canonical writer form

    const val SINGLE_HEADER = "Attached file (read it from your host):"
    const val MULTIPLE_HEADER = "Attached files (read them from your host):"

    /** The message block the agent reads: header + one path per line. */
    fun compose(paths: List<String>): String {
        val header = if (paths.size == 1) SINGLE_HEADER else MULTIPLE_HEADER
        return header + "\n" + paths.joinToString("\n") { "- $it" }
    }

    // MARK: Reader

    /**
     * Every header any past or present writer produced. FROZEN legacy —
     * these exact strings sit in gateway transcripts forever; new variants
     * are never added (writers emit only the canonical pair above).
     */
    val acceptedHeaders: Set<String> = setOf(
        SINGLE_HEADER,
        MULTIPLE_HEADER,
        // Mac ≤4.6.3 (localized writers).
        "Archivo adjunto (léelo desde tu host):",
        "Archivos adjuntos (léelos desde tu host):",
        "Приложен файл (прочитай его со своей машины):",
        "Приложены файлы (прочитай их со своей машины):",
        // Android ≤2.3.
        "The user attached a file, available at this path on your host:",
        "The user attached files, available at these paths on your host:",
    )

    /** Display text without the note + the note's paths (empty = no note). */
    data class Split(val display: String, val paths: List<String>)

    /**
     * A line that is nothing but a gateway media placeholder —
     * `[screenshot]`, `[image]`… Bounded so a real one-line bracketed
     * sentence is not mistaken for one.
     */
    private fun isPlaceholderLine(line: String): Boolean {
        if (!line.startsWith("[") || !line.endsWith("]")) return false
        if (line.length < 3 || line.length > 42) return false
        val inner = line.substring(1, line.length - 1)
        return '[' !in inner && ']' !in inner
    }

    /**
     * Splits a message into the display text and the note's paths (empty
     * when the message carries no note). Tolerant reader: CRLF, trailing
     * blank lines and trailing `[…]` placeholders do not break detection.
     */
    fun split(text: String): Split {
        // Raw lines build the display (a code block in the user's text must
        // keep its indentation); the trimmed twins drive the matching.
        val rawLines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
        val lines = rawLines.map { it.trim() }

        // Walk up from the end: blank lines and media placeholders first…
        var index = lines.size - 1
        while (index >= 0 && (lines[index].isEmpty() || isPlaceholderLine(lines[index]))) {
            index--
        }
        // …then the contiguous "- path" block…
        val paths = ArrayDeque<String>()
        while (index >= 0 && lines[index].startsWith("- ")) {
            paths.addFirst(lines[index].substring(2))
            index--
        }
        // …then the header right above it.
        if (paths.isEmpty() || index < 0 || lines[index] !in acceptedHeaders) {
            return Split(text, emptyList())
        }
        val display = rawLines.subList(0, index).joinToString("\n").trim()
        return Split(display, paths.toList())
    }

    // MARK: Mirror-sync matching

    private val placeholderRegex = Regex("""\[[^\]\n]{1,40}\]""")

    /**
     * Normalizes a transcript row's text for comparing against a locally
     * held message: the gateway appends `[…]` media placeholders for
     * inline image parts it keeps no pixels for, while the local copy
     * holds the real attachment instead. ONE definition shared with the
     * desktop mirror matcher.
     */
    fun normalizedForMatching(text: String): String =
        placeholderRegex.replace(text, "").trim()
}
