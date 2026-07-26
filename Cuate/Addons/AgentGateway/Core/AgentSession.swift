import Foundation

extension Notification.Name {
    /// ▶ menu on a shell block while an agent role is active: run the
    /// command (object: String) ON THE AGENT — it goes over as a normal
    /// turn and passes the gateway's own policy (§7.3).
    static let agentRunCommandRemotely = Notification.Name("agentRunCommandRemotely")
}

// MARK: - AgentGateway core: the session contract
//
// Shared substrate for external-agent addons (HermesAddon now, OpenClawAddon
// later). An agent is NOT a stateless LLM provider: it holds the conversation
// context on its side, runs its own tools, and can ask the human for
// permission mid-turn. `LLMProvider` (request/response with a text stream) is
// too small for that — this is the richer contract the chat pipeline speaks
// when an agent role is active. See AGENT-ADDONS-NOTES.md §4.

/// One tool step of an agent turn (from `tool.started`/`tool.completed`
/// events). Identity is the gateway's message ID + tool name + start time —
/// enough to match a completion to its start within one turn.
struct AgentStep: Identifiable, Equatable {
    enum Status: String {
        case running
        case completed
        case failed
    }

    let id: String
    let toolName: String
    /// Human-readable argument preview (e.g. the shell command text).
    let preview: String?
    var status: Status
    let startedAt: Date
    var finishedAt: Date?

    var duration: TimeInterval? {
        finishedAt.map { $0.timeIntervalSince(startedAt) }
    }
}

/// A pending permission request surfaced by the gateway mid-turn ("the agent
/// wants to run this command"). Resolved via `AgentSession.resolveApproval`.
struct AgentApproval: Identifiable, Equatable {
    let id: String
    /// The action awaiting approval, verbatim (command text, tool call
    /// summary). Rendered monospaced in the approval card; may be hidden in
    /// notifications ("hide details" option).
    let subject: String
    let toolName: String?
    /// Where the action would execute — the gateway host plus its terminal
    /// backend when known ("mac-mini · local, no isolation"). The human must
    /// see what they are approving and where it runs.
    let hostDescription: String?
    /// Whether the gateway accepts a persistent "always allow" answer for
    /// this request. The card shows the button only when true — we never
    /// fake a policy write the gateway wouldn't honor.
    let supportsAlways: Bool
}

enum AgentApprovalDecision: String {
    case approve
    case approveAlways
    case deny
}

/// Normalized failure surfaced to the chat (and the diagnostics panel).
/// `probeStatus` carries the structured cause when the failure maps onto a
/// known gateway condition — the UI renders `GatewayProbe.Status.message`.
struct AgentDiagnostic: Error {
    let message: String
    var probeStatus: GatewayProbe.Status?
}

/// Coarse connection state for the role chip's status dot.
enum AgentConnectionState: Equatable {
    case unknown
    case connected
    case degraded(String)
    case disconnected(String)
}

/// Events produced while an agent processes one turn. The chat pipeline maps
/// these onto its own stream: `.text` feeds the live reply bubble, `.step`
/// the status pill and the step journal, `.approvalRequested` an inline
/// card, `.usage` the spend ledger (tokens only — the gateway pays).
enum AgentTurnEvent {
    /// A chunk of assistant text. May arrive as many small deltas OR as one
    /// full-text event at the end — Hermes sends only `assistant.completed`
    /// when the agent's own streaming is off (see Hermes-API-Fixtures.md).
    case text(String)
    /// The definitive full text of the reply. Replaces whatever deltas
    /// accumulated (they are a prefix of it on well-behaved gateways; the
    /// authoritative copy wins either way).
    case finalText(String)
    case step(AgentStep)
    case approvalRequested(AgentApproval)
    case usage(TokenUsage)
}

/// One conversation with an agent, bound to a gateway-side session. The
/// implementation owns the transport (HTTP+SSE for Hermes, WS for OpenClaw
/// later) and the session-continuity bookkeeping.
///
/// `send` returns a per-turn stream — same shape the chat pipeline already
/// consumes from `ChatService.streamReply` — rather than one long-lived
/// event stream: HTTP transports have no standing connection, and turn
/// boundaries are what the UI actually keys on. Cross-turn state (connection
/// health) is published by the addon, not threaded through here.
@MainActor
protocol AgentSession: AnyObject {
    /// Sends one user turn. Only the NEW turn goes over the wire — the agent
    /// holds the conversation context on its side; re-sending local history
    /// would double both context and cost (AGENT-ADDONS-NOTES.md §6.1).
    func send(text: String, attachments: [ChatAttachment]) -> AsyncThrowingStream<AgentTurnEvent, Error>

    /// Stops the in-flight turn on the gateway (best effort).
    func abort() async

    /// Answers a pending approval request.
    func resolveApproval(id: String, decision: AgentApprovalDecision) async throws
}
