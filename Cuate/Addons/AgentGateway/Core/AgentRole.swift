import Foundation

/// An agent role offered in the prompt-preset switcher, next to "Assistant"
/// and "Translator" — one list, one gesture, no separate mode
/// (AGENT-ADDONS-NOTES.md §6). A role carries the whole stack: which addon
/// (transport), which agent/profile on that gateway, and its own isolated
/// conversation (`ChatStore.ConversationID.agent`).
struct AgentRole: Identifiable, Equatable {
    /// Stable identity: "<addonID>:<agentID>" (e.g. "hermes:hermes-agent").
    /// Persisted in `AppSettings.activeAgentRoleID`.
    let id: String
    /// The addon that owns the transport ("hermes").
    let addonID: String
    /// The agent/profile on the gateway (Hermes: the model id from
    /// `/v1/models`, usually the profile name).
    let agentID: String
    /// Name shown in the switcher and the role chip.
    let displayName: String
    /// Emoji for the chip row (same visual language as preset icons).
    let icon: String

    /// The role's default thread; pass a session id for the conversation of
    /// ONE specific gateway session (its own store and stream isolation).
    func conversationID(sessionID: String? = nil) -> ChatStore.ConversationID {
        .agent(addonID: addonID, agentID: agentID, sessionID: sessionID)
    }

    var conversationID: ChatStore.ConversationID {
        conversationID()
    }

    /// Parses a persisted role id back into (addonID, agentID).
    /// Agent IDs may contain ":" themselves — split on the FIRST separator.
    static func parseID(_ id: String) -> (addonID: String, agentID: String)? {
        guard let sep = id.firstIndex(of: ":") else { return nil }
        let addon = String(id[..<sep])
        let agent = String(id[id.index(after: sep)...])
        guard !addon.isEmpty, !agent.isEmpty else { return nil }
        return (addon, agent)
    }

    static func makeID(addonID: String, agentID: String) -> String {
        "\(addonID):\(agentID)"
    }
}
