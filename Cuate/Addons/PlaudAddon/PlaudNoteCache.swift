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
    }

    // MARK: - Paths

    static func metaRelativePath(fileID: String, kind: String = "note") -> String {
        "PlaudNotes/\(fileID)__\(kind)__meta.json"
    }

    static func tabRelativePath(fileID: String, slug: String) -> String {
        "PlaudNotes/\(fileID)__tab__\(slug).md"
    }

    static func transcriptRelativePath(fileID: String) -> String {
        "PlaudNotes/\(fileID)__tab__transcript.md"
    }

    /// Raw segment JSON (start/end ms, speaker, text) — the preview's
    /// transcript tab renders rows from THIS so timecodes stay clickable
    /// (audio seek); the .md twin is for chips/export.
    static func transcriptSegmentsRelativePath(fileID: String) -> String {
        "PlaudNotes/\(fileID)__tab__transcript.json"
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

    static func writeTab(fileID: String, tabName: String, content: String) {
        let tabSlug = slug(for: tabName)
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

    static func writeTranscript(fileID: String, content: String, rawSegments: String? = nil) {
        write(content, relative: transcriptRelativePath(fileID: fileID))
        if let rawSegments {
            write(rawSegments, relative: transcriptSegmentsRelativePath(fileID: fileID))
        }
        updateMeta(fileID: fileID) { $0.hasTranscript = true }
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

    static func transcriptContent(fileID: String) -> String? {
        let url = ChatAttachment.resolveURL(transcriptRelativePath(fileID: fileID))
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func transcriptSegmentsRaw(fileID: String) -> String? {
        let url = ChatAttachment.resolveURL(transcriptSegmentsRelativePath(fileID: fileID))
        return try? String(contentsOf: url, encoding: .utf8)
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

    /// Transcript segments → reader-friendly Markdown.
    static func transcriptMarkdown(from segments: [[String: Any]]) -> String {
        segments.map { segment in
            let start = segment["start_time"] as? Double ?? 0
            let speaker = segment["speaker"] as? String
                ?? segment["original_speaker"] as? String ?? "Speaker"
            return "**[\(clockString(ms: start))] \(speaker):** \(segment["content"] as? String ?? "")"
        }.joined(separator: "\n\n")
    }

    /// Decodes a `source_list` "transaction" payload into segments.
    static func transcriptSegments(fromRaw raw: String) -> [[String: Any]]? {
        guard let data = raw.data(using: .utf8),
              let segments = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !segments.isEmpty else { return nil }
        return segments
    }
}
