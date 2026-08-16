import Foundation

/// The agent-turn counterpart of `ChatService.streamReply`: sends ONE user
/// turn to the active agent role and maps `AgentTurnEvent`s onto the same
/// `ChatService.ChatEvent` stream the chat window already consumes — the
/// window's streaming loop stays a single code path.
///
/// What deliberately does NOT happen here (AGENT-ADDONS-NOTES.md §5, §6.1):
/// no history is sent (the agent holds the context), no system prompt, no
/// presets, no local tools, no reasoning knob, no summary compression.
@MainActor
enum AgentChatService {

    static func streamReply(
        role: AgentRole,
        conversation: ChatStore.ConversationID,
        history: [ChatMessage],
        store: ChatStore
    ) -> AsyncThrowingStream<ChatService.ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                // Only the NEW turn goes over the wire.
                guard let userMessage = history.last(where: { $0.isUser }) else {
                    continuation.finish()
                    return
                }
                // Bound to the ORIGIN conversation: switching sessions mid
                // stream must deliver the reply into its home thread, never
                // the one on screen (stream isolation, as native chats).
                let conversationKey = conversation.storageKey
                let session = HermesAddon.shared.agentSession(for: role, conversationKey: conversationKey)
                let journal = AgentStepJournal()
                // One agent run can produce SEVERAL assistant messages
                // (Hermes interim messages: "let me check…" → tools → the
                // real answer). They all land in ONE bubble, joined by blank
                // lines: `completedText` holds the finished messages,
                // `currentText` the one still streaming.
                var completedText = ""
                var currentText = ""
                var displayedText: String {
                    if completedText.isEmpty { return currentText }
                    return currentText.isEmpty ? completedText : completedText + "\n\n" + currentText
                }
                var sawFinalText = false

                do {
                    continuation.yield(.status(AGL("agent.status.thinking")))
                    // The background poll must not misread our own turn as
                    // outside activity, and the mirror sync must keep its
                    // hands off this conversation until the turn delivers
                    // (registered per conversation — parallel session turns
                    // each hold their own key). Baseline re-seeded once done.
                    HermesAddon.shared.beginStreaming(conversationKey: conversationKey)
                    defer {
                        HermesAddon.shared.endStreaming(conversationKey: conversationKey)
                        Task { await HermesAddon.shared.reseedPollBaseline() }
                    }
                    let events = session.send(text: userMessage.text, attachments: userMessage.attachments)
                    for try await event in events {
                        switch event {
                        case .text(let chunk):
                            // First delta of a follow-up message: visually
                            // separate it from the finished text before it.
                            if currentText.isEmpty, !completedText.isEmpty {
                                continuation.yield(.text("\n\n"))
                            }
                            currentText += chunk
                            continuation.yield(.text(chunk))
                        case .finalText(let full):
                            sawFinalText = true
                            // The authoritative copy of the CURRENT message —
                            // deltas differ from it in whitespace (fixtures),
                            // and with the agent's streaming off it is the
                            // only text event. Replaces the bubble with all
                            // finished messages joined.
                            let trimmedFull = full.trimmingCharacters(in: .whitespacesAndNewlines)
                            let before = displayedText
                            if !trimmedFull.isEmpty {
                                completedText = completedText.isEmpty
                                    ? trimmedFull
                                    : completedText + "\n\n" + trimmedFull
                            } else if !currentText.isEmpty {
                                // Empty completed frame after real deltas —
                                // keep what streamed.
                                completedText = completedText.isEmpty
                                    ? currentText
                                    : completedText + "\n\n" + currentText
                            }
                            currentText = ""
                            if completedText.trimmingCharacters(in: .whitespacesAndNewlines)
                                != before.trimmingCharacters(in: .whitespacesAndNewlines) {
                                continuation.yield(.replaceText(completedText))
                            }
                        case .step(let step):
                            journal.record(step)
                            // The list as it stands — the pill renders the
                            // steps while the turn runs, instead of only the
                            // newest one flickering through the status line.
                            continuation.yield(.agentStepsLive(journal.steps))
                            if step.status == .running {
                                continuation.yield(.status(String(format: AGL("agent.status.tool"), step.toolName)))
                            } else {
                                continuation.yield(.status(AGL("agent.status.thinking")))
                            }
                        case .approvalRequested(let approval):
                            // Inline card in the chat + a time-sensitive
                            // banner when the panel is elsewhere. Dormant on
                            // Hermes 0.19.0 (no mid-run approval frames yet).
                            NotificationService.shared.postApprovalRequest(
                                approval, roleID: role.id, roleName: role.displayName,
                                conversationKey: conversationKey
                            )
                            let resolvingSession = session
                            continuation.yield(.agentApproval(approval) { decision in
                                NotificationService.shared.revokeApproval(id: approval.id)
                                Task {
                                    try? await resolvingSession.resolveApproval(id: approval.id, decision: decision)
                                }
                            })
                        case .usage:
                            // NOT recorded into the spend ledger: the gateway
                            // pays for its own model calls (subscription), and
                            // its usage frames are run-cumulative — every
                            // tool-loop call re-counts the whole prompt, which
                            // drowned the Ø-tokens-per-message stat (a single
                            // agent turn read as ~1M input tokens). The context
                            // gauge gets its number in HermesAgentSession.
                            break
                        }
                    }

                    // Recordings the agent named by id (its host carries the
                    // Plaud plugin): resolved here with OUR grant into the
                    // usual chips, so the reply keeps the words and the card
                    // keeps every tab, the timecoded transcript and the audio.
                    // The markers leave the text — they are addressing, not
                    // prose (AgentPlaudNote).
                    let (plaudDisplay, plaudRefs) = AgentPlaudNote.split(completedText)
                    if !plaudRefs.isEmpty {
                        // Chips FIRST, text after: a marker is only noise once
                        // it became a card. Stripping it up front — as this did
                        // — left an empty bubble whenever the lookup failed
                        // (Plaud disconnected, addon off), and a reply that is
                        // nothing but a marker then vanished entirely.
                        let chips = await PlaudAgentChips.attachments(for: plaudRefs)
                        if !chips.isEmpty {
                            Diagnostics.log("plaud", "agent.chips n=\(chips.count) refs=\(plaudRefs.count)")
                            continuation.yield(.attachments(chips))
                        }
                        if chips.count == plaudRefs.count, plaudDisplay != completedText {
                            completedText = plaudDisplay
                            continuation.yield(.replaceText(plaudDisplay))
                        }
                    }

                    if let summary = journal.summary() {
                        continuation.yield(.agentSteps(summary))
                    }
                    // Long-turn banner: suppressed automatically when the
                    // panel is open on this very conversation (§7.1).
                    NotificationService.shared.postTurnCompleted(
                        roleID: role.id, roleName: role.displayName,
                        preview: displayedText,
                        conversationKey: conversationKey
                    )
                    Diagnostics.log("agent", "turn.end role=\(role.id) chars=\(displayedText.count) steps=\(journal.steps.count) final=\(sawFinalText)")
                    // Counters/previews in the sidebar's session rows moved.
                    NotificationCenter.default.post(name: .hermesSessionsDidChange, object: nil)
                    continuation.finish()
                } catch {
                    // Best effort: tell the gateway to stop the run the user
                    // just walked away from (new chat, deleted preset, stop).
                    if Task.isCancelled {
                        let abortable = session
                        Task { await abortable.abort() }
                    }
                    Diagnostics.log("agent", "turn.error \(String(error.localizedDescription.prefix(200)))")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

}
