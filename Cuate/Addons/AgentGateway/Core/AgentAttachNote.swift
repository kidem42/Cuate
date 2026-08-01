import Foundation

/// THE cross-device contract for attachment delivery in agent chats.
///
/// The Hermes gateway stores only text (no pixels, no metadata channel), so
/// the note woven into an outgoing message — "header\n- path" — is the sole
/// carrier that lets ANOTHER device render what was attached: it splits the
/// note back out and fetches the files from the agent's host. That makes
/// this format a protocol, not prose:
///
/// - **Writers emit ONE canonical English form** (`compose`) on every
///   platform. The note is agent-facing — the UI strips it — so localizing
///   it was a mistake: each platform drifting its own wording is exactly
///   how a phone-sent photo reached the desktop as raw text (2026-08-01).
/// - **Readers accept every form any writer ever produced** (`split`):
///   the canonical pair, the legacy localized Mac trio, the legacy Android
///   English pair — old transcripts live forever on the gateway.
/// - **Readers tolerate the gateway's trailing media placeholders**: an
///   image rides the send as an inline part too, and the transcript renders
///   it as a bare `[screenshot]` line AFTER the note. Placeholders are
///   skipped when locating the paths block.
///
/// Kept in lockstep with the Kotlin twin (`hermes/AgentAttachNote.kt`);
/// `shared/fixtures/attach-note.json` is the executable source of truth —
/// run `scripts/test-attach-note.sh` after touching either side.
///
/// PURE Foundation on purpose: the contract tests compile this file
/// standalone, outside the app target.
enum AgentAttachNote {

    // MARK: Canonical writer form

    static let singleHeader = "Attached file (read it from your host):"
    static let multipleHeader = "Attached files (read them from your host):"

    /// The message block the agent reads: header + one path per line.
    static func compose(paths: [String]) -> String {
        let header = paths.count == 1 ? singleHeader : multipleHeader
        return header + "\n" + paths.map { "- \($0)" }.joined(separator: "\n")
    }

    // MARK: Reader

    /// Every header any past or present writer produced. FROZEN legacy —
    /// these exact strings sit in gateway transcripts forever; new variants
    /// are never added (writers emit only the canonical pair above).
    static let acceptedHeaders: Set<String> = [
        singleHeader,
        multipleHeader,
        // Mac ≤4.6.3 (localized writers).
        "Archivo adjunto (léelo desde tu host):",
        "Archivos adjuntos (léelos desde tu host):",
        "Приложен файл (прочитай его со своей машины):",
        "Приложены файлы (прочитай их со своей машины):",
        // Android ≤2.3.
        "The user attached a file, available at this path on your host:",
        "The user attached files, available at these paths on your host:",
    ]

    /// A line that is nothing but a gateway media placeholder —
    /// `[screenshot]`, `[image]`… Bounded so a real one-line bracketed
    /// sentence is not mistaken for one.
    private static func isPlaceholderLine(_ line: String) -> Bool {
        guard line.hasPrefix("["), line.hasSuffix("]"),
              line.count >= 3, line.count <= 42 else { return false }
        let inner = line.dropFirst().dropLast()
        return !inner.contains("[") && !inner.contains("]")
    }

    /// Splits a message into the display text and the note's paths (empty
    /// when the message carries no note). Tolerant reader: CRLF, trailing
    /// blank lines and trailing `[…]` placeholders do not break detection.
    static func split(_ text: String) -> (display: String, paths: [String]) {
        // Raw lines build the display (a code block in the user's text must
        // keep its indentation); the trimmed twins drive the matching.
        let rawLines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        let lines = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }

        // Walk up from the end: blank lines and media placeholders first…
        var index = lines.count - 1
        while index >= 0, lines[index].isEmpty || isPlaceholderLine(lines[index]) {
            index -= 1
        }
        // …then the contiguous "- path" block…
        var paths: [String] = []
        while index >= 0, lines[index].hasPrefix("- ") {
            paths.insert(String(lines[index].dropFirst(2)), at: 0)
            index -= 1
        }
        // …then the header right above it.
        guard !paths.isEmpty, index >= 0, acceptedHeaders.contains(lines[index]) else {
            return (text, [])
        }
        let display = rawLines[..<index].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (display, paths)
    }

    // MARK: Mirror-sync matching

    /// Normalizes a transcript row's text for comparing against a locally
    /// held message: the gateway appends `[…]` media placeholders for
    /// inline image parts it keeps no pixels for, while the local copy
    /// holds the real attachment instead. ONE definition shared by every
    /// mirror matcher — two hand-rolled regexes were how the platforms
    /// drifted apart.
    static func normalizedForMatching(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\[[^\]\n]{1,40}\]"#, with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
