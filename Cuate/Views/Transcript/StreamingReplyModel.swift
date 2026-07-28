import SwiftUI
import Combine

/// Live buffer for the reply currently being streamed.
///
/// The transcript list knows nothing about it: chunks land here, only the
/// streaming bubble observes it, and the store receives the full text once
/// (plus periodic persistence checkpoints). That is what makes a flush
/// O(chunk) instead of O(whole answer): nothing re-diffs the message list
/// and nothing re-parses the parts of the answer that are already final.
///
/// Incremental layout: the text is split into FROZEN SEGMENTS (markdown
/// parsed once, never touched again) and a short TAIL that grows with the
/// stream. Freezing happens only at safe block boundaries — a blank line
/// outside any code fence — so segment-by-segment rendering is identical
/// to parsing the whole text at once (every block type in
/// `MarkdownBlocksView.parse` terminates at a blank line except fences).
/// Main-thread only, like ChatStore: every mutation comes from the
/// @MainActor streaming task, every read from SwiftUI bodies.
final class StreamingReplyModel: ObservableObject {
    struct Segment: Identifiable, Equatable {
        let id: Int
        let text: String
    }

    @Published private(set) var segments: [Segment] = []
    @Published private(set) var tail: String = ""
    /// Complete accumulated text — what gets committed to the store.
    private(set) var fullText: String = ""
    private var nextSegmentID = 0

    /// The tail is left alone until it outgrows this (in UTF-8 bytes):
    /// short answers stay a single parse, and segments never come out
    /// dust-sized.
    private static let freezeThreshold = 600

    func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        fullText += chunk
        tail += chunk
        freezeIfPossible()
    }

    func reset() {
        segments = []
        tail = ""
        fullText = ""
        nextSegmentID = 0
    }

    /// Replaces the whole buffer (re-attaching to an in-flight reply after
    /// a conversation switch back to its origin).
    func setFullText(_ text: String) {
        reset()
        append(text)
    }

    /// Moves the largest safe prefix of the tail into a frozen segment.
    private func freezeIfPossible() {
        guard tail.utf8.count > Self.freezeThreshold else { return }
        // A cut can only succeed BEFORE the first fence that never closes —
        // clamp the boundary search there. Without the clamp, a streaming
        // artifact (an 11 KB HTML fence full of blank lines) made this loop
        // probe EVERY blank line × rescan the whole tail, on EVERY flush:
        // O(n²) on the main thread — the live bubble froze until the stream
        // ended ("плашка исчезает, потом резко готовый бабл", 2026-07-28).
        let limit = firstUnclosedFenceStart() ?? tail.endIndex
        guard limit > tail.startIndex else { return }
        var searchRange = tail.startIndex..<limit
        while let boundary = tail.range(of: "\n\n", options: .backwards, range: searchRange) {
            let candidate = String(tail[..<boundary.upperBound])
            if hasNoOpenFence(candidate) {
                segments.append(Segment(id: nextSegmentID, text: candidate))
                nextSegmentID += 1
                tail = String(tail[boundary.upperBound...])
                return
            }
            // The boundary sits inside an open ``` fence — try an earlier one.
            searchRange = tail.startIndex..<boundary.lowerBound
        }
    }

    /// Start index of the first fence that stays open to the end of the
    /// tail, or nil when every fence is closed. One linear pass.
    private func firstUnclosedFenceStart() -> String.Index? {
        var openTicks = 0
        var openStart: String.Index?
        var lineStart = tail.startIndex
        while lineStart < tail.endIndex {
            let lineEnd = tail[lineStart...].firstIndex(of: "\n") ?? tail.endIndex
            let trimmed = tail[lineStart..<lineEnd].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                let ticks = trimmed.prefix(while: { $0 == "`" }).count
                if openTicks == 0 {
                    openTicks = ticks
                    openStart = lineStart
                } else if ticks >= openTicks, trimmed.drop(while: { $0 == "`" }).isEmpty {
                    openTicks = 0
                    openStart = nil
                }
            }
            lineStart = lineEnd < tail.endIndex ? tail.index(after: lineEnd) : tail.endIndex
        }
        return openTicks > 0 ? openStart : nil
    }

    /// True when every ``` fence opened in `text` is closed again — the
    /// only case where cutting the text is invisible to the block parser.
    private func hasNoOpenFence(_ text: String) -> Bool {
        var openTicks = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("```") else { continue }
            let ticks = trimmed.prefix(while: { $0 == "`" }).count
            if openTicks == 0 {
                openTicks = ticks
            } else if ticks >= openTicks, trimmed.drop(while: { $0 == "`" }).isEmpty {
                // Closing fence: backticks-only, at least as long as the
                // opener (matches the parser's CommonMark rule).
                openTicks = 0
            }
        }
        return openTicks == 0
    }
}

/// Markdown body of the live streaming bubble: frozen segments render once
/// and are skipped by SwiftUI on every subsequent flush (`.equatable()`
/// plus the parse cache), only the short tail is re-laid-out.
struct StreamingReplyText: View {
    @ObservedObject var model: StreamingReplyModel
    let linkColor: Color

    var body: some View {
        // spacing 6 == MarkdownBlocksView's chat block spacing, so a split
        // at a segment boundary is visually identical to one big parse.
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.segments) { segment in
                FrozenSegmentView(text: segment.text, linkColor: linkColor)
                    .equatable()
            }
            if !model.tail.isEmpty {
                // The `<continue/>` auto-continuation marker is an app-model
                // contract, not content — it never renders, even for the
                // moment before the round loop strips it from the buffer.
                let visibleTail = model.tail
                    .replacingOccurrences(of: "<continue/>", with: "")
                    .replacingOccurrences(of: "<continue />", with: "")
                if !visibleTail.isEmpty {
                    MarkdownBlocksView(text: visibleTail, linkColor: linkColor, isStreaming: true)
                }
            }
        }
    }

    private struct FrozenSegmentView: View, Equatable {
        let text: String
        let linkColor: Color

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.text == rhs.text }

        var body: some View {
            MarkdownBlocksView(text: text, linkColor: linkColor)
        }
    }
}
