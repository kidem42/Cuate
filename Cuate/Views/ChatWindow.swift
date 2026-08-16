import SwiftUI
import Combine
import AppKit
import Foundation
import UniformTypeIdentifiers

extension Notification.Name {
    static let chatWindowDidBecomeVisible = Notification.Name("chatWindowDidBecomeVisible")
}

struct ChatWindow: View {
    // @StateObject, NOT @ObservedObject: the view OWNS the store it creates.
    // With @ObservedObject a re-instantiation of the root view struct would
    // silently spin up a second ChatStore — whose init re-runs migration,
    // load and the media sweep — and orphan the in-flight streaming state.
    @StateObject private var chatStore = ChatStore()
    @ObservedObject private var settings = AppSettings.shared
    // Agent roles in the switcher + the role chip's connection dot
    // (Addons/HermesAddon; renders nothing while the addon is off).
    // Both objects are observed: roles derive from the SETTINGS' cached
    // agent list — without this the chips would not appear until some other
    // state change happened to re-render the header.
    @ObservedObject private var hermesAddon = HermesAddon.shared
    @ObservedObject private var hermesSettings = HermesSettings.shared
    @StateObject private var audioRecorder = AudioRecorder()
    @State private var messageText = ""
    /// Captured selection shown as an editable styled region in the composer.
    @State private var quotedText: String?
    @State private var quoteToInsert: String?
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: AppState
    /// Staged images, oldest first (up to `Self.maxPendingAttachments`).
    /// ONE image keeps the full toolbar (ImageAddon actions, Extract Text);
    /// several collapse to bare thumbnails — a batch goes to the model as
    /// vision content parts, and per-image editing tools would be ambiguous.
    @State private var pendingAttachments: [ChatAttachment] = []
    @State private var isExtractingText = false

    /// What a failed turn should re-run: the chat request (message already in
    /// history) or the transcription stage of a voice recording.
    private enum RetryAction {
        case chat
        case transcription(URL)
    }
    @State private var pendingRetry: RetryAction?
    /// Pending "start this local model?" confirmation, shown as an assistant-style
    /// bubble with Yes/No buttons in the chat (instead of sending straight away).
    private struct PendingLocalStart {
        let prompt: String
        let send: () -> Void
    }
    @State private var pendingLocalStart: PendingLocalStart?
    /// Pending agent approval request rendered as an inline card
    /// (AgentGateway). Cleared on resolve and when the turn ends.
    private struct PendingAgentApproval {
        let approval: AgentApproval
        let resolve: @MainActor (AgentApprovalDecision) -> Void
    }
    @State private var pendingAgentApproval: PendingAgentApproval?
    /// Slash autocomplete: keyboard-selected row, and the exact text for
    /// which the popup was dismissed with Esc (typing anything re-arms it).
    @State private var slashSelection = 0
    @State private var slashDismissedText: String?
    /// Header folder popover: all files the agent shared in this chat.
    @State private var showAgentFiles = false
    /// Agent mode: non-image files picked for the next message — sent as
    /// PATHS the agent's file tools read (uploaded first via the dashboard
    /// courier when the gateway is remote). Multiple files are fine.
    @State private var pendingAgentFilePaths: [String] = []
    /// A drag hovers over the panel (drop-zone highlight).
    @State private var isDropTargeted = false
    /// Pinned-message navigation: which pin the bar targets next (cycles,
    /// Telegram-style; resets on conversation switch via task(id:)).
    @State private var pinCycleIndex = 0

    /// Pinned messages of the OPEN agent conversation that are actually in
    /// the loaded window (stale ids — cleared chats — drop out silently).
    private var resolvedPinnedMessages: [ChatMessage] {
        guard chatStore.conversation.isAgent else { return [] }
        let ids = hermesSettings.pinnedMessages(forConversationKey: chatStore.conversation.storageKey)
        guard !ids.isEmpty else { return [] }
        return ids.compactMap { id in
            chatStore.messages.first { $0.id.uuidString == id }
        }
    }

