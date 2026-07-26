import Foundation

/// Lazy loader of full step details for the journal's second level: the
/// persisted summary is one line per step; the command text, output and
/// exit code live in the GATEWAY transcript and are fetched only when the
/// user expands a row (notes §6.1 p.5 — the full log is never persisted).
@MainActor
enum HermesStepDetails {

    /// Transcript cache per session (one expand shouldn't refetch per row;
    /// invalidated by time — the transcript only grows).
    private static var cache: (sessionID: String, rows: [HermesTranscriptMessage], at: Date)?

    /// Details for ALL steps of the assistant message with gateway row id
    /// `assistantSeq`, in step order — same grouping the summary rebuild
    /// uses (tool rows since the previous content-bearing row).
    static func details(forAssistantSeq assistantSeq: Int) async -> [AgentStepDetail] {
        // The open conversation names the session (the journal lives in it).
        guard let key = ChatWindowBridge.chatStore?.conversation.storageKey,
              let sessionID = HermesSettings.shared.sessionID(forConversationKey: key) else { return [] }

        let rows: [HermesTranscriptMessage]
        if let cached = cache, cached.sessionID == sessionID, Date().timeIntervalSince(cached.at) < 20 {
            rows = cached.rows
        } else {
            guard let fetched = try? await HermesAddon.shared.transport().messages(sessionID: sessionID) else {
                return []
            }
            rows = fetched
            cache = (sessionID, fetched, Date())
        }

        // Arguments live on the assistant tool-call SHELLS (empty content),
        // keyed by tool_call_id; results on the tool rows.
        var argsByCallID: [String: String] = [:]
        for row in rows where row.role == "assistant" {
            for call in row.toolCallArguments {
                argsByCallID[call.id] = call.arguments
            }
        }

        var pending: [AgentStepDetail] = []
        for row in rows {
            if row.role == "tool" {
                var detail = AgentStepDetail()
                if let callID = row.toolCallID, let raw = argsByCallID[callID] {
                    detail.command = Self.commandText(fromArguments: raw)
                }
                if let data = row.content.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    detail.output = (json["output"] as? String)
                        ?? (json["message"] as? String)
                        ?? String(row.content.prefix(4000))
                    detail.exitCode = json["exit_code"] as? Int
                } else {
                    detail.output = String(row.content.prefix(4000))
                }
                detail.output = detail.output.map { String($0.prefix(4000)) }
                detail.paths = AgentFilePaths.extract(
                    from: (detail.command ?? "") + "\n" + (detail.output ?? "")
                )
                pending.append(detail)
            } else if row.role == "assistant",
                      !row.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if row.id == assistantSeq {
                    return pending
                }
                pending = []
            } else if row.role == "user" {
                pending = []
            }
        }
        return []
    }

    /// The human-facing argument text: for terminal-style tools the command
    /// itself, else the compact JSON.
    private static func commandText(fromArguments raw: String) -> String {
        if let data = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let command = json["command"] as? String { return command }
            if let path = json["path"] as? String { return path }
            return json.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")
        }
        return raw
    }
}
