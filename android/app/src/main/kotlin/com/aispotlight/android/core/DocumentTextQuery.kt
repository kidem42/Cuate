package com.aispotlight.android.core

/**
 * The read_document tool's text side: page markers, page ranges, paragraph
 * search and the result cap. Port of the Mac `DocumentTextQuery`; pure
 * Kotlin, covered by the unit test with the same cases.
 */
object DocumentTextQuery {
    const val MAX_RESULT_CHARACTERS = 30_000
    const val MAX_SEARCH_HITS = 20
    const val TRUNCATION_NOTE = "[Truncated — request a page range or a query]"

    fun pageMarker(number: Int) = "[Page $number]"

    /** Joins per-page texts with markers; empty pages keep their marker. */
    fun join(pages: List<String>): String =
        pages.mapIndexed { index, page -> pageMarker(index + 1) + "\n" + page.trim() }
            .joinToString("\n\n")

    /** Splits marked text back into pages (index 0 = page 1). */
    fun pages(text: String): List<String> {
        val pages = mutableMapOf<Int, MutableList<String>>()
        var current = 1
        var sawMarker = false
        for (line in text.split("\n")) {
            val number = markerNumber(line)
            if (number != null) {
                current = number
                sawMarker = true
                pages.getOrPut(current) { mutableListOf() }
                continue
            }
            pages.getOrPut(current) { mutableListOf() }.add(line)
        }
        if (!sawMarker) return listOf(text.trim())
        val last = pages.keys.maxOrNull() ?: 1
        return (1..last).map { number -> (pages[number] ?: emptyList()).joinToString("\n").trim() }
    }

    private fun markerNumber(line: String): Int? {
        val trimmed = line.trim()
        if (!trimmed.startsWith("[Page ") || !trimmed.endsWith("]")) return null
        return trimmed.removePrefix("[Page ").removeSuffix("]").toIntOrNull()
    }

    /** "3-5", "7", " 2 – 4 " → a closed 1-based range clamped to the document. */
    fun parsePageRange(raw: String?, pageCount: Int): IntRange? {
        if (raw == null || pageCount <= 0) return null
        val cleaned = raw.replace("–", "-").replace("—", "-").replace(" ", "")
        if (cleaned.isEmpty()) return null
        val parts = cleaned.split("-")
        val start: Int
        val end: Int
        when (parts.size) {
            1 -> { val single = parts[0].toIntOrNull() ?: return null; start = single; end = single }
            2 -> {
                val first = parts[0].toIntOrNull() ?: return null
                val second = parts[1].toIntOrNull() ?: return null
                start = minOf(first, second); end = maxOf(first, second)
            }
            else -> return null
        }
        if (start < 1 || start > pageCount) return null
        return start..minOf(end, pageCount)
    }

    data class Hit(val page: Int, val paragraph: String)

    /** Case-insensitive paragraph match with page numbers (plain substring). */
    fun search(text: String, query: String): List<Hit> {
        val needle = query.trim().lowercase()
        if (needle.isEmpty()) return emptyList()
        val hits = mutableListOf<Hit>()
        pages(text).forEachIndexed { index, page ->
            for (paragraph in page.split("\n\n")) {
                val trimmed = paragraph.trim()
                if (trimmed.isEmpty() || !trimmed.lowercase().contains(needle)) continue
                hits.add(Hit(index + 1, trimmed))
                if (hits.size >= MAX_SEARCH_HITS) return hits
            }
        }
        return hits
    }

    /** Applies the cap; the note replaces the tail, never mid-word. */
    fun capped(text: String): String {
        if (text.length <= MAX_RESULT_CHARACTERS) return text
        var head = text.take(MAX_RESULT_CHARACTERS)
        val cut = head.lastIndexOfAny(charArrayOf('\n', ' '))
        if (cut > 0) head = head.substring(0, cut)
        return head + "\n" + TRUNCATION_NOTE
    }

    /** One tool result: a page range, a query, or the whole text. */
    fun render(name: String, text: String, pageRange: String?, query: String?): String {
        val allPages = pages(text)
        var header = "$name — ${allPages.size} page${if (allPages.size == 1) "" else "s"}"
        if (!pageRange.isNullOrBlank()) {
            val range = parsePageRange(pageRange, allPages.size)
                ?: return "$header\nInvalid page range \"$pageRange\". Valid pages: 1-${allPages.size}."
            header += ", pages ${range.first}-${range.last}"
            val body = range.joinToString("\n\n") { number -> pageMarker(number) + "\n" + allPages[number - 1] }
            return capped("$header\n\n$body")
        }
        if (!query.isNullOrBlank()) {
            val hits = search(text, query)
            if (hits.isEmpty()) return "$header\nNo matches for \"$query\"."
            val lines = hits.joinToString("\n\n") { "Page ${it.page}:\n${it.paragraph}" }
            val more = if (hits.size >= MAX_SEARCH_HITS) "\n[First $MAX_SEARCH_HITS matches shown — narrow the query]" else ""
            return capped("$header, ${hits.size} match${if (hits.size == 1) "" else "es"} for \"$query\"\n\n$lines$more")
        }
        return capped("$header\n\n$text")
    }
}
