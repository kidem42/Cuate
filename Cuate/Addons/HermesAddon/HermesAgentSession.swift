import Foundation

/// `AgentSession` over the Hermes sessions API: binds a role's local
/// conversation to one gateway session (created + model-locked lazily on the
/// first send), streams turns over SSE, and keeps the current run id so
/// abort/approval can target it.
@MainActor
final class HermesAgentSession: AgentSession {
    private let addon: HermesAddon
    private let role: AgentRole
    /// The CONVERSATION this session serves — each gateway session is its
    /// own conversation now, so the binding key must come from the caller
    /// (the role's default thread when nil).
    private let conversationKey: String
    private let settings = HermesSettings.shared

    /// The run currently streaming — target for `abort()` and approvals.
    private var currentRunID: String?

    init(addon: HermesAddon, role: AgentRole, conversationKey: String? = nil) {
        self.addon = addon
        self.role = role
        self.conversationKey = conversationKey
            ?? role.conversationID(sessionID: HermesSettings.shared.activeSession(roleID: role.id)).storageKey
    }

    /// The bound gateway session id, if any (mirror sync reads it too).
    var boundSessionID: String? {
        settings.sessionID(forConversationKey: conversationKey)
    }

    /// Returns the bound gateway session, creating + model-locking one on
    /// first use. The lock is mandatory: a fresh Hermes session inherits the
    /// literal "hermes-agent" model and every turn 404s (fixtures).
    ///
    /// The title comes from the FIRST message (Hermes' own auto-titler
    /// skips API-created sessions — probed live 2026-07-26 — so a static
    /// name would make every our session look identical in the list).
    /// Excerpt of a first message used as a session title (shared by the
    /// create and the late-rename paths).
    static func titleExcerpt(_ text: String) -> String? {
        let excerpt = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !excerpt.isEmpty else { return nil }
        return String(excerpt.prefix(48)) + (excerpt.count > 48 ? "…" : "")
    }

    func ensureSession(firstText: String = "") async throws -> String {
        if let existing = boundSessionID {
            // A session created by a button carries the placeholder title —
            // the first real turn names it (Telegram/CLI-made ones aren't
            // marked, so their own titles are never overwritten).
            if let title = Self.titleExcerpt(firstText),
               settings.consumeAwaitingTitle(existing) {
                Task { [addon] in
                    try? await addon.transport().renameSession(id: existing, title: title)
                    await MainActor.run {
                        NotificationCenter.default.post(name: .hermesSessionsDidChange, object: nil)
                    }
                }
            }
            return existing
        }
        let transport = addon.transport()
        let title = Self.titleExcerpt(firstText) ?? "Cuate — \(role.displayName)"
        let info = try await transport.createSession(title: title)
        if Self.titleExcerpt(firstText) == nil {
            settings.markAwaitingTitle(info.id)
        }
        if let pair = await addon.resolveLockPair() {
            // Best effort: an old gateway without the lock endpoint should
            // not block chatting (the turn itself may still route fine).
            try? await transport.lockModel(sessionID: info.id, provider: pair.provider, model: pair.model)
            settings.recordModelLock(provider: pair.provider, model: pair.model, forSession: info.id)
        }
        settings.bindSession(info.id, toConversationKey: conversationKey)
        // The sidebar's sessions list must learn about the fresh session
        // right away, not on its next reopen (e2e 2026-07-26).
        NotificationCenter.default.post(name: .hermesSessionsDidChange, object: nil)
        return info.id
    }

    // MARK: - AgentSession

    func send(text: String, attachments: [ChatAttachment]) -> AsyncThrowingStream<AgentTurnEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let sessionID = try await ensureSession(firstText: text)
                    let transport = addon.transport()
                    // Images ride as OpenAI-style content parts (probed live;
                    // a flat "images" field is silently ignored by Hermes).
                    // Downscaled to the model ceiling like every provider path
                    // (a raw retina PNG is 10+ MB of base64 — it blew through
                    // reverse-proxy body limits as an opaque 413, and the
                    // gateway's model would downscale it server-side anyway).
                    let imageAttachments = attachments.filter { $0.mimeType.hasPrefix("image") }
                    let images = imageAttachments
                        .map { attachment -> (mimeType: String, base64: String) in
                            let wire = LLMImage.forModel(
                                mimeType: attachment.mimeType,
                                base64: attachment.contentBase64
                            )
                            return (wire.mimeType, wire.base64)
                        }
                        .filter { !$0.base64.isEmpty }

