import Foundation

/// The read_document tool's text side: page markers, page ranges, paragraph
/// search and the result cap. Pure Foundation — compiled standalone by
/// `scripts/DocumentContractTest.swift`.
nonisolated enum DocumentTextQuery {
    /// Per tool call. Mirrors the Plaud note cap: big enough for a chapter,
    /// small enough that one call can't crowd out the conversation.
    static let maxResultCharacters = 30_000
    static let maxSearchHits = 20
    static let truncationNote = "[Truncated — request a page range or a query]"

    // MARK: - Page markers

    static func pageMarker(_ number: Int) -> String { "[Page \(number)]" }

    /// Joins per-page texts with markers. Empty pages keep their marker so
    /// the numbering stays aligned with the PDF viewer's.
    static func join(pages: [String]) -> String {
        pages.enumerated().map { index, page in
            pageMarker(index + 1) + "\n" + page.trimmingCharacters(in: .whitespacesAndNewlines)
        }.joined(separator: "\n\n")
    }

    /// Splits marked text back into pages (index 0 = page 1). Text without
    /// markers is a single page; text before the first marker is page 1.
    static func pages(of text: String) -> [String] {
        var pages: [Int: [String]] = [:]
        var current = 1
        var sawMarker = false
        for line in text.components(separatedBy: "\n") {
            if let number = markerNumber(line) {
                current = number
                sawMarker = true
                if pages[current] == nil { pages[current] = [] }
                continue
            }
            pages[current, default: []].append(line)
        }
        guard sawMarker else {
            return [text.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        let last = pages.keys.max() ?? 1
        return (1...last).map { number in
            (pages[number] ?? []).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func markerNumber(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[Page "), trimmed.hasSuffix("]") else { return nil }
        let inner = trimmed.dropFirst("[Page ".count).dropLast()
        return Int(inner)
    }

    // MARK: - Page ranges

    /// "3-5", "7", " 2 – 4 " → a closed 1-based range clamped to the
    /// document; nil for garbage or a range that starts past the last page.
    static func parsePageRange(_ raw: String?, pageCount: Int) -> ClosedRange<Int>? {
        guard let raw, pageCount > 0 else { return nil }
        let cleaned = raw
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty else { return nil }
        let parts = cleaned.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        let start: Int
        let end: Int
        switch parts.count {
        case 1:
            guard let single = Int(parts[0]) else { return nil }
            start = single; end = single
        case 2:
            guard let first = Int(parts[0]), let second = Int(parts[1]) else { return nil }
            start = min(first, second); end = max(first, second)
        default:
            return nil
        }
        guard start >= 1, start <= pageCount else { return nil }
        return start...min(end, pageCount)
    }

    // MARK: - Search

    struct Hit: Equatable {
        let page: Int
        let paragraph: String
    }

    /// Case-insensitive paragraph match with page numbers. Plain substring
    /// search: a 40-page contract is a few hundred paragraphs.
    static func search(_ text: String, query: String) -> [Hit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        var hits: [Hit] = []
        for (index, page) in pages(of: text).enumerated() {
            for paragraph in page.components(separatedBy: "\n\n") {
                let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed.lowercased().contains(needle) else { continue }
                hits.append(Hit(page: index + 1, paragraph: trimmed))
                if hits.count >= maxSearchHits { return hits }
            }
        }
        return hits
    }

    // MARK: - Rendering

    /// Applies the cap; the note replaces the tail, never lands mid-word.
    static func capped(_ text: String) -> String {
        guard text.count > maxResultCharacters else { return text }
        var head = String(text.prefix(maxResultCharacters))
        if let cut = head.lastIndex(where: { $0 == "\n" || $0 == " " }) {
            head = String(head[..<cut])
        }
        return head + "\n" + truncationNote
    }

    /// One tool result: a page range, a query, or the whole text — in that
    /// order of precedence when several are given.
    static func render(name: String, text: String, pageRange raw: String?, query: String?) -> String {
        let allPages = pages(of: text)
        var header = "\(name) — \(allPages.count) page\(allPages.count == 1 ? "" : "s")"

        if let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let range = parsePageRange(raw, pageCount: allPages.count) else {
                return "\(header)\nInvalid page range \"\(raw)\". Valid pages: 1-\(allPages.count)."
            }
            header += ", pages \(range.lowerBound)-\(range.upperBound)"
            let body = range.map { number in
                pageMarker(number) + "\n" + allPages[number - 1]
            }.joined(separator: "\n\n")
            return capped(header + "\n\n" + body)
        }

        if let query, !query.trimmingCharacters(in: .whitespaces).isEmpty {
            let hits = search(text, query: query)
            guard !hits.isEmpty else {
                return "\(header)\nNo matches for \"\(query)\"."
            }
            let lines = hits.map { "Page \($0.page):\n\($0.paragraph)" }.joined(separator: "\n\n")
            let more = hits.count >= maxSearchHits ? "\n[First \(maxSearchHits) matches shown — narrow the query]" : ""
            return capped("\(header), \(hits.count) match\(hits.count == 1 ? "" : "es") for \"\(query)\"\n\n\(lines)\(more)")
        }

        return capped(header + "\n\n" + text)
    }
}