    /// Telegram-style bar over the transcript: shows the target pin, click
    /// jumps to it and advances the cycle; ✕ unpins the shown one.
    @ViewBuilder
    private var pinnedMessagesBar: some View {
        let pins = resolvedPinnedMessages
        if !pins.isEmpty {
            let index = pinCycleIndex % pins.count
            let target = pins[index]
            HStack(spacing: 8) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundColor(palette.ink)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(AGL("agent.pin.title"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(palette.ink)
                        if pins.count > 1 {
                            Text("\(index + 1)/\(pins.count)")
                                .font(.system(size: 10))
                                .foregroundColor(palette.secondaryText)
                        }
                    }
                    Text(target.text.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 11))
                        .foregroundColor(palette.primaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button {
                    hermesSettings.toggleMessagePin(
                        target.id.uuidString,
                        conversationKey: chatStore.conversation.storageKey)
                    pinCycleIndex = 0
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(palette.secondaryText)
                }
                .buttonStyle(PlainButtonStyle())
                .help(AGL("agent.pin.unpin"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .onTapGesture {
                // Telegram mechanics: if the shown pin is off-screen, the
                // first click brings you TO it; cycling to the next pin only
                // starts once the current target is in view.
                if transcriptController.isRowVisible(id: target.id.uuidString) {
                    let next = (index + 1) % pins.count
                    transcriptController.scrollTo(id: pins[next].id.uuidString)
                    pinCycleIndex = next
                } else {
                    transcriptController.scrollTo(id: target.id.uuidString)
                    pinCycleIndex = index
                }
            }
            .background(Color.secondary.opacity(0.07))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 1)
            }
            .help(AGL("agent.pin.barHelp"))
        }
    }

    /// File paths from the conversation, deduped, newest first (the header
    /// folder popover). FILES only — directory mentions stay on the
    /// per-bubble chips but are noise in this list. Two groups: produced by
    /// the AGENT, and attached BY THE USER (from the attach notes).
    private func collectAgentFilePaths() -> (agent: [String], user: [String]) {
        var seen = Set<String>()
        var agent: [String] = []
        var user: [String] = []
        for message in chatStore.messages.reversed() {
            if message.isUser {
                for path in AgentAttachNote.split(message.text).paths
                where AgentFilePaths.isListableFile(path) && seen.insert(path).inserted {
                    user.append(path)
                }
            } else {
                for path in AgentFilePaths.extract(from: message.text)
                where AgentFilePaths.isListableFile(path) && seen.insert(path).inserted {
                    agent.append(path)
                }
            }
        }
        return (agent, user)
    }
    /// Bookkeeping of ONE in-flight assistant reply. Several conversations
    /// can stream at once (Hermes sessions: start a task, switch, start
    /// another) — each keeps its own slot, so returning to any of them
    /// restores its bubble/pill, not just the newest one's.
    private struct StreamSlot {
        /// The stream task. Survives conversation switches (the reply keeps
        /// streaming in the background into its origin chat); cancelled only
        /// when the origin chat itself is deleted/stopped.
        var task: Task<Void, Never>?
        /// Live buffer of the reply streaming in. NOT observed by this view:
        /// only the streaming bubble's text subtree subscribes, so a flush
        /// re-renders that subtree alone.
        let live: StreamingReplyModel
        /// Identity/timestamp stub for the streaming bubble. While set (and
        /// the origin conversation is on screen) the transcript masks the
        /// store's copy of this message and renders the live row in its place.
        var stub: ChatMessage?
        /// True from send until the first streamed text chunk (the
        /// tool/thinking phase). Switching conversations wipes the store's
        /// isLoading/statusText — this plus `lastStatus` remember enough to
        /// put the pill back when the user returns to this chat.
        var awaitingText = true
        var lastStatus: String?
        /// Agent turns: the tool steps taken so far, streamed into the pill.
        /// Kept per slot for the same reason as `lastStatus` — coming back to
        /// a chat that is still working must restore ITS list, not the
        /// newest stream's.
        var liveSteps: [AgentStep] = []
    }
    /// Origin conversation → its in-flight reply. One per conversation at
    /// most: send is disabled while its chat is loading, and a finished
    /// stream removes its own slot before the next send can start.
    @State private var streamSlots: [ChatStore.ConversationID: StreamSlot] = [:]
    /// Live content of the "working…" pill (status line + step journal).
    /// Deliberately `@State` and not `@StateObject`: this view must NOT
    /// subscribe. The pill's own subtree observes it, so a step redraws the
    /// pill alone instead of re-running this body — which would rebuild every
    /// transcript item (hashing every message's text) and make the engine
    /// re-lay out the whole document. Same arrangement as `StreamSlot.live`.
    @State private var livePill = LiveTurnPillModel()
    /// Whether the pill currently has steps. A plain flag rather than the
    /// array: `showThinkingIndicator` needs to react to the pill appearing and
    /// disappearing (rare), not to each step arriving (constant).
    @State private var hasLiveSteps = false
    /// Whether the scroll position is near the newest message (reported by
    /// the transcript engine; mirrors its pin state).
    @State private var isNearBottom = true
    /// Keyboard control of voice recording: Space stops, double-Space cancels.
    @State private var panelKeyMonitor: Any?
    @State private var pendingVoiceSend: DispatchWorkItem?
    /// Conversation on screen when the mic OPENED — the voice send's true
    /// origin. Captured at record start (not at send: every stop path has an
    /// async gap a fast chat switch can slip into); cleared by send/cancel.
    @State private var voiceRecordingOrigin: ChatStore.ConversationID?
    /// Imperative handle to the transcript engine (scroll-to-bottom on send
    /// and summon). @State so the instance survives view-struct re-inits.
    @State private var transcriptController = TranscriptController()
    @FocusState private var isInputFocused: Bool
    @State private var textEditorHeight: CGFloat = 27 // Default height for one line
    /// Providers offered by the header switcher (see `refreshAvailableProviders`).
    @State private var availableProviders: [ProviderID] = []
    /// Agent conversations: the last catch-up sync could not reach the
    /// gateway — the transcript shows an honest plaque instead of silently
    /// pretending the local mirror is complete.
    @State private var agentGatewayOffline = false
    /// Whether the agent sidebar should show at all (role active and not
    /// collapsed by the user for this role). The CHAT column is invariant:
    /// the window grows LEFT by exactly the sidebar width when this flips
    /// on, and shrinks back when it flips off — the AppDelegate applies the
    /// delta on `.agentSidebarVisibilityChanged`.
    private var agentSidebarVisible: Bool {
        guard let role = settings.activeAgentRole else { return false }
        return !hermesSettings.isSidebarCollapsed(roleID: role.id)
    }

    /// Windowed history rendering: only the newest `visibleCount` messages
    /// live in the view tree, so the bottom-anchored layout lands on the
    /// latest message instantly. Scrolling to the top backfills another page.
    /// Purely presentation — the full history stays in ChatStore (and in the
    /// API context).
    private static let historyPageSize = 30

    /// How many extra working rounds one reply may request with a trailing
    /// `<continue/>` marker (each round gets a fresh tool budget). Bounds
    /// the auto-continuation so a marker-happy model can't loop forever.
    private static let maxAutoContinues = 3

    /// Detects a trailing `<continue/>` continuation marker and returns the
    /// text without it. The marker is a contract taught in
    /// `AppSettings.mandatoryPromptRules`.
    static func strippingContinueMarker(_ text: String) -> (text: String, wantsContinuation: Bool) {
        let markers = ["<continue/>", "<continue />"]
        let tail = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let marker = markers.first(where: { tail.hasSuffix($0) }),
              let range = text.range(of: marker, options: .backwards) else {
            return (text, false)
        }
        var stripped = text
        stripped.removeSubrange(range)
        while let last = stripped.unicodeScalars.last,
              CharacterSet.whitespacesAndNewlines.contains(last) {
            stripped.unicodeScalars.removeLast()
        }
        return (stripped, true)
    }
    @State private var visibleCount = ChatWindow.historyPageSize
    /// Newest rows currently NOT rendered — reading deep history slides the
    /// window UP the conversation and drops rows off its bottom edge, so the
    /// count of live hosting views stays capped. Non-zero only while the
    /// user is far from the newest message; every "back to latest" path
    /// (jump button, summon, own send, conversation switch) resets it to 0.
    ///
    /// Why a cap at all: rows are real NSViews, and AppKit walks the WHOLE
    /// view tree every display cycle while scrolling (tracking areas,
    /// layout). Profiled 2026-07-28: an uncapped history scroll spent ~8% of
    /// the main thread in `updateTrackingAreasWithInvalidCursorRects` alone,
    /// growing with every backfilled page.
    @State private var bottomDropCount = 0
    /// Ceiling for live transcript rows (window slides beyond it). ~10
    /// viewports of typical rows — deep enough that the slide is invisible.
    private static let maxLiveRows = 120
    /// Guards against cascading backfills while one is restoring the scroll.
    @State private var isBackfilling = false

    /// Remembers the panel's content width across launches so the FIRST
    /// layout pass already uses the real bubble width — starting from the
    /// 320 pt fallback meant every row laid out twice on appear (once at the
    /// fallback, again when the probe landed).
    private static let containerWidthDefaultsKey = "chatPanelContentWidth"

    /// Width of the scroll viewport, captured WITHOUT a layout-imposing
    /// `GeometryReader` wrapper. The old wrapper fed `geo.size.width` into
    /// every row, so any geometry event (external-display wake/reconfigure,
    /// window resize, full-screen) re-proposed sizes to the whole list and
    /// could pin the main thread re-laying it out. A background probe writes
    /// this instead; only a genuine width change republishes.
    @State private var bubbleContainerWidth: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: ChatWindow.containerWidthDefaultsKey)
        return stored > 0 ? stored : 576 // default 600 pt panel minus padding
    }()

    /// The rendered slice of the conversation: `visibleCount` rows ending
    /// `bottomDropCount` rows before the newest message. Both edges are
    /// anchored to the END of the array, so store-side prepends (older pages
    /// loading in) never shift the window's content, and appends slide it by
    /// one row — which the engine's anchor compensation absorbs.
    private var visibleMessages: ArraySlice<ChatMessage> {
        let messages = chatStore.messages
        let end = max(0, messages.count - bottomDropCount)
        let start = max(0, end - visibleCount)
        return messages[start..<end]
    }

    /// Resolved theme tokens for the active theme + color scheme. `current`
    /// resolves to the glass palette and leaves every surface untouched.
    private var palette: ThemePalette {
        ThemePalette.palette(for: settings.theme, scheme: colorScheme)
    }

    // MARK: - Transcript rows

    /// The stream slot of the ON-SCREEN conversation, if it has a reply in
    /// flight. Replies streaming for other conversations keep their own
    /// slots and never touch this transcript.
    private var currentStreamSlot: StreamSlot? {
        streamSlots[chatStore.conversation]
    }

    /// Whether an in-flight reply is being rendered live in THIS transcript
    /// (its origin conversation is on screen). While true, the store's copy
    /// of the streaming message is masked and the live row stands in for it.
    private var liveStreamOnScreen: Bool {
        currentStreamSlot?.stub != nil
    }

    /// Rows for the transcript engine. Identity + revision give the engine
    /// point updates: a row's SwiftUI view is rebuilt only when its revision
    /// changes. The streaming reply is deliberately NOT part of the row
    /// data — its store row is masked and a dedicated live row (observing
    /// `StreamingReplyModel` internally) renders in its place, so a stream
    /// flush re-renders one text subtree and touches no list at all.
    private var transcriptItems: [TranscriptItem] {
        // Rows span the viewport minus the engine's 12pt edge insets.
        let rowWidth = max(200, bubbleContainerWidth - 24)
        let maxBubble = max(320, bubbleContainerWidth * 0.75)
        // Environment the hosting views can't inherit from the panel root:
        // a change to any of it must rebuild every row.
        var seed = Hasher()
        seed.combine(settings.theme)
        seed.combine(colorScheme)
        seed.combine(rowWidth)
        let baseRevision = seed.finalize()

        var items: [TranscriptItem] = []

        // Agent conversation, gateway unreachable: older history lives on
        // the agent — an empty scroll-past-the-top must say so, not stay
        // silently blank (notes §6.1).
        if agentGatewayOffline, chatStore.conversation.isAgent {
            items.append(TranscriptItem(id: "agent-offline-plaque", revision: baseRevision) { [palette] in
                AnyView(
                    HStack(spacing: 6) {
                        Image(systemName: "wifi.slash")
                            .font(.caption)
                        Text(AGL("agent.offline.older"))
                            .font(.footnote)
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(width: rowWidth)
                    .environment(\.themePalette, palette)
                    .fontDesign(palette.fontDesign)
                )
            })
        }

        if chatStore.messages.count - bottomDropCount > visibleCount || chatStore.hasOlderMessages {
            // Waves only while the user is actually up reading history —
            // parked at the bottom it is far off-screen, and an always-on
            // 30 fps TimelineView kept invalidating for nothing.
            var hasher = Hasher()
            hasher.combine(baseRevision)
            hasher.combine(isNearBottom)
            let paused = isNearBottom
            items.append(TranscriptItem(id: "backfill-spinner", revision: hasher.finalize()) {
                AnyView(
                    HStack {
                        Spacer()
                        ThinkingEqualizer(paused: paused)
                            .scaleEffect(0.8)
                        Spacer()
                    }
                    .frame(width: rowWidth, height: 24)
                )
            })
        }

        let maskedID = currentStreamSlot?.stub?.id
        for message in visibleMessages where message.id != maskedID {
            items.append(messageItem(message, rowWidth: rowWidth,
                                     maxBubble: maxBubble, baseRevision: baseRevision))
        }

        // Reading deep history (newest rows dropped off the window's bottom
        // edge): a bottom spinner marks the ongoing restore, and the rows
        // that belong AFTER the newest message (live stream, thinking pill)
        // stay out — they'd otherwise render after some mid-history row.
        // Approval/confirm cards still join below: they demand action, and
        // at the fake bottom is exactly where the user is looking.
        if bottomDropCount > 0 {
            items.append(TranscriptItem(id: "backfill-spinner-bottom", revision: baseRevision) {
                AnyView(
                    HStack {
                        Spacer()
                        ThinkingEqualizer()
                            .scaleEffect(0.8)
                        Spacer()
                    }
                    .frame(width: rowWidth, height: 24)
                )
            })
        }

        if bottomDropCount == 0, let slot = currentStreamSlot, let stub = slot.stub {
            // Constant revision WITHIN a stream on purpose: the row's CONTENT
            // updates itself through the model — the engine never rebuilds it
            // mid-stream. But it must differ PER STREAM (stub.id is fresh
            // each turn): the engine parks removed rows for reuse, and a
            // same-revision "live-reply" comes back with the PREVIOUS turn's
            // rootView — old stub, reset model — an empty bubble the new
            // stream never writes into, while the real text goes to a model
            // nobody renders (empty bubble till delivery, 2026-07-29).
            var liveHasher = Hasher()
            liveHasher.combine(baseRevision)
            liveHasher.combine(stub.id)
            let live = slot.live
            items.append(TranscriptItem(id: "live-reply", revision: liveHasher.finalize()) { [palette] in
                AnyView(
                    MessageRow(message: stub, maxBubbleWidth: maxBubble,
                               isStreamingReply: true, liveModel: live)
                        .environment(\.themePalette, palette)
                        .fontDesign(palette.fontDesign)
                        .frame(width: rowWidth, alignment: .leading)
                )
            })
        }

        if bottomDropCount == 0, showThinkingIndicator {
            // A turn running on the GATEWAY (started from the phone, or ours
            // before a relaunch) drives the same pill: our process has no
            // slot for it, so the status line and the steps come from the
            // transcript instead of the stream.
            // Revision deliberately carries NO per-step or per-status state:
            // the pill's content arrives through `livePill`, which its own
            // subtree observes. Rebuilding this row on every step is what put
            // the main thread at 100% for the length of an agent turn — each
            // rebuild made the engine re-solve layout for the entire
            // transcript (spin-20260812-175422). Row reuse across turns is
            // harmless now: the model, not a captured value, decides what is
            // drawn.
            var hasher = Hasher()
            hasher.combine(baseRevision)
            hasher.combine(externalTurn != nil)
            let pill = livePill
            let fallbackStatus = L("panel.thinking")
            items.append(TranscriptItem(id: "thinking-indicator", revision: hasher.finalize()) { [palette] in
                AnyView(
                    LiveTurnPill(model: pill, fallbackStatus: fallbackStatus, rowWidth: rowWidth)
                        .environment(\.themePalette, palette)
                        .fontDesign(palette.fontDesign)
                )
            })
        }

        if let pending = pendingLocalStart {
            items.append(TranscriptItem(id: "local-start-confirm", revision: baseRevision) { [palette] in
                AnyView(
                    localStartConfirmBubble(pending)
                        .environment(\.themePalette, palette)
                        .fontDesign(palette.fontDesign)
                        .frame(width: rowWidth, alignment: .leading)
                )
            })
        }

        if let pending = pendingAgentApproval {
            let approval = pending.approval
            let resolve = pending.resolve
            items.append(TranscriptItem(id: "agent-approval-\(approval.id)", revision: baseRevision) { [palette] in
                AnyView(
                    AgentApprovalCard(approval: approval) { decision in
                        pendingAgentApproval = nil
                        resolve(decision)
                    }
                    .environment(\.themePalette, palette)
                    .fontDesign(palette.fontDesign)
                    .frame(width: rowWidth, alignment: .leading)
                )
            })
        }

        return items
    }

    private func messageItem(_ message: ChatMessage, rowWidth: CGFloat,
                             maxBubble: CGFloat, baseRevision: Int) -> TranscriptItem {
        // Telegram-style pins, agent chats only (right-click → pin).
        let conversationKey = chatStore.conversation.storageKey
        let pinnable = chatStore.conversation.isAgent && message.messageType != .system
        let isPinned = pinnable
            && hermesSettings.isMessagePinned(message.id.uuidString, conversationKey: conversationKey)

        var hasher = Hasher()
        hasher.combine(baseRevision)
        hasher.combine(message.text)
        hasher.combine(message.messageType.rawValue)
        // A mirror sync can FLIP a row's side with the text unchanged
        // (legacy service notices migrating to the assistant side).
        hasher.combine(message.isUser)
        hasher.combine(message.audioURL)
        // Agent step journal attaches at delivery, after the last text
        // checkpoint — without this the row never rebuilds to show it.
        hasher.combine(message.agentSteps)
        // Pin state feeds the row's context menu label.
        hasher.combine(isPinned)
        for attachment in message.attachments {
            hasher.combine(attachment.id)
            hasher.combine(attachment.fileURLString)
            hasher.combine(attachment.ocrText)
        }
        // The bubble owns its context menu (CopyableBubble) — the pin entry
        // must ride inside it, an outer .contextMenu would be shadowed.
        let pinMenu: MessageRow.PinMenu? = pinnable ? MessageRow.PinMenu(
            isPinned: isPinned,
            toggle: {
                HermesSettings.shared.toggleMessagePin(
                    message.id.uuidString, conversationKey: conversationKey)
            }
        ) : nil

        return TranscriptItem(id: message.id.uuidString, revision: hasher.finalize()) { [palette] in
            AnyView(
                MessageRow(message: message, maxBubbleWidth: maxBubble, pinMenu: pinMenu)
                    .environment(\.themePalette, palette)
                    .fontDesign(palette.fontDesign)
                    .frame(width: rowWidth, alignment: .leading)
            )
        }
    }

    var body: some View {
        // Split into three expressions on purpose: body as ONE expression
        // (the giant container + ~25 handlers) blew the type-checker's
        // budget when the agent-role handlers joined.
        applyLifecycleHandlers(applyConversationHandlers(panelContent))
    }

    /// The panel itself (glass container, agent sidebar, chat column).
    private var panelContent: some View {
        // Liquid Glass: the panel itself is a transient overlay (functional
        // layer), so a single glassEffect wraps everything. Content inside
        // (message bubbles, input field) stays on opaque backings — no
        // glass-on-glass stacking. Pre-macOS 26 the same surface renders as
        // a translucent material (see AdaptiveGlass.swift).
        //
        // The agent management column lives in its OWN child window docked
        // to the panel's left edge (AppDelegate.setAgentSidebarVisible) —
        // sliding it in and out never touches this window's frame or
        // re-lays the transcript (the old in-window column did both, and
        // the toggle looked like the panel was glitching).
        AdaptiveGlassContainer(spacing: 24) {
            chatColumn
            // Untinted regular glass for the Current theme; the other themes
            // fill the panel with their gradient + signature pattern instead
            // (see themedPanelSurface). Legibility comes from the bubbles.
            .themedPanelSurface(palette, cornerRadius: 18)
            // Drop zone (pairs with the pin — an unpinned panel hides the
            // moment Finder takes focus): agent mode accepts ANY file (it
            // rides as a path for the agent's file tools), ordinary chats
            // keep the image-only rule.
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                handleFileDrop(providers)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.accentColor.opacity(isDropTargeted ? 0.8 : 0), lineWidth: 2)
            )
        }
        // The AppDelegate slides the docked column window in/out; this
        // window's own frame never changes.
        .onChange(of: agentSidebarVisible) { _, visible in
            NotificationCenter.default.post(
                name: .agentSidebarVisibilityChanged, object: nil,
                userInfo: ["visible": visible]
            )
        }
        // Role switch with the column already out: same visibility, new
        // content — repost so the column re-roots to the new role.
        .onChange(of: settings.activeAgentRole?.id) { _, _ in
            NotificationCenter.default.post(
                name: .agentSidebarVisibilityChanged, object: nil,
                userInfo: ["visible": agentSidebarVisible]
            )
        }
    }

    /// Accepts a file dragged onto the panel. Images attach as usual (with
    /// HEIC/TIFF conversion); other files only in agent mode, as a path.
    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }
        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }
                guard let url else { return }
                DispatchQueue.main.async {
                    acceptPickedFile(url)
                }
            }
        }
        return true
    }

    /// The chat column itself (header, transcript, composer).
    private var chatColumn: some View {
            VStack(spacing: 0) {
                // Window drag handle (transparent area at the top)
                ZStack(alignment: .trailing) {
                    DragHandle()
                        .frame(height: 22)
                        .background(Color.clear)
                        .accessibilityHidden(true)

                    // Provider switcher (left corner) · preset switcher + new
                    // chat (right corner). All share the same visual language:
                    // 11pt secondary text / 12pt icons, a fixed 20pt row.
                    // The Spacer between the zones stays click-through, so the
                    // middle of the strip still drags the window.
                    HStack(alignment: .center, spacing: 12) {
                        // Agent role active → the role chip; otherwise the
                        // quick provider switcher (extracted: the inline
                        // branch pushed body past the type-checker's budget).
                        headerProviderControl

                        Spacer(minLength: 12)

                        // Prompt preset switcher: dropdown menu or one-click
                        // chip row, per the style chosen in Settings → Prompts.
                        if settings.presetSwitcherStyle == .buttons {
                            presetChipsRow
                        } else {
                            presetMenu
                        }

                        Button(action: startNewChat) {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(height: 20)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help(L("panel.newChat"))
                        // Extra gap: visually separates "new chat" from the
                        // preset zone so a mis-click doesn't wipe the chat.
                        .padding(.leading, 10)

                        // Settings, one click from the chat — at the far
                        // right, apart from everything else (moved from the
                        // leading corner; e2e feedback 2026-07-25). Same
                        // quiet secondary ink as the rest of the header.
                        SettingsGearButton(
                            tab: .general,
                            color: .secondary,
                            help: L("panel.settingsHelp")
                        )
                        .padding(.leading, 4)
                    }
                    .frame(height: 20)
                    .padding(.horizontal, 12)
                    .padding(.top, 5)
                }
                .frame(height: 22)

                // Telegram-style pinned-message bar (agent chats).
                pinnedMessagesBar

                // Chat messages area — AppKit transcript engine
                // (Views/Transcript/): point row updates, an owned scroll
                // offset, and pin-to-bottom as an invariant re-asserted
                // after every layout change. Replaces the SwiftUI
                // ScrollView + LazyVStack + ScrollViewReader stack, whose
                // scrollTo-by-id was a silent no-op for unrendered rows and
                // needed a pile of asyncAfter re-assertions to approximate
                // all of this.
                ZStack(alignment: .bottomTrailing) {
                    ChatTranscriptView(
                        items: transcriptItems,
                        resetToken: chatStore.conversation.storageKey,
                        controller: transcriptController,
                        onNearBottomChange: { isNearBottom = $0 },
                        onViewportWidthChange: { updateContainerWidth($0) },
                        onNeedOlder: { loadOlderMessages() },
                        onNeedNewer: { restoreNewerRows() }
                    )
                    // A turn running on the GATEWAY has no local stream to
                    // write into the pill, so its journal is mirrored in here.
                    // Rides this inner view on purpose: the outer chain is at
                    // the type-checker's limit (see RecordingStatusView).
                    .onChange(of: externalTurn) { syncExternalTurnPill() }

                    // Floating "jump to latest" button (Telegram-style)
                    if !isNearBottom {
                        Button {
                            jumpToLatest(animated: true)
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 30, height: 30)
                                .background(.regularMaterial, in: Circle())
                                .overlay(Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .padding(.trailing, 14)
                        .padding(.bottom, 10)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        .help(L("panel.jumpLatest"))
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: isNearBottom)
                .onChange(of: chatStore.messages.count) { oldCount, _ in
                    if oldCount == 0 {
                        // Wholesale history arrival (launch, conversation
                        // switch): render only the newest page — the engine
                        // lays it out already pinned to the newest message.
                        visibleCount = Self.historyPageSize
                        bottomDropCount = 0
                        isBackfilling = false
                    } else if chatStore.messages.last?.isUser == true {
                        // Own messages always jump down (and re-arm
                        // auto-follow) even if the user was reading history.
                        // Incoming rows never yank the view: the engine's
                        // pin state decides, and a backfill PREPEND is
                        // re-anchored by the engine itself.
                        jumpToLatest(animated: true)
                    }
                }
                .onChange(of: pendingLocalStart != nil) { _, visible in
                    // The local-model confirmation appears with NO store
                    // change, so no other trigger fires — and it answers
                    // the user's own send, so it always comes into view.
                    if visible {
                        jumpToLatest(animated: true)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .chatWindowDidBecomeVisible)) { _ in
                    // Every summon shows the newest message — and drops the
                    // history window back to one page (reading history
                    // widens it and nothing else narrows it again; between
                    // summons there is no viewport to disturb).
                    jumpToLatest(animated: false)
                }
                .onChange(of: chatStore.conversation.storageKey) {
                    // Returning to a chat whose reply is still in flight: the
                    // switch wiped the store's isLoading/statusText, and the
                    // stream only touches them on events that arrive while
                    // live — until the next one, the chat looked dead and
                    // then a reply "appeared out of nowhere". Restore from
                    // THIS conversation's slot (each in-flight chat keeps its
                    // own — the newest stream must not eat the others' pills).
                    guard let slot = currentStreamSlot else {
                        // A chat with nothing in flight shows no pill — the
                        // previous chat's steps must not ride along.
                        livePill.clear()
                        hasLiveSteps = false
                        return
                    }
                    chatStore.setLoading(true)
                    let restoredStatus = (slot.awaitingText || !slot.liveSteps.isEmpty)
                        ? slot.lastStatus : nil
                    livePill.begin(turnID: slot.stub?.id.uuidString ?? chatStore.conversation.storageKey,
                                   status: restoredStatus, steps: slot.liveSteps)
                    hasLiveSteps = !slot.liveSteps.isEmpty
                    if let restoredStatus {
                        chatStore.statusText = restoredStatus
                    }
                }

                // Input area (also acts as a drag region)
                VStack(spacing: 8) {
                    // Recording status (shown when recording)
                    RecordingStatusView(isRecording: $audioRecorder.isRecording)
                        // Rides an always-mounted inner view: the outer
                        // modifier chain is at the type-checker's limit —
                        // one more .onReceive there fails the whole body.
                        .onReceive(
                            NotificationCenter.default.publisher(for: .hermesSystemNotice),
                            perform: handleHermesNotice
                        )

                    // Slash autocomplete (agent mode): "/" lists the agent's
                    // skills — the agent itself interprets "/skill-name …"
                    // in plain text (probed live) — plus Cuate's own local
                    // image commands, which intercept before sending.
                    agentSlashSuggestions

                    // Agent mode: picked non-image files ride as paths.
                    if !pendingAgentFilePaths.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(pendingAgentFilePaths, id: \.self) { filePath in
                                    HStack(spacing: 6) {
                                        Image(systemName: "doc")
                                            .font(.system(size: 11))
                                        Text((filePath as NSString).lastPathComponent)
                                            .font(.system(size: 12, design: .monospaced))
                                            .lineLimit(1)
                                        Button {
                                            pendingAgentFilePaths.removeAll { $0 == filePath }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 11))
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                    }
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.secondary.opacity(0.10), in: Capsule())
                                    .help(filePath)
                                }
                            }
                            .padding(.horizontal, 12)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    ThemedComposerDivider(palette: palette)

                    // Retry after a failed turn — no re-typing / re-recording:
                    // the message (or the recorded audio file) is still there.
                    if let retry = pendingRetry, !chatStore.isLoading {
                        Button {
                            pendingRetry = nil
                            switch retry {
                            case .chat:
                                streamAssistantReply()
                            case .transcription(let url):
                                Task { await sendVoiceMessage(audioURL: url) }
                            }
                        } label: {
                            Label(L("panel.retry"), systemImage: "arrow.clockwise")
                                .font(.callout)
                        }
                        .buttonStyle(.bordered)
                        .padding(.horizontal, 12)
                    }

                    if !pendingAttachments.isEmpty {
                        attachmentCard
                    }

                    HStack(alignment: .bottom, spacing: 8) {
                        // Agent mode: session model + reasoning effort, the
                        // Hermes composer's own control brought over.
                        if settings.activeAgentRole != nil {
                            agentModelControl
                        }

                        // Attach an image (opens as a sheet so the panel
                        // doesn't auto-hide on losing key status)
                        Button(action: presentAttachOpenPanel) {
                            Image(systemName: "paperclip")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(palette.isGlass ? .secondary : palette.ink)
                                .frame(width: 24, height: 27)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(audioRecorder.isRecording)
                        .help(L("tooltip.attach"))

                        // Multi-line text input
                        ZStack(alignment: .topLeading) {
                            if messageText.isEmpty, quotedText == nil {
                                HStack(spacing: 3) {
                                    // ONE localized placeholder for every theme. The old
                                    // per-theme flavor strings were hardcoded in a single
                                    // language each (Sakura greeted English users in
                                    // Russian) — theme flavor stays in colors and the
                                    // Terminal caret, not in copy.
                                    Text(L("panel.typeMessage"))
                                        .font(.system(size: 13, design: palette.fontDesign))
                                        .foregroundColor(palette.isGlass ? .secondary.opacity(0.5) : palette.placeholderColor)
                                    // Terminal's blinking block caret after the "$ …" prompt.
                                    // The decorative placeholder caret steps
                                    // aside while the field is focused — the
                                    // REAL block caret takes over there.
                                    if palette.placeholderCaret, !isInputFocused {
                                        BlinkingCaret(color: palette.accent, height: 13)
                                    }
                                }
                                .padding(.leading, 7)
                                .padding(.top, 7)
                                .allowsHitTesting(false)
                            }

                            CustomTextEditor(
                                text: $messageText,
                                quotedText: $quotedText,
                                quoteToInsert: $quoteToInsert,
                                measuredHeight: $textEditorHeight,
                                onSubmit: sendMessage,
                                isDisabled: audioRecorder.isRecording,
                                onPasteImage: handleImagePaste,
                                // Terminal theme: a real blinking block caret
                                // in the composer, not just the placeholder ▮.
                                blockCaretColor: palette.placeholderCaret ? NSColor(palette.accent) : nil
                            )
                            .frame(height: textEditorHeight)
                            .focused($isInputFocused)
                            .help(L("tooltip.input"))
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                        // Material for Current; themed fill/border otherwise.
                        .themedInputField(palette)
                        .shadow(color: Color.black.opacity(0.07), radius: 2, x: 0, y: 1)

                        // Enhanced Voice button with cancel functionality
                        EnhancedVoiceButton(
                            isRecording: $audioRecorder.isRecording,
                            startRecording: {
                                handleVoiceRecordingStart()
                            },
                            stopRecording: {
                                handleVoiceRecordingStop()
                            },
                            cancelRecording: {
                                handleVoiceRecordingCancel()
                            }
                        )
                        // Tooltip lives inside EnhancedVoiceButton (the deepest
                        // view wins tooltip resolution, so a duplicate here
                        // would just shadow-drift over time).

                        // Send button — or STOP while an agent turn streams
                        // into this conversation AND the composer is empty
                        // (typing anything turns it back into send, the
                        // native-chat pattern). Cancelling also stops the
                        // run on the gateway.
                        if agentTurnInFlight, composerIsEmpty {
                            Button(action: stopAgentTurn) {
                                ZStack {
                                    Circle()
                                        .fill(palette.isGlass ? AnyShapeStyle(Color.accentColor) : palette.sendFill)
                                        .frame(width: 32, height: 32)
                                    Image(systemName: "stop.fill")
                                        .foregroundColor(palette.isGlass ? .white : palette.sendGlyphColor)
                                        .font(.system(size: 13, weight: .medium))
                                }
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help(AGL("agent.stop"))
                        } else {
                        Button(action: sendMessage) {
                            if palette.themeID == .diaDeMuertos {
                                // Marigold flower send button (with glow).
                                MarigoldFlower(dark: colorScheme == .dark, withInner: true, withSparkle: true)
                                    .frame(width: 34, height: 34)
                                    .opacity(composerIsEmpty ? 0.45 : 1.0)
                                    .shadow(color: palette.sendGlow ?? .clear, radius: 6)
                            } else if palette.themeID == .halloween {
                                // Glowing jack-o'-lantern send button (spec §2a).
                                JackOLantern(dark: colorScheme == .dark)
                                    .frame(width: 34, height: 32)
                                    .opacity(composerIsEmpty ? 0.45 : 1.0)
                                    .shadow(color: palette.sendGlow ?? .clear, radius: colorScheme == .dark ? 8 : 6,
                                            y: colorScheme == .dark ? 0 : 2)
                            } else {
                                ZStack {
                                    // Blueprint's composer buttons are rounded
                                    // squares (composerButtonRadius); every other
                                    // themed/glass send button stays a circle.
                                    Group {
                                        if let r = palette.composerButtonRadius, !palette.isGlass {
                                            RoundedRectangle(cornerRadius: r).fill(palette.sendFill)
                                        } else {
                                            Circle().fill(palette.isGlass ? AnyShapeStyle(Color.accentColor) : palette.sendFill)
                                        }
                                    }
                                    .frame(width: 32, height: 32)
                                    .opacity(composerIsEmpty ? 0.3 : 1.0)
                                    .shadow(color: palette.isGlass ? .clear : (palette.sendGlow ?? .clear), radius: 6)

                                    // Yule's gold band just inside the circle's edge.
                                    if let rim = palette.sendRim, !palette.isGlass {
                                        Circle()
                                            .strokeBorder(rim, lineWidth: 2.5)
                                            .frame(width: 32, height: 32)
                                            .opacity(composerIsEmpty ? 0.3 : 1.0)
                                    }

                                    Image(systemName: "paperplane.fill")
                                        .foregroundColor(palette.isGlass ? .white : palette.sendGlyphColor)
                                        .font(.system(size: 14, weight: .medium))
                                }
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(composerIsEmpty || audioRecorder.isRecording)
                        .help(L("tooltip.send"))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
                .background(
                    DragHandle()
                        .background(Color.clear)
                )
            }
    }

    /// Conversation-routing handlers (presets, agent roles, mirror sync).
    private func applyConversationHandlers<V: View>(_ view: V) -> some View {
        view
        // The switcher's provider list is state, not a body computation — keep
        // it in step with the things it depends on.
        .onReceive(NotificationCenter.default.publisher(for: .apiKeysDidChange)) { _ in
            refreshAvailableProviders()
        }
        .onChange(of: settings.onlineModelsEnabled) { refreshAvailableProviders() }
        .onChange(of: settings.localModelsEnabled) { refreshAvailableProviders() }
        .onChange(of: settings.localEndpointVerified) { refreshAvailableProviders() }
        // Isolated preset chats: follow the active preset (panel switcher AND
        // the Settings picker) and react to the isolation toggle itself.
        .onChange(of: settings.activePresetName) {
            syncConversation()
        }
        .onChange(of: settings.isolatedPresets) {
            syncConversation()
        }
        // Agent roles: selecting/leaving a role switches to its forced
        // isolated conversation; the addon toggling off drops the role.
        .onChange(of: settings.activeAgentRoleID) {
            syncConversation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .hermesAddonDidChange)) { _ in
            // Role list changed (addon toggled, profiles refreshed). If the
            // active role vanished, fall back to conventional chat.
            if settings.activeAgentRoleID != nil, settings.activeAgentRole == nil {
                settings.activeAgentRoleID = nil
            }
            syncConversation()
        }
        // Settings' sessions list: "continue here" binds the role's chat to
        // an existing gateway session and mirrors it in.
        .onReceive(NotificationCenter.default.publisher(for: .hermesContinueSession)) { note in
            guard let sessionID = note.userInfo?["sessionID"] as? String else { return }
            continueHermesSession(sessionID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .presetDeleted)) { note in
            guard let name = note.object as? String else { return }
            handlePresetDeleted(name)
        }
        // ▶ menu "run at the agent": the command goes over as a normal turn
        // and passes the gateway's own policy — never auto-run (§7.3).
        // Context gauge clicked in the sidebar: the gateway's own /compact
        // runs as an ordinary turn (there is no compaction endpoint), so it
        // shows up in the transcript and its result is visible.
        .onReceive(NotificationCenter.default.publisher(for: .hermesCompactContext)) { _ in
            guard settings.activeAgentRole != nil, !chatStore.isLoading else { return }
            performSend(text: "/compact", attachments: [])
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentRunCommandRemotely)) { note in
            guard let command = note.object as? String,
                  settings.activeAgentRole != nil, !chatStore.isLoading else { return }
            performSend(text: String(format: AGL("agent.code.remotePrompt"), command), attachments: [])
        }
        .modifier(agentSyncHandlers)
    }

    /// Mirror-sync triggers for agent conversations, bundled: a fourth
    /// handler group — the modifier chains are split so no single expression
    /// blows the type-checker's budget.
    private var agentSyncHandlers: some ViewModifier {
        AgentSyncHandlersModifier(
            isAgent: chatStore.conversation.isAgent,
            conversationKey: chatStore.conversation.storageKey,
            isHistoryLoaded: chatStore.isHistoryLoaded,
            canPoll: {
                FloatingPanelWindow.chatPanel?.isVisible == true
                    && streamSlots[chatStore.conversation] == nil
            },
            catchUp: { runAgentCatchUpIfNeeded() }
        )
    }

    /// Environment, focus, appearance and composer-side handlers.
    private func applyLifecycleHandlers<V: View>(_ view: V) -> some View {
        view
        .environment(\.themePalette, palette)
        // Terminal → monospaced, Pastel → rounded, others → system (.default,
        // a no-op). Applies across the whole panel per the design spec.
        .fontDesign(palette.fontDesign)
        .defaultFocus($isInputFocused, true)
        .onReceive(chatStore.$isHistoryLoaded) { loaded in
            // Welcome message — only after the async history load settled,
            // otherwise it would race the load and end up duplicated.
            if loaded, chatStore.messages.isEmpty {
                chatStore.addMessage(text: welcomeText(), isUser: false)
            }
        }
        .onAppear {
            NotificationCenter.default.addObserver(forName: .chatWindowDidBecomeVisible, object: nil, queue: .main) { _ in
                // Activate focus when window appears
                DispatchQueue.main.async {
                    self.isInputFocused = true
                }
            }
            refreshAvailableProviders()
            // AppState is an INBOX for externally-produced attachments
            // (screenshot hotkeys): consume into the staging row and clear.
            if let staged = appState.pendingAttachment {
                appendPendingAttachment(staged)
                appState.clearPendingAttachment()
            }
            installPanelKeyMonitor()
            ChatWindowBridge.chatStore = chatStore // ImageAddon (Addons/ImageAddon)
            // Safety net: ChatStore.init resolved the conversation from
            // UserDefaults before AppSettings' migrations could rewrite the
            // active preset — re-align if they diverged.
            syncConversation()
        }
        .onDisappear {
            // The root view lives as long as the panel, so this normally never
            // fires — but if the hosting view is ever torn down, leaked
            // monitors would keep intercepting Space/scroll for a dead view.
            if let monitor = panelKeyMonitor {
                NSEvent.removeMonitor(monitor)
                panelKeyMonitor = nil
            }
        }
        // ImageAddon: retry-after-error and "Continue editing"
        // hand an attachment back to the composer.
        .onReceive(NotificationCenter.default.publisher(for: .imageAddonAttachRequest)) { note in
            if let attachment = note.object as? ChatAttachment {
                appState.pendingAttachment = attachment
            }
        }
        .onReceive(appState.$pendingAttachment) { attachment in
            // Inbox semantics: a new arrival is APPENDED (screenshots stack
            // with what's already staged); the publisher's nil on clear is
            // not a command to drop the local staging row.
            guard let attachment else { return }
            appendPendingAttachment(attachment)
            appState.clearPendingAttachment()
        }
        .onReceive(appState.$pendingInputText) { text in
            guard let text, !text.isEmpty else { return }
            // The captured selection lands as an editable styled quote region
            // at the top of the composer; a typed draft stays below it.
            if quotedText != text.trimmingCharacters(in: .whitespacesAndNewlines) {
                quoteToInsert = text
            }
            appState.pendingInputText = nil
        }
        .onChange(of: audioRecorder.autoStoppedDueToLimit) {
            handleAutoStoppedRecording()
        }
    }

    /// Mirror-sync triggers for an agent conversation (§6.1): catch-up on
    /// load/appear/summon, plus a ~20s on-screen poll — Hermes has no push
    /// channel, so the transcript is only as fresh as our last ask.
    private struct AgentSyncHandlersModifier: ViewModifier {
        let isAgent: Bool
        let conversationKey: String
        let isHistoryLoaded: Bool
        let canPoll: () -> Bool
        let catchUp: () -> Void

        func body(content: Content) -> some View {
            content
                .onChange(of: isHistoryLoaded) { _, loaded in
                    if loaded { catchUp() }
                }
                // Cold start: the history may finish loading BEFORE the
                // handler above attaches — without this the sync never ran
                // until the user re-entered the conversation (e2e 2026-07-25).
                .onAppear { catchUp() }
                // Every summon re-syncs — the agent kept working while the
                // panel was hidden.
                .onReceive(NotificationCenter.default.publisher(for: .chatWindowDidBecomeVisible)) { _ in
                    catchUp()
                }
                // On-screen poll (skipped while our own stream runs — its
                // events are live). Restarts per conversation via task(id:).
                .task(id: conversationKey) {
                    guard isAgent else { return }
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 20_000_000_000)
                        guard !Task.isCancelled, canPoll() else { continue }
                        catchUp()
                    }
                }
        }
    }

    /// The recorder auto-stopped at the length limit: send what was recorded
    /// and drop a system notice. Extracted from `body` — the inline closure
    /// was the straw that pushed the modifier chain past the type-checker's
    /// budget once the agent-role handlers joined it.
    private func handleAutoStoppedRecording() {
        guard audioRecorder.autoStoppedDueToLimit == true else { return }
        Task {
            let limitMinutes = Int(Config.maxVoiceRecordingDuration / 60)
            // Small delay to ensure file is finalized
            try? await Task.sleep(nanoseconds: 300_000_000)
            if let audioURL = audioRecorder.recordingURL {
                await sendVoiceMessage(audioURL: audioURL)
                let notice = String(format: L("panel.recordLimitSent"), limitMinutes)
                _ = await MainActor.run {
                    chatStore.addMessage(text: notice, isUser: false, messageType: .system)
                }
            } else {
                let notice = String(format: L("panel.recordLimitStopped"), limitMinutes)
                _ = await MainActor.run {
                    chatStore.addMessage(text: notice, isUser: false, messageType: .system)
                }
            }
        }
    }

    private func welcomeText() -> String {
        L("panel.welcome")
    }

    /// Chat providers that are ready to use (keyed cloud, or reachable local)
    /// and whose class is enabled — for the quick switcher.
    ///
    /// Resolved into state instead of recomputed in `body`: the readiness check
    /// consults the key store, and doing that per body evaluation put the
    /// Keychain on the render path — the FIRST evaluation (which runs inside
    /// `setupChatWindow`, before anything is on screen) blocked launch there
    /// for seconds, or indefinitely behind an authorization dialog.
    private func refreshAvailableProviders() {
        // Agents are excluded by design: roles live in the preset switcher.
        let resolved = ProviderID.allCases.filter { !$0.isAgent && settings.isAvailable($0) }
        if resolved != availableProviders { availableProviders = resolved }
    }

    /// Left header slot: the agent role chip while a role is active (the
    /// provider pair is the agent's business; chatProvider stays untouched
    /// underneath), else the quick provider switcher.
    // MARK: - Agent composer controls (slash autocomplete, model/effort)

    /// Whether the app's OWN model-backed image features (ImageAddon bar,
    /// OCR extract, /upscale-style slash commands) may surface in the
    /// CURRENT conversation. Ordinary chats: always. Agent conversations:
    /// only behind the separate Hermes opt-in — the agent owns its sessions,
    /// our tools don't mix in uninvited (Settings → Hermes → App features).
    private var imageFeaturesAllowed: Bool {
        !chatStore.conversation.isAgent || hermesSettings.imageFeaturesEnabled
    }

    /// The "/query" being typed, when the composer is in slash-prefix state
    /// (single line, no space after the command yet). Agent mode always has
    /// commands; ordinary chats only when a local addon offers one (/plaud).
    private var slashQuery: String? {
        guard messageText.hasPrefix("/"),
              !messageText.contains("\n"),
              !messageText.dropFirst().contains(" ") else { return nil }
        if settings.activeAgentRole == nil {
            guard PlaudAddon.shared.isAvailable else { return nil }
        }
        return String(messageText.dropFirst()).lowercased()
    }

    /// The flat suggestion list for the current query — ONE source for the
    /// popup rows and the ↑/↓/⏎ keyboard handling in the panel key monitor.
    private func slashSuggestionItems() -> [(command: String, description: String?)] {
        guard let query = slashQuery, messageText != slashDismissedText else { return [] }
        var items: [(String, String?)] = []
        // Ordinary chats: /plaud pins the turn to the user's Plaud notes.
        // Agent sessions: skipped — the agent runs its own tools on its
        // host; our client-side Plaud tools don't mix in.
        if settings.activeAgentRole == nil, PlaudAddon.shared.isAvailable,
           query.isEmpty || "plaud".contains(query) {
            items.append(("/plaud", PLL("plaud.slash.description")))
        }
        if ImageAddonSettings.shared.enabled, imageFeaturesAllowed {
            items += ["/upscale", "/bg", "/cleanup"]
                .filter { query.isEmpty || $0.dropFirst().contains(query) }
                .map { ($0, nil) }
        }
        items += hermesAddon.cachedSkills
            .filter { query.isEmpty || $0.name.lowercased().contains(query) }
            .prefix(12)
            .map { ("/\($0.name)", $0.description) }
        return items
    }

    /// Applies a picked suggestion to the composer.
    private func acceptSlashSuggestion(_ command: String) {
        messageText = command + " "
        slashSelection = 0
        isInputFocused = true
    }

    @ViewBuilder
    private var agentSlashSuggestions: some View {
        let items = slashSuggestionItems()
        if !items.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.command) { index, item in
                            slashRow(command: item.command, description: item.description,
                                     selected: index == slashSelection)
                                .id(index)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 220)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                .padding(.horizontal, 12)
                // Keyboard selection stays in view while ↑/↓ walk the list.
                .onChange(of: slashSelection) { _, index in
                    withAnimation(.easeInOut(duration: 0.1)) { proxy.scrollTo(index) }
                }
                .onChange(of: messageText) { _, _ in slashSelection = 0 }
            }
        }
    }

    private func slashRow(command: String, description: String?, selected: Bool) -> some View {
        Button {
            acceptSlashSuggestion(command)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(command)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
                if let description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(selected ? Color.accentColor.opacity(0.18) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    /// The model pair shown in the composer, most specific first: the OPEN
    /// session's own lock → the global default for new sessions → the
    /// agent's configured model. Every gateway session carries its own lock.
    private var composerModelPair: (provider: String, model: String)? {
        if chatStore.conversation.isAgent,
           let sessionID = hermesSettings.sessionID(forConversationKey: chatStore.conversation.storageKey),
           let lock = hermesSettings.modelLock(forSession: sessionID) {
            return lock
        }
        if !hermesSettings.lockProvider.isEmpty, !hermesSettings.lockModel.isEmpty {
            return (hermesSettings.lockProvider, hermesSettings.lockModel)
        }
        return hermesAddon.currentModelPair
    }

    /// Compact "model · effort" menu — the Hermes composer's own control:
    /// picking a model re-locks the CURRENT gateway session (and becomes the
    /// default for new ones); effort rides as `model_options` per request.
    /// Whether this provider row owns the ACTIVE pair — so the top level of
    /// the menu answers "whose model runs now" at a glance (user ask
    /// 2026-08-13). A reconciled label may carry the model without a
    /// provider — then the row that lists the model wins.
    private func providerOwnsActivePair(_ provider: HermesProviderOption) -> Bool {
        guard let pair = composerModelPair else { return false }
        if !pair.provider.isEmpty { return pair.provider == provider.slug }
        return provider.models.contains { HermesSettings.sameModelID($0, pair.model) }
    }

    private var agentModelControl: some View {
        Menu {
            ForEach(hermesAddon.cachedProviders.filter { !$0.models.isEmpty }) { provider in
                Menu {
                    ForEach(provider.models, id: \.self) { model in
                        Button {
                            switchSessionModel(provider: provider.slug, model: model)
                        } label: {
                            // Model ids tolerate the vendor prefix drift
                            // ("openai/gpt-5.6-luna" vs "gpt-5.6-luna") and
                            // an unknown provider on a reconciled label.
                            if let pair = composerModelPair,
                               HermesSettings.sameModelID(pair.model, model),
                               pair.provider.isEmpty || pair.provider == provider.slug {
                                Label(model, systemImage: "checkmark")
                            } else {
                                Text(model)
                            }
                        }
                    }
                } label: {
                    // Same selection glyph as the model rows below — one
                    // style across every picker (user ask 2026-08-13).
                    if providerOwnsActivePair(provider) {
                        Label(provider.name, systemImage: "checkmark")
                    } else {
                        Text(provider.name)
                    }
                }
            }
            Divider()
            Menu(HL("hermes.composer.effort")) {
                Button {
                    hermesSettings.reasoningEffort = ""
                } label: {
                    if hermesSettings.reasoningEffort.isEmpty {
                        Label(HL("hermes.composer.effort.default"), systemImage: "checkmark")
                    } else {
                        Text(HL("hermes.composer.effort.default"))
                    }
                }
                ForEach(HermesSettings.effortLevels, id: \.self) { level in
                    Button {
                        hermesSettings.reasoningEffort = level
                    } label: {
                        if hermesSettings.reasoningEffort == level {
                            Label(level.capitalized, systemImage: "checkmark")
                        } else {
                            Text(level.capitalized)
                        }
                    }
                }
            }
        } label: {
            Text(composerModelLabel)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(height: 27)
                // The menu must mirror the gateway's CURRENT catalog, not
                // the launch-time probe: quotas renew and the gateway gets
                // fixed while the app sits open — re-read (throttled) on
                // every return to the panel. SwiftUI's Menu has no "will
                // open" hook, so the panel-level moments stand in for it.
                .onAppear { Task { await hermesAddon.refreshCatalogIfStale() } }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                    Task { await hermesAddon.refreshCatalogIfStale() }
                }
        }
        .menuIndicator(.hidden)
        .buttonStyle(PlainButtonStyle())
        .fixedSize()
        .help(HL("hermes.composer.model.help"))
    }

    private var composerModelLabel: String {
        let model = composerModelPair?.model ?? "—"
        let short = model.split(separator: "/").last.map(String.init) ?? model
        let effort = hermesSettings.reasoningEffort
        let effortLabel = effort.isEmpty ? "" : " · \(effort.prefix(3).capitalized)"
        return String(short.prefix(16)) + effortLabel
    }

    /// Re-locks the model on the gateway session bound to the CURRENT
    /// conversation (each session is its own thread now) and stores the
    /// pair as the default for new sessions.
    ///
    /// The gateway's answer is awaited and surfaced as a system line — a
    /// silently swallowed lock left the UI claiming a switch that never
    /// happened (live 2026-07-29); the local per-session record (what the
    /// composer label shows) is only written once the gateway accepted.
    private func switchSessionModel(provider: String, model: String) {
        hermesSettings.lockProvider = provider
        hermesSettings.lockModel = model
        guard chatStore.conversation.isAgent,
              let sessionID = hermesSettings.sessionID(forConversationKey: chatStore.conversation.storageKey)
        else { return }
        let providerName = hermesAddon.cachedProviders.first { $0.slug == provider }?.name ?? provider
        Task {
            do {
                let locked = try await hermesAddon.transport()
                    .lockModel(sessionID: sessionID, provider: provider, model: model)
                // 0.20: a config `model_routes` alias can silently override
                // the requested provider (picked Codex, got Nous — live
                // 2026-08-13). The 200 carries the truth in `runtime` —
                // record and announce what was ACTUALLY locked, and call the
                // hijack out instead of celebrating the request.
                let hijacked = !locked.provider.isEmpty && locked.provider != provider
                hermesSettings.recordModelLock(
                    provider: hijacked ? locked.provider : provider,
                    model: locked.model.isEmpty ? model : locked.model,
                    forSession: sessionID)
                Diagnostics.log("hermes", "sessionLock.switch ok requested=\(provider)/\(model) locked=\(locked.provider)/\(locked.model) route=\(locked.routeSource) session=\(sessionID)")
                let notice: String
                if hijacked {
                    let lockedName = hermesAddon.cachedProviders
                        .first { $0.slug == locked.provider }?.name ?? locked.provider
                    notice = HL("hermes.lock.rerouted")
                        .replacingOccurrences(of: "%requested%", with: providerName)
                        .replacingOccurrences(of: "%provider%", with: lockedName)
                        .replacingOccurrences(of: "%model%", with: locked.model)
                } else {
                    notice = HL("hermes.lock.switched")
                        .replacingOccurrences(of: "%provider%", with: providerName)
                        .replacingOccurrences(of: "%model%", with: model)
                }
                NotificationCenter.default.post(name: .hermesSystemNotice, object: notice)
            } catch {
                Diagnostics.log("hermes", "sessionLock.switch fail \(provider)/\(model) session=\(sessionID) \(String(error.localizedDescription.prefix(120)))")
                let notice = HL("hermes.lock.switchFailed")
                    .replacingOccurrences(of: "%model%", with: model)
                    .replacingOccurrences(of: "%error%", with: error.localizedDescription)
                NotificationCenter.default.post(name: .hermesSystemNotice, object: notice)
            }
        }
    }

    /// Pin toggle: keeps the panel on screen when it loses focus (the World
    /// Time panel's escape hatch, brought to the chat). Leftmost in normal
    /// mode; between the sidebar toggle and the role chip in agent mode.
    private var pinButton: some View {
        Button {
            settings.panelPinned.toggle()
        } label: {
            Image(systemName: settings.panelPinned ? "pin.fill" : "pin")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(settings.panelPinned ? Color.accentColor : .secondary)
                .frame(height: 20)
        }
        .buttonStyle(PlainButtonStyle())
        .help(settings.panelPinned ? WTL("wt.unpin") : WTL("wt.pin"))
    }

    @ViewBuilder
    private var headerProviderControl: some View {
        if let role = settings.activeAgentRole {
            // Sidebar toggle leads (it controls the column right next to
            // it), then the pin, then the role chip with the connection dot.
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    hermesSettings.setSidebarCollapsed(
                        !hermesSettings.isSidebarCollapsed(roleID: role.id), roleID: role.id)
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(height: 20)
            }
            .buttonStyle(PlainButtonStyle())
            .help(HL("hermes.sidebar.toggle"))
            pinButton
            AgentRoleChip(role: role, state: hermesAddon.connectionState)
                .onTapGesture {
                    // The dot's detail lives in the addon tab.
                    SettingsView.pendingTab = .hermes
                    NotificationCenter.default.post(
                        name: .selectSettingsTab, object: SettingsTab.hermes.rawValue)
                    NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
                }
            // Every file the agent handed over in this conversation —
            // open / reveal without scrolling the transcript.
            Button {
                showAgentFiles.toggle()
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(height: 20)
            }
            .buttonStyle(PlainButtonStyle())
            .help(AGL("agent.files.title"))
            .popover(isPresented: $showAgentFiles, arrowEdge: .bottom) {
                let collected = collectAgentFilePaths()
                AgentChatFilesView(paths: collected.agent, userPaths: collected.user)
                    .environment(\.themePalette, palette)
            }
        } else if availableProviders.count <= 1 {
            // No switcher to show — the pin still needs its corner.
            pinButton
            localFilesButton
        } else {
            pinButton
            localFilesButton
            Menu {
                ForEach(availableProviders) { provider in
                    Button {
                        settings.chatProvider = provider
                        // Loads the provider's model list, or the OpenRouter
                        // catalog for manual entry — never clobbers a
                        // user-typed slug.
                        settings.autoLoadModelsIfNeeded(for: provider)
                    } label: {
                        Label {
                            Text(provider == settings.chatProvider
                                 ? "\(provider.displayName) ✓"
                                 : provider.displayName)
                        } icon: {
                            ProviderLogo(provider: provider, size: 16)
                        }
                    }
                }
            } label: {
                headerControlLabel(
                    text: settings.chatProvider.displayName
                ) {
                    ProviderLogo(provider: settings.chatProvider, size: 12)
                }
            }
            .menuIndicator(.hidden)
            .buttonStyle(PlainButtonStyle())
            .fixedSize()
            .help(L("panel.providerHelp"))
        }
    }

    /// Hermes feedback channel (model-switch confirmed/failed) — one system
    /// line, in agent chats.
    private func handleHermesNotice(_ note: Notification) {
        if chatStore.conversation.isAgent, let notice = note.object as? String {
            chatStore.addMessage(text: notice, isUser: false, messageType: .system)
        }
    }

    /// Ordinary chats' counterpart to the agent's CHAT FILES folder: every
    /// file exchanged with the model in this conversation (attachments,
    /// artifact documents, Plaud recordings).
    private var localFilesButton: some View {
        Button {
            showAgentFiles.toggle()
        } label: {
            Image(systemName: "folder")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .frame(height: 20)
        }
        .buttonStyle(PlainButtonStyle())
        .help(L("chatfiles.help"))
        .popover(isPresented: $showAgentFiles, arrowEdge: .bottom) {
            LocalChatFilesView.collect(from: chatStore.messages)
                .environment(\.themePalette, palette)
        }
    }

    /// Shared look for the header controls: small icon + 11pt secondary text,
    /// vertically centered in a fixed 20pt row so nothing "dances".
    private func headerControlLabel<Icon: View>(
        text: String,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        HStack(spacing: 4) {
            icon()
            Text(text)
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .foregroundColor(.secondary)
        .frame(height: 20)
    }

    // MARK: - Preset switcher (header)

    /// Menu entries for a list of presets; a checkmark marks the active one.
    /// A preset click also leaves the agent role — one list, one gesture.
    @ViewBuilder
    private func presetMenuItems(_ presets: [AppSettings.PromptPreset]) -> some View {
        ForEach(presets) { preset in
            Button {
                settings.activeAgentRoleID = nil
                settings.applyPreset(named: preset.name)
            } label: {
                if preset.name == settings.activePresetName, settings.activeAgentRoleID == nil {
                    Label(preset.name, systemImage: "checkmark")
                } else {
                    Text(preset.name)
                }
            }
        }
    }

    /// Agent roles join the same switcher as one more section — an agent is
    /// "just another role" next to Assistant and Translator (notes §6).
    @ViewBuilder
    private var agentRoleMenuItems: some View {
        let roles = hermesAddon.roles
        if !roles.isEmpty {
            Divider()
            ForEach(roles) { role in
                Button {
                    settings.activeAgentRoleID = role.id
                } label: {
                    Label {
                        Text(role.id == settings.activeAgentRoleID
                             ? "\(role.displayName) ✓"
                             : role.displayName)
                    } icon: {
                        ProviderGlyph(name: role.addonID,
                                      fallbackLetter: String(role.icon.prefix(1)),
                                      size: 16)
                    }
                }
            }
        }
    }

    /// Classic dropdown: icon + active preset (or agent role) name.
    private var presetMenu: some View {
        Menu {
            presetMenuItems(settings.switcherPresets)
            agentRoleMenuItems
        } label: {
            headerControlLabel(
                text: settings.activeAgentRole?.displayName ?? settings.activePresetName
            ) {
                Image(systemName: settings.activeAgentRole == nil
                      ? "person.crop.square" : "brain.head.profile")
                    .font(.system(size: 11))
            }
        }
        .menuIndicator(.hidden)
        .buttonStyle(PlainButtonStyle())
        .fixedSize()
        .help(L("panel.presetHelp"))
    }

    /// Presets beyond the first five collapse into a trailing "…" menu.
    private static let maxVisiblePresetChips = 5

    /// One-click chip row. When the active preset is hidden in the overflow,
    /// the "…" button borrows its icon so the active state stays visible.
    /// Agent roles ride after the presets as emoji chips of the same size.
    private var presetChipsRow: some View {
        let presets = settings.switcherPresets
        let visible = Array(presets.prefix(Self.maxVisiblePresetChips))
        let overflow = Array(presets.dropFirst(Self.maxVisiblePresetChips))
        let roleActive = settings.activeAgentRoleID != nil
        return HStack(spacing: 6) {
            // Agent roles lead the group (leftmost), set off from the
            // preset chips by a hairline — agents are a different kind of
            // thing than prompt presets, the divider says so (e2e feedback
            // 2026-07-25).
            ForEach(hermesAddon.roles) { role in
                Button {
                    settings.activeAgentRoleID = role.id
                } label: {
                    ProviderGlyph(name: role.addonID,
                                  fallbackLetter: String(role.icon.prefix(1)),
                                  size: 14)
                        .opacity(role.id == settings.activeAgentRoleID ? 1 : 0.45)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(PlainButtonStyle())
                .help(role.displayName)
            }
            if !hermesAddon.roles.isEmpty {
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 1, height: 12)
            }
            ForEach(visible) { preset in
                Button {
                    settings.activeAgentRoleID = nil
                    settings.applyPreset(named: preset.name)
                } label: {
                    presetChipIcon(preset, isActive: !roleActive && preset.name == settings.activePresetName)
                }
                .buttonStyle(PlainButtonStyle())
                .help(preset.name)
            }
            if !overflow.isEmpty {
                let hiddenActive = overflow.first { !roleActive && $0.name == settings.activePresetName }
                Menu {
                    presetMenuItems(overflow)
                } label: {
                    if let hiddenActive {
                        presetChipIcon(hiddenActive, isActive: true)
                    } else {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(width: 20, height: 20)
                    }
                }
                .menuIndicator(.hidden)
                .buttonStyle(PlainButtonStyle())
                .fixedSize()
                .help(L("panel.presetHelp"))
            }
        }
        .frame(height: 20)
    }

    /// A 20pt chip: the preset's emoji (grayscale when inactive, colored when
    /// active) or a two-letter fallback in a subtle circle.
    @ViewBuilder
    private func presetChipIcon(_ preset: AppSettings.PromptPreset, isActive: Bool) -> some View {
        if let emoji = settings.presetIcon(named: preset.name) {
            Text(emoji)
                .font(.system(size: 13))
                .grayscale(isActive ? 0 : 1)
                .opacity(isActive ? 1 : 0.65)
                .frame(width: 20, height: 20)
        } else {
            Text(String(preset.name.trimmingCharacters(in: .whitespaces).prefix(2)).uppercased())
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(isActive ? .primary : .secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.secondary.opacity(isActive ? 0.25 : 0.12)))
        }
    }

    private func startNewChat() {
        // A reply still streaming into THIS conversation must not survive the
        // wipe: without the cancel, its next flush would re-append the answer
        // into the fresh chat — an orphan reply to a question just erased.
        if let slot = streamSlots[chatStore.conversation] {
            slot.task?.cancel()
            // Drop the slot (and its live row) NOW — the cancelled task
            // unwinds a beat later, and the fresh chat must not show the
            // orphan bubble for that beat.
            streamSlots.removeValue(forKey: chatStore.conversation)
            chatStore.statusText = nil
            livePill.clear()
            hasLiveSteps = false
            chatStore.setLoading(false)
        }
        // Agent conversation: "new chat" must also mean a NEW gateway
        // session — clearing only the local mirror would leave the agent
        // answering with the old context, which reads as a haunted chat.
        // The next send creates a fresh session; the role's "which session
        // is open" memory resets to the default thread.
        if chatStore.conversation.isAgent {
            HermesSettings.shared.unbindSession(forConversationKey: chatStore.conversation.storageKey)
            if let role = role(for: chatStore.conversation) {
                HermesSettings.shared.setActiveSession(nil, roleID: role.id)
            }
            agentGatewayOffline = false
        }
        chatStore.clearMessages()
        chatStore.addMessage(text: welcomeText(), isUser: false)
    }

    /// Whether an agent turn is currently streaming into the ON-SCREEN
    /// conversation (drives the send→stop button swap).
    private var agentTurnInFlight: Bool {
        chatStore.conversation.isAgent
            && currentStreamSlot != nil
            && chatStore.isLoading
    }

    /// Stop button in the thinking pill (agent turns): cancels our stream —
    /// the cancellation path fires `session.abort()`, which stops the run on
    /// the gateway too. The last ~1s checkpoint of the partial reply stays
    /// in the store; a catch-up moments later pulls whatever the gateway
    /// recorded for the interrupted turn.
    private func stopAgentTurn() {
        guard let slot = streamSlots[chatStore.conversation] else { return }
        slot.task?.cancel()
        streamSlots.removeValue(forKey: chatStore.conversation)
        pendingAgentApproval = nil
        chatStore.statusText = nil
        livePill.clear()
        hasLiveSteps = false
        chatStore.setLoading(false)
        chatStore.addMessage(text: AGL("agent.stopped"), isUser: false, messageType: .system)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            runAgentCatchUpIfNeeded()
        }
    }

    // MARK: - Agent mirror sync

    /// Kicks a catch-up sync for the on-screen agent conversation; flips the
    /// offline plaque on failure.
    private func runAgentCatchUpIfNeeded() {
        guard chatStore.conversation.isAgent,
              let role = role(for: chatStore.conversation) else {
            agentGatewayOffline = false
            return
        }
        Task { @MainActor in
            let conversation = chatStore.conversation
            let reachable = await HermesMirrorSync.catchUp(role: role, store: chatStore)
            // The conversation may have moved on during the fetch. Compared
            // against the conversation the sync RAN FOR, not the role's
            // default thread: a chat opened from the sessions list is
            // `.agent(role, session:)` and never equalled the bare
            // `role.conversationID`, so neither the offline plaque nor the
            // read receipt ever fired for it.
            if chatStore.conversation == conversation {
                agentGatewayOffline = !reachable
                // Catch-up runs at every "came back to look" moment (panel
                // shown, conversation switched) and may itself have pulled
                // fresh rows — what's on screen now counts as read.
                if reachable,
                   let sessionID = hermesSettings.sessionID(forConversationKey: chatStore.conversation.storageKey) {
                    await hermesAddon.markSessionRead(sessionID)
                }
            }
        }
    }

    /// "Continue here": opens the chosen gateway session AS ITS OWN
    /// conversation (own store, own streaming isolation — switching away
    /// leaves any in-flight reply finishing into its home thread, exactly
    /// like isolated presets). Nothing is cleared or replaced.
    private func continueHermesSession(_ sessionID: String) {
        // Ensure an agent role is active (the first one when none is).
        if settings.activeAgentRole == nil {
            guard let first = hermesAddon.roles.first else { return }
            settings.activeAgentRoleID = first.id
        }
        guard let role = settings.activeAgentRole else { return }
        let conversation = role.conversationID(sessionID: sessionID)
        HermesSettings.shared.bindSession(sessionID, toConversationKey: conversation.storageKey)
        HermesSettings.shared.setActiveSession(sessionID, roleID: role.id)
        syncConversation()
        runAgentCatchUpIfNeeded()
        NotificationCenter.default.post(name: .chatWindowDidBecomeVisible, object: nil)
    }

    // MARK: - Isolated preset chats

    /// The conversation the active preset (or agent role) should be showing.
    /// An active agent role wins: its isolation is forced, not a toggle —
    /// the conversation also lives on the agent's side (notes §6). Which of
    /// the role's SESSIONS is open comes from the addon's per-role memory:
    /// each session is its own conversation (full stream isolation).
    private func targetConversation() -> ChatStore.ConversationID {
        if let role = settings.activeAgentRole {
            return role.conversationID(sessionID: hermesSettings.activeSession(roleID: role.id))
        }
        return settings.isPresetIsolated(named: settings.activePresetName)
            ? .preset(settings.activePresetName)
            : .general
    }

    /// Resolves the role that owns a conversation — from the addon's live
    /// role list when possible, else reconstructed from the id so an
    /// in-flight reply can finish even after the role list changed.
    private func role(for conversation: ChatStore.ConversationID) -> AgentRole? {
        guard case .agent(let addonID, let agentID, _) = conversation else { return nil }
        let id = AgentRole.makeID(addonID: addonID, agentID: agentID)
        if let live = HermesAddon.shared.roles.first(where: { $0.id == id }) { return live }
        return AgentRole(id: id, addonID: addonID, agentID: agentID,
                         displayName: agentID, icon: "🤖")
    }

    /// Aligns the store's conversation with the active preset. An in-flight
    /// reply is NOT interrupted: it keeps streaming in the background and is
    /// delivered into its origin chat (see `streamAssistantReply`).
    /// Idempotent — cheap to call from multiple observers.
    private func syncConversation() {
        let target = targetConversation()
        guard target != chatStore.conversation else { return }
        chatStore.switchConversation(to: target)
        // The just-opened agent thread is read NOW — its badge must not
        // wait for the sidebar's 30s watermark poll (report 2026-07-31).
        if case .agent = target,
           let sessionID = hermesSettings.sessionID(forConversationKey: target.storageKey) {
            Task { await hermesAddon.markSessionRead(sessionID) }
        }
    }

    /// A custom preset was deleted: its dormant chat file + media go away.
    /// If that chat is on screen, leave it first (applyPreset has already
    /// moved the active preset back to a built-in one).
    private func handlePresetDeleted(_ name: String) {
        let deletedID = ChatStore.ConversationID.preset(name)
        // A reply streaming FOR the deleted chat — live or background — is
        // discarded: cancellation makes the stream task skip delivery, so it
        // cannot resurrect the deleted file.
        if let slot = streamSlots[deletedID] {
            slot.task?.cancel()
            streamSlots.removeValue(forKey: deletedID)
        }
        if chatStore.conversation == deletedID {
            Task { @MainActor in
                if chatStore.conversation == deletedID {
                    chatStore.switchConversation(to: targetConversation())
                }
                // Enqueued on the store's serial disk queue AFTER the switch's
                // flush — the deletion also removes the just-flushed file.
                ChatStore.deleteConversationData(presetNamed: name)
            }
        } else {
            ChatStore.deleteConversationData(presetNamed: name)
        }
    }

    /// Whether the "Thinking…" pill is currently in the list. An agent turn
    /// with steps in flight keeps it up even once the reply text is flowing —
    /// the pill IS the live step journal, and Hermes commonly interleaves
    /// interim text with more tool work.
    private var showThinkingIndicator: Bool {
        if externalTurn != nil { return true }
        return chatStore.isLoading
            && (chatStore.statusText != nil || hasLiveSteps
                || chatStore.messages.last?.isUser == true)
    }

    /// A turn this process is NOT streaming: the gateway is mid-run for the
    /// open conversation (someone sent from the phone, or our own run
    /// outlived a relaunch — the slot died with the process, the run did
    /// not). Our own stream always wins: while a slot exists the pill
    /// belongs to it, and the mirror is deliberately blind mid-turn anyway.
    /// Mirrors a gateway-run turn's journal into the pill's model. Those
    /// arrive on mirror polls (seconds apart), not per token, so copying is
    /// cheap — and going through the model keeps the transcript row out of
    /// the rebuild, exactly as the local stream does.
    private func syncExternalTurnPill() {
        guard let turn = externalTurn else { return }
        // No id on the turn itself, and `lastRowAt` moves with every poll —
        // keying on that would restart the turn (and snap the journal shut)
        // on each one. The FIRST step's id is stable for the run and differs
        // between runs; before any step lands there is nothing to keep open.
        let turnID = "external|" + (turn.steps.first?.id
            ?? String(turn.lastRowAt.timeIntervalSince1970))
        if livePill.turnID != turnID {
            livePill.begin(turnID: turnID,
                           status: AGL("agent.status.external"),
                           steps: turn.steps)
        } else {
            livePill.steps = turn.steps
        }
        hasLiveSteps = !turn.steps.isEmpty
    }

    private var externalTurn: HermesLiveTurn? {
        guard chatStore.conversation.isAgent, currentStreamSlot == nil else { return nil }
        return hermesAddon.liveTurn(forConversationKey: chatStore.conversation.storageKey)
    }

    /// Widens the history window by one page when the user nears the top
    /// (the engine calls this and re-anchors the viewport itself, so the
    /// prepended rows never move what the user is reading). Two tiers:
    /// first widen over the in-memory history; once that is exhausted,
    /// page older rows in from the store (ChatStore keeps only a suffix
    /// window loaded).
    private func loadOlderMessages() {
        guard !isBackfilling else { return }
        if chatStore.messages.count - bottomDropCount > visibleCount {
            isBackfilling = true
            growVisibleWindow(by: Self.historyPageSize)
        } else if chatStore.hasOlderMessages {
            isBackfilling = true
            chatStore.loadOlderPage(Self.historyPageSize) { added in
                if added > 0 {
                    growVisibleWindow(by: added)
                } else {
                    DispatchQueue.main.async { isBackfilling = false }
                }
            }
        }
    }

    /// Rows a single trickle step prepends (see `growVisibleWindow`).
    private static let backfillChunk = 5

    /// Widens the window a few rows per runloop tick instead of a whole page
    /// per frame. A 30-row prepend meant 30 fresh hosting views (markdown +
    /// layout each) plus a full-stack Auto Layout pass inside ONE frame —
    /// repeatedly while the user kept scrolling up, which read as the
    /// transcript freezing in agent chats (their rows are the heavy ones).
    /// The engine re-anchors every prepend, so the trickle is invisible;
    /// `isBackfilling` stays up until the target lands, keeping `onNeedOlder`
    /// from stacking a second page mid-trickle. A conversation switch (or a
    /// summon reset) aborts silently — the new chat starts its own window.
    ///
    /// Past `maxLiveRows` the window SLIDES instead of growing: every row
    /// gained on top retires one off the bottom (`bottomDropCount`), so the
    /// live-view population stays bounded no matter how deep the scroll.
    /// Bottom removals sit below the viewport — nothing the user sees moves.
    private func growVisibleWindow(by total: Int) {
        let conversation = chatStore.conversation.storageKey
        var remaining = total
        var expectedVisible = visibleCount
        var expectedDrop = bottomDropCount
        func step() {
            // A conversation switch or a summon reset rewrote the window out
            // from under the trickle — the reset wins, the trickle stops.
            guard chatStore.conversation.storageKey == conversation,
                  visibleCount == expectedVisible,
                  bottomDropCount == expectedDrop else {
                isBackfilling = false
                return
            }
            let hiddenAbove = chatStore.messages.count - bottomDropCount - visibleCount
            let add = min(Self.backfillChunk, remaining, max(0, hiddenAbove))
            guard add > 0 else {
                isBackfilling = false
                return
            }
            visibleCount += add
            if visibleCount > Self.maxLiveRows {
                bottomDropCount += visibleCount - Self.maxLiveRows
                visibleCount = Self.maxLiveRows
            }
            remaining -= add
            expectedVisible = visibleCount
            expectedDrop = bottomDropCount
            DispatchQueue.main.async { step() }
        }
        step()
    }

    /// Downward counterpart of `loadOlderMessages`: nearing the window's
    /// BOTTOM edge while newest rows are dropped slides the window back down
    /// one page (same trickle, same cap — rows re-enter at the bottom, the
    /// oldest retire off the top). No store round-trip: the dropped rows are
    /// still in `chatStore.messages`.
    private func restoreNewerRows() {
        guard !isBackfilling, bottomDropCount > 0 else { return }
        isBackfilling = true
        let conversation = chatStore.conversation.storageKey
        var remaining = Self.historyPageSize
        var expectedDrop = bottomDropCount
        func step() {
            guard chatStore.conversation.storageKey == conversation,
                  bottomDropCount == expectedDrop else {
                isBackfilling = false
                return
            }
            let restore = min(Self.backfillChunk, remaining, bottomDropCount)
            guard restore > 0 else {
                isBackfilling = false
                return
            }
            bottomDropCount -= restore
            remaining -= restore
            expectedDrop = bottomDropCount
            DispatchQueue.main.async { step() }
        }
        step()
    }

    /// Back to the newest message from ANY depth: rebuilds the window as the
    /// plain newest page (sliding hundreds of rows through the cap would be
    /// pure churn) and pins to the bottom.
    private func jumpToLatest(animated: Bool) {
        if bottomDropCount > 0 || visibleCount > Self.historyPageSize {
            bottomDropCount = 0
            visibleCount = Self.historyPageSize
        }
        transcriptController.scrollToBottom(animated: animated)
    }

    /// Stores the probed viewport width; persisted so the next launch's first
    /// layout starts from the real width instead of the fallback.
    private func updateContainerWidth(_ width: CGFloat) {
        guard width > 0, width != bubbleContainerWidth else { return }
        bubbleContainerWidth = width
        UserDefaults.standard.set(Double(width), forKey: Self.containerWidthDefaultsKey)
    }

    // MARK: - Sending

    /// Verifies the active chat provider is configured; posts a hint otherwise.
    private func ensureChatConfigured() -> Bool {
        // Key lookups are cache-only. In the first moments of a session the
        // cache may still be filling (or waiting on authorization), and
        // answering "no key" there would be a lie — the send path awaits the
        // warm and reports a real, specific error if the key is truly missing.
        guard APIKeyStore.isWarm else { return true }
        // Agent role: the addon owns configuration — no provider key or
        // model selection applies. A missing token answers with a pointer
        // to the addon tab; liveness errors surface per-send with the
        // structured probe message.
        if settings.activeAgentRole != nil {
            guard HermesAddon.shared.isAvailable else {
                chatStore.addMessage(text: HL("hermes.noKey"),
                                     isUser: false, messageType: .system)
                SettingsView.pendingTab = .hermes
                NotificationCenter.default.post(
                    name: .selectSettingsTab, object: SettingsTab.hermes.rawValue)
                NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
                return false
            }
            return true
        }
        guard settings.isAvailable(settings.chatProvider) else {
            chatStore.addMessage(text: L("panel.noProviderKey"), isUser: false, messageType: .system)
            return false
        }
        let model = settings.selectedModel(for: settings.chatProvider)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let model, !model.isEmpty else {
            chatStore.addMessage(text: L("panel.noModelSelected"), isUser: false, messageType: .system)
            return false
        }
        return true
    }

    /// True when there is nothing to send: no instruction, no quote and no
    /// attachment. An attachment alone is sendable — preset system prompts
    /// (e.g. a translator chat) act on the bare image without any typed text.
    private var composerIsEmpty: Bool {
        messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && quotedText == nil
            && pendingAttachments.isEmpty
            && pendingAgentFilePaths.isEmpty
    }

    private func sendMessage() {
        // ImageAddon slash commands (/upscale, /bg, /cleanup) act on the
        // pending attachment instead of being sent as chat text. Behind the
        // Hermes opt-in in agent conversations — there a "/..." the app
        // doesn't claim goes to the agent as an ordinary message.
        if imageFeaturesAllowed, pendingAttachments.count <= 1, ImageSlashCommands.handle(
            input: messageText,
            attachment: pendingAttachments.first,
            chatStore: chatStore,
            clearAttachment: clearPendingAttachments
        ) {
            messageText = ""
            return
        }

        // The quote region (if any) becomes a markdown blockquote in the
        // outgoing text; on screen it was a styled block without markers.
        var text = SelectionGrabber.message(quote: quotedText, instruction: messageText)

        // Attachment-only sends are allowed: the image goes to the model as
        // is and the conversation's system prompt drives what happens to it.
        // Providers already handle the empty text (vision → image block only,
        // non-vision → OCR text is injected in buildLLMMessages).
        guard !text.isEmpty || !pendingAttachments.isEmpty else { return }
        guard ensureChatConfigured() else {
            messageText = ""
            quotedText = nil
            return
        }

        // Agent mode with files: the courier resolves the paths first —
        // local gateway keeps them as-is, a REMOTE one gets the files
        // uploaded through the dashboard API and the note lists the remote
        // paths (Hermes' API server itself takes no file inputs).
        // Images go the same way (since 4.4): the gateway keeps no pixels, so
        // a photo sent here reaches the OTHER surfaces as a bare
        // "[screenshot]" unless a real file lands on the agent's host. The
        // note must be part of the LOCAL message too — appending it deeper in
        // the send made our bubble and the gateway's row differ, and the
        // mirror inserted the gateway's copy as a duplicate (e2e 2026-07-27).
        let hasAgentImages = settings.activeAgentRole != nil
            && HermesSettings.shared.isRemoteGateway
            && HermesSettings.shared.dashboardBaseURL != nil
            && pendingAttachments.contains { $0.mimeType.hasPrefix("image") }
        if settings.activeAgentRole != nil, !pendingAgentFilePaths.isEmpty || hasAgentImages {
            let paths = pendingAgentFilePaths
            pendingAgentFilePaths = []
            let baseText = text
            let attachments = pendingAttachments
            Task { @MainActor in
                var noteBlocks: [String] = []
                if !paths.isEmpty {
                    let delivery = await HermesFileCourier.deliver(paths: paths)
                    noteBlocks.append(delivery.note)
                    if let warning = delivery.warning {
                        chatStore.addMessage(text: warning, isUser: false, messageType: .system)
                    }
                }
                // Uploads run off the pixels we already hold; a failure is
                // silent by design — the image still reaches the model inline.
                var imagePaths: [String] = []
                for attachment in attachments where attachment.mimeType.hasPrefix("image") {
                    guard let data = Data(base64Encoded: attachment.contentBase64) else { continue }
                    if let remote = await HermesFileCourier.uploadBytes(
                        data, filename: attachment.filename
                    ) {
                        imagePaths.append(remote)
                    }
                }
                if !imagePaths.isEmpty {
                    noteBlocks.append(HermesFileCourier.note(for: imagePaths))
                }
                let full = ([baseText] + noteBlocks)
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
                performSend(text: full, attachments: attachments)
            }
            return
        }

        // Local provider: if the selected model isn't in memory, sending would
        // implicitly load it (time + RAM) — confirm first. Otherwise send now.
        // Not for agent roles: chatProvider is dormant there.
        if settings.chatProvider.isLocal, settings.activeAgentRole == nil {
            let attachments = pendingAttachments
            confirmLocalModelIfNeeded { performSend(text: text, attachments: attachments) }
            return
        }
        performSend(text: text, attachments: pendingAttachments)
    }

    /// Whether a follow-up typed right now should STEER the running agent
    /// turn instead of opening a competing one: an agent conversation with a
    /// turn in flight (ours or one detected on the gateway — phone/CLI), a
    /// steer-capable gateway (the Cuate 0.20 patch advertises
    /// `session_steer`), and a text-only send (the steer channel is text —
    /// attachments keep the pre-steer behavior).
    private func shouldSteer(attachments: [ChatAttachment]) -> Bool {
        guard chatStore.conversation.isAgent,
              attachments.isEmpty,
              agentTurnInFlight || externalTurn != nil,
              HermesSettings.shared.sessionID(
                  forConversationKey: chatStore.conversation.storageKey) != nil
        else { return false }
        return steerRoute() != nil
    }

    /// Which steer channel this turn can take, if any.
    /// - `.run` — upstream `POST /v1/runs/{id}/steer` (`features.run_steer`,
    ///   Hermes v2026.8.13+). Needs a run id, so it covers OUR streaming
    ///   turn only.
    /// - `.session` — the legacy Cuate gateway patch (`features.session_steer`),
    ///   addressed by session id. Kept as the fallback: it is what steers a
    ///   turn started ELSEWHERE (phone/CLI), where no run id ever reaches us.
    private enum SteerRoute { case run(String), session }
    private func steerRoute() -> SteerRoute? {
        let caps = HermesAddon.shared.capabilities
        if caps?.supports("run_steer") == true,
           let runID = HermesAddon.shared.activeRunID(
               conversationKey: chatStore.conversation.storageKey) {
            return .run(runID)
        }
        if caps?.supports("session_steer") == true { return .session }
        return nil
    }

    /// Mid-turn follow-up: the bubble lands in the chat as usual, the text
    /// rides into the RUNNING turn via `/steer` (the agent sees it on its
    /// next tool-batch boundary). When the turn is already over by the time
    /// the request lands (409) — or the gateway balks — the text goes out as
    /// an ordinary new turn instead: the bubble is already in the store, so
    /// the fallback only starts the stream.
    private func performSteer(text: String) {
        let conversationKey = chatStore.conversation.storageKey
        guard let sessionID = HermesSettings.shared.sessionID(forConversationKey: conversationKey),
              let route = steerRoute() else { return }
        chatStore.appendNow(ChatMessage(text: text, isUser: true))
        messageText = ""
        quotedText = nil
        clearPendingAttachments()
        Task { @MainActor in
            do {
                let transport = HermesAddon.shared.transport()
                let queued: Bool
                switch route {
                case .run(let runID):
                    queued = try await transport.steerRun(runID: runID, text: text)
                    Diagnostics.log("hermes", "steer run=\(runID) accepted=\(queued)")
                case .session:
                    queued = try await transport.steer(sessionID: sessionID, text: text)
                    Diagnostics.log("hermes", "steer session=\(sessionID) queued=\(queued)")
                }
                guard queued else {
                    streamAssistantReply() // agent refused — ordinary turn
                    return
                }
                // Queued into the running turn. The pill keeps streaming;
                // the reply to this follow-up arrives within the same turn.
            } catch {
                // The turn ended under us (404 run_not_found / 409
                // run_not_accepting_steer upstream, 409 no_active_turn on the
                // patched route), or any transport failure: deliver as a
                // normal turn so the message is never lost. The user bubble
                // is already on screen.
                Diagnostics.log("hermes", "steer fallback: \(String(error.localizedDescription.prefix(120)))")
                streamAssistantReply()
            }
        }
    }

    /// Appends the user message and streams the reply, clearing the composer.
    /// The whole staged batch rides on ONE message — providers turn each
    /// attachment into a vision content part (or OCR text for non-vision
    /// models) in `buildMessages`.
    private func performSend(text: String, attachments: [ChatAttachment]) {
        // Agent turn already running → steer it instead of racing it.
        if shouldSteer(attachments: attachments) {
            performSteer(text: text)
            return
        }
        // An attachment restored from an existing chat message (ImageAddon
        // "continue editing") already owns a store row; posting the
        // same id again would collide with the unique index and persist an
        // attachment-less message — re-wrap with a fresh identity.
        let posted = attachments.map {
            ImageOperations.isRestoredFromChat($0) ? ImageOperations.freshCopyForPosting($0) : $0
        }
        let userMessage = ChatMessage(text: text, isUser: true, attachments: posted)
        chatStore.appendNow(userMessage)
        messageText = "" // the editor re-measures itself back to one line
        quotedText = nil
        clearPendingAttachments()
        streamAssistantReply()
    }

    /// For a local (Ollama) provider: refreshes the loaded state, and if the
    /// selected model isn't in memory, asks before loading it — loading a local
    /// model costs time and RAM. On confirm runs `send`; on cancel guides the
    /// user to switch provider or pick a model that's already loaded.
    private func confirmLocalModelIfNeeded(_ send: @escaping () -> Void) {
        let model = settings.selectedModel(for: .ollama) ?? ""
        Task { @MainActor in
            let admin = OllamaAdminService(endpointURL: settings.localEndpointURL)
            await settings.refreshOllamaLoaded(using: admin)
            if model.isEmpty || settings.ollamaLoadedModels.contains(model) {
                send()
                return
            }
            // Not in memory → ask in-chat (assistant-style bubble with buttons).
            let prompt = String(format: L("local.start.confirm.message"), model)
            pendingLocalStart = PendingLocalStart(prompt: prompt, send: send)
        }
    }

    /// The in-chat confirmation: an assistant-style bubble carrying the prompt
    /// and Start/Cancel buttons. Start runs the deferred send (which loads the
    /// model); Cancel clears it and drops a hint to switch provider/model.
    @ViewBuilder
    private func localStartConfirmBubble(_ pending: PendingLocalStart) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 10) {
                Text(pending.prompt)
                    .font(.system(size: 13, design: palette.fontDesign))
                    .foregroundColor(palette.isGlass ? .primary : palette.ink)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 8) {
                    Button(L("local.start.confirm.yes")) {
                        let send = pending.send
                        pendingLocalStart = nil
                        send()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)
                    Button(L("local.start.confirm.no")) {
                        pendingLocalStart = nil
                        chatStore.addMessage(text: L("local.start.confirm.declined"),
                                             isUser: false, messageType: .system)
                    }
                    .buttonStyle(.bordered)
                    .tint(palette.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .modifier(ThemedBubble(palette: palette, isUser: false))
            .shadow(color: Color.black.opacity(0.10), radius: 2.5, x: 0, y: 1)
            .frame(maxWidth: max(320, bubbleContainerWidth * 0.75), alignment: .leading)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    /// Streams the assistant reply for the current history into the chat,
    /// then triggers best-effort context compression.
    private func streamAssistantReply(
        /// Stream for THIS conversation instead of the on-screen one: a
        /// voice send whose transcription outlived a chat switch starts its
        /// reply already detached — the slot/delivery machinery below treats
        /// it exactly like a mid-stream switch. History + summary must come
        /// along (the store only holds the ON-SCREEN chat's context).
        for originOverride: ChatStore.ConversationID? = nil,
        history historyOverride: [ChatMessage]? = nil,
        summary summaryOverride: String? = nil
    ) {
        // The conversation this reply belongs to. If the user switches to
        // another preset chat mid-stream, generation continues in the
        // background and the reply is delivered back to this one. The slot
        // is keyed by it — parallel streams in OTHER conversations keep
        // their own slots untouched.
        let origin = originOverride ?? chatStore.conversation
        if origin == chatStore.conversation {
            chatStore.setLoading(true)
            chatStore.statusText = nil
            // Each turn starts collapsed; expanding is the user's call.
            livePill.begin(turnID: origin.storageKey + "|" + String(Date().timeIntervalSince1970),
                           status: nil, steps: [])
            hasLiveSteps = false
            pendingRetry = nil
        }
        let history = historyOverride ?? chatStore.activeContextMessages
        let summary = summaryOverride ?? chatStore.conversationSummary

        // Fresh live buffer per stream: an older background stream keeps its
        // own instance and can't write into this one's bubble.
        let live = StreamingReplyModel()
        streamSlots[origin] = StreamSlot(task: nil, live: live)

        let task = Task { @MainActor in
            // Whether this stream still owns its conversation's slot (a
            // stop/new-chat/delete may have retired it mid-flight).
            var owns: Bool { streamSlots[origin]?.live === live }
            // Local canonical copy of the reply (stable UUID). The LIVE
            // transcript renders from `live` (frozen segments + short tail,
            // O(chunk) per flush — see StreamingReplyModel); the STORE sees
            // the reply only as ~1 Hz persistence checkpoints plus the final
            // delivery. A flush re-publishes no list and re-parses no
            // already-final text, which is what lets it run at 30 Hz.
            var reply: ChatMessage?
            var isLive: Bool { chatStore.conversation == origin }
            // Whether the on-screen store currently holds the reply row
            // (false while detached; re-checked once on each return).
            var storeRowInSync = false
            var pendingText = ""
            var lastFlush = ContinuousClock.now
            var lastCheckpoint = ContinuousClock.now
            // One line per turn, max — see the invisible-prefix guard in flush().
            var loggedInvisiblePrefix = false
            // Tool-produced chips (Plaud notes) buffered until delivery —
            // they arrive mid-turn, usually BEFORE any reply text exists to
            // hang them on.
            var pendingChipAttachments: [ChatAttachment] = []

            // Persistence checkpoint: the partial reply lands in the store
            // (whose debounced save persists it) about once a second, so a
            // crash or force-quit mid-stream loses ~1s of text — the same
            // retention the old per-flush sync gave, at a fraction of the
            // publishes. Also exactly what a mid-stream return to this chat
            // reloads from disk. Cancellation (new chat / preset deleted)
            // must not write the partial back.
            func checkpoint() {
                guard !Task.isCancelled,
                      let current = reply, isLive, chatStore.isHistoryLoaded,
                      lastCheckpoint.duration(to: .now) > .seconds(1) else { return }
                lastCheckpoint = .now
                if chatStore.messages.contains(where: { $0.id == current.id }) {
                    chatStore.setText(current.text, for: current.id)
                } else {
                    // Returned mid-stream: the reloaded history holds only
                    // the last checkpointed partial — or none of it.
                    chatStore.appendNow(current)
                }
            }

            func flush() {
                guard !pendingText.isEmpty else { return }
                if var current = reply {
                    current.text += pendingText
                    reply = current
                } else {
                    // Only VISIBLE content materializes the bubble: models
                    // open a message with a bare "\n"/"\n\n" delta (Hermes —
                    // see its API fixtures; kimi-k3 in plain chat, 2026-07-28
                    // 18:20 in the diagnostics log) and then think/run tools
                    // for seconds-to-minutes — flushing on that parked an
                    // EMPTY bubble on screen for the whole phase. The
                    // whitespace stays buffered and rides out with the first
                    // real text.
                    guard !pendingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        // Escaped so the exact invisible bytes are readable;
                        // if an "empty bubble" report ever comes back, this
                        // line says what the provider actually sent.
                        if !loggedInvisiblePrefix {
                            loggedInvisiblePrefix = true
                            Diagnostics.log("chat", "live.buffer invisible prefix \(String(reflecting: pendingText.prefix(60)))")
                        }
                        return
                    }
                    let first = ChatMessage(text: pendingText, isUser: false)
                    reply = first
                    // Text is flowing — the tool/thinking phase is over. The
                    // stub arms the live row even while DETACHED: returning
                    // to this chat then renders the growing bubble at once,
                    // not on the next flush.
                    if owns {
                        streamSlots[origin]?.awaitingText = false
                        // …but an agent turn still taking steps keeps its
                        // status: the pill stays up as the step journal, and
                        // returning to this chat must put it back.
                        if streamSlots[origin]?.liveSteps.isEmpty ?? true {
                            streamSlots[origin]?.lastStatus = nil
                        }
                        streamSlots[origin]?.stub = first
                    }
                    if isLive, chatStore.isHistoryLoaded, !Task.isCancelled, owns {
                        // Materialize the store row the moment text flows
                        // (masked while streaming — persistence and API
                        // context see it); the live row renders in its place.
                        chatStore.appendNow(first)
                        storeRowInSync = true
                    } else {
                        // Telemetry for the "bubble freezes then pops" hunt:
                        // an unarmed live row renders at ~1 Hz checkpoint
                        // cadence instead of streaming.
                        Diagnostics.log("chat", "live.unarmed isLive=\(isLive) historyLoaded=\(chatStore.isHistoryLoaded) sameModel=\(owns)")
                    }
                }
                // Mid-stream return: the reply may have materialized while
                // ANOTHER chat was on screen (the branch above skipped the
                // store row). Once the origin is back, give the store its
                // masked copy — the live row is already armed via the slot.
                // `storeRowInSync` keeps the contains() scan off the 30 Hz
                // flush path: it runs once per return, not per chunk.
                if !isLive {
                    storeRowInSync = false
                } else if !storeRowInSync, let current = reply,
                          chatStore.isHistoryLoaded, !Task.isCancelled, owns {
                    if !chatStore.messages.contains(where: { $0.id == current.id }) {
                        chatStore.appendNow(current)
                    }
                    storeRowInSync = true
                }
                live.append(pendingText)
                pendingText = ""
                lastFlush = .now
                checkpoint()
            }
            do {
                // Auto-continuation: the model may end a round with a
                // trailing `<continue/>` marker (taught in the mandatory
                // prompt rules) — "I need another working round". The marker
                // is stripped, a hidden "Continue." user turn is appended to
                // the REQUEST (never to the chat), and the next round streams
                // into the SAME bubble with a fresh tool budget. Bounded so a
                // marker-happy model can't loop forever.
                var requestHistory = history
                var round = 0
                var lastRoundText = ""
                // Agent conversation → the agent pipeline: one turn over the
                // wire, context lives on the gateway. Everything below (live
                // bubble, checkpoints, delivery) is shared with normal turns.
                let agentRole = role(for: origin)
                roundLoop: while true {
                let stream: AsyncThrowingStream<ChatService.ChatEvent, Error>
                if let agentRole {
                    stream = AgentChatService.streamReply(role: agentRole, conversation: origin,
                                                          history: requestHistory, store: chatStore)
                } else {
                    stream = try await ChatService.streamReply(history: requestHistory, summary: summary, store: chatStore)
                }
                for try await event in stream {
                    switch event {
                    case .text(let chunk):
                        pendingText += chunk
                        // Text is flowing — the thinking/search pill must go
                        // away (otherwise it lingers *below* the growing
                        // answer bubble, since it renders after the messages).
                        // Only VISIBLE text counts: a leading "\n\n" delta
                        // must not kill the pill before there is a bubble —
                        // that left the chat looking dead until the next
                        // status event.
                        //
                        // Agent turns with a live step journal are the
                        // exception: the pill carries the steps, and killing
                        // it on the agent's "let me check…" would hide every
                        // tool it runs afterwards.
                        if isLive, chatStore.statusText != nil, !hasLiveSteps,
                           reply != nil || !pendingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            chatStore.statusText = nil
                        }
                        // The first chunk flushes immediately so the bubble
                        // appears the moment text starts flowing.
                        //
                        // 30 Hz cadence: a flush costs O(chunk) now (the live
                        // row is outside the list; final text is frozen), so
                        // small frequent steps are what makes the growth read
                        // as continuous — no scroll animation needed. The one
                        // exception is a long UNCLOSED fence (an artifact
                        // generating): the whole fence stays in the re-parsed
                        // tail, so those throttle back to the old 8 Hz to
                        // bound the per-flush parse.
                        let interval: Duration = live.tail.utf8.count > 8192
                            ? .milliseconds(120)
                            : .milliseconds(33)
                        if reply == nil || lastFlush.duration(to: .now) > interval {
                            flush()
                        }
                    case .status(let status):
                        flush() // keep text/status ordering intact
                        if owns { streamSlots[origin]?.lastStatus = status }
                        if isLive {
                            livePill.status = status
                            chatStore.statusText = status
                        }
                    case .agentStepsLive(let steps):
                        flush() // same ordering rule as .status
                        if owns { streamSlots[origin]?.liveSteps = steps }
                        if isLive {
                            livePill.steps = steps
                            hasLiveSteps = !steps.isEmpty
                        }
                    case .toolContext(let context):
                        // Arrives once per round, at its end. Stored on the
                        // reply (never rendered) so follow-up turns keep the
                        // search results as grounding. Rounds accumulate;
                        // the suffix cap keeps the freshest grounding.
                        flush() // materialize `reply` if text is still pending
                        if var current = reply {
                            let merged = [current.toolContext, context]
                                .compactMap { $0 }
                                .joined(separator: "\n\n")
                            current.toolContext = String(merged.suffix(6000))
                            reply = current
                        }
                    case .attachments(let list):
                        // Tool-produced chips (Plaud notes). Buffered, not
                        // attached: the reply bubble may not exist yet (tools
                        // run before the answer text). Deduped by payload
                        // path — the model re-reading the same note must not
                        // double the chip row. Merged into the reply at
                        // delivery below.
                        let existing = Set(pendingChipAttachments.compactMap(\.fileURLString))
                        pendingChipAttachments += list.filter {
                            $0.fileURLString.map { !existing.contains($0) } ?? true
                        }
                    case .replaceText(let full):
                        // Agent turns: the authoritative full text — replaces
                        // whatever streamed (deltas differ in whitespace, or
                        // never came at all). Same mechanics as the
                        // continue-marker strip below.
                        pendingText = ""
                        if var current = reply {
                            current.text = full
                            reply = current
                            if owns { live.setFullText(full) }
                            if isLive, chatStore.isHistoryLoaded,
                               chatStore.messages.contains(where: { $0.id == current.id }) {
                                chatStore.setText(full, for: current.id)
                            }
                        } else {
                            // No bubble yet (no deltas): materialize through
                            // the normal first-flush path.
                            pendingText = full
                            flush()
                        }
                    case .agentSteps(let summary):
                        // Persisted tool-step journal for the reply; the
                        // final delivery below writes it to the store.
                        flush()
                        if var current = reply {
                            current.agentSteps = summary
                            reply = current
                        }
                    case .agentApproval(let approval, let resolve):
                        flush()
                        if isLive {
                            pendingAgentApproval = PendingAgentApproval(approval: approval, resolve: resolve)
                            transcriptController.scrollToBottom(animated: true)
                        }
                    }
                }
                flush()
                // A turn that ended (either way) retires its approval card —
                // the gateway resolved or timed it out on its side.
                if pendingAgentApproval != nil { pendingAgentApproval = nil }

                // Continuation round? Only when the model asked for one, the
                // budget allows, and the round actually added text (a
                // marker-only round would spin without progress). Agent turns
                // never continue — the marker contract is ours, not theirs.
                if !Task.isCancelled, agentRole == nil, round < Self.maxAutoContinues,
                   var current = reply {
                    let (stripped, wantsMore) = Self.strippingContinueMarker(current.text)
                    if wantsMore, stripped != lastRoundText, !stripped.isEmpty {
                        lastRoundText = stripped
                        round += 1
                        current.text = stripped + "\n\n"
                        reply = current
                        // Reflect the strip in the live bubble and the store
                        // copy so the marker never survives to the final text.
                        if owns {
                            live.setFullText(current.text)
                            streamSlots[origin]?.lastStatus = L("panel.thinking")
                        }
                        if isLive, chatStore.isHistoryLoaded,
                           chatStore.messages.contains(where: { $0.id == current.id }) {
                            chatStore.setText(current.text, for: current.id)
                        }
                        // The pill under the bubble says the work goes on.
                        if isLive { chatStore.statusText = L("panel.thinking") }
                        // The hidden nudge lives only in the request payload.
                        requestHistory = history + [
                            ChatMessage(text: current.text, isUser: false),
                            ChatMessage(text: "Continue.", isUser: true),
                        ]
                        continue roundLoop
                    }
                }
                break roundLoop
                }
                if !Task.isCancelled {
                    if var finished = reply {
                        // A marker that survived (continuation budget spent)
                        // must not reach the stored message.
                        finished.text = Self.strippingContinueMarker(finished.text).text
                        // Tool chips buffered during the turn land on the
                        // finished reply (deduped against redeliveries).
                        if !pendingChipAttachments.isEmpty {
                            let existing = Set(finished.attachments.compactMap(\.fileURLString))
                            finished.attachments += pendingChipAttachments.filter {
                                $0.fileURLString.map { !existing.contains($0) } ?? true
                            }
                        }
                        reply = finished
                        // No-op when live and already synced; routes the reply
                        // into the origin chat's file when detached.
                        chatStore.deliver(finished, to: origin)
                    } else if isLive {
                        chatStore.addMessage(text: L("panel.emptyReply"), isUser: false)
                    }
                }
            } catch {
                flush()
                // Cancellation (preset deleted) discards the reply silently.
                // `Task.isCancelled` covers both CancellationError and
                // URLError.cancelled paths.
                if !Task.isCancelled {
                    if var failed = reply {
                        failed.text += "\n\n⚠️ \(error.localizedDescription)"
                        reply = failed
                        chatStore.deliver(failed, to: origin)
                    } else if isLive {
                        chatStore.addMessage(text: error.localizedDescription, isUser: false, messageType: .system)
                    } else {
                        // Failed before any text while detached — surface the
                        // error as a system line in the origin chat.
                        chatStore.deliver(
                            ChatMessage(text: error.localizedDescription, isUser: false, messageType: .system),
                            to: origin
                        )
                    }
                    // Retry only makes sense while the origin chat (whose
                    // history the retry would resend) is still on screen.
                    if isLive { pendingRetry = .chat }
                }
            }
            // Retire the slot only AFTER the delivery above put the final
            // text into the store row (a synchronous upsert when live): both
            // changes land in one UI update, so the live→store row swap is
            // invisible. Guarded — a stop/new-chat may have retired it (and
            // a fresh stream may already own the key).
            if owns {
                streamSlots.removeValue(forKey: origin)
                live.reset()
            }
            if isLive {
                chatStore.statusText = nil
                // The journal's live copy retires with the turn — the
                // delivered reply carries its own (persisted) one.
                livePill.clear()
            hasLiveSteps = false
                chatStore.setLoading(false)
                // Fold older turns into the rolling summary when the context
                // grows. Skipped on cancellation (the chat is being deleted)
                // and for agent chats — compaction is the AGENT's job, we
                // never send it our history (notes §6.1 p.2).
                if !Task.isCancelled, !origin.isAgent {
                    await ChatService.compressHistoryIfNeeded(store: chatStore)
                }
            }
        }
        // Both writes are on the MainActor: the task body cannot have run
        // before this line, so the slot always sees its task handle.
        streamSlots[origin]?.task = task
    }

    // MARK: - Attachments / OCR

    /// Compact card hugging its content — the attachment zone must not read
    /// as a full-width band across the chat. ONE image: preview, filename,
    /// and ONE pill row — the ImageAddon actions (render nothing while the
    /// addon is off; behind the separate Hermes opt-in in agent
    /// conversations) with Extract Text at the same level and height.
    /// SEVERAL images: a bare thumbnail row (each with its ✕) — the batch
    /// goes to the model as-is, per-image tools would be ambiguous. Top
    /// alignment keeps the right pills in place when the bar unfolds its
    /// mask editor below. Own property: inlining this in the composer body
    /// blew the type-checker's budget.
    @ViewBuilder
    private var attachmentCard: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if pendingAttachments.count == 1, let attachment = pendingAttachments.first {
                    PendingAttachmentPreview(
                        attachment: attachment,
                        removeAction: clearPendingAttachments
                    )
                    HStack(alignment: .top, spacing: 8) {
                        if imageFeaturesAllowed {
                            ImageAttachmentActionsBar(
                                attachment: attachment,
                                chatStore: chatStore,
                                clearAttachment: clearPendingAttachments
                            )
                        }
                        if OCRService.isAvailable, attachment.mimeType.hasPrefix("image"),
                           imageFeaturesAllowed {
                            Button {
                                extractText(from: attachment)
                            } label: {
                                Label(isExtractingText ? L("panel.extracting") : L("panel.extractText"),
                                      systemImage: "text.viewfinder")
                                    .font(.system(size: 11))
                                    .frame(height: 14)
                            }
                            .actionPillStyle(.generic(palette: palette, dark: colorScheme == .dark),
                                             glass: palette.isGlass)
                            .disabled(isExtractingText)
                            .help(L("tooltip.extract"))
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        ForEach(pendingAttachments) { attachment in
                            PendingAttachmentThumbnail(attachment: attachment) {
                                removePendingAttachment(attachment)
                            }
                        }
                    }
                    Text(String(format: L("panel.attachCount"),
                                pendingAttachments.count, Self.maxPendingAttachments))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
    }

    /// Batch ceiling. 5 is comfortably inside every supported provider's
    /// per-request image limit (the tightest cloud cap is Mistral's 8;
    /// Anthropic allows 100, OpenAI/Gemini hundreds) — and past ~5 images
    /// answer quality degrades faster than limits bind.
    static let maxPendingAttachments = 5

    /// Appends to the staging row; over the ceiling the image is dropped
    /// with an in-chat notice (never silently).
    private func appendPendingAttachment(_ attachment: ChatAttachment) {
        guard pendingAttachments.count < Self.maxPendingAttachments else {
            chatStore.addMessage(
                text: String(format: L("panel.attachLimit"), Self.maxPendingAttachments),
                isUser: false, messageType: .system)
            return
        }
        pendingAttachments.append(attachment)
    }

    private func removePendingAttachment(_ attachment: ChatAttachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
    }

    private func clearPendingAttachments() {
        pendingAttachments = []
        appState.clearPendingAttachment()
    }

    /// Formats the chat/vision providers take as-is; anything else (HEIC,
    /// TIFF, …) is converted to PNG locally before attaching.
    private static let directlyAttachableMimes = ["image/png", "image/jpeg", "image/webp", "image/gif"]

    /// "Attach an image" via a system dialog. Presented as a SHEET of the
    /// floating panel: the dialog takes key status, and a free-standing
    /// dialog would trigger the panel's auto-hide (see `hideChatWindow`).
    ///
    /// Agent mode accepts ANY file: Hermes has no upload API, but its host
    /// is (usually) this very Mac and its file tools read paths — so a
    /// non-image attachment travels as a PATH REFERENCE in the message,
    /// not as bytes (e2e request 2026-07-26).
    private func presentAttachOpenPanel() {
        guard let window = FloatingPanelWindow.chatPanel else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        // Multiple selection everywhere: images stage as a batch (up to
        // `maxPendingAttachments`); agent mode additionally takes any file
        // as a path reference.
        panel.allowsMultipleSelection = true
        if settings.activeAgentRole == nil {
            panel.allowedContentTypes = [.png, .jpeg, .webP, .heic, .heif, .tiff, .gif]
        }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            for url in panel.urls {
                acceptPickedFile(url)
            }
        }
    }

    /// Routes one picked/dropped file: images join the staged batch until
    /// the ceiling; non-images (and image overflow in agent mode) join the
    /// path list for the agent.
    private func acceptPickedFile(_ url: URL) {
        let mime = UTType(filenameExtension: url.pathExtension.lowercased())?.preferredMIMEType ?? ""
        if mime.hasPrefix("image"), pendingAttachments.count < Self.maxPendingAttachments {
            _ = attachImageFile(at: url)
        } else if settings.activeAgentRole != nil {
            if !pendingAgentFilePaths.contains(url.path) {
                pendingAgentFilePaths.append(url.path)
            }
        } else if mime.hasPrefix("image") {
            // Ordinary chat, batch full: report instead of silently dropping.
            chatStore.addMessage(
                text: String(format: L("panel.attachLimit"), Self.maxPendingAttachments),
                isUser: false, messageType: .system)
        }
    }

    /// Reads an image file and attaches it, converting exotic formats to PNG.
    @discardableResult
    private func attachImageFile(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        let mime = UTType(filenameExtension: url.pathExtension.lowercased())?.preferredMIMEType ?? "application/octet-stream"
        if Self.directlyAttachableMimes.contains(mime.lowercased()) {
            attach(data: data, mime: mime, filename: url.lastPathComponent)
            return true
        }
        guard let png = Self.pngData(from: data) else { return false }
        attach(data: png, mime: "image/png",
               filename: (url.lastPathComponent as NSString).deletingPathExtension + ".png")
        return true
    }

    /// ⌘V in the composer: an image on the pasteboard becomes the pending
    /// attachment (Slack/Telegram-style). Plain-text pastes fall through.
    private func handleImagePaste(_ pasteboard: NSPasteboard) -> Bool {
        // Opt-in diagnostics: which raw types arrived (first few — browsers
        // declare dozens) so a "nothing happened" paste report pins the source.
        Diagnostics.log("ui", "paste types=\((pasteboard.types ?? []).prefix(6).map(\.rawValue))")

        // A copied image FILE (Finder ⌘C) arrives as a file URL + its name as
        // a string — the file wins over the text.
        let urlOptions: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier]
        ]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: urlOptions) as? [URL],
           let url = urls.first {
            return attachImageFile(at: url)
        }

        // Raster data (screenshot copy, browser "Copy Image"). PNG/TIFF/JPEG
        // are the common clipboard image types — normalize to PNG. A failure
        // to build the PNG falls through to the NSImage path below rather than
        // bailing (so a lazily-provided or exotic type still has a chance).
        if let type = pasteboard.availableType(from: [.png, .tiff, Self.jpegPasteboardType]),
           let data = pasteboard.data(forType: type),
           let png = (type == .png) ? data : Self.pngData(from: data) {
            attach(data: png, mime: "image/png", filename: "pasted-\(Int(Date().timeIntervalSince1970)).png")
            return true
        }

        // Last resort: any NSImage representation on the pasteboard. Some apps
        // vend only an NSImage object with no raw png/tiff/jpeg data type — this
        // is the canonical way to read an image from a pasteboard, so it catches
        // sources the explicit-type check above misses. Returns nil for a
        // text-only clipboard, so plain-text pastes still fall through.
        if let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
           let tiff = image.tiffRepresentation,
           let png = Self.pngData(from: tiff) {
            attach(data: png, mime: "image/png", filename: "pasted-\(Int(Date().timeIntervalSince1970)).png")
            return true
        }
        return false
    }

    /// `public.jpeg` as a pasteboard type (no AppKit constant for it).
    private static let jpegPasteboardType = NSPasteboard.PasteboardType(UTType.jpeg.identifier)

    /// Persists the attachment payload as a FILE in Application Support and
    /// references it from the message (`base64` stays empty). Keeping image
    /// bytes out of `chat.json` is what stops the history file from growing
    /// into the tens of megabytes — inline base64 was the root of the
    /// launch-time decode cost and the re-layout memory blow-up. Written into
    /// the same `images/` directory the orphan sweep protects, so an attached-
    /// then-cancelled file is reclaimed. Falls back to inline base64 only if
    /// the write fails, so attaching never silently drops the image.
    private func attach(data: Data, mime: String, filename: String) {
        appendPendingAttachment(ChatAttachment.fileBacked(data: data, mimeType: mime, filename: filename))
    }

    /// Re-encodes arbitrary image bytes (HEIC, TIFF, …) to PNG.
    private static func pngData(from data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Runs OCR on the pending image via the selected provider. Apple Vision
    /// (default) returns plain text; Mistral returns layout-aware markdown
    /// (headings, lists, tables). The result is shown in the chat and the raw
    /// text is copied to the clipboard for pasting into editors.
    private func extractText(from attachment: ChatAttachment) {
        guard !isExtractingText else { return }
        isExtractingText = true

        Task { @MainActor in
            do {
                let markdown = try await OCRService.extractText(
                    imageBase64: attachment.contentBase64,
                    mimeType: attachment.mimeType
                )
                // Same dual-flavor copy as the bubble button: tables get an
                // HTML <table> flavor so spreadsheets split them into cells.
                MarkdownBlocksView.copyMarkdownToPasteboard(markdown)
                clearPendingAttachments()
                // Show the source screenshot in the chat, then the extracted text.
                chatStore.appendNow(ChatMessage(text: "", isUser: true, attachments: [attachment]))
                chatStore.addMessage(text: markdown, isUser: false)
                chatStore.addMessage(text: L("panel.ocrDone"), isUser: false, messageType: .system)
            } catch {
                chatStore.addMessage(text: String(format: L("panel.ocrFailed"), error.localizedDescription), isUser: false, messageType: .system)
            }
            isExtractingText = false
        }
    }

    // MARK: - Voice

    private var transcriptionAvailable: Bool {
        STTProviderID.allCases.contains { $0.hasKey }
    }

    private func handleVoiceRecordingStart() {
        // The dictation belongs to the chat on screen at the moment the mic
        // OPENS. Every stop path reaches sendVoiceMessage through an async
        // gap (0.5s file-finalize wait, the 0.35s Space cancel window) — a
        // fast switch right after "send" landed inside that gap, so a
        // capture at send time still aimed at the NEW chat (report
        // 2026-07-31, second round: the voice bubble followed the switch).
        voiceRecordingOrigin = chatStore.conversation
        Task {
            guard transcriptionAvailable else {
                _ = await MainActor.run {
                    chatStore.addMessage(text: L("panel.needTranscription"), isUser: false, messageType: .system)
                }
                return
            }

            // Start recording
            let success = await audioRecorder.startRecording()
            if !success {
                _ = await MainActor.run {
                    chatStore.addMessage(text: L("panel.recordStartFailed"), isUser: false, messageType: .system)
                }
            }
        }
    }

    private func handleVoiceRecordingStop() {
        Task {
            // Stop recording and send
            audioRecorder.stopRecording()

            // Wait a moment for the recording to finish
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

            guard let audioURL = audioRecorder.recordingURL else {
                return
            }

            await sendVoiceMessage(audioURL: audioURL)
            // Note: We don't delete the recording immediately - it stays until session ends
        }
    }

    private func handleVoiceRecordingCancel() {
        voiceRecordingOrigin = nil
        audioRecorder.cancelRecording()
    }

    // MARK: - Panel keyboard control (Space / double-Space / Esc)

    /// While recording, Space stops (send after a short grace window) and a
    /// second Space within that window cancels; the text editor is disabled
    /// during recording, so Space is free. Esc cancels a recording, and
    /// dismisses the panel when there is none.
    ///
    /// One monitor rather than several: Esc has to mean "cancel the recording"
    /// BEFORE it can mean "close the panel", and separate monitors would leave
    /// that precedence to the order AppKit happens to call them in.
    private func installPanelKeyMonitor() {
        guard panelKeyMonitor == nil else { return }
        panelKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let plainKey = event.modifierFlags
                .intersection([.command, .option, .control, .shift])
                .isEmpty

            // Slash autocomplete owns ↑/↓/⏎/⇥/Esc while its popup is open —
            // BEFORE the text view sees them (⏎ must pick, not send).
            let slashItems = slashSuggestionItems()
            if !slashItems.isEmpty, plainKey {
                switch event.keyCode {
                case 125: // ↓
                    slashSelection = min(slashSelection + 1, slashItems.count - 1)
                    return nil
                case 126: // ↑
                    slashSelection = max(slashSelection - 1, 0)
                    return nil
                case 36, 48: // ⏎ / ⇥
                    let index = min(slashSelection, slashItems.count - 1)
                    acceptSlashSuggestion(slashItems[index].command)
                    return nil
                case 53: // Esc closes the popup for THIS text; typing re-arms
                    slashDismissedText = messageText
                    return nil
                default:
                    break
                }
            }

            // Space (keyCode 49)
            if event.keyCode == 49, plainKey {
                if audioRecorder.isRecording {
                    stopRecordingWithCancelWindow()
                    return nil
                }
                if pendingVoiceSend != nil {
                    cancelPendingVoiceSend()
                    return nil
                }
            }
            // Esc (keyCode 53): cancels a recording if one is running, and
            // otherwise dismisses the panel — the same thing clicking away
            // does, and what the World Time panel already does. A borderless
            // window has no close button, so without this the only way out
            // with the panel focused is the hotkey.
            if event.keyCode == 53 {
                if audioRecorder.isRecording {
                    audioRecorder.cancelRecording()
                    return nil
                }
                if let panel = FloatingPanelWindow.chatPanel,
                   panel.isKeyWindow,
                   // A system dialog presented as our sheet owns Esc: dismissing
                   // the panel under it would strand the sheet.
                   panel.attachedSheet == nil {
                    panel.orderOut(nil)
                    return nil
                }
            }
            return event
        }
    }

    /// Stops the recording immediately, but delays the send briefly so a
    /// second Space press can turn the stop into a cancel.
    private func stopRecordingWithCancelWindow() {
        audioRecorder.stopRecording()

        let work = DispatchWorkItem {
            pendingVoiceSend = nil
            Task {
                // Small delay so the audio file is fully finalized.
                try? await Task.sleep(nanoseconds: 200_000_000)
                if let audioURL = audioRecorder.recordingURL {
                    await sendVoiceMessage(audioURL: audioURL)
                }
            }
        }
        pendingVoiceSend = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func cancelPendingVoiceSend() {
        pendingVoiceSend?.cancel()
        pendingVoiceSend = nil
        voiceRecordingOrigin = nil
        audioRecorder.deleteRecording()
        chatStore.addMessage(text: L("panel.recordingCancelled"), isUser: false, messageType: .system)
    }

    /// Transcribes the recording locally-configured STT provider, shows the
    /// voice bubble with its transcript, and streams the assistant reply.
    @MainActor
    private func sendVoiceMessage(audioURL: URL) async {
        guard ensureChatConfigured() else { return }

        // The chat the user dictated IN — captured when the mic OPENED
        // (voiceRecordingOrigin), not here: between the stop tap and this
        // call sit async gaps (file finalize, cancel window) a fast session
        // switch can slip into, and transcription itself takes seconds.
        // Everything below binds to this capture instead of the live store —
        // a send re-aimed by a switch fed the dictation into the WRONG
        // Hermes session (report 2026-07-31, both rounds).
        let origin = voiceRecordingOrigin ?? chatStore.conversation
        voiceRecordingOrigin = nil

        // Synchronous set + status (not setLoading's async dispatch): during
        // transcription the last message is still the assistant's previous
        // reply, so the thinking pill only shows because statusText is set —
        // without it a long recognition looks like the message was lost.
        // (A switch wipes both — correctly: they belong to the origin chat.)
        chatStore.isLoading = true
        chatStore.statusText = L("panel.transcribing")
        pendingRetry = nil
        do {
            let transcript = try await TranscriptionService.transcribe(audioURL: audioURL)
            let onOrigin = chatStore.conversation == origin
            guard !transcript.isEmpty else {
                if onOrigin {
                    chatStore.statusText = nil
                    chatStore.setLoading(false)
                    chatStore.addMessage(text: L("panel.noSpeech"), isUser: false, messageType: .system)
                } else {
                    chatStore.deliver(
                        ChatMessage(text: L("panel.noSpeech"), isUser: false, messageType: .system),
                        to: origin
                    )
                }
                return
            }
            let userMessage: ChatMessage
            if !pendingAttachments.isEmpty {
                // Dictation over staged images: voice here is just an input
                // method (instead of typing), so the transcript goes out as a
                // regular text message under the images — no audio kept, no
                // voice reply. (A failed transcription keeps the attachments
                // staged for retry.)
                userMessage = ChatMessage(text: transcript, isUser: true, attachments: pendingAttachments)
                clearPendingAttachments()
                try? FileManager.default.removeItem(at: audioURL)
            } else {
                userMessage = ChatMessage(text: transcript, isUser: true, messageType: .voice, audioURL: audioURL)
            }
            if onOrigin {
                chatStore.appendNow(userMessage)
                streamAssistantReply()
            } else {
                // Switched away mid-transcription: the message goes home (the
                // origin's file / its pending-load queue), and the reply
                // starts already DETACHED with the origin's own context read
                // from disk — the stream-slot machinery delivers it exactly
                // like any turn whose chat was switched away mid-stream.
                chatStore.deliver(userMessage, to: origin)
                guard streamSlots[origin] == nil else { return }
                ChatPersistence.load(key: origin.storageKey, mediaExpiredText: L("chat.mediaExpired")) { loaded in
                    DispatchQueue.main.async {
                        // The user may have re-sent in the origin meanwhile.
                        guard streamSlots[origin] == nil else { return }
                        // Same context-window rule as activeContextMessages:
                        // the summarized prefix stays out.
                        let start = min(max(0, loaded.summaryCoversCount - loaded.windowStart),
                                        loaded.messages.count)
                        var history = Array(loaded.messages[start...])
                        // The delivery above and this load ride the same disk
                        // queue, so the message is normally in — the append
                        // is the belt to that suspender.
                        if !history.contains(where: { $0.id == userMessage.id }) {
                            history.append(userMessage)
                        }
                        streamAssistantReply(for: origin, history: history, summary: loaded.summary)
                    }
                }
            }
        } catch {
            if chatStore.conversation == origin {
                chatStore.statusText = nil
                chatStore.setLoading(false)
                chatStore.addMessage(text: String(format: L("panel.transcriptionFailed"), error.localizedDescription), isUser: false, messageType: .system)
                // The recording file persists — Retry re-runs transcription + send.
                pendingRetry = .transcription(audioURL)
            } else {
                // No retry affordance while detached (retry resends the
                // ON-SCREEN history) — the failure surfaces in the origin.
                chatStore.deliver(
                    ChatMessage(text: String(format: L("panel.transcriptionFailed"), error.localizedDescription),
                                isUser: false, messageType: .system),
                    to: origin
                )
            }
        }
    }
}