                    // The courier upload that makes these images visible on
                    // OTHER surfaces happens in the send path (ChatWindow),
                    // so its note is part of the local message too — doing it
                    // here left our bubble and the gateway's row different.
                    let input = HermesTransport.inputPayload(text: text, images: images)
                    // Reasoning effort from the composer control ("" = the
                    // agent's own default, nothing is sent).
                    let effort = self.settings.reasoningEffort
                    let modelOptions: [String: Any]? = effort.isEmpty
                        ? nil : ["reasoning_effort": effort]
                    var deltaCount = 0
                    var runningTool: (name: String, preview: String?, started: Date)?

                    for try await event in transport.chatStream(sessionID: sessionID, input: input,
                                                                modelOptions: modelOptions) {
                        switch event {
                        case .runStarted(let runID):
                            self.currentRunID = runID
                        case .messageStarted:
                            break
                        case .toolStarted(let tool, let preview):
                            guard tool != "_thinking" else { break }
                            let step = AgentStep(
                                id: "\(self.currentRunID ?? "run")-\(tool)-\(Date().timeIntervalSince1970)",
                                toolName: tool, preview: preview,
                                status: .running, startedAt: Date(), finishedAt: nil
                            )
                            runningTool = (tool, preview, step.startedAt)
                            continuation.yield(.step(step))
                        case .toolProgress:
                            // "_thinking" reasoning stream and tool progress
                            // noise — not rendered (journal keeps summaries).
                            break
                        case .toolCompleted(let tool):
                            guard tool != "_thinking" else { break }
                            let started = runningTool?.name == tool ? runningTool!.started : Date()
                            let step = AgentStep(
                                id: "\(self.currentRunID ?? "run")-\(tool)-done-\(Date().timeIntervalSince1970)",
                                toolName: tool, preview: runningTool?.preview,
                                status: .completed, startedAt: started, finishedAt: Date()
                            )
                            runningTool = nil
                            continuation.yield(.step(step))
                        case .assistantDelta(let delta):
                            deltaCount += 1
                            continuation.yield(.text(delta))
                        case .assistantCompleted(let content, _):
                            // Authoritative full text — with the agent's own
                            // streaming off, this is the ONLY text event.
                            continuation.yield(.finalText(content))
                        case .runCompleted(let usage):
                            if !usage.isEmpty {
                                continuation.yield(.usage(usage))
                                // Context fill of THIS session: the prompt the
                                // gateway just sent plus what it generated is
                                // what the next turn's prompt starts from.
                                // Cached reads count — they are context too.
                                self.settings.recordContextTokens(
                                    usage.inputTokens + usage.cacheReadTokens + usage.outputTokens,
                                    forSession: sessionID
                                )
                            }
                        case .done:
                            break
                        case .unknown(let name, let payload):
                            // `approval_events` is advertised by capabilities
                            // but 0.19.0 emits no such frames (probed live) —
                            // this best-effort mapping arms the UI for the
                            // Hermes version that starts sending them.
                            if name.localizedCaseInsensitiveContains("approval"),
                               let approvalID = (payload["approval_id"] ?? payload["id"]) as? String {
                                let subject = (payload["command"] ?? payload["preview"] ?? payload["gist"] ?? payload["subject"]) as? String
                                let approval = AgentApproval(
                                    id: approvalID,
                                    subject: subject ?? name,
                                    toolName: payload["tool_name"] as? String,
                                    hostDescription: self.settings.baseURL.host,
                                    supportsAlways: false
                                )
                                continuation.yield(.approvalRequested(approval))
                            }
                            Diagnostics.log("hermes", "sse.unknown \(name) keys=\(payload.keys.sorted().joined(separator: ","))")
                        }
                    }
                    self.currentRunID = nil
                    continuation.finish()
                } catch {
                    self.currentRunID = nil
                    let diagnostic = AgentDiagnostic(
                        message: error.localizedDescription,
                        probeStatus: (error as? HermesTransportError)?.probeStatus
                            ?? GatewayProbe.status(forTransportError: error)
                    )
                    continuation.finish(throwing: diagnostic)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func abort() async {
        guard let runID = currentRunID else { return }
        try? await addon.transport().stopRun(runID: runID)
    }

    func resolveApproval(id: String, decision: AgentApprovalDecision) async throws {
        guard let runID = currentRunID else { return }
        try await addon.transport().resolveApproval(
            runID: runID, approvalID: id,
            approve: decision != .deny
        )
    }
}
