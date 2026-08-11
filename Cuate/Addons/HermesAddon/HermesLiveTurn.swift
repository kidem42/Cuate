import Foundation

/// A turn running ON THE GATEWAY rather than in this process: started from
/// another client (phone, Telegram, cron), or started by us and orphaned by
/// a restart/crash. Our own in-flight turns live in `ChatWindow.streamSlots`
/// and never come through here.
///
/// Hermes has no push channel and no run-status field in the session
/// metadata (probed 2026-08-10: sessions carry counters and `last_active`,
/// nothing about an active run), so this is rebuilt from the transcript the
/// mirror already fetches — no extra requests.
struct HermesLiveTurn: Equatable {
    /// How the turn was recognized — it decides how long it may survive
    /// without fresh evidence (see `HermesAddon.noteNoGrowth`).
    enum Source {
        /// The tail itself is unfinished (tool rows / an unanswered message
        /// after the last reply). Trustworthy on its own.
        case tail
        /// The tail READS finished, but the transcript grew since the last
        /// look. Hermes emits interim replies mid-turn ("let me check…"),
        /// so a finished-looking tail is not proof the run is over — growth
        /// is. Weak evidence: it expires the moment growth stops.
        case growth
    }

    /// Steps rebuilt from the transcript tail. May be empty: a turn whose
    /// user message just landed has no tool rows yet, and a growth-detected
    /// one has no unfinished calls to show at all.
    var steps: [AgentStep]
    /// Timestamp of the newest transcript row — what staleness is measured
    /// against (a crashed run leaves its tail unfinished forever).
    var lastRowAt: Date
    var source: Source = .tail
}

@MainActor
enum HermesLiveTurnDetector {

    /// A tail this old stops counting as a running turn. Generous on
    /// purpose: one tool call can legitimately go quiet for minutes (a long
    /// build, a slow fetch), and a false "still working" is a smaller sin
    /// than a chat that looks dead while the agent works.
    static let staleAfter: TimeInterval = 20 * 60

    /// Reads the transcript tail as a running turn, or nil when the session
    /// is idle.
    ///
    /// A turn is over when the newest row is an assistant message WITH text:
    /// that is the reply. Anything after it — tool results, tool-call shells,
    /// or a user message still awaiting an answer — means work is in flight.
    static func detect(rows: [HermesTranscriptMessage], now: Date = Date()) -> HermesLiveTurn? {
        guard let newest = rows.last else { return nil }
        let lastReply = rows.lastIndex { row in
            row.role == "assistant"
                && !row.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if lastReply == rows.indices.last { return nil }
        // Freshness is judged on the newest row that carries a timestamp —
        // rows without one (older gateways) must not read as 1970.
        let lastRowAt = rows.reversed().compactMap(\.timestamp).first ?? now
        guard now.timeIntervalSince(lastRowAt) < staleAfter else { return nil }
        let tailStart = lastReply.map { rows.index(after: $0) } ?? rows.startIndex
        return HermesLiveTurn(steps: steps(in: rows[tailStart...], now: now), lastRowAt: lastRowAt)
    }

    /// Pairs tool-call shells with their result rows: a call still missing
    /// its result is the step running right now.
    private static func steps(in tail: ArraySlice<HermesTranscriptMessage>, now: Date) -> [AgentStep] {
        var steps: [AgentStep] = []
        var pending: [(id: String, name: String, startedAt: Date)] = []
        for row in tail {
            switch row.role {
            case "assistant":
                for call in row.toolCallArguments where call.name != "_thinking" {
                    pending.append((call.id, call.name, row.timestamp ?? now))
                }
            case "tool":
                let match = pending.first { $0.id == row.toolCallID }
                let name = row.toolName ?? match?.name ?? "tool"
                guard name != "_thinking" else { break }
                steps.append(AgentStep(
                    id: "gw-\(row.id)",
                    toolName: name,
                    preview: nil,
                    status: .completed,
                    startedAt: match?.startedAt ?? row.timestamp ?? now,
                    finishedAt: row.timestamp ?? now
                ))
                pending.removeAll { $0.id == row.toolCallID }
            default:
                break
            }
        }
        // Whatever never got a result row is what the agent is doing now.
        for call in pending {
            steps.append(AgentStep(
                id: "gw-pending-\(call.id)",
                toolName: call.name,
                preview: nil,
                status: .running,
                startedAt: call.startedAt,
                finishedAt: nil
            ))
        }
        return steps
    }
}
