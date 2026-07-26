import Foundation

/// Mirror-mode synchronization of an agent conversation with its gateway
/// session (AGENT-ADDONS-NOTES.md §6.1). The gateway is the source of truth:
/// the same session grows through Telegram, CLI and cron while we are away.
/// Catch-up runs when the conversation opens — it stamps our own rows with
/// their gateway identity (`externalID`/`seq`) and inserts everything that
/// happened past us, in gateway order.
///
/// Hermes 0.19.0 serves the FULL transcript only (`limit`/`offset`/`before_id`
/// are ignored — probed live, see fixtures), so both catch-up and deep
/// backfill work from one fetch; the local cache bound decides what stays.
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
        let conversationID = store.conversation
        guard conversationID.isAgent,
              let sessionID = HermesSettings.shared.sessionID(forConversationKey: conversationID.storageKey) else {
            return true // nothing to sync yet — not an error
        }
        do {
            let rows = try await HermesAddon.shared.transport().messages(sessionID: sessionID)
            // The user may have switched conversations during the fetch.
            guard store.conversation == conversationID, store.isHistoryLoaded else { return true }
            let (merged, changed) = merge(local: store.messages, gateway: rows, sessionID: sessionID)
            if changed {
                store.applyAgentMerge(merged)
                Diagnostics.log("hermes", "mirror.catchUp session=\(sessionID) rows=\(rows.count) merged=\(merged.count)")
            }
            return true
        } catch {
            Diagnostics.log("hermes", "mirror.catchUp failed: \(String(error.localizedDescription.prefix(120)))")
            return false
        }
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
        // Only user/assistant turns with content mirror into the chat as
        // bubbles. Tool rows and empty tool-call shells are folded into a
        // step summary attached to the NEXT content-bearing assistant row —
        // without this, a mirror rebuild (app restart) lost the whole tool
        // trail of a turn (e2e 2026-07-25).
        let gwRows = gateway.filter {
            ($0.role == "user" || $0.role == "assistant")
                && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !gwRows.isEmpty else { return (local, false) }
        let stepsByRowID = stepSummaries(gateway: gateway)

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
            let gwText = gwRow.content.trimmingCharacters(in: .whitespacesAndNewlines)
            var scan = textScanStart
            while scan < localRows.count {
                let candidate = localRows[scan]
                // Text match — OR the gateway's image placeholder against
                // our attachment-only send: Hermes keeps no pixels, its
                // transcript says "[screenshot]"/"[image]" where we hold the
                // real attachment; without this rule the placeholder came
                // back as a duplicate text bubble (e2e 2026-07-25).
                let candidateMatches: (ChatMessage) -> Bool = { candidate in
                    let localText = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if localText == gwText { return true }
                    return isUser
                        && !candidate.attachments.isEmpty
                        && localText.isEmpty
                        && gwText.hasPrefix("[") && gwText.hasSuffix("]")
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

        return (merged, changed)

        func message(from row: HermesTranscriptMessage, sessionID: String) -> ChatMessage {
            ChatMessage(
                id: UUID(),
                text: row.content,
                isUser: row.role == "user",
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
