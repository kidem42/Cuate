import Foundation
import Combine
import AppKit

/// HermesAddon — connects a self-hosted Hermes Agent (Nous Research) as an
/// isolated role in the prompt switcher. The agent is a black box with its
/// own prompt, tools, memory and model keys; we are one more surface of the
/// same agent the user already talks to elsewhere (AGENT-ADDONS-NOTES.md).
///
/// Mount points (pattern: `CalendarAddon`): master switch + settings tab in
/// `SettingsView`, roles in the chat header switcher, the agent-turn branch
/// in the chat pipeline, and the management sidebar.
@MainActor
final class HermesAddon: ObservableObject {
    static let shared = HermesAddon()

    static let addonID = "hermes"

    private let settings = HermesSettings.shared

    /// Connection state for the role chip; refreshed by `probe()`.
    @Published private(set) var connectionState: AgentConnectionState = .unknown
    /// Gateway capabilities from the last successful probe — gates UI
    /// sections (sessions, skills, approvals). nil until first contact.
    @Published private(set) var capabilities: HermesCapabilities?
    /// Skills from the last successful probe — shared by the sidebar list
    /// and the composer's slash autocomplete (the agent itself interprets
    /// "/skill-name …" in plain message text — probed live, fixtures).
    @Published private(set) var cachedSkills: [HermesSkill] = []
    /// Provider/model catalog + the agent's current pair (composer picker).
    @Published private(set) var cachedProviders: [HermesProviderOption] = []
    @Published private(set) var currentModelPair: (provider: String, model: String)?

    /// Conversations OUR chat pipeline is streaming a turn into right now
    /// (several Hermes sessions can run at once). Two consumers:
    /// - the background poll must not misreport our own replies as outside
    ///   activity (and one turn ending must not unmute it while another
    ///   still runs);
    /// - the mirror sync must not touch a conversation mid-turn. Its old
    ///   guard was `store.isLoading`, which a session switch wipes — a
    ///   catch-up then ran DURING the run and inserted the gateway's rows
    ///   for the in-flight reply as duplicate bubbles (app.log 2026-07-29
    ///   12:40: catchUp between turn start and turn.end).
    /// `@Published` so the sidebar's session rows can show a live "agent is
    /// working here" wave: it changes once per turn start/end — a cheap
    /// invalidation, nothing per-chunk rides on it.
    @Published private var activeTurnKeys: [String: Int] = [:]
    var streamActive: Bool { !activeTurnKeys.isEmpty }
    func beginStreaming(conversationKey: String) {
        activeTurnKeys[conversationKey, default: 0] += 1
    }
    func endStreaming(conversationKey: String) {
        guard let count = activeTurnKeys[conversationKey] else { return }
        if count <= 1 {
            activeTurnKeys.removeValue(forKey: conversationKey)
            // Our own finished turn must not resurface as a GATEWAY-side one:
            // a poll that landed mid-run left a live-turn record behind, and
            // the pill would flash back the moment our slot retires.
            if let sessionID = settings.sessionID(forConversationKey: conversationKey) {
                liveTurns.removeValue(forKey: sessionID)
            }
        } else {
            activeTurnKeys[conversationKey] = count - 1
        }
    }

    /// Run id of the turn OUR pipeline is streaming into a conversation.
    /// `HermesAgentSession` is created per turn (the factory hands out a
    /// fresh instance), so its own `currentRunID` is invisible to the
    /// window — the composer needs it here to address the upstream
    /// `POST /v1/runs/{id}/steer`. Not `@Published`: it changes inside a
    /// turn whose start/end already invalidate through `activeTurnKeys`.
    private var runIDsByConversation: [String: String] = [:]
    func noteRun(_ runID: String, conversationKey: String) {
        runIDsByConversation[conversationKey] = runID
    }
    func clearRun(conversationKey: String) {
        runIDsByConversation.removeValue(forKey: conversationKey)
    }
    func activeRunID(conversationKey: String) -> String? {
        runIDsByConversation[conversationKey]
    }
    func isTurnActive(forConversationKey key: String) -> Bool {
        activeTurnKeys[key] != nil
    }

    // Approvals use the existing run-status and session polling paths. No
    // transcript rows or consent decisions are persisted as authority.
    @Published private(set) var approvalLedgers: [String: HermesApprovalLedger] = [:]
    @Published private(set) var approvalUnavailable: Set<String> = []
    private var approvalReads: Set<String> = []
    private var approvalTerminalRuns: [String: String] = [:]

    func refreshApprovals(sessionID: String, manual: Bool = false) async {
        guard let runID = settings.activeRun(forSession: sessionID),
              approvalReads.insert(sessionID).inserted else { return }
        defer { approvalReads.remove(sessionID) }
        let endpoint = settings.endpointURL
        let revision = approvalLedgers[sessionID]?.revision ?? 0
        let probe = await transport().runProbe(runID: runID)
        guard endpoint == settings.endpointURL,
              settings.activeRun(forSession: sessionID) == runID,
              (approvalLedgers[sessionID]?.revision ?? 0) == revision else { return }
        switch probe {
        case .known(let state):
            if state.isTerminal { approvalTerminalRuns[sessionID] = runID }
            else { approvalTerminalRuns.removeValue(forKey: sessionID) }
            var ledger = approvalLedgers[sessionID] ?? HermesApprovalLedger()
            let requests = state.status == "waiting_for_approval" ? state.approvals.compactMap {
                HermesApproval.parse($0, endpoint: endpoint, sessionID: sessionID, runID: runID)
            } : []
            ledger.reconcile(requests)
            if manual { ledger.allowManualRetry() }
            approvalLedgers[sessionID] = ledger
            if state.status == "waiting_for_approval" && requests.isEmpty {
                approvalUnavailable.insert(sessionID)
            } else { approvalUnavailable.remove(sessionID) }
            if state.isTerminal && state.pendingSteer == nil {
                settings.setActiveRun(nil, forSession: sessionID)
                markTailDead(sessionID: sessionID)
            }
        case .gone:
            settings.setActiveRun(nil, forSession: sessionID)
            markTailDead(sessionID: sessionID)
            approvalLedgers.removeValue(forKey: sessionID)
            approvalUnavailable.remove(sessionID)
        case .unreachable:
            // Keep the run and cards. Submission always performs a fresh read.
            approvalUnavailable.insert(sessionID)
        }
    }

