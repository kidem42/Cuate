import Foundation

/// Mirror-mode synchronization of an agent conversation with its gateway
/// session (AGENT-ADDONS-NOTES.md §6.1). The gateway is the source of truth:
/// the same session grows through Telegram, CLI and cron while we are away.
/// Catch-up runs when the conversation opens — it stamps our own rows with
/// their gateway identity (`externalID`/`seq`) and inserts everything that
/// happened past us, in gateway order.
///
/// The transport's `messages()` always delivers the FULL transcript: on
/// Hermes 0.20 it walks the paginated endpoint oldest-first (an unqualified
/// GET there returns only the newest 500 — it would silently behead long
/// sessions), on 0.19 the params are ignored and everything arrives at once.
/// Either way both catch-up and deep backfill work from one complete fetch;
/// the local cache bound decides what stays.
@MainActor
enum HermesMirrorSync {

    /// Fetches the gateway transcript and merges it into the store. Syncs
    /// the store's CURRENT conversation (each gateway session is its own
    /// thread). No-op when that conversation is not bound to a session yet,
    /// or has switched away while the fetch was in flight. Returns false
    /// when the gateway was unreachable (the caller shows the plaque).
    @discardableResult
    static func catchUp(role: AgentRole, store: ChatStore) async -> Bool {
        // Cold start: the key cache may still be filling — a keyless 401
        // here is noise, not "offline" (the apiKeysDidChange probe re-syncs
        // moments later).
        guard APIKeyStore.isWarm else { return true }
        // A turn in flight owns this conversation: its reply lives in the
        // LIVE bubble, not in the store yet, so the gateway's row for it has
        // nothing to claim and would be inserted as a second copy (e2e
        // 2026-07-27 — duplicates appeared mid-run, while tools were still
        // running). The post-turn sync picks everything up moments later.
        // Checked against the addon's own turn registry, NOT store.isLoading
        // alone: a session switch wipes the store flag, and a catch-up then
        // ran mid-run and duplicated the in-flight reply (2026-07-29 12:40).
        guard !store.isLoading else { return true }
        let conversationID = store.conversation
        guard !HermesAddon.shared.isTurnActive(forConversationKey: conversationID.storageKey) else {
            return true
        }
        guard conversationID.isAgent,
              let sessionID = HermesSettings.shared.sessionID(forConversationKey: conversationID.storageKey) else {
            return true // nothing to sync yet — not an error
        }
        // Coalesce concurrent triggers: onAppear, panel.show, the history-
        // loaded hook and the 20s poll all fire around the same moments, and
        // the telemetry showed the SAME session fetched 2–3× in parallel
        // (15:41:54–56: three overlapping 1.5–3.7s fetches). One sync per
        // session at a time; skippers return true — the in-flight pass
        // delivers, and any tail it missed rides the next tick.
        guard !inFlight.contains(sessionID) else { return true }
        inFlight.insert(sessionID)
        defer { inFlight.remove(sessionID) }
        do {
            // Count gate (perf 2026-07-31): the transcript endpoint serves
            // the FULL session (limit/offset ignored — fixtures) and, with
            // the target MainActor-isolated by default, its JSON parse +
            // merge run on the main thread — a stall that scales with the
            // chat's length, repeating on the ~20s poll and every summon
            // even when nothing changed. The sessions LIST is a few KB of
            // metadata and carries `message_count` (append-only transcript,
            // fixtures): unchanged count since the last merge ⇒ nothing to
            // fetch. A session outside the first 50 rows falls through to
            // the full fetch — the gate only ever SKIPS work it can prove
            // redundant.
            var gateCount: Int?
            let gateSessions = try? await HermesAddon.shared.transport().sessions(limit: 50)
            if let gateSessions {
                // Same fetch doubles as the label reconcile: the composer
                // shows the gateway's ACTUAL session model at launch and on
                // every poll, however the model was changed (user call-out
                // 2026-08-13 — the app must show real state, not our own
                // last request).
                HermesAddon.shared.reconcileSessionModels(sessions: gateSessions)
            }
            if let sessions = gateSessions,
               let row = sessions.first(where: { $0.id == sessionID }) {
                if lastMergedCounts[sessionID] == row.messageCount {
                    // Proof the transcript did NOT grow — retires a turn that
                    // was only inferred from growth (an interim reply mid-run
                    // looks exactly like a final one).
                    HermesAddon.shared.noteNoGrowth(sessionID: sessionID)
                    return true
                }
                gateCount = row.messageCount
            }
            let clock = ContinuousClock()
            var mark = clock.now
            let rows = try await HermesAddon.shared.transport().messages(sessionID: sessionID)
            let fetchMs = elapsedMs(since: &mark, clock: clock)
            // Is the gateway mid-turn right now? Read off the same fetch —
            // this is what restores the progress pill after a relaunch, and
            // what shows a run someone started from the phone.
            HermesAddon.shared.noteLiveTurn(
                HermesLiveTurnDetector.detect(rows: rows),
                rows: rows, sessionID: sessionID)
            // The user may have switched conversations during the fetch.
            guard store.conversation == conversationID, store.isHistoryLoaded else { return true }
            let (merged, changed) = merge(local: store.messages, gateway: rows, sessionID: sessionID)
            let mergeMs = elapsedMs(since: &mark, clock: clock)
            // The transcript just fetched is at LEAST as fresh as the count
            // read before it — committing the earlier count can only err
            // low, which re-fetches next tick (the safe direction).
            if let gateCount { lastMergedCounts[sessionID] = gateCount }
            // A transcript that mirrors into far fewer bubbles than it holds
            // rows is the signature of rows being dropped wholesale (an old
            // phone-held session came back as two bubbles out of 289 rows —
            // 2026-08-10, content parts read as empty strings). Log WHY, in
            // counts only, never text: the next occurrence is then
            // diagnosable from the log alone, with no gateway access.
            if merged.count * 4 < rows.count {
                var roles: [String: Int] = [:]
                for row in rows { roles[row.role, default: 0] += 1 }
                let empty = rows.filter {
                    $0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }.count
                let synthetic = rows.filter {
                    $0.role == "user" && HermesCompaction.visibleUserText($0.content) == nil
                }.count
                let roleTally = roles.sorted { $0.key < $1.key }
                    .map { "\($0.key):\($0.value)" }.joined(separator: ",")
                Diagnostics.log("hermes", "mirror.thin session=\(sessionID) rows=\(rows.count) merged=\(merged.count) roles=\(roleTally) empty=\(empty) synthetic=\(synthetic)")
            }
            if changed {
                // Rows the gateway just handed us hold the agent's RAW text,
                // Plaud markers included — the live path strips them and grows
                // chips instead, and a turn that ran elsewhere deserves the
                // same card. Runs before the store write so the window lands
                // in one update. No-op unless something new arrived carrying a
                // marker (the guard above), and unless Plaud is connected.
                let merged = await PlaudAgentChips.decorating(merged)
                guard store.conversation == conversationID, store.isHistoryLoaded else { return true }
                store.applyAgentMerge(merged)
                Diagnostics.log("hermes", "mirror.catchUp session=\(sessionID) rows=\(rows.count) merged=\(merged.count) fetch=\(fetchMs)ms merge=\(mergeMs)ms")
            } else if fetchMs + mergeMs > 50 {
                // No-change syncs used to be invisible in the log while
                // still paying the full parse — surface the slow ones.
                Diagnostics.log("hermes", "mirror.catchUp.slow session=\(sessionID) rows=\(rows.count) fetch=\(fetchMs)ms merge=\(mergeMs)ms")
            }
            return true
        } catch {
            Diagnostics.log("hermes", "mirror.catchUp failed: \(String(error.localizedDescription.prefix(120)))")
            return false
        }
    }

