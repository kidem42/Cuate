import SwiftUI

/// Terminal-output processing for agent replies (notes §7.2 items 2–3): agents
/// paste raw stdout — ANSI colors, `\r` progress-bar redraws, unified diffs.
/// In a plain code block that is garbage; here it becomes what a terminal
/// would have shown. Pure functions — nothing here touches app state.
enum AgentTerminalText {

    // MARK: - ANSI

    /// Whether the text contains ANSI escape sequences at all (cheap gate —
    /// ordinary code blocks skip the whole pipeline).
    static func containsANSI(_ text: String) -> Bool {
        text.contains("\u{1B}[")
    }

    /// Collapses carriage-return redraws: within each line, only the LAST
    /// `\r`-segment survives — a progress bar animated over one line renders
    /// as its final state, exactly like a real terminal.
    static func collapsingCarriageReturns(_ text: String) -> String {
        guard text.contains("\r") else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            guard line.contains("\r") else { return String(line) }
            // Keep the last non-empty segment: many tools end the line with
            // "\r" alone, which would otherwise erase the final state.
            let segments = line.split(separator: "\r", omittingEmptySubsequences: false)
            return String(segments.last(where: { !$0.isEmpty }) ?? "")
        }.joined(separator: "\n")
    }

    /// SGR color table (30–37 standard, 90–97 bright), tuned per theme by
    /// the caller through `AnsiPalette`.
    struct AnsiPalette {
        var black: Color = .primary
        var red = Color(red: 0.78, green: 0.27, blue: 0.25)
        var green = Color(red: 0.28, green: 0.60, blue: 0.30)
        var yellow = Color(red: 0.72, green: 0.55, blue: 0.10)
        var blue = Color(red: 0.25, green: 0.45, blue: 0.80)
        var magenta = Color(red: 0.66, green: 0.34, blue: 0.72)
        var cyan = Color(red: 0.20, green: 0.58, blue: 0.62)
        var white: Color = .secondary

        func color(for code: Int) -> Color? {
            switch code {
            case 30, 90: return black
            case 31, 91: return red
            case 32, 92: return green
            case 33, 93: return yellow
            case 34, 94: return blue
            case 35, 95: return magenta
            case 36, 96: return cyan
            case 37, 97: return white
            default: return nil
            }
        }
    }

    /// Renders ANSI-colored text into an AttributedString: SGR color/bold
    /// codes become attributes, every other escape sequence (cursor moves,
    /// OSC titles) is stripped. `\r` redraws are collapsed first.
    static func ansiAttributed(_ raw: String, palette: AnsiPalette, baseColor: Color) -> AttributedString {
        let text = collapsingCarriageReturns(raw)
        var result = AttributedString()
        var currentColor: Color?
        var bold = false

        var index = text.startIndex
        var chunk = ""
        func flushChunk() {
            guard !chunk.isEmpty else { return }
            var piece = AttributedString(chunk)
            piece.foregroundColor = currentColor ?? baseColor
            if bold {
                piece.font = .system(size: 11.5, design: .monospaced).weight(.semibold)
            }
            result += piece
            chunk = ""
        }

        while index < text.endIndex {
            let char = text[index]
            if char == "\u{1B}" {
                flushChunk()
                let after = text.index(after: index)
                if after < text.endIndex, text[after] == "[" {
                    // CSI: parameters until a letter terminator.
                    var scan = text.index(after: after)
                    var params = ""
                    while scan < text.endIndex, !text[scan].isLetter {
                        params.append(text[scan])
                        scan = text.index(after: scan)
                    }
                    if scan < text.endIndex {
                        if text[scan] == "m" {
                            // SGR: apply codes; anything else is dropped.
                            let codes = params.split(separator: ";").compactMap { Int($0) }
                            for code in codes.isEmpty ? [0] : codes {
                                switch code {
                                case 0: currentColor = nil; bold = false
                                case 1: bold = true
                                case 22: bold = false
                                case 39: currentColor = nil
                                default:
                                    if let mapped = palette.color(for: code) { currentColor = mapped }
                                }
                            }
                        }
                        index = text.index(after: scan)
                        continue
                    }
                    index = scan
                    continue
                } else if after < text.endIndex, text[after] == "]" {
                    // OSC: until BEL or ESC \.
                    var scan = text.index(after: after)
                    while scan < text.endIndex, text[scan] != "\u{07}", text[scan] != "\u{1B}" {
                        scan = text.index(after: scan)
                    }
                    index = scan < text.endIndex ? text.index(after: scan) : scan
                    continue
                }
                index = after
                continue
            }
            chunk.append(char)
            index = text.index(after: index)
        }
        flushChunk()
        return result
    }

    // MARK: - Shell heuristics

    /// First tokens that make an untagged code line read as a command.
    private static let commandWords: Set<String> = [
        "ls", "cd", "pwd", "cat", "grep", "find", "git", "python", "python3",
        "pip", "pip3", "brew", "npm", "npx", "node", "mkdir", "rm", "cp",
        "mv", "echo", "curl", "wget", "ssh", "scp", "tail", "head", "chmod",
        "chown", "open", "docker", "make", "swift", "xcodebuild", "kill",
        "pkill", "ps", "whoami", "sudo", "touch", "which", "export", "source",
        "sh", "bash", "zsh", "man", "df", "du", "top", "uname", "date", "env"
    ]

    /// Whether an UNTAGGED fence looks like runnable shell commands — agents
    /// don't follow our prompt rules, so their shell blocks arrive without a
    /// ```sh tag and lost the ▶ button (e2e 2026-07-25). Conservative: a few
    /// short lines, every one starting with a known command / path / $-prompt.
    static func looksLikeShellCommands(_ content: String) -> Bool {
        let lines = content.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !lines.isEmpty, lines.count <= 12 else { return false }
        return lines.allSatisfy { line in
            var body = line
            if body.hasPrefix("$ ") { body = String(body.dropFirst(2)) }
            if body.hasPrefix("./") || body.hasPrefix("~/") || body.hasPrefix("/") { return true }
            guard let first = body.split(separator: " ").first else { return false }
            return commandWords.contains(String(first))
        }
    }

    // MARK: - Unified diff

    /// Whether a code block is a unified diff: explicit ```diff tag, or the
    /// classic header/hunk markers in the first lines.
    static func isUnifiedDiff(content: String, language: String) -> Bool {
        if language.lowercased() == "diff" || language.lowercased() == "patch" { return true }
        let head = content.split(separator: "\n").prefix(10)
        let hasFileHeader = head.contains { $0.hasPrefix("+++ ") } && head.contains { $0.hasPrefix("--- ") }
        let hasHunk = head.contains { $0.hasPrefix("@@") }
        return hasFileHeader && hasHunk
    }

    /// The file name a diff touches (from the `+++ b/...` header), for the
    /// block's title strip.
    static func diffFileName(_ content: String) -> String? {
        for line in content.split(separator: "\n").prefix(20) where line.hasPrefix("+++ ") {
            var name = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("b/") { name = String(name.dropFirst(2)) }
            if name != "/dev/null" { return name }
        }
        return nil
    }

    /// Line-colored rendering of a unified diff (+ additions, − removals,
    /// @@ hunk headers dimmed).
    static func diffAttributed(_ content: String, palette: AnsiPalette, baseColor: Color) -> AttributedString {
        var result = AttributedString()
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        for (offset, line) in lines.enumerated() {
            var piece = AttributedString(String(line))
            if line.hasPrefix("+"), !line.hasPrefix("+++") {
                piece.foregroundColor = palette.green
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                piece.foregroundColor = palette.red
            } else if line.hasPrefix("@@") {
                piece.foregroundColor = palette.cyan
            } else if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") {
                piece.foregroundColor = baseColor
                piece.font = .system(size: 11.5, design: .monospaced).weight(.semibold)
            } else {
                piece.foregroundColor = baseColor
            }
            result += piece
            if offset < lines.count - 1 {
                result += AttributedString("\n")
            }
        }
        return result
    }
}