    func resolveApproval(_ request: HermesApproval, approve: Bool) async {
        guard request.endpoint == settings.endpointURL,
              settings.activeRun(forSession: request.sessionID) == request.runID,
              stopTasks[request.runID] == nil,
              var ledger = approvalLedgers[request.sessionID], ledger.begin(request) else { return }
        approvalLedgers[request.sessionID] = ledger
        let client = transport()
        var accepted = false
        // A stale card must never address the next request or a different run.
        if case .known(let state) = await client.runProbe(runID: request.runID),
           state.status == "waiting_for_approval",
           state.approvals.contains(where: {
               HermesApproval.parse($0, endpoint: request.endpoint, sessionID: request.sessionID,
                                    runID: request.runID) == request
           }), request.endpoint == settings.endpointURL,
           settings.activeRun(forSession: request.sessionID) == request.runID,
           stopTasks[request.runID] == nil {
            do {
                try await client.resolveApproval(runID: request.runID, approvalID: request.requestID, approve: approve)
                accepted = true
            } catch {
                // The POST may have reached Hermes. Never resend automatically.
                Diagnostics.log("hermes", "approval.unconfirmed")
            }
        }
        guard request.endpoint == settings.endpointURL else { return }
        approvalLedgers[request.sessionID]?.finish(request, accepted: accepted)
        await refreshApprovals(sessionID: request.sessionID)
    }

    // MARK: - Stopping a run

    /// What a stop request came to, as the chat reports it.
    enum StopOutcome: Equatable {
        /// `GET /v1/runs/{id}` read a terminal status after the stop.
        case stopped(status: String)
        /// The gateway no longer knows the run: it had ended already, or a
        /// restart swept it. Either way nothing is running.
        case gone
        /// The stop was accepted but the run was still winding down when
        /// the confirmation window closed — the agent may still be working
        /// (a long tool call returns first; the live-turn detector keeps
        /// watching the transcript).
        case unconfirmed
        /// The stop request itself failed (transport, auth, 5xx).
        case failed(String)
    }

    /// How long a stop waits for the run to read finished. A hard interrupt
    /// lands at the agent's next loop check — milliseconds between tool
    /// calls — but a tool already running has to return first, and the
    /// gateway reaps that tool's background processes on the way out.
    static let stopConfirmWindow: TimeInterval = 20

    /// In-flight stop requests by run id. Two callers ask for the same run
    /// — the window's Stop button, and the session's own cancellation path
    /// that fires for Stop, new chat and a deleted role alike — and both
    /// await ONE request instead of racing two.
    private var stopTasks: [String: Task<StopOutcome, Never>] = [:]

    /// Stops a run on the gateway and waits for the gateway to confirm.
    ///
    /// Until the detached-runs patch, closing our stream interrupted the
    /// run as a side effect (stock Hermes: `agent.interrupt("SSE client
    /// disconnected")`), which is what Stop silently relied on — the
    /// explicit `POST /v1/runs/{id}/stop` sat in a `catch` the cancellation
    /// path never reached (an `AsyncThrowingStream` ends with nil when its
    /// consumer is cancelled, it does not throw). Patched gateways keep the
    /// run going, so "Stopped." was a lie and the agent worked on for
    /// minutes (2026-09-07 14:49). This request is the only stop there is
    /// now; the confirmation comes from `GET /v1/runs/{id}`.
    func requestStop(runID: String, sessionID: String?) async -> StopOutcome {
        if let running = stopTasks[runID] { return await running.value }
        let task = Task<StopOutcome, Never> { @MainActor [weak self] in
            guard let self else { return .failed("addon released") }
            return await self.performStop(runID: runID, sessionID: sessionID)
        }
        stopTasks[runID] = task
        let outcome = await task.value
        stopTasks.removeValue(forKey: runID)
        return outcome
    }

    private func performStop(runID: String, sessionID: String?) async -> StopOutcome {
        let transport = transport()
        Diagnostics.log("hermes", "stop.request run=\(runID)")
        let reply: HermesTransport.RunStopReply
        do {
            reply = try await transport.stopRun(runID: runID)
        } catch {
            Diagnostics.log("hermes", "stop.failed run=\(runID) \(String(error.localizedDescription.prefix(120)))")
            return .failed(error.localizedDescription)
        }
        var outcome: StopOutcome = .unconfirmed
        if reply == .notFound {
            outcome = .gone
        } else {
            let deadline = Date().addingTimeInterval(Self.stopConfirmWindow)
            var polls = 0
            confirm: while Date() < deadline {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                polls += 1
                switch await transport.runProbe(runID: runID) {
                case .known(let state):
                    if state.isTerminal {
                        outcome = .stopped(status: state.status)
                        break confirm
                    }
                case .gone:
                    outcome = .gone
                    break confirm
                case .unreachable:
                    // The stop was accepted; a flaky probe is no reason to
                    // give up before the window closes.
                    continue
                }
            }
            Diagnostics.log("hermes", "stop.confirm run=\(runID) polls=\(polls)")
        }
        switch outcome {
        case .stopped, .gone:
            // The interrupted turn's transcript tail may end on a tool call
            // with no result row — retire the pill now, as the orphan path
            // does, instead of waiting out the staleness window. The run is
            // over for sure: the persisted id has nothing left to point at.
            if let sessionID {
                markTailDead(sessionID: sessionID)
                if settings.activeRun(forSession: sessionID) == runID {
                    settings.setActiveRun(nil, forSession: sessionID)
                }
            }
        case .unconfirmed, .failed:
            // Kept on purpose: a relaunch can still stop it.
            break
        }
        Diagnostics.log("hermes", "stop.outcome run=\(runID) \(outcome.logLabel)")
        return outcome
    }

