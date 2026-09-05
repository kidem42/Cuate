import Foundation

// MARK: - Mid-turn follow-ups (steer)
//
// A message typed while an agent turn runs does not open a competing turn:
// it rides INTO the running one through `POST /v1/runs/{id}/steer` (or the
// patched session route). Hermes appends the text to the last tool result
// of its next completed tool batch, wrapped in the out-of-band markers from
// `agent/prompt_builder.py`, and its system prompt tells the model to treat
// the marker as a direct user instruction "with the same authority as the
// original request" and to "adjust course accordingly" — nothing says the
// task in progress is still the task. Left alone, the model pivots to the
// follow-up and drops the original work (live 2026-09-04: a question sent
// mid-turn was answered, the table it was meant to supplement never was).
//
// Cuate's contract: everything typed mid-turn is an ADDITION to the cycle in
// progress — the addition itself may well redirect the work ("stop that, do
// this instead"), so the frame says only which cycle it belongs to and
// leaves the rest to the user's words. The wire text carries that in a
// tagged addendum block ahead of the words; the local bubble
// shows only the words, and the mirror strips the block when the marker
// comes back inside a tool row (`extract`). A steer the agent never read —
// accepted after the run's last tool batch, so no tool result was left to
// carry it (`pending_steer` on `run.completed`) — is unframed and sent again
// as the next turn.
//
// Pure Foundation: compiled standalone by scripts/test-attach-note.sh.
// Twin: `HermesSteer` on Android (`hermes/HermesSteer.kt`) — keep in sync;
// both are checked against `shared/fixtures/steer-frame.json`.
enum HermesSteer {
    /// Hermes' own markers around a steer inside a tool result. The open
    /// marker's bracket text may evolve between versions, so matching is
    /// anchored on its stable prefix; the close marker is exact.
    static let openPrefix = "[OUT-OF-BAND USER MESSAGE"
    static let closeMarker = "[/OUT-OF-BAND USER MESSAGE]"

    static let frameOpen = "<cuate-addendum>"
    static let frameClose = "</cuate-addendum>"

    /// English regardless of the UI language, like the briefing: it talks
    /// to the agent, whose system prompt is English. Byte-identical on
    /// Android (the fixture pins it).
    static let frame = frameOpen + "\n"
        + "The user is adding to the request you are working on right now: "
        + "take the addition below into account in the current cycle.\n"
        + frameClose

    /// The wire text of a mid-turn send.
    static func framed(_ text: String) -> String {
        frame + "\n\n" + text
    }

    /// The user's own words of a wire text, one piece per addendum block.
    /// Hermes joins steers accepted before one drain point with a newline,
    /// so a single marker — or a single `pending_steer` — may carry several
    /// framed sends. Text outside any block (a steer from a device without
    /// the frame, the CLI's `/steer`) is a piece of its own; an unclosed
    /// open tag is literal text. Pieces are trimmed; empty ones drop.
    static func pieces(_ text: String) -> [String] {
        var result: [String] = []
        var cursor = text.startIndex
        func flush(_ range: Range<String.Index>) {
            let piece = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { result.append(piece) }
        }
        while let open = text.range(of: frameOpen, range: cursor..<text.endIndex),
              let close = text.range(of: frameClose, range: open.upperBound..<text.endIndex) {
            flush(cursor..<open.lowerBound)
            cursor = close.upperBound
        }
        flush(cursor..<text.endIndex)
        return result
    }

    /// The user's own words of a wire text as one string (what a replayed
    /// `pending_steer` sends as the next turn).
    static func unframed(_ text: String) -> String {
        pieces(text).joined(separator: "\n\n")
    }

    /// The steered texts inside one tool row's content, in order — the
    /// user's words only, addendum blocks stripped.
    static func extract(fromToolContent content: String) -> [String] {
        guard content.contains(openPrefix) else { return [] }
        var texts: [String] = []
        var cursor = content.startIndex
        while let open = content.range(of: openPrefix, range: cursor..<content.endIndex) {
            // End of the open marker's bracket, then the payload up to close.
            guard let bracket = content.range(of: "]", range: open.upperBound..<content.endIndex),
                  let close = content.range(of: closeMarker, range: bracket.upperBound..<content.endIndex)
            else { break }
            texts += pieces(String(content[bracket.upperBound..<close.lowerBound]))
            cursor = close.upperBound
        }
        return texts
    }
}
