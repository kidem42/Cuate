import Foundation

/// Disk cache for Plaud recording payloads, under `Application Support/…/
/// PlaudNotes/`. One meta JSON plus one Markdown file per tab (and one for
/// the transcript) per recording. Chip attachments reference the meta path;
/// the preview window reads and refreshes everything by recording ID.
nonisolated enum PlaudNoteCache {

    struct TabMeta: Codable, Equatable {
        let slug: String
        /// Original tab name as Plaud shows it ("Summary", "Highlights").
        let title: String
    }

    struct Meta: Codable {
        var name: String
        var day: String
        var duration: String
        var tabs: [TabMeta]
        var hasTranscript: Bool?
        /// Slugs whose payload is an utterance list (a `.json` twin next to
        /// the `.md`), so the preview renders clickable timecodes instead of
        /// Markdown. Absent in caches written before 4.7 — `hasTranscript`
        /// covers those.
        var segmentTabs: [String]?
    }

    // MARK: - Paths

    static func metaRelativePath(fileID: String, kind: String = "note") -> String {
        "PlaudNotes/\(fileID)__\(kind)__meta.json"
    }

    static func tabRelativePath(fileID: String, slug: String) -> String {
        "PlaudNotes/\(fileID)__tab__\(slug).md"
    }

    /// Raw segment JSON (start/end ms, speaker, text) — the preview renders
    /// rows from THIS so timecodes stay clickable (audio seek); the .md twin
    /// is for chips/export. The raw transcript keeps the slug `transcript`,
    /// so caches written before the polished/outline blocks existed still
    /// resolve.
    static func segmentsRelativePath(fileID: String, slug: String) -> String {
        "PlaudNotes/\(fileID)__tab__\(slug).json"
    }

    static func slug(for tabName: String) -> String {
        let allowed = CharacterSet.alphanumerics
        return String(tabName.lowercased().unicodeScalars.map {
            allowed.contains($0) ? Character($0) : "-"
        }.prefix(24))
    }

    // MARK: - Writing

    @discardableResult
    private static func write(_ content: String, relative: String) -> Bool {
        let url = ChatAttachment.resolveURL(relative)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            Diagnostics.log("plaud", "cache.write failed: \(error.localizedDescription)")
            return false
        }
    }

    /// `slug` is explicit for blocks whose title is localized (a language
    /// switch must not orphan the file); Plaud's own tab names derive theirs.
    static func writeTab(fileID: String, tabName: String, content: String, slug explicitSlug: String? = nil) {
        let tabSlug = explicitSlug ?? slug(for: tabName)
        write(content, relative: tabRelativePath(fileID: fileID, slug: tabSlug))
        updateMeta(fileID: fileID) { meta in
            let tab = TabMeta(slug: tabSlug, title: tabName)
            if let index = meta.tabs.firstIndex(where: { $0.slug == tabSlug }) {
                meta.tabs[index] = tab
            } else {
                meta.tabs.append(tab)
            }
        }
    }

    /// A transcript-shaped tab: Markdown for chips and export, plus the raw
    /// utterance list the preview needs for clickable timecodes. The title is
    /// localized, the slug never is — a language switch must not orphan the
    /// files already on disk.
    static func writeSegmentTab(
        fileID: String, slug: String, title: String, markdown: String, rawSegments: String
    ) {
        write(markdown, relative: tabRelativePath(fileID: fileID, slug: slug))
        write(rawSegments, relative: segmentsRelativePath(fileID: fileID, slug: slug))
        updateMeta(fileID: fileID) { meta in
            let tab = TabMeta(slug: slug, title: title)
            if let index = meta.tabs.firstIndex(where: { $0.slug == slug }) {
                meta.tabs[index] = tab
            } else {
                meta.tabs.append(tab)
            }
            var segmentTabs = meta.segmentTabs ?? []
            if !segmentTabs.contains(slug) { segmentTabs.append(slug) }
            meta.segmentTabs = segmentTabs
            if slug == PlaudSourceBlock.transaction.slug { meta.hasTranscript = true }
        }
    }

    /// Merge-updates the recording's meta file (creating it when absent).
    static func updateMeta(
        fileID: String, name: String? = nil, day: String? = nil, duration: String? = nil,
        mutate: ((inout Meta) -> Void)? = nil
    ) {
        var current = meta(fileID: fileID)
            ?? Meta(name: "", day: "", duration: "", tabs: [], hasTranscript: false)
        if let name { current.name = name }
        if let day { current.day = day }
        if let duration { current.duration = duration }
        mutate?(&current)
        if let data = try? JSONEncoder().encode(current),
           let json = String(data: data, encoding: .utf8) {
            write(json, relative: metaRelativePath(fileID: fileID))
        }
    }

    // MARK: - Reading

    static func meta(fileID: String) -> Meta? {
        let url = ChatAttachment.resolveURL(metaRelativePath(fileID: fileID))
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    static func tabContent(fileID: String, slug: String) -> String? {
        let url = ChatAttachment.resolveURL(tabRelativePath(fileID: fileID, slug: slug))
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func segmentsRaw(fileID: String, slug: String) -> String? {
        let url = ChatAttachment.resolveURL(segmentsRelativePath(fileID: fileID, slug: slug))
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// The blocks a recording's `source_list` can carry. `transaction` is the raw
/// transcript (verbatim, the one to quote from), `transaction_polish` the same
/// utterances cleaned up by Plaud's AI — shorter and far easier to read —
/// and `outline` a structured overview. Plaud fills them per recording: a
/// given file may have one, all three, or (unprocessed) none.
nonisolated enum PlaudSourceBlock: String, CaseIterable {
    case transaction
    case transactionPolish = "transaction_polish"
    case outline

    /// Cache slug. `transaction` keeps the historical `transcript` so files
    /// written by earlier builds stay readable.
    var slug: String {
        switch self {
        case .transaction: return "transcript"
        case .transactionPolish: return "transcript-polish"
        case .outline: return "outline"
        }
    }

    var title: String {
        switch self {
        case .transaction: return PLL("plaud.preview.transcriptTab")
        case .transactionPolish: return PLL("plaud.preview.polishTab")
        case .outline: return PLL("plaud.preview.outlineTab")
        }
    }

    /// Left-to-right tab order in the preview: the readable transcript first,
    /// the verbatim one next to it, the overview last. Note tabs follow.
    static let displayOrder: [PlaudSourceBlock] = [.transactionPolish, .transaction, .outline]

    static func from(slug: String) -> PlaudSourceBlock? {
        allCases.first { $0.slug == slug }
    }

    /// What the model calls it — Plaud's own `data_type` names say nothing
    /// about what the block is for.
    var publicName: String {
        switch self {
        case .transaction: return "verbatim"
        case .transactionPolish: return "clean"
        case .outline: return "outline"
        }
    }

    static func from(publicName: String) -> PlaudSourceBlock? {
        let normalized = publicName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allCases.first { $0.publicName == normalized || $0.rawValue == normalized }
    }
}

/// Formatting shared by the tool results (for the model) and the preview
/// window (for the human).
nonisolated enum PlaudFormat {

    /// Milliseconds → "5m23s" / "1h05m" (raw ms are for logs only).
    static func durationString(_ raw: Any?) -> String {
        let ms = raw as? Double ?? Double(raw as? Int ?? 0)
        let totalSeconds = Int(ms / 1000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return String(format: "%dh%02dm", hours, minutes) }
        if minutes > 0 { return String(format: "%dm%02ds", minutes, seconds) }
        return "\(seconds)s"
    }

    static func clockString(ms: Double) -> String {
        let totalSeconds = Int(ms / 1000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    /// One row of an utterance-shaped block.
    struct Row {
        let startMs: Double
        /// nil for blocks that have no speakers at all (the outline).
        let speaker: String?
        let text: String
    }

    /// The blocks are utterance lists but NOT the same shape: the transcripts
    /// carry `content` + `speaker`, the outline carries `topic` and nobody
    /// speaking. Reading the outline through the transcript keys produced a
    /// page of bare timecodes labelled "Speaker" (e2e 2026-08-05) — hence one
    /// tolerant reader for all of them.
    static func rows(from segments: [[String: Any]]) -> [Row] {
        segments.compactMap { segment in
            let text = segment["content"] as? String
                ?? segment["topic"] as? String
                ?? segment["title"] as? String
                ?? ""
            let rawSpeaker = segment["speaker"] as? String
                ?? segment["original_speaker"] as? String
            let speaker = (rawSpeaker?.isEmpty == false) ? rawSpeaker : nil
            guard !text.isEmpty || speaker != nil else { return nil }
            return Row(startMs: segment["start_time"] as? Double ?? 0, speaker: speaker, text: text)
        }
    }

    /// Utterance rows → reader-friendly Markdown (chips, export).
    static func transcriptMarkdown(from segments: [[String: Any]]) -> String {
        rows(from: segments).map { row in
            let time = clockString(ms: row.startMs)
            return row.speaker.map { "**[\(time)] \($0):** \(row.text)" }
                ?? "**[\(time)]** \(row.text)"
        }.joined(separator: "\n\n")
    }

    /// Some note tabs ("Highlights") arrive as a JSON array rather than
    /// Markdown: `[{content, timestamp, title, picture_link}]`. Shown raw it
    /// is a wall of escaped JSON — in the preview AND in the model's context
    /// (e2e 2026-08-05). Convert it to the Markdown it always meant to be;
    /// anything of another shape comes back untouched.
    static func noteMarkdown(fromRaw raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !items.isEmpty,
              items.contains(where: { $0["content"] is String }) else { return raw }
        var sections: [String] = []
        for item in items {
            var lines: [String] = []
            let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stamp = (item["timestamp"] as? Double).map { "[\(clockString(ms: $0))] " } ?? ""
            if !title.isEmpty || !stamp.isEmpty {
                lines.append("### \(stamp)\(title)")
            }
            if let picture = item["picture_link"] as? String, !picture.isEmpty {
                lines.append("![](\(picture))")
            }
            if let content = item["content"] as? String, !content.isEmpty {
                // Plaud writes "• " bullets; Markdown needs "- " to render
                // them as a list instead of one run-on paragraph.
                lines.append(content
                    .replacingOccurrences(of: "\n• ", with: "\n- ")
                    .replacingOccurrences(
                        of: "^• ", with: "- ", options: .regularExpression
                    ))
            }
            if !lines.isEmpty { sections.append(lines.joined(separator: "\n\n")) }
        }
        return sections.isEmpty ? raw : sections.joined(separator: "\n\n")
    }

    /// Decodes a `source_list` "transaction" payload into segments.
    static func transcriptSegments(fromRaw raw: String) -> [[String: Any]]? {
        guard let data = raw.data(using: .utf8),
              let segments = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !segments.isEmpty else { return nil }
        return segments
    }
}