    // MARK: - One session, one conversation

    /// A gateway session lives in ONE local conversation. A session started
    /// from a role's default thread is bound to that thread's key; the
    /// sessions list used to open the very same session AS ITS OWN
    /// conversation on top of that (`role.conversationID(sessionID:)`),
    /// mirroring the transcript into a twin — every row rebuilt from the
    /// gateway, which keeps no pixels and no audio, so a screenshot sent
    /// from the default thread "vanished" the moment the user picked the
    /// session in the sidebar (report 2026-09-07 14:49). The window now
    /// opens the default thread for such a session (`continueHermesSession`)
    /// and resolves a stale "active session" the same way; this folds the
    /// twins older builds left behind into the default thread — rows keyed
    /// by `externalID`, the copy holding media wins, pins carried over —
    /// and drops the twin. Cheap when there is nothing to do, so it runs at
    /// every launch (a settings import can bring a twin back).
    func mergeTwinConversations() {
        for role in roles {
            let defaultKey = role.conversationID().storageKey
            guard let sessionID = settings.sessionID(forConversationKey: defaultKey) else { continue }
            let twinKey = role.conversationID(sessionID: sessionID).storageKey
            // Settings are rewritten synchronously here, the store merge is
            // enqueued — so the store step must not depend on the settings
            // still showing the twin: a launch that died between the two
            // would otherwise leave the twin's rows orphaned with nothing
            // pointing at them. The persistence merge is a no-op when no
            // such conversation exists, which makes every launch after the
            // first one free.
            if settings.sessionID(forConversationKey: twinKey) == sessionID {
                settings.unbindSession(forConversationKey: twinKey)
                settings.mergePins(fromConversationKey: twinKey, intoConversationKey: defaultKey)
                Diagnostics.log("hermes", "twin.merge session=\(sessionID)")
            }
            if settings.activeSession(roleID: role.id) == sessionID {
                settings.setActiveSession(nil, roleID: role.id)
            }
            ChatPersistence.mergeConversation(key: twinKey, intoKey: defaultKey)
        }
    }

    /// sessionID → a turn running ON THE GATEWAY (started elsewhere, or by
    /// us before a restart). Rebuilt from the transcripts the mirror and the
    /// poll already fetch, so nothing extra goes over the wire. This is what
    /// puts the progress pill back after a relaunch — our own slots die with
    /// the process, the gateway's run does not.
    @Published private(set) var liveTurns: [String: HermesLiveTurn] = [:]
    @Published private(set) var continuationRequests: [String: HermesContinuationRequest] = [:]
    @Published private(set) var backgroundWork: [String: [HermesBackgroundWork]] = [:]

    func awaitsBackgroundResult(conversationKey: String) -> Bool {
        guard let sid = settings.sessionID(forConversationKey: conversationKey) else { return false }
        return !(backgroundWork[sid] ?? []).isEmpty || continuationRequests[sid] != nil
    }

    /// Read the completed parent's transcript before declaring its task done.
    /// The async dispatch is a tool result, absent from its short final text.
    func refreshBackgroundWork(conversationKey: String) async {
        let endpoint = settings.endpointURL
        guard let sid = settings.sessionID(forConversationKey: conversationKey),
              let rows = try? await transport().messages(sessionID: sid),
              !Task.isCancelled, endpoint == settings.endpointURL,
              settings.sessionID(forConversationKey: conversationKey) == sid else { return }
        noteLiveTurn(HermesLiveTurnDetector.detect(rows: rows), rows: rows, sessionID: sid)
        lastSeenCounts[sid] = rows.count
    }

    private var continuationChecks: Set<String> = []

    func dismissContinuation(_ request: HermesContinuationRequest) {
        settings.continuationConsent.handle(request)
        Diagnostics.log("hermes", "continuation.claim session=\(request.sessionID) rows=\(request.rowIDs.count)")
        NotificationService.shared.revokeContinuation(sessionID: request.sessionID)
        if continuationRequests[request.sessionID] == request {
            continuationRequests.removeValue(forKey: request.sessionID)
        }
    }

    /// Re-read before sending: another client may already have continued.
    /// A reservation coalesces clicks/polls while that read is in flight.
    func validateContinuation(_ request: HermesContinuationRequest) async -> Bool {
        guard request.endpoint == settings.endpointURL, settings.enabled,
              settings.continuationConsent.needsDecision(request),
              continuationChecks.insert(request.id).inserted else { return false }
        defer { continuationChecks.remove(request.id) }
        let keys = settings.sessionMap.filter { $0.value == request.sessionID }.map(\.key)
        guard !keys.contains(where: { isTurnActive(forConversationKey: $0) }) else { return false }
        let client = transport()
        if let runID = settings.activeRun(forSession: request.sessionID) {
            switch await client.runProbe(runID: runID) {
            case .known(let state):
                guard ["completed", "failed", "cancelled", "canceled"].contains(state.status),
                      state.pendingSteer == nil else { return false }
            case .gone: break
            case .unreachable: return false
            }
        }
        guard let rows = try? await client.messages(sessionID: request.sessionID),
              request.endpoint == settings.endpointURL else { return false }
        noteLiveTurn(HermesLiveTurnDetector.detect(rows: rows), rows: rows, sessionID: request.sessionID)
        return continuationRequests[request.sessionID] == request
            && settings.continuationConsent.needsDecision(request)
            && !keys.contains(where: { isTurnActive(forConversationKey: $0) })
    }


