import Foundation

/// THE contract for Plaud recordings mentioned by an AGENT.
///
/// When the agent's host carries the Plaud plugin, the agent can find and read
/// recordings by itself — but its reply is plain text, and a wall of transcript
/// pasted into the chat is not what the app already renders beautifully. So the
/// agent hands back an IDENTIFIER instead of content:
///
///     plaud://<file_id>
///
/// The app resolves that id with its own Plaud grant and produces the same chip
/// and preview an ordinary chat gets — every summary tab, the timecoded
/// transcript, inline audio. Nothing of the recording travels through the
/// gateway: no five-minute content links to race, no megabytes burning the
/// agent's context, and the phone renders the same reply just as well.
///
/// **The reader is deliberately forgiving.** The writer here is a language
/// model, not our code: it may inline the marker mid-sentence, wrap it in a
/// markdown link, list several under a heading, or bracket it. Anything of the
/// shape `plaud://<id>` counts, wherever it sits; the optional block form below
/// is what the plugin's prompt asks for, not what the reader requires.
///
/// PURE Foundation on purpose: the contract test compiles this file standalone,
/// outside the app target. Kept in lockstep with the Kotlin twin
/// (`hermes/AgentPlaudNote.kt`); `shared/fixtures/plaud-note.json` is the
/// executable source of truth — run `scripts/test-attach-note.sh` after
/// touching either side.
enum AgentPlaudNote {

    /// A recording the agent referred to. `title` is whatever label the agent
    /// put next to the marker (a markdown link's text, or the rest of a list
    /// line) — a hint for the chip while the real name is fetched; empty when
    /// the agent gave none.
    struct Reference: Equatable {
        let fileID: String
        let title: String
    }

    // MARK: Canonical writer form (what the plugin's prompt asks for)

    static let header = "Plaud recordings:"

    /// The block the plugin instructs the agent to append. Readers do not
    /// depend on it — see the type's note — but a predictable shape keeps
    /// replies tidy and gives the reader clean titles.
    static func compose(_ references: [Reference]) -> String {
        guard !references.isEmpty else { return "" }
        let lines = references.map { ref in
            ref.title.isEmpty ? "- plaud://\(ref.fileID)"
                              : "- plaud://\(ref.fileID) — \(ref.title)"
        }
        return ([header] + lines).joined(separator: "\n")
    }

    // MARK: Reader

    /// Plaud ids are opaque strings from their API; accept the character set
    /// they have ever used and stop at anything that cannot belong to one.
    private static let idCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
    )

    /// Extracts every recording the text refers to, in order of appearance and
    /// without duplicates, and returns the text with the markers removed —
    /// what the bubble shows. The chips carry the recordings from there.
    ///
    /// Removal rules, in the order they matter:
    /// - a canonical block at the end goes entirely (header included);
    /// - a list line that is nothing but a marker plus a label goes entirely;
    /// - a markdown link `[label](plaud://id)` collapses to its label;
    /// - a bare inline marker is dropped, and the leftover punctuation
    ///   ("see plaud://x — great call") is tidied.
    static func split(_ text: String) -> (display: String, references: [Reference]) {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard normalized.contains("plaud://") else { return (text, []) }

        var references: [Reference] = []
        var seen = Set<String>()
        func note(_ fileID: String, _ title: String) {
            guard !fileID.isEmpty else { return }
            if seen.insert(fileID).inserted {
                references.append(Reference(fileID: fileID, title: title))
            } else if let index = references.firstIndex(where: { $0.fileID == fileID }),
                      references[index].title.isEmpty, !title.isEmpty {
                references[index] = Reference(fileID: fileID, title: title)
            }
        }

        var lines = normalized.components(separatedBy: "\n")

        // 1. Markdown links first: they carry the best titles.
        let linkPattern = #"\[([^\]\n]{1,120})\]\(\s*plaud://([A-Za-z0-9_-]+)\s*\)"#
        for index in lines.indices {
            lines[index] = replacingMatches(in: lines[index], pattern: linkPattern) { groups in
                note(groups[1], groups[0].trimmingCharacters(in: .whitespaces))
                return groups[0]           // keep the human-readable label
            }
        }

        // 2. Whole lines that exist only to carry a marker.
        var kept: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == header { continue }
            if let bare = markerOnlyLine(trimmed) {
                note(bare.fileID, bare.title)
                continue
            }
            kept.append(line)
        }
        lines = kept

        // 3. Whatever markers are left sit inside prose. Only a line we
        // actually cut gets tidied — an untouched line's own punctuation
        // ("Нашёл две записи:") is the author's, not our leftover.
        for index in lines.indices {
            let stripped = replacingMatches(in: lines[index], pattern: #"plaud://([A-Za-z0-9_-]+)"#) { groups in
                note(groups[0], "")
                return ""
            }
            if stripped != lines[index] { lines[index] = tidied(stripped) }
        }

        let display = lines.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (display, references)
    }

    /// `- plaud://id — Title` / `* plaud://id (Title)` / a naked marker on its
    /// own line: the id plus whatever label trails it.
    private static func markerOnlyLine(_ trimmed: String) -> Reference? {
        var rest = Substring(trimmed)
        for bullet in ["- ", "* ", "• "] where rest.hasPrefix(bullet) {
            rest = rest.dropFirst(bullet.count)
            break
        }
        guard rest.hasPrefix("plaud://") else { return nil }
        rest = rest.dropFirst("plaud://".count)
        let id = String(rest.prefix { $0.unicodeScalars.allSatisfy(idCharacters.contains) })
        guard !id.isEmpty else { return nil }
        let title = String(rest.dropFirst(id.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: " —-–:()[]\t"))
        return Reference(fileID: id, title: title)
    }

    /// Cleans what a removed inline marker left behind: doubled spaces and a
    /// dangling separator at either end of the line.
    private static func tidied(_ line: String) -> String {
        var out = line.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\(\s*\)"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"[ \t]+([,.;:!?])"#, with: "$1", options: .regularExpression)
        let danglers = CharacterSet(charactersIn: " \t—–-:,;")
        while let last = out.unicodeScalars.last, danglers.contains(last) {
            out = String(out.unicodeScalars.dropLast())
        }
        return out
    }

    /// Regex replace with access to capture groups (NSRegularExpression's
    /// template syntax cannot call back into Swift).
    private static func replacingMatches(
        in line: String, pattern: String, _ transform: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return line }
        let ns = line as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            var groups: [String] = []
            for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
                groups.append(ns.substring(with: match.range(at: index)))
            }
            out += transform(groups)
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }
}