    /// `message_count` at the last completed catch-up, per session — the
    /// count gate above. In-memory on purpose: a fresh launch always syncs.
    private static var lastMergedCounts: [String: Int] = [:]

    /// Sessions with a catch-up mid-flight (concurrent-trigger coalescing).
    private static var inFlight: Set<String> = []

    /// Milliseconds since `mark`; advances `mark` to now (chained timings).
    /// Fetch time includes the network wait — the parse share is what lands
    /// on the main thread; merge time is pure main-thread work.
    private static func elapsedMs(since mark: inout ContinuousClock.Instant,
                                  clock: ContinuousClock) -> Int {
        let now = clock.now
        let duration = mark.duration(to: now)
        mark = now
        return Int(duration.components.seconds) * 1000
            + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Merges the local window with the gateway transcript.
    ///
    /// Identity rules (§6.1 p.5 of the plan):
    /// - a local row with `externalID` matches its gateway row directly;
    /// - a local row WITHOUT one (our own send the gateway hasn't been
    ///   matched to yet) is claimed by the first unclaimed gateway row with
    ///   the same role and trimmed text, in order — it gets stamped;
    /// - gateway rows nobody claimed become new messages (arrived via
    ///   Telegram/CLI), inserted in gateway order;
    /// - local rows never matched (welcome line, system notices) keep their
    ///   position relative to their neighbors.
    static func merge(
        local: [ChatMessage],
        gateway: [HermesTranscriptMessage],
        sessionID: String
    ) -> (messages: [ChatMessage], changed: Bool) {
        // Gateway service notifications (delegation results, background-
        // process reports) ride the transcript as `role == "user"` rows —
        // older builds mirrored them as bubbles the USER supposedly sent.
        // They render assistant-side now (`message(from:)` below); this
        // pre-pass migrates the legacy copies wherever they sit, including
        // the head the incremental split fences off.
        var local = local
        var converted = false
        for index in local.indices
        where local[index].isUser && local[index].messageType != .system
            && HermesServiceNotice.isNotice(local[index].text) {
            local[index] = assistantSide(local[index])
            converted = true
        }
        // Long sessions re-merge only their tail (the claim pass is
        // gateway-rows × local-rows, and the transcript arrives whole on
        // every sync — there is no pagination to lean on).
        if let split = incrementalSplit(local: local, gateway: gateway) {
            let (tail, changed) = mergeFull(
                local: split.localTail, gateway: split.gatewayTail, sessionID: sessionID)
            return (split.head + tail, changed || converted)
        }
        let (messages, changed) = mergeFull(local: local, gateway: gateway, sessionID: sessionID)
        return (messages, changed || converted)
    }

    /// The same message flipped to the assistant side (service notices; all
    /// other identity — gateway stamp, timestamp — is preserved).
    private static func assistantSide(_ message: ChatMessage) -> ChatMessage {
        ChatMessage(
            id: message.id, text: message.text, isUser: false,
            timestamp: message.timestamp, messageType: message.messageType,
            audioURL: message.audioURL, attachments: message.attachments,
            toolContext: message.toolContext, externalID: message.externalID,
            seq: message.seq, agentSteps: message.agentSteps
        )
    }

    /// Only user/assistant turns with content mirror into the chat as
    /// bubbles. Tool rows and empty tool-call shells are folded into a step
    /// summary attached to the NEXT content-bearing assistant row — without
    /// this, a mirror rebuild (app restart) lost the whole tool trail of a
    /// turn (e2e 2026-07-25).
    private static func contentRows(_ gateway: [HermesTranscriptMessage]) -> [HermesTranscriptMessage] {
        gateway.compactMap { row in
            guard row.role == "user" || row.role == "assistant" else { return nil }
            var content = row.content
            if row.role == "user" {
                // Compaction summaries ride the transcript as user rows and
                // mirrored verbatim they render as OUR message (2026-08-01).
                // Nil = fully synthetic — drop; a merged row keeps only its
                // real user part (which also lets the claim pass text-match
                // our local bubble).
                guard let visible = HermesCompaction.visibleUserText(content) else { return nil }
                content = visible
            }
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            if content == row.content { return row }
            return HermesTranscriptMessage(
                id: row.id, role: row.role, content: content,
                toolName: row.toolName, toolCallID: row.toolCallID,
                toolCallArguments: row.toolCallArguments, timestamp: row.timestamp
            )
        }
    }

    /// Overlap kept below the anchor: the newest stamped rows re-merge every
    /// time, so a turn whose text or step trail was still settling on the
    /// gateway can still be adopted (containment match, late step summary).
    private static let incrementalOverlap = 6
    /// Transcripts below this stay on the full path — the quadratic pass is
    /// milliseconds there, and the split's own scan would not pay for itself.
    private static let incrementalFloor = 200

    /// Splits local+gateway into an untouched head and the tail worth
    /// re-merging, or nil when the whole thing must be merged.
    ///
    /// The anchor is a local row carrying a gateway `seq`, taken `overlap`
    /// rows back from the newest one; everything before it is already
    /// mirrored, so neither side needs re-scanning. Two guards keep this
    /// honest: no anchor (a young or never-synced chat) and an INCOMPLETE
    /// head both fall back to the full merge — the latter is what lets a
    /// session that once mirrored thin (content parts read as empty, fixed
    /// 2026-08-10) heal itself on the next sync instead of being fenced off
    /// behind its own anchor forever.
    private static func incrementalSplit(
        local: [ChatMessage],
        gateway: [HermesTranscriptMessage]
    ) -> (head: [ChatMessage], localTail: [ChatMessage], gatewayTail: [HermesTranscriptMessage])? {
        guard gateway.count >= incrementalFloor else { return nil }
        let stamped = local.indices.filter { local[$0].seq != nil }
        guard let anchorIndex = stamped.dropLast(incrementalOverlap).last,
              let anchorSeq = local[anchorIndex].seq else { return nil }
        // User rows never collapse into one another (only assistant runs do),
        // so they count the head's completeness one for one. Service notices
        // are user-role on the gateway but mirror assistant-side — counting
        // them here would fail the completeness guard on every sync.
        let gatewayUsersBefore = contentRows(gateway)
            .filter {
                $0.role == "user" && $0.id < anchorSeq
                    && !HermesServiceNotice.isNotice($0.content)
            }.count
        let localUsersBefore = local[..<anchorIndex]
            .filter { $0.isUser && $0.messageType != .system }.count
        guard localUsersBefore >= gatewayUsersBefore else { return nil }
        let gatewayTail = gateway.filter { $0.id >= anchorSeq }
        Diagnostics.log("hermes", "mirror.incremental rows=\(gateway.count) tail=\(gatewayTail.count) head=\(anchorIndex)")
        return (Array(local[..<anchorIndex]), Array(local[anchorIndex...]), gatewayTail)
    }

    private static func mergeFull(
        local: [ChatMessage],
        gateway: [HermesTranscriptMessage],
        sessionID: String
    ) -> (messages: [ChatMessage], changed: Bool) {
        let filtered = contentRows(gateway)
        guard !filtered.isEmpty else { return (local, false) }
        var stepsByRowID = stepSummaries(gateway: gateway)

        // Collapse consecutive assistant rows into ONE row joined by blank
        // lines — the live UI glues a run's interim assistant messages into
        // a single bubble the same way, and the mirror must compare against
        // that shape: without this every interim segment came back as its
        // own duplicate bubble (e2e 2026-07-27). The run keeps the HEAD
        // segment's identity; follow-up segments' step trails fold into it.
        var gwRows: [HermesTranscriptMessage] = []
        for row in filtered {
            if row.role == "assistant", let last = gwRows.last, last.role == "assistant" {
                if let extra = stepsByRowID.removeValue(forKey: row.id) {
                    stepsByRowID[last.id] = [stepsByRowID[last.id], extra]
                        .compactMap { $0 }.joined(separator: "\n")
                }
                gwRows[gwRows.count - 1] = HermesTranscriptMessage(
                    id: last.id, role: "assistant",
                    content: last.content + "\n\n" + row.content,
                    toolName: nil, toolCallID: nil, toolCallArguments: [],
                    timestamp: last.timestamp
                )
                continue
            }
            gwRows.append(row)
        }

        var localRows = local
        var changed = false
        // gwIndex → index into localRows (claimed pairs).
        var claims = [Int: Int]()
        var claimedLocal = Set<Int>()
        let extToLocal = Dictionary(
            localRows.enumerated().compactMap { index, message in
                message.externalID.map { ($0, index) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        // Claim pass. Text matching scans forward so two identical sends
        // claim two distinct gateway rows in order.
        var textScanStart = 0
        for (gwIndex, gwRow) in gwRows.enumerated() {
            let externalID = gwRow.externalID(sessionID: sessionID)
            if let localIndex = extToLocal[externalID] {
                claims[gwIndex] = localIndex
                claimedLocal.insert(localIndex)
                textScanStart = max(textScanStart, localIndex + 1)
                continue
            }
            let isUser = gwRow.role == "user"
            // Our briefed first send holds preamble + text on the gateway,
            // while the local bubble holds the text alone — strip the tagged
            // block before comparing (and below, before inserting).
            // Plaud markers are addressing, not prose: the live bubble already
            // dropped them and grew chips instead, so the transcript's copy is
            // normalized the same way here. Comparing the raw form made every
            // such turn look like a NEW message and inserted a duplicate
            // carrying the raw `plaud://…` ids (e2e 2026-08-16).
            let gwText = AgentPlaudNote.split(
                HermesBriefing.stripped(gwRow.content)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            ).display
            var scan = textScanStart
            while scan < localRows.count {
                let candidate = localRows[scan]
                // Text match — OR the gateway's media placeholders against
                // our attachment send: Hermes keeps no pixels, its transcript
                // says "check again [screenshot]" where we hold "check again"
                // + the real attachment. Bracketed tokens are stripped before
                // comparing, which covers attachment-only sends ("" left) AND
                // text+image sends — the latter came back as a duplicate
                // text bubble (e2e 2026-07-27).
                let candidateMatches: (ChatMessage) -> Bool = { candidate in
                    let localText = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if localText == gwText { return true }
                    // A reply whose recordings could not be resolved KEEPS its
                    // markers (better a visible id than an empty bubble), so
                    // the same turn exists in two shapes. Normalize ours too
                    // before deciding it is a different message.
                    if localText.contains("plaud://"),
                       AgentPlaudNote.split(localText).display == gwText { return true }
                    // Assistant turns: the live bubble glues a run's interim
                    // segments as they arrive, the transcript stores them as
                    // separate rows — a partial overlap is the SAME turn, not
                    // a new one. Without containment matching the run came
                    // back as a second bubble holding the other half of the
                    // text (e2e 2026-07-27). Bounded by length so two short
                    // "ok" turns can't claim each other.
                    if !isUser, !localText.isEmpty, !gwText.isEmpty,
                       min(localText.count, gwText.count) >= 40,
                       localText.contains(gwText) || gwText.contains(localText) {
                        return true
                    }
                    guard isUser, !candidate.attachments.isEmpty else { return false }
                    return AgentAttachNote.normalizedForMatching(gwText) == localText
                }
                if !claimedLocal.contains(scan),
                   candidate.externalID == nil,
                   candidate.isUser == isUser,
                   candidate.messageType != .system,
                   candidateMatches(candidate) {
                    // Stamp our own row with its gateway identity (and the
                    // rebuilt step trail when the live one was lost).
                    localRows[scan].externalID = externalID
                    localRows[scan].seq = gwRow.id
                    // Claimed by containment → the gateway holds the whole
                    // turn, our bubble only part of it: adopt its text so the
                    // chat shows the full answer instead of half of it. NOT
                    // when the only difference is unresolved Plaud markers —
                    // adopting there would drop the ids and leave a bubble
                    // with nothing in it.
                    let localText = localRows[scan].text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !isUser, !gwText.isEmpty, localText != gwText,
                       !(localText.contains("plaud://") && AgentPlaudNote.split(localText).display == gwText) {
                        localRows[scan].text = gwText
                    }
                    if localRows[scan].agentSteps == nil, let steps = stepsByRowID[gwRow.id] {
                        localRows[scan].agentSteps = steps
                    }
                    claims[gwIndex] = scan
                    claimedLocal.insert(scan)
                    textScanStart = scan + 1
                    changed = true
                    break
                }
                scan += 1
            }
        }

        // Merge pass: walk local rows; before a claimed row, flush every
        // earlier unclaimed gateway row as a new message.
        var merged: [ChatMessage] = []
        var nextGW = 0
        func flushGW(upTo bound: Int) {
            while nextGW < bound {
                if claims[nextGW] == nil {
                    merged.append(message(from: gwRows[nextGW], sessionID: sessionID))
                    changed = true
                }
                nextGW += 1
            }
        }
        for (index, row) in localRows.enumerated() {
            if let gwIndex = claims.first(where: { $0.value == index })?.key {
                flushGW(upTo: gwIndex)
                nextGW = max(nextGW, gwIndex + 1)
            }
            merged.append(row)
        }
        flushGW(upTo: gwRows.count)

        // Self-heal duplicates older races left behind (a mid-run catch-up
        // once inserted the gateway's copy of an in-flight reply; adoption
        // later grew one bubble to the full text while the partial copy
        // stayed): two ADJACENT assistant bubbles where one text fully
        // contains the other are the same turn twice — a genuine repeat has
        // the user's message between them. Keep the fuller copy and move
        // the gateway identity/steps onto it when only the dropped one had
        // them. Bounded like the claim containment (≥40 chars) so short
        // "ok"-style answers never merge.
        var healed: [ChatMessage] = []
        for row in merged {
            // Compaction summaries older builds imported as OUR bubbles:
            // purge (their gateway rows are filtered out above, so nothing
            // reinserts them).
            if row.isUser, row.messageType != .system,
               HermesCompaction.visibleUserText(row.text) == nil {
                changed = true
                continue
            }
            if let previous = healed.last,
               !row.isUser, !previous.isUser,
               row.messageType != .system, previous.messageType != .system,
               // Service-notice cards are assistant-side but never halves of
               // a split reply — keep them out of containment absorption.
               !HermesServiceNotice.isNotice(row.text),
               !HermesServiceNotice.isNotice(previous.text) {
                let a = previous.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let b = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if min(a.count, b.count) >= 40 {
                    if a.contains(b), row.attachments.isEmpty {
                        healed[healed.count - 1] = absorbing(previous, dropped: row)
                        changed = true
                        continue
                    }
                    if b.contains(a), previous.attachments.isEmpty {
                        healed[healed.count - 1] = absorbing(row, dropped: previous)
                        changed = true
                        continue
                    }
                }
            }
            healed.append(row)
        }

        return (healed, changed)

        func absorbing(_ keeper: ChatMessage, dropped: ChatMessage) -> ChatMessage {
            var kept = keeper
            if kept.externalID == nil {
                kept.externalID = dropped.externalID
                kept.seq = dropped.seq
            }
            if kept.agentSteps == nil {
                kept.agentSteps = dropped.agentSteps
            }
            return kept
        }

        func message(from row: HermesTranscriptMessage, sessionID: String) -> ChatMessage {
            // Service notifications are user-role only formally (see the
            // merge pre-pass) — they mirror as an assistant-side card.
            let isNotice = row.role == "user" && HermesServiceNotice.isNotice(row.content)
            return ChatMessage(
                id: UUID(),
                // A briefed first send rebuilt from the gateway (app
                // reinstall, another Cuate) must not show the preamble.
                text: row.role == "user" && !isNotice
                    ? HermesBriefing.stripped(row.content) : row.content,
                isUser: row.role == "user" && !isNotice,
                timestamp: row.timestamp ?? Date(),
                messageType: .text,
                audioURL: nil,
                attachments: [],
                toolContext: nil,
                externalID: row.externalID(sessionID: sessionID),
                seq: row.id,
                agentSteps: row.role == "assistant" ? stepsByRowID[row.id] : nil
            )
        }
    }

    /// Rebuilds step-journal summaries from the transcript: tool rows (and
    /// their call arguments from the tool-call shells) accumulate and attach
    /// to the id of the NEXT content-bearing assistant row. Format matches
    /// `AgentStepJournal.summary()` — `parse` renders both the same way.
    private static func stepSummaries(gateway: [HermesTranscriptMessage]) -> [Int: String] {
        var result: [Int: String] = [:]
        var pending: [String] = []
        for row in gateway {
            if row.role == "tool" {
                let name = row.toolName ?? "tool"
                // Result preview: exit code when the payload carries one,
                // else the head of the raw content.
                var detail = String(row.content.replacingOccurrences(of: "\n", with: " ").prefix(100))
                if let data = row.content.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let output = json["output"] as? String, !output.isEmpty {
                        detail = String(output.replacingOccurrences(of: "\n", with: " ").prefix(100))
                    } else if let message = json["message"] as? String {
                        detail = String(message.prefix(100))
                    }
                }
                pending.append("\(name) · completed · \(detail)")
            } else if row.role == "assistant",
                      !row.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !pending.isEmpty {
                    result[row.id] = pending.joined(separator: "\n")
                    pending = []
                }
            }
        }
        return result
    }
}