    /// Publishes (or retires) the turn detected in a freshly fetched
    /// transcript. Equality-gated: an unchanged turn must not invalidate the
    /// transcript row on every 20-second poll.
    /// How long a growth-detected turn survives WITHOUT new rows. The agent
    /// writes in bursts (a long exec flushes only on completion — observed
    /// gaps of several minutes between rows of one working stretch), so the
    /// first quiet poll must not retire the pill: that made it live exactly
    /// 16 seconds (app.log 2026-08-10 16:39:42→16:39:58). The cost is the
    /// reverse error: after the agent's LAST monologue message the pill
    /// overstays by up to this long.
    private static let growthHold: TimeInterval = 5 * 60

    func noteLiveTurn(_ detected: HermesLiveTurn?, rows: [HermesTranscriptMessage], sessionID: String) {
        let work = HermesBackgroundWork.detect(rows: rows)
        if (backgroundWork[sessionID] ?? []) != work {
            backgroundWork[sessionID] = work.isEmpty ? nil : work
            Diagnostics.log("hermes", "background.pending session=\(sessionID) groups=\(work.count) children=\(work.reduce(0) { $0 + $1.count })")
        }
        let request = HermesContinuationRequest.detect(rows: rows, endpoint: settings.endpointURL,
                                                        sessionID: sessionID)
        let pending = request.flatMap { settings.continuationConsent.needsDecision($0) ? $0 : nil }
        if continuationRequests[sessionID] != pending {
            continuationRequests[sessionID] = pending
            Diagnostics.log("hermes", "continuation.pending session=\(sessionID) rows=\(pending?.rowIDs.count ?? 0)")
            if let pending, !settings.continuationConsent.allowsAutomatically(pending),
               let role = roles.first,
               let key = settings.sessionMap.first(where: { $0.value == sessionID })?.key {
                NotificationService.shared.postContinuationRequest(roleID: role.id, roleName: role.displayName,
                    sessionID: sessionID, conversationKey: key)
            } else if pending == nil {
                NotificationService.shared.revokeContinuation(sessionID: sessionID)
            }
        }
        // A delivery is waiting for consent, not running. Keep it out of
        // Stop/steer and held-send recovery even if it is old or dismissed.
        if request != nil {
            settings.setLiveTurnRowCount(rows.count, forSession: sessionID)
            apply(nil, sessionID: sessionID)
            return
        }
        let previous = settings.liveTurnRowCount(forSession: sessionID)
        settings.setLiveTurnRowCount(rows.count, forSession: sessionID)

        // Unfinished tail — the strongest evidence, stands on its own.
        if let detected {
            apply(detected, sessionID: sessionID)
            return
        }
        // Tail reads finished. New rows since the last look tell which kind
        // of finish it was:
        // - the segment contains a REAL user message → an exchange — a
        //   question got its answer, the turn is over;
        // - pure assistant/tool rows → a monologue — Hermes narrates interim
        //   progress mid-run ("prepared 14 of 36…") and keeps working.
        //   That interim reply is indistinguishable from a final one by
        //   shape, but nobody asked for it — which is the tell.
        if let previous, rows.count > previous {
            let segment = rows.suffix(rows.count - previous)
            let isExchange = segment.contains {
                $0.role == "user" && HermesCompaction.visibleUserText($0.content) != nil
            }
            apply(isExchange ? nil : HermesLiveTurn(steps: [], lastRowAt: Date(), source: .growth),
                  sessionID: sessionID)
            return
        }
        // No growth: a monologue-detected turn coasts through the hold
        // (bursty writes), then retires. Anything else is plain idle.
        if let turn = liveTurns[sessionID], turn.source == .growth,
           Date().timeIntervalSince(turn.lastRowAt) < Self.growthHold {
            return
        }
        apply(nil, sessionID: sessionID)
    }

    /// Called when the count gate proved the transcript did NOT grow (no
    /// rows were fetched). Apply staleness here too, so the count gate
    /// cannot leave an expired waiting/work indicator published indefinitely.
    func noteNoGrowth(sessionID: String) {
        guard let turn = liveTurns[sessionID] else { return }
        let limit = turn.source == .growth ? Self.growthHold : HermesLiveTurnDetector.staleAfter
        guard Date().timeIntervalSince(turn.lastRowAt) >= limit else { return }
        apply(nil, sessionID: sessionID)
    }

    /// Sessions whose unfinished tail the GATEWAY has disowned: we streamed a
    /// run, it died mid-tool (a restart, a crash, an agent that killed the
    /// gateway it was running in), and `GET /v1/runs/{id}` confirmed it is
    /// gone. Without this the tail — a tool call with no result row — reads
    /// as "still working" for the full 20-minute staleness window, and the
    /// chat looks frozen with nothing to press.
    ///
    /// The mark covers rows no newer than itself, so the next real turn
    /// lifts it by simply being newer — no cleanup pass needed.
    private var deadTailMarks: [String: Date] = [:]

    /// Confirmed dead: retire the pill now instead of waiting out staleness.
    func markTailDead(sessionID: String) {
        deadTailMarks[sessionID] = Date()
        apply(nil, sessionID: sessionID)
        Diagnostics.log("hermes", "liveTurn session=\(sessionID) retired=run-gone")
    }

    private func apply(_ turnIn: HermesLiveTurn?, sessionID: String) {
        var turn = turnIn
        if let mark = deadTailMarks[sessionID] {
            if let candidate = turn, candidate.lastRowAt <= mark {
                turn = nil                       // the tail we already buried
            } else if turn != nil {
                deadTailMarks.removeValue(forKey: sessionID)  // a newer turn — mark spent
            }
        }
        // Logged on every EDGE (idle↔running), never per poll: "the pill did
        // not come back" is otherwise indistinguishable from "the gateway
        // was idle by then" — both look like silence.
        let wasActive = liveTurns[sessionID] != nil
        if wasActive != (turn != nil) {
            let steps = turn.map { "\($0.steps.count)" } ?? "-"
            let via = turn.map { "\($0.source)" } ?? "-"
            let age = turn.map { Int(Date().timeIntervalSince($0.lastRowAt)) } ?? 0
            Diagnostics.log("hermes", "liveTurn session=\(sessionID) active=\(turn != nil) via=\(via) steps=\(steps) tailAge=\(age)s")
        }
        if let turn {
            if liveTurns[sessionID] != turn { liveTurns[sessionID] = turn }
        } else if liveTurns[sessionID] != nil {
            liveTurns.removeValue(forKey: sessionID)
        }
    }

