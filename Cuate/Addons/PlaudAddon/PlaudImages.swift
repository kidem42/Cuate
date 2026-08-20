import Foundation

/// Pictures inside Plaud notes (Highlights photos, summary posters).
///
/// Plaud references them by a bare STORAGE PATH (`picture_link:
/// "permanent/<uid>/mark/<name>.jpg"`), not by URL — pasted into Markdown
/// as-is they render as dead text. Their own clients resolve such paths
/// through `download_link_map` / `download_path_mapping` (path → presigned
/// S3 URL, minutes-long TTL) that rides in the file-detail response, or by
/// fetching the path off the API host with the bearer.
///
/// So the pictures are downloaded HERE, at the moment the note is read —
/// while the presigned links are still alive — into the note cache next to
/// the tabs, and the Markdown is rewritten to the cache-relative path the
/// app can always render, online or not. A path that fails to download
/// stays as-is; the next note read or preview refresh retries it.
@MainActor
enum PlaudImages {

    /// Rewrites every relative image reference in `markdown` to a local
    /// cached copy, downloading what the cache does not hold yet. `file` is
    /// the recording's file-detail dictionary — the link maps live there.
    static func localize(markdown: String, fileID: String, file: [String: Any]) async -> String {
        guard markdown.contains("![") else { return markdown }
        let paths = relativeImagePaths(in: markdown)
        guard !paths.isEmpty else { return markdown }

        let map = linkMap(from: file)
        var out = markdown
        for path in paths {
            let normalized = normalize(path)
            let relative = cacheRelativePath(fileID: fileID, path: normalized)
            let target = ChatAttachment.resolveURL(relative)
            if !FileManager.default.fileExists(atPath: target.path) {
                guard let data = await PlaudClient.shared.fetchAsset(path: normalized, linkMap: map) else { continue }
                do {
                    try FileManager.default.createDirectory(
                        at: target.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    try data.write(to: target, options: .atomic)
                } catch {
                    Diagnostics.log("plaud", "image.write failed: \(error.localizedDescription)")
                    continue
                }
            }
            out = out.replacingOccurrences(of: "](\(path))", with: "](\(relative))")
        }
        return out
    }

    /// Image targets that are neither absolute URLs nor already localized —
    /// the storage paths only Plaud's backend can serve.
    private static func relativeImagePaths(in markdown: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\(\s*([^)\s]+)\s*\)"#) else { return [] }
        let ns = markdown as NSString
        var seen = Set<String>()
        var out: [String] = []
        for match in regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
            let target = ns.substring(with: match.range(at: 1))
            guard !target.contains("://"), !target.hasPrefix("data:"),
                  !target.hasPrefix("PlaudNotes/"),
                  seen.insert(target).inserted else { continue }
            out.append(target)
        }
        return out
    }

    /// Both map spellings observed in the wild, on the file itself and on
    /// its note items — merged, keys normalized to no leading slash.
    private static func linkMap(from file: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        var sources: [[String: Any]] = [file]
        sources += file["note_list"] as? [[String: Any]] ?? []
        for source in sources {
            for key in ["download_link_map", "download_path_mapping"] {
                guard let map = source[key] as? [String: String] else { continue }
                for (path, url) in map where !url.isEmpty {
                    out[normalize(path)] = url
                }
            }
        }
        return out
    }

    private static func normalize(_ path: String) -> String {
        var out = path.trimmingCharacters(in: .whitespaces)
        while out.hasPrefix("/") { out.removeFirst() }
        return out
    }

    /// `PlaudNotes/<fileID>__img__<hash8>-<basename>` — the hash keeps two
    /// same-named pictures from different folders apart; the basename keeps
    /// the file recognizable in Finder.
    private static func cacheRelativePath(fileID: String, path: String) -> String {
        let base = (path as NSString).lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let safeBase = String(base.unicodeScalars.map {
            allowed.contains($0) ? Character($0) : "-"
        }.suffix(60))
        // FNV-1a over the full path, 8 hex chars.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return "PlaudNotes/\(fileID)__img__\(String(format: "%08x", UInt32(truncatingIfNeeded: hash)))-\(safeBase)"
    }
}