// MARK: - Pending Attachment Preview

/// Compact tile for the multi-image staging row: a square thumbnail with an
/// ✕ badge. No per-image tools — the batch goes to the model as-is.
private struct PendingAttachmentThumbnail: View {
    let attachment: ChatAttachment
    let removeAction: () -> Void
    @State private var decodedImage: NSImage?

    var body: some View {
        Group {
            if let image = decodedImage ?? AttachmentImageCache.cachedImage(for: attachment) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.08))
                    .overlay(ThinkingEqualizer().scaleEffect(0.5))
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button(action: removeAction) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.black.opacity(0.55)))
            }
            .buttonStyle(.plain)
            .padding(3)
            .help(L("tooltip.removeAttachment"))
        }
        .help(attachment.filename)
        .task(id: attachment.id) {
            decodedImage = AttachmentImageCache.cachedImage(for: attachment)
            decodedImage = await AttachmentImageCache.image(for: attachment)
        }
    }
}

private struct PendingAttachmentPreview: View {
    let attachment: ChatAttachment
    /// Detach: an ✕ badge on the preview's corner (the iMessage pattern) —
    /// keeping it out of the pill row keeps the attachment card narrow.
    let removeAction: () -> Void
    /// Decoded off the main thread (see AttachmentImageCache).
    @State private var decodedImage: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if attachment.mimeType.hasPrefix("image"),
               let image = decodedImage ?? AttachmentImageCache.cachedImage(for: attachment) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .topTrailing) { removeBadge }
            } else if attachment.mimeType.hasPrefix("image") {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(width: 180, height: 120)
                    .overlay(ThinkingEqualizer().scaleEffect(0.8))
                    .overlay(alignment: .topTrailing) { removeBadge }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "doc.fill")
                        .foregroundColor(.secondary)
                    Text(attachment.filename)
                        .font(.callout)
                    removeBadge
                }
            }

            // Extract Text moved to the host's pill row next to the
            // ImageAddon actions — the preview keeps only the filename.
            Text(attachment.filename)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        // On the container, not the placeholder: the pending attachment can
        // be REPLACED while this view lives — the id-keyed task both resets
        // the stale preview and kicks off the new decode.
        .task(id: attachment.id) {
            decodedImage = AttachmentImageCache.cachedImage(for: attachment)
            decodedImage = await AttachmentImageCache.image(for: attachment)
        }
    }

    /// Small circled ✕ over the preview corner. Dark scrim + white glyph
    /// stays legible over any image and any theme.
    private var removeBadge: some View {
        Button(action: removeAction) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.black.opacity(0.55)))
        }
        .buttonStyle(.plain)
        .padding(5)
        .help(L("tooltip.removeAttachment"))
    }
}