    /// The running turn of a conversation, once staleness is applied — a run
    /// that died mid-tool leaves an unfinished tail behind forever, and the
    /// pill must not outlive it.
    func liveTurn(forConversationKey key: String) -> HermesLiveTurn? {
        guard let sessionID = settings.sessionID(forConversationKey: key) else { return nil }
        return liveTurn(sessionID: sessionID)
    }

    func liveTurn(sessionID: String) -> HermesLiveTurn? {
        // A known run remains busy until an authoritative terminal result.
        // Transcript silence, including a long human approval wait, is not completion.
        if let runID = settings.activeRun(forSession: sessionID) {
            if approvalTerminalRuns[sessionID] == runID { return nil }
            return HermesLiveTurn(steps: liveTurns[sessionID]?.steps ?? [], lastRowAt: Date())
        }
        guard let turn = liveTurns[sessionID],
              Date().timeIntervalSince(turn.lastRowAt) < HermesLiveTurnDetector.staleAfter,
              deadTailMarks[sessionID].map({ turn.lastRowAt > $0 }) ?? true
        else { return nil }
        return turn
    }

    /// Background gateway poll (§7.1: notifications must also cover runs we
    /// did NOT start — Hermes has no push channel, so we ask periodically).
    private var pollTask: Task<Void, Never>?
    /// sessionID → message_count at the last look (baseline seeded silently).
    private var lastSeenCounts: [String: Int] = [:]
    private var lastPollEndpoint: String?

    /// sessionID → unread VISIBLE messages (sidebar badge). The gateway's
    /// message_count includes tool rows — see `unreadCount(for:)`.
    @Published private(set) var unreadBadges: [String: Int] = [:]
    /// sessionID → the message_count each badge was computed at (stale →
    /// the transcript tail is refetched); plus in-flight fetch dedup.
    private var badgeComputedAt: [String: Int] = [:]
    private var badgeFetchesInFlight: Set<String> = []

    private init() {
        // A Mac waking from sleep still wears last night's connection state
        // (green chip, no banner) while the network is only coming up — the
        // first sidebar action then fails with zero explanation (2026-08-03:
        // "new session" looked like a dead button). Re-probe shortly after
        // wake so the chip/banner turn honest within seconds; the 30s
        // background poll keeps self-healing until the gateway answers.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                let addon = HermesAddon.shared
                guard addon.isAvailable else { return }
                // Interfaces need a beat — probing at t=0 fails every time.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await addon.probe()
            }
        }
    }

    // MARK: - Availability

    /// The addon is usable when switched on and a token is stored. Actual
    /// liveness is the role chip's job (probe) — a temporarily unreachable
    /// gateway must not eject the role from the switcher.
    var isAvailable: Bool {
        settings.enabled && APIKeyStore.hasKey(aux: .hermes)
    }

    // MARK: - Roles

    /// Roles offered in the prompt switcher: one per gateway model/profile
    /// (from the cached `/v1/models` list, usually a single "hermes-agent").
    /// Gated on the master switch ALONE — a missing key must not hide the
    /// role (the user flips the toggle, sees nothing, and is lost; e2e
    /// 2026-07-25). A keyless send answers with a pointer to the settings.
    /// Before the first successful probe the default pseudo-model stands in.
    var roles: [AgentRole] {
        guard settings.enabled else { return [] }
        let ids = settings.cachedAgentIDs.isEmpty ? ["hermes-agent"] : settings.cachedAgentIDs
        return ids.map { agentID in
            AgentRole(
                id: AgentRole.makeID(addonID: Self.addonID, agentID: agentID),
                addonID: Self.addonID,
                agentID: agentID,
                displayName: roleDisplayName(for: agentID),
                icon: "🤖"
            )
        }
    }

    private func roleDisplayName(for agentID: String) -> String {
        // The default pseudo-model reads better as plain "Hermes"; real
        // profile names pass through as-is.
        agentID == "hermes-agent" ? "Hermes" : agentID
    }

    // MARK: - Transport

    /// A transport bound to the current endpoint + token. Value type — cheap
    /// to make per call site, always up to date with the settings.
    func transport() -> HermesTransport {
        HermesTransport(baseURL: settings.baseURL, apiKey: APIKeyStore.key(aux: .hermes) ?? "")
    }

    // MARK: - Session deletion

    /// Deletes a gateway session AND every local trace of it — the ONE path
    /// both delete buttons (sidebar list, settings list) go through.
    ///
    /// Gateway-first, and NOT fire-and-forget: a silently failed DELETE once
    /// left the session alive on the gateway while a list dropped it — every
    /// other surface (the phone) kept showing "deleted" sessions and the
    /// user blamed their sync (e2e 2026-07-27). On failure nothing local is
    /// touched; rethrows so the caller can keep its row.
    ///
    /// Local cleanup: the session's own mirrored thread is dropped (its
    /// source of truth is gone) and every binding pointing at the session is
    /// released so the next send starts fresh instead of 404-ing. A role's
    /// DEFAULT thread keeps its messages on purpose — it is only unbound,
    /// the on-screen chat must not vanish from under the user.
    func deleteSession(id: String) async throws {
        try await transport().deleteSession(id: id)
        settings.forgetSessionMarks(id)
        for role in roles {
            let sessionThread = role.conversationID(sessionID: id).storageKey
            for key in [role.conversationID.storageKey, sessionThread]
            where settings.sessionID(forConversationKey: key) == id {
                settings.unbindSession(forConversationKey: key)
            }
            if settings.activeSession(roleID: role.id) == id {
                settings.setActiveSession(nil, roleID: role.id)
            }
            ChatPersistence.deleteConversation(key: sessionThread)
        }
        NotificationCenter.default.post(name: .hermesSessionsDidChange, object: nil)
    }

    // MARK: - Probe

    /// Health + authorized discovery in one pass: verifies the gateway,
    /// refreshes capabilities and the role list, updates the connection
    /// state. Returns the structured result for the settings' diagnostics.
    @discardableResult
    func probe() async -> GatewayProbe.Result {
        let transport = transport()
        var serverInfo: String?
        do {
            serverInfo = try await transport.health()
        } catch {
            let status = (error as? HermesTransportError)?.probeStatus
                ?? GatewayProbe.status(forTransportError: error)
            setConnection(.disconnected(status.message))
            return GatewayProbe.Result(status: status, serverInfo: nil)
        }
        do {
            let models = try await transport.models()
            capabilities = try? await transport.capabilities()
            if let skills = try? await transport.skills() {
                cachedSkills = skills
            }
            if let options = try? await transport.modelOptions() {
                cachedProviders = options.providers
                currentModelPair = options.current
            }
            // Context window of the agent's model, resolved by Hermes itself
            // (the gauge's authoritative source). `/api/model/info` has NEVER
            // lived on the API server (checked against 0.19 and 0.20 route
            // tables, 2026-08-12) — it belongs to the DASHBOARD server, so
            // the primary call is only kept for a future/proxied gateway that
            // does answer. The real source is the dashboard base URL when the
            // user configured one (the route is in the dashboard's public
            // paths — the courier token is passed but not required). Failing
            // both, `try?` leaves the cached value / table fallback in charge
            // (HermesModelContext.limit).
            if let info = try? await transport.modelInfo() {
                settings.recordAgentContext(model: info.model, length: info.contextLength)
            } else if let dashboard = settings.dashboardBaseURL {
                let dashTransport = HermesTransport(
                    baseURL: dashboard,
                    apiKey: APIKeyStore.key(aux: .hermesDashboard) ?? "")
                if let info = try? await dashTransport.modelInfo() {
                    settings.recordAgentContext(model: info.model, length: info.contextLength)
                }
            }
            if settings.cachedAgentIDs != models {
                settings.cachedAgentIDs = models
            }
            guard !models.isEmpty else {
                setConnection(.degraded(GatewayProbe.Status.noAgents.message))
                return GatewayProbe.Result(status: .noAgents, serverInfo: serverInfo)
            }
            setConnection(.connected)
            return GatewayProbe.Result(status: .ok, serverInfo: serverInfo)
        } catch {
            let status = (error as? HermesTransportError)?.probeStatus
                ?? GatewayProbe.status(forTransportError: error)
            setConnection(.disconnected(status.message))
            return GatewayProbe.Result(status: status, serverInfo: serverInfo)
        }
    }

    /// Re-reads the provider/model catalog from the gateway. The truth
    /// about availability lives THERE (its picker logic, its caches, its
    /// quota handling — 2026-07-29) — the composer menu must mirror it
    /// whenever the user comes back to the panel, not the snapshot of the
    /// launch-time probe (a gateway-side picker fix stayed invisible until
    /// an app restart). Throttled: the triggers (panel key, app active,
    /// composer appear) fire in bursts.
    private var lastCatalogRefresh: Date = .distantPast
    func refreshCatalogIfStale() async {
        guard Date().timeIntervalSince(lastCatalogRefresh) > 15 else { return }
        lastCatalogRefresh = Date()
        guard isAvailable, let options = try? await transport().modelOptions() else { return }
        cachedProviders = options.providers
        currentModelPair = options.current
    }

    private func setConnection(_ state: AgentConnectionState) {
        guard connectionState != state else { return }
        connectionState = state
        NotificationCenter.default.post(name: .hermesConnectionDidChange, object: nil)
    }

    // MARK: - Background activity poll

    /// Watches the gateway for activity in sessions BOUND to our role
    /// conversations: a run finished via Telegram/cron/another surface (or
    /// one that outlived our app restart) grows the session's message count
    /// — that becomes a "task finished" banner (§7.1) and a mirror sync for
    /// the on-screen conversation. Idempotent; call on launch and enable.
    func startBackgroundPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, self.isAvailable else { continue }
                // Self-heal: a gateway restart / dropped VPN / early keyless
                // 401 must not park the chip on red forever — re-probe until
                // green, then watch sessions.
                if self.connectionState != .connected {
                    await self.probe()
                }
                guard self.connectionState == .connected else { continue }
                await self.pollBoundSessions()
            }
        }
    }

    /// Advances the read watermarks from a fresh sessions list: the session
    /// whose conversation is OPEN on a visible panel is read up to its
    /// current count; sessions never seen before seed silently (their whole
    /// history is not "unread"). Everything else accrues badge counts.
    func updateReadWatermarks(sessions: [HermesSessionInfo]) {
        // "Looking at it" = the panel is up OR the app is frontmost: the
        // panel-only check left badges stuck on the conversation the user
        // was reading in a normal window (e2e 2026-07-27).
        let watching = FloatingPanelWindow.chatPanel?.isVisible == true || NSApp.isActive
        let openKey = watching ? ChatWindowBridge.chatStore?.conversation.storageKey : nil
        let openSession = openKey.flatMap { settings.sessionID(forConversationKey: $0) }
        for session in sessions {
            if session.id == openSession || settings.readCount(for: session.id) == nil {
                settings.markSessionRead(session.id, count: session.messageCount)
            }
        }
        refreshUnreadBadges(sessions: sessions)
    }

    /// Adopts the gateway's session-row models into the stored lock labels —
    /// what the composer shows at LAUNCH must be the server's reality, not
    /// the pair this app once requested (a lock changed from the phone/CLI,
    /// a gateway restart, or a model-routes reroute all drift otherwise).
    /// The row knows only the model — the provider survives when the model
    /// still matches, and empties out when it does not (honest "unknown").
    func reconcileSessionModels(sessions rows: [HermesSessionInfo]) {
        for row in rows {
            guard let model = row.model else { continue }
            settings.reconcileSessionModel(sessionID: row.id, provider: "", model: model)
        }
    }

    // MARK: - Server-side session pins (Hermes 0.20)

    /// Reconciles pins with a fresh sessions list. On the FIRST contact with
    /// a pin-capable gateway (rows carry `pinned`), local pins migrate UP —
    /// the user's existing desktop pins must survive the 0.20 upgrade, not
    /// be wiped by an empty server state. From then on the server owns the
    /// truth (pins made on other devices land here), and local storage is
    /// just its mirror plus any sessions the fetch window missed.
    func syncServerPins(sessions rows: [HermesSessionInfo]) {
        guard rows.contains(where: { $0.pinned != nil }) else { return } // 0.19 gateway
        let serverPinned = Set(rows.filter { $0.pinned == true }.map(\.id))
        let known = Set(rows.map(\.id))
        let migrationFlag = "hermes.sessionPinsPushed"
        if !UserDefaults.standard.bool(forKey: migrationFlag) {
            let toPush = settings.pinnedSessionIDs.filter {
                known.contains($0) && !serverPinned.contains($0)
            }
            UserDefaults.standard.set(true, forKey: migrationFlag)
            guard toPush.isEmpty else {
                Task { [weak self] in
                    for id in toPush {
                        try? await self?.transport().setSessionPinned(id: id, pinned: true)
                    }
                    Diagnostics.log("hermes", "pins.migrated count=\(toPush.count)")
                    await self?.reloadSessionsListeners()
                }
                return // adopt on the refresh the push triggers
            }
        }
        // Adopt: server state for sessions this fetch covered, local state
        // kept for ids outside the window (pinned rows are backfilled by the
        // server, so a REAL server pin is always in `rows`).
        let preserved = settings.pinnedSessionIDs.filter { !known.contains($0) }
        settings.replaceSessionPins(Array(serverPinned) + preserved)
    }

    /// Pin toggle used by the sidebar: local flip immediately (works against
    /// any gateway), server write best-effort (0.19 400s — the local pin
    /// still stands, exactly the pre-0.20 behavior).
    func toggleSessionPin(_ sessionID: String) {
        settings.toggleSessionPin(sessionID)
        let pinned = settings.isSessionPinned(sessionID)
        Task { [weak self] in
            do { try await self?.transport().setSessionPinned(id: sessionID, pinned: pinned) }
            catch { Diagnostics.log("hermes", "pins.server write failed (kept local): \(String(error.localizedDescription.prefix(80)))") }
        }
    }

    /// Asks sidebar/settings surfaces to refetch their session lists (pin
    /// migration just changed server state behind their backs). The sidebar
    /// listens on `.hermesSessionsDidChange` — the same signal a turn's
    /// session-create fires.
    private func reloadSessionsListeners() {
        NotificationCenter.default.post(name: .hermesSessionsDidChange, object: nil)
    }

    /// Immediate read-marking for the session whose conversation just came
    /// on screen. The sidebar's watermark pass only rides the 30s poll
    /// (muted during any streaming turn) and sidebar reloads — waiting for
    /// it left badges hanging long after the user had opened the thread
    /// (report 2026-07-31). The badge retires optimistically right away;
    /// the watermark trues up from a fresh sessions fetch.
    func markSessionRead(_ sessionID: String) async {
        unreadBadges.removeValue(forKey: sessionID)
        badgeComputedAt.removeValue(forKey: sessionID)
        guard let sessions = try? await transport().sessions(limit: 50),
              let row = sessions.first(where: { $0.id == sessionID }) else { return }
        settings.markSessionRead(sessionID, count: row.messageCount)
        // The user is looking at these rows — they must not come back as
        // an "outside activity" banner either.
        lastSeenCounts[sessionID] = row.messageCount
        refreshUnreadBadges(sessions: sessions)
    }

    /// Unread messages of a session, in MESSAGES the user would see — not in
    /// gateway transcript rows. The raw watermark delta counts tool results
    /// and tool-call shells too, so one agent turn showed as "34 unread";
    /// the badge now reads from `unreadBadges` (computed from the transcript
    /// tail), and 0 stands in while a fresh delta is still being resolved.
    func unreadCount(for session: HermesSessionInfo) -> Int {
        guard let read = settings.readCount(for: session.id),
              session.messageCount > read else { return 0 }
        return unreadBadges[session.id] ?? 0
    }

    /// Recomputes visible-unread badges for sessions whose raw message_count
    /// moved past the read watermark. One transcript fetch per (session,
    /// count) — the poll and the sidebar reload both funnel through here.
    private func refreshUnreadBadges(sessions: [HermesSessionInfo]) {
        for session in sessions {
            guard let read = settings.readCount(for: session.id),
                  session.messageCount > read else {
                // Read (or freshly seeded) — retire any stale badge.
                if unreadBadges[session.id] != nil {
                    unreadBadges.removeValue(forKey: session.id)
                    badgeComputedAt.removeValue(forKey: session.id)
                }
                continue
            }
            guard badgeComputedAt[session.id] != session.messageCount,
                  !badgeFetchesInFlight.contains(session.id) else { continue }
            badgeFetchesInFlight.insert(session.id)
            Task { @MainActor in
                defer { badgeFetchesInFlight.remove(session.id) }
                let started = ContinuousClock.now
                guard let rows = try? await transport().messages(sessionID: session.id) else { return }
                // Perf telemetry (2026-07-31): this is a FULL-transcript
                // fetch parsed on the main actor, one per unread session per
                // count change — with dozens of sessions and background
                // agents it was a suspected source of scroll stutter.
                let elapsed = started.duration(to: .now)
                let ms = Int(elapsed.components.seconds) * 1000
                    + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
                if ms > 50 {
                    Diagnostics.log("hermes", "badge.fetch session=\(session.id) rows=\(rows.count) ms=\(ms)")
                }
                // Rows are append-only: the first `read` ones were on screen
                // when the watermark was set — everything after is new.
                // Visible = what the transcript renders as bubbles: user
                // turns and assistant rows with actual text (tool results
                // and bare tool-call shells stay out).
                // User rows minus compaction artifacts — a context summary
                // the gateway injected must not light the badge.
                let visible = rows.suffix(max(0, rows.count - read)).filter {
                    ($0.role == "user" && HermesCompaction.visibleUserText($0.content) != nil)
                        || ($0.role == "assistant"
                            && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.count
                badgeComputedAt[session.id] = session.messageCount
                // Never 0 while the raw count moved: an all-tool tail still
                // means the agent worked here since the user last looked.
                unreadBadges[session.id] = max(1, visible)
            }
        }
    }

    private func pollBoundSessions() async {
        let endpoint = settings.endpointURL
        if lastPollEndpoint != endpoint {
            lastSeenCounts.removeAll()
            approvalLedgers.removeAll()
            approvalUnavailable.removeAll()
            approvalTerminalRuns.removeAll()
            continuationRequests.removeAll()
            backgroundWork.removeAll()
            lastPollEndpoint = endpoint
        }
        for sessionID in Set(settings.sessionMap.values) {
            await refreshApprovals(sessionID: sessionID)
        }
        guard let sessions = try? await transport().sessions(limit: 50),
              settings.endpointURL == endpoint else { return }
        // A session appeared or vanished on ANOTHER surface (their app,
        // CLI, Telegram) — the sidebar list must learn without a reopen.
        let ids = Set(sessions.map(\.id))
        if ids != Set(lastSeenCounts.keys) {
            NotificationCenter.default.post(name: .hermesSessionsDidChange, object: nil)
        }
        updateReadWatermarks(sessions: sessions)
        // conversationKey ↔ sessionID (the map is stored the other way).
        let bindings = settings.sessionMap // [conversationKey: sessionID]
        for session in sessions {
            let previous = lastSeenCounts[session.id]
            // The first fetch also restores pending consent after a relaunch.
            guard previous.map({ session.messageCount > $0 }) ?? true else { continue }
            guard let conversationKey = bindings.first(where: { $0.value == session.id })?.key,
                  let role = roles.first else {
                lastSeenCounts[session.id] = session.messageCount
                continue
            }
            guard !isTurnActive(forConversationKey: conversationKey) else { continue }
            // Growth can be only a background report. A completion needs a
            // new assistant reply; a failed fetch cannot establish that.
            var preview: String?
            let previewStart = ContinuousClock.now
            if let rows = try? await transport().messages(sessionID: session.id) {
                guard settings.endpointURL == endpoint else { return }
                guard settings.sessionID(forConversationKey: conversationKey) == session.id,
                      !isTurnActive(forConversationKey: conversationKey) else { continue }
                lastSeenCounts[session.id] = session.messageCount
                // Same fetch also answers "is this session working right
                // now" for every bound session, not just the open one.
                noteLiveTurn(HermesLiveTurnDetector.detect(rows: rows),
                             rows: rows, sessionID: session.id)
                if (backgroundWork[session.id] ?? []).isEmpty {
                    preview = HermesLiveTurnDetector.completionPreview(rows: rows, previousCount: previous ?? rows.count)
                }
                let elapsed = previewStart.duration(to: .now)
                let ms = Int(elapsed.components.seconds) * 1000
                    + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
                if ms > 50 {
                    Diagnostics.log("hermes", "poll.preview session=\(session.id) rows=\(rows.count) ms=\(ms)")
                }
            }
            if let preview {
                NotificationService.shared.postTurnCompleted(
                    roleID: role.id, roleName: role.displayName,
                    preview: preview, conversationKey: conversationKey
                )
            }
        }
        // Also retry consent preflights that were blocked by a busy run or
        // unreachable gateway, even when the transcript count stayed flat.
        NotificationCenter.default.post(name: .hermesConnectionDidChange, object: nil)
    }

    // MARK: - Sessions per conversation

    /// The AgentSession for one CONVERSATION of a role (each gateway session
    /// is its own conversation). Reuses the bound gateway session; a missing
    /// binding is created lazily on the first send. nil key = the role's
    /// currently active thread.
    func agentSession(for role: AgentRole, conversationKey: String? = nil) -> HermesAgentSession {
        HermesAgentSession(addon: self, role: role, conversationKey: conversationKey)
    }

    /// Model-lock pair for new sessions: the explicit setting when present,
    /// else the gateway's current top-level (provider, model) from
    /// `/api/model/options` — the agent's own configured default.
    ///
    /// The explicit choice is NOT validated against the catalog: the catalog
    /// mirrors the gateway's momentary mood (quota cooldowns shrink it —
    /// live 2026-07-29), while limits renew on the user's schedule. A model
    /// that is truly gone fails the send with a visible hint
    /// (`HermesAgentSession.annotateGatewayFailure`) — the user re-picks;
    /// nothing silently overrides their choice (4.6 regression: the old
    /// auto-heal reverted an explicit pick back to the quota-dead provider).
    func resolveLockPair() async -> (provider: String, model: String)? {
        if !settings.lockProvider.isEmpty, !settings.lockModel.isEmpty {
            return (settings.lockProvider, settings.lockModel)
        }
        return (try? await transport().modelOptions())?.current
    }
}

extension Notification.Name {
    /// Object: the user-facing notice string. ChatWindow shows it as one
    /// system line in the active agent chat (model-switch feedback).
    static let hermesSystemNotice = Notification.Name("hermesSystemNotice")
}

extension HermesAddon.StopOutcome {
    /// Diagnostics label — states only, never gateway error text beyond
    /// what the transport already logs.
    var logLabel: String {
        switch self {
        case .stopped(let status): return "stopped status=\(status)"
        case .gone: return "gone"
        case .unconfirmed: return "unconfirmed"
        case .failed: return "failed"
        }
    }
}
