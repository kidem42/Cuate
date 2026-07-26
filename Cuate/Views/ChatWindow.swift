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
    @State private var pendingAttachment: ChatAttachment?
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

    /// File paths from every agent reply of the conversation, deduped,
    /// newest first (the header folder popover).
    private func collectAgentFilePaths() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for message in chatStore.messages.reversed() where !message.isUser {
            for path in AgentFilePaths.extract(from: message.text)
            where seen.insert(path).inserted {
                result.append(path)
            }
        }
        return result
    }
    /// In-flight assistant reply. Survives conversation switches (the reply
    /// keeps streaming in the background into its origin chat); cancelled
    /// only when the origin chat itself is deleted.
    @State private var streamingTask: Task<Void, Never>?
    /// Which conversation the in-flight reply belongs to.
    @State private var streamingOrigin: ChatStore.ConversationID?
    /// Whether the scroll position is near the newest message (reported by
    /// the transcript engine; mirrors its pin state).
    @State private var isNearBottom = true
    /// Keyboard control of voice recording: Space stops, double-Space cancels.
    @State private var panelKeyMonitor: Any?
    @State private var pendingVoiceSend: DispatchWorkItem?
    /// Imperative handle to the transcript engine (scroll-to-bottom on send
    /// and summon). @State so the instance survives view-struct re-inits.
    @State private var transcriptController = TranscriptController()
    /// Live buffer of the reply currently streaming in. NOT observed by this
    /// view (no @ObservedObject on purpose): only the streaming bubble's
    /// text subtree subscribes, so a flush re-renders that subtree alone.
    @State private var liveReply = StreamingReplyModel()
    /// Identity/timestamp stub for the streaming bubble. While set (and the
    /// origin conversation is on screen) the transcript masks the store's
    /// copy of this message and renders the live row in its place.
    @State private var liveReplyStub: ChatMessage?
    /// True from send until the first streamed text chunk (the tool/thinking
    /// phase). Switching conversations wipes the store's isLoading/statusText
    /// — these two remember enough to put the pill back when the user
    /// returns to a chat whose reply is still in that phase.
    @State private var streamingAwaitingText = false
    @State private var streamingLastStatus: String?
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

    /// The rendered slice of the conversation (newest `visibleCount`).
    private var visibleMessages: ArraySlice<ChatMessage> {
        chatStore.messages.suffix(visibleCount)
    }

    /// Resolved theme tokens for the active theme + color scheme. `current`
    /// resolves to the glass palette and leaves every surface untouched.
    private var palette: ThemePalette {
        ThemePalette.palette(for: settings.theme, scheme: colorScheme)
    }

    // MARK: - Transcript rows

    /// Whether the in-flight reply is being rendered live in THIS transcript
    /// (its origin conversation is on screen). While true, the store's copy
    /// of the streaming message is masked and the live row stands in for it.
    private var liveStreamOnScreen: Bool {
        liveReplyStub != nil && streamingOrigin == chatStore.conversation
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

        if chatStore.messages.count > visibleCount || chatStore.hasOlderMessages {
            items.append(TranscriptItem(id: "backfill-spinner", revision: baseRevision) {
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

        let maskedID = liveStreamOnScreen ? liveReplyStub?.id : nil
        for message in visibleMessages where message.id != maskedID {
            items.append(messageItem(message, rowWidth: rowWidth,
                                     maxBubble: maxBubble, baseRevision: baseRevision))
        }

        if liveStreamOnScreen, let stub = liveReplyStub {
            // Constant revision on purpose: the row's CONTENT updates itself
            // through the model — the engine never rebuilds it mid-stream.
            let live = liveReply
            items.append(TranscriptItem(id: "live-reply", revision: baseRevision) { [palette] in
                AnyView(
                    MessageRow(message: stub, maxBubbleWidth: maxBubble,
                               isStreamingReply: true, liveModel: live)
                        .environment(\.themePalette, palette)
                        .fontDesign(palette.fontDesign)
                        .frame(width: rowWidth, alignment: .leading)
                )
            })
        }

        if showThinkingIndicator {
            var hasher = Hasher()
            hasher.combine(baseRevision)
            hasher.combine(chatStore.statusText)
            let statusText = chatStore.statusText
            items.append(TranscriptItem(id: "thinking-indicator", revision: hasher.finalize()) { [palette] in
                AnyView(
                    HStack(spacing: 8) {
                        ThinkingEqualizer()
                        Text(statusText ?? L("panel.thinking"))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        // ImageAddon: cancels a running image operation;
                        // hidden otherwise.
                        ImageOperationCancelButton()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .environment(\.themePalette, palette)
                    .fontDesign(palette.fontDesign)
                    .frame(width: rowWidth, alignment: .leading)
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
        var hasher = Hasher()
        hasher.combine(baseRevision)
        hasher.combine(message.text)
        hasher.combine(message.messageType.rawValue)
        hasher.combine(message.audioURL)
        // Agent step journal attaches at delivery, after the last text
        // checkpoint — without this the row never rebuilds to show it.
        hasher.combine(message.agentSteps)
        for attachment in message.attachments {
            hasher.combine(attachment.id)
            hasher.combine(attachment.fileURLString)
            hasher.combine(attachment.ocrText)
        }
        return TranscriptItem(id: message.id.uuidString, revision: hasher.finalize()) { [palette] in
            AnyView(
                MessageRow(message: message, maxBubbleWidth: maxBubble)
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
        // The agent management column joins INSIDE the one glass surface
        // (left, sidebar convention): the surface itself is unconditional —
        // recreating glassEffect in if-branches is the known backdrop bug.
        AdaptiveGlassContainer(spacing: 24) {
            HStack(spacing: 0) {
                if agentSidebarVisible, let role = settings.activeAgentRole {
                    HermesSidebarView(role: role)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 1)
                }
                chatColumn
            }
            // Untinted regular glass for the Current theme; the other themes
            // fill the panel with their gradient + signature pattern instead
            // (see themedPanelSurface). Legibility comes from the bubbles.
            .themedPanelSurface(palette, cornerRadius: 18)
        }
        // The window makes room for the column (grow left / shrink back);
        // the chat column itself never changes size.
        .onChange(of: agentSidebarVisible) { _, visible in
            NotificationCenter.default.post(
                name: .agentSidebarVisibilityChanged, object: nil,
                userInfo: ["visible": visible]
            )
        }
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
                        onNeedOlder: { loadOlderMessages() }
                    )

                    // Floating "jump to latest" button (Telegram-style)
                    if !isNearBottom {
                        Button {
                            transcriptController.scrollToBottom(animated: true)
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
                        isBackfilling = false
                    } else if chatStore.messages.last?.isUser == true {
                        // Own messages always jump down (and re-arm
                        // auto-follow) even if the user was reading history.
                        // Incoming rows never yank the view: the engine's
                        // pin state decides, and a backfill PREPEND is
                        // re-anchored by the engine itself.
                        transcriptController.scrollToBottom(animated: true)
                    }
                }
                .onChange(of: pendingLocalStart != nil) { _, visible in
                    // The local-model confirmation appears with NO store
                    // change, so no other trigger fires — and it answers
                    // the user's own send, so it always comes into view.
                    if visible {
                        transcriptController.scrollToBottom(animated: true)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .chatWindowDidBecomeVisible)) { _ in
                    // Every summon shows the newest message — and drops the
                    // history window back to one page (reading history
                    // widens it and nothing else narrows it again; between
                    // summons there is no viewport to disturb).
                    if visibleCount > Self.historyPageSize {
                        visibleCount = Self.historyPageSize
                    }
                    transcriptController.scrollToBottom(animated: false)
                }
                .onChange(of: chatStore.conversation.storageKey) {
                    // Returning to a chat whose reply is still in the
                    // tool/thinking phase: the switch wiped the store's
                    // isLoading/statusText, and the stream only touches them
                    // on events that arrive while live — until the next one,
                    // the chat looked dead and then a reply "appeared out of
                    // nowhere". Put the pill straight back.
                    guard streamingAwaitingText,
                          streamingOrigin == chatStore.conversation else { return }
                    chatStore.setLoading(true)
                    if let status = streamingLastStatus {
                        chatStore.statusText = status
                    }
                }

                // Input area (also acts as a drag region)
                VStack(spacing: 8) {
                    // Recording status (shown when recording)
                    RecordingStatusView(isRecording: $audioRecorder.isRecording)

                    // Slash autocomplete (agent mode): "/" lists the agent's
                    // skills — the agent itself interprets "/skill-name …"
                    // in plain text (probed live) — plus Cuate's own local
                    // image commands, which intercept before sending.
                    agentSlashSuggestions

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

                    if let attachment = pendingAttachment {
                        PendingAttachmentPreview(
                            attachment: attachment,
                            isExtractingText: isExtractingText,
                            canExtractText: OCRService.isAvailable && attachment.mimeType.hasPrefix("image"),
                            removeAction: clearCurrentAttachment,
                            extractTextAction: { extractText(from: attachment) }
                        )
                        .padding(.horizontal, 12)

                        // ImageAddon actions (Addons/ImageAddon) — renders
                        // nothing while the addon is disabled.
                        ImageAttachmentActionsBar(
                            attachment: attachment,
                            chatStore: chatStore,
                            clearAttachment: clearCurrentAttachment
                        )
                        .padding(.horizontal, 12)
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
                                    Text(palette.isGlass ? L("panel.typeMessage") : (palette.placeholderText ?? L("panel.typeMessage")))
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

                        // Send button
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
        .onReceive(NotificationCenter.default.publisher(for: .agentRunCommandRemotely)) { note in
            guard let command = note.object as? String,
                  settings.activeAgentRole != nil, !chatStore.isLoading else { return }
            performSend(text: String(format: AGL("agent.code.remotePrompt"), command), attachment: nil)
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
                    && (streamingOrigin != chatStore.conversation || streamingTask == nil)
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
            self.pendingAttachment = appState.pendingAttachment
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
        // ImageAddon: retry-after-error and «Продолжить редактирование»
        // hand an attachment back to the composer.
        .onReceive(NotificationCenter.default.publisher(for: .imageAddonAttachRequest)) { note in
            if let attachment = note.object as? ChatAttachment {
                appState.pendingAttachment = attachment
            }
        }
        .onReceive(appState.$pendingAttachment) { attachment in
            self.pendingAttachment = attachment
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

    /// The "/query" being typed, when the composer is in slash-prefix state
    /// (agent mode, single line, no space after the command yet).
    private var slashQuery: String? {
        guard settings.activeAgentRole != nil,
              messageText.hasPrefix("/"),
              !messageText.contains("\n"),
              !messageText.dropFirst().contains(" ") else { return nil }
        return String(messageText.dropFirst()).lowercased()
    }

    /// The flat suggestion list for the current query — ONE source for the
    /// popup rows and the ↑/↓/⏎ keyboard handling in the panel key monitor.
    private func slashSuggestionItems() -> [(command: String, description: String?)] {
        guard let query = slashQuery, messageText != slashDismissedText else { return [] }
        var items: [(String, String?)] = []
        if ImageAddonSettings.shared.enabled {
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
    private var agentModelControl: some View {
        Menu {
            ForEach(hermesAddon.cachedProviders.filter { !$0.models.isEmpty }) { provider in
                Menu(provider.name) {
                    ForEach(provider.models, id: \.self) { model in
                        Button {
                            switchSessionModel(provider: provider.slug, model: model)
                        } label: {
                            if composerModelPair?.model == model, composerModelPair?.provider == provider.slug {
                                Label(model, systemImage: "checkmark")
                            } else {
                                Text(model)
                            }
                        }
                    }
                }
            }
            Divider()
            Menu(HL("hermes.composer.effort")) {
                Button {
                    hermesSettings.reasoningEffort = ""
                } label: {
                    hermesSettings.reasoningEffort.isEmpty
                        ? Label(HL("hermes.composer.effort.default"), systemImage: "checkmark")
                        : Label(HL("hermes.composer.effort.default"), systemImage: "circle")
                }
                ForEach(HermesSettings.effortLevels, id: \.self) { level in
                    Button {
                        hermesSettings.reasoningEffort = level
                    } label: {
                        hermesSettings.reasoningEffort == level
                            ? Label(level.capitalized, systemImage: "checkmark")
                            : Label(level.capitalized, systemImage: "circle")
                    }
                }
            }
        } label: {
            Text(composerModelLabel)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(height: 27)
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
    private func switchSessionModel(provider: String, model: String) {
        hermesSettings.lockProvider = provider
        hermesSettings.lockModel = model
        guard chatStore.conversation.isAgent,
              let sessionID = hermesSettings.sessionID(forConversationKey: chatStore.conversation.storageKey)
        else { return }
        hermesSettings.recordModelLock(provider: provider, model: model, forSession: sessionID)
        Task {
            try? await hermesAddon.transport().lockModel(sessionID: sessionID, provider: provider, model: model)
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
                AgentChatFilesView(paths: collectAgentFilePaths())
                    .environment(\.themePalette, palette)
            }
        } else if availableProviders.count <= 1 {
            // No switcher to show — the pin still needs its corner.
            pinButton
        } else {
            pinButton
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
        if streamingOrigin == chatStore.conversation {
            streamingTask?.cancel()
            // Drop the live row NOW — the cancelled task unwinds a beat
            // later, and the fresh chat must not show the orphan bubble
            // for that beat.
            liveReplyStub = nil
            chatStore.statusText = nil
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
            let reachable = await HermesMirrorSync.catchUp(role: role, store: chatStore)
            // The conversation may have moved on during the fetch.
            if chatStore.conversation == role.conversationID {
                agentGatewayOffline = !reachable
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
    }

    /// A custom preset was deleted: its dormant chat file + media go away.
    /// If that chat is on screen, leave it first (applyPreset has already
    /// moved the active preset back to a built-in one).
    private func handlePresetDeleted(_ name: String) {
        let deletedID = ChatStore.ConversationID.preset(name)
        // A reply streaming FOR the deleted chat — live or background — is
        // discarded: cancellation makes the stream task skip delivery, so it
        // cannot resurrect the deleted file.
        if streamingOrigin == deletedID {
            streamingTask?.cancel()
            liveReplyStub = nil
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

    /// Whether the "Thinking…" pill is currently in the list.
    private var showThinkingIndicator: Bool {
        chatStore.isLoading && (chatStore.statusText != nil || chatStore.messages.last?.isUser == true)
    }

    /// Widens the history window by one page when the user nears the top
    /// (the engine calls this and re-anchors the viewport itself, so the
    /// prepended rows never move what the user is reading). Two tiers:
    /// first widen over the in-memory history; once that is exhausted,
    /// page older rows in from the store (ChatStore keeps only a suffix
    /// window loaded).
    private func loadOlderMessages() {
        guard !isBackfilling else { return }
        if chatStore.messages.count > visibleCount {
            isBackfilling = true
            visibleCount = min(visibleCount + Self.historyPageSize, chatStore.messages.count)
            DispatchQueue.main.async { isBackfilling = false }
        } else if chatStore.hasOlderMessages {
            isBackfilling = true
            chatStore.loadOlderPage(Self.historyPageSize) { added in
                if added > 0 {
                    visibleCount = min(visibleCount + added, chatStore.messages.count)
                }
                DispatchQueue.main.async { isBackfilling = false }
            }
        }
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
            && pendingAttachment == nil
    }

    private func sendMessage() {
        // ImageAddon slash commands (/upscale, /bg, /cleanup) act on the
        // pending attachment instead of being sent as chat text.
        if ImageSlashCommands.handle(
            input: messageText,
            attachment: pendingAttachment,
            chatStore: chatStore,
            clearAttachment: clearCurrentAttachment
        ) {
            messageText = ""
            return
        }

        // The quote region (if any) becomes a markdown blockquote in the
        // outgoing text; on screen it was a styled block without markers.
        let text = SelectionGrabber.message(quote: quotedText, instruction: messageText)
        // Attachment-only sends are allowed: the image goes to the model as
        // is and the conversation's system prompt drives what happens to it.
        // Providers already handle the empty text (vision → image block only,
        // non-vision → OCR text is injected in buildLLMMessages).
        guard !text.isEmpty || pendingAttachment != nil else { return }
        guard ensureChatConfigured() else {
            messageText = ""
            quotedText = nil
            return
        }

        // Local provider: if the selected model isn't in memory, sending would
        // implicitly load it (time + RAM) — confirm first. Otherwise send now.
        // Not for agent roles: chatProvider is dormant there.
        if settings.chatProvider.isLocal, settings.activeAgentRole == nil {
            let attachment = pendingAttachment
            confirmLocalModelIfNeeded { performSend(text: text, attachment: attachment) }
            return
        }
        performSend(text: text, attachment: pendingAttachment)
    }

    /// Appends the user message and streams the reply, clearing the composer.
    private func performSend(text: String, attachment: ChatAttachment?) {
        // An attachment restored from an existing chat message (ImageAddon
        // «продолжить редактирование») already owns a store row; posting the
        // same id again would collide with the unique index and persist an
        // attachment-less message — re-wrap with a fresh identity.
        let posted = attachment.map {
            ImageOperations.isRestoredFromChat($0) ? ImageOperations.freshCopyForPosting($0) : $0
        }
        let attachments = posted.map { [$0] } ?? []
        let userMessage = ChatMessage(text: text, isUser: true, attachments: attachments)
        chatStore.appendNow(userMessage)
        messageText = "" // the editor re-measures itself back to one line
        quotedText = nil
        clearCurrentAttachment()
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
    private func streamAssistantReply() {
        chatStore.setLoading(true)
        chatStore.statusText = nil
        pendingRetry = nil
        let history = chatStore.activeContextMessages
        let summary = chatStore.conversationSummary
        // The conversation this reply belongs to. If the user switches to
        // another preset chat mid-stream, generation continues in the
        // background and the reply is delivered back to this one.
        let origin = chatStore.conversation
        streamingOrigin = origin

        // Fresh live buffer per stream: an older background stream keeps its
        // own instance and can't write into this one's bubble.
        let live = StreamingReplyModel()
        liveReply = live
        liveReplyStub = nil
        streamingAwaitingText = true
        streamingLastStatus = nil

        streamingTask = Task { @MainActor in
            // Local canonical copy of the reply (stable UUID). The LIVE
            // transcript renders from `live` (frozen segments + short tail,
            // O(chunk) per flush — see StreamingReplyModel); the STORE sees
            // the reply only as ~1 Hz persistence checkpoints plus the final
            // delivery. A flush re-publishes no list and re-parses no
            // already-final text, which is what lets it run at 30 Hz.
            var reply: ChatMessage?
            var isLive: Bool { chatStore.conversation == origin }
            var pendingText = ""
            var lastFlush = ContinuousClock.now
            var lastCheckpoint = ContinuousClock.now

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
                    let first = ChatMessage(text: pendingText, isUser: false)
                    reply = first
                    // Text is flowing — the tool/thinking phase is over.
                    if liveReply === live {
                        streamingAwaitingText = false
                        streamingLastStatus = nil
                    }
                    if isLive, chatStore.isHistoryLoaded, !Task.isCancelled, liveReply === live {
                        // Materialize both rows the moment text flows: the
                        // store row (masked while streaming — persistence and
                        // API context see it) and the live row that renders.
                        liveReplyStub = first
                        chatStore.appendNow(first)
                    }
                }
                // Mid-stream return: the reply may have materialized while
                // ANOTHER chat was on screen (the branch above skipped the
                // stub). Once the origin is back, re-arm the live row and
                // give the store its masked copy — otherwise the rest of
                // the stream would render at checkpoint cadence (~1 Hz).
                if liveReplyStub == nil, let current = reply,
                   isLive, chatStore.isHistoryLoaded, !Task.isCancelled, liveReply === live {
                    liveReplyStub = current
                    if !chatStore.messages.contains(where: { $0.id == current.id }) {
                        chatStore.appendNow(current)
                    }
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
                        // Text is flowing — the thinking/search pill must go
                        // away (otherwise it lingers *below* the growing
                        // answer bubble, since it renders after the messages).
                        if isLive, chatStore.statusText != nil {
                            chatStore.statusText = nil
                        }
                        pendingText += chunk
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
                        if liveReply === live { streamingLastStatus = status }
                        if isLive { chatStore.statusText = status }
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
                    case .replaceText(let full):
                        // Agent turns: the authoritative full text — replaces
                        // whatever streamed (deltas differ in whitespace, or
                        // never came at all). Same mechanics as the
                        // continue-marker strip below.
                        pendingText = ""
                        if var current = reply {
                            current.text = full
                            reply = current
                            if liveReply === live { live.setFullText(full) }
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
                        if liveReply === live {
                            live.setFullText(current.text)
                            streamingLastStatus = L("panel.thinking")
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
            // Retire the live row only AFTER the delivery above put the
            // final text into the store row (a synchronous upsert when
            // live): both changes land in one UI update, so the live→store
            // row swap is invisible. Guarded — a newer stream may already
            // own the live slot.
            if liveReply === live {
                liveReplyStub = nil
                live.reset()
                streamingAwaitingText = false
                streamingLastStatus = nil
            }
            if isLive {
                chatStore.statusText = nil
                chatStore.setLoading(false)
                // Fold older turns into the rolling summary when the context
                // grows. Skipped on cancellation (the chat is being deleted)
                // and for agent chats — compaction is the AGENT's job, we
                // never send it our history (notes §6.1 p.2).
                if !Task.isCancelled, !origin.isAgent {
                    await ChatService.compressHistoryIfNeeded(store: chatStore)
                }
            }
            // streamingTask deliberately NOT nil-ed here: a newer stream may
            // already own the slot, and cancelling a finished task is a no-op.
        }
    }

    // MARK: - Attachments / OCR

    private func clearCurrentAttachment() {
        pendingAttachment = nil
        appState.clearPendingAttachment()
    }

    /// Formats the chat/vision providers take as-is; anything else (HEIC,
    /// TIFF, …) is converted to PNG locally before attaching.
    private static let directlyAttachableMimes = ["image/png", "image/jpeg", "image/webp", "image/gif"]

    /// "Attach an image" via a system dialog. Presented as a SHEET of the
    /// floating panel: the dialog takes key status, and a free-standing
    /// dialog would trigger the panel's auto-hide (see `hideChatWindow`).
    private func presentAttachOpenPanel() {
        guard let window = FloatingPanelWindow.chatPanel else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .webP, .heic, .heif, .tiff, .gif]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            _ = attachImageFile(at: url)
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
        appState.pendingAttachment = ChatAttachment.fileBacked(data: data, mimeType: mime, filename: filename)
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
                clearCurrentAttachment()
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
        audioRecorder.deleteRecording()
        chatStore.addMessage(text: L("panel.recordingCancelled"), isUser: false, messageType: .system)
    }

    /// Transcribes the recording locally-configured STT provider, shows the
    /// voice bubble with its transcript, and streams the assistant reply.
    @MainActor
    private func sendVoiceMessage(audioURL: URL) async {
        guard ensureChatConfigured() else { return }

        // Synchronous set + status (not setLoading's async dispatch): during
        // transcription the last message is still the assistant's previous
        // reply, so the thinking pill only shows because statusText is set —
        // without it a long recognition looks like the message was lost.
        chatStore.isLoading = true
        chatStore.statusText = L("panel.transcribing")
        pendingRetry = nil
        do {
            let transcript = try await TranscriptionService.transcribe(audioURL: audioURL)
            guard !transcript.isEmpty else {
                chatStore.statusText = nil
                chatStore.setLoading(false)
                chatStore.addMessage(text: L("panel.noSpeech"), isUser: false, messageType: .system)
                return
            }
            if let attachment = pendingAttachment {
                // Dictation over a staged image: voice here is just an input
                // method (instead of typing), so the transcript goes out as a
                // regular text message under the image — no audio kept, no
                // voice reply. (A failed transcription keeps the attachment
                // staged for retry.)
                let userMessage = ChatMessage(text: transcript, isUser: true, attachments: [attachment])
                chatStore.appendNow(userMessage)
                clearCurrentAttachment()
                try? FileManager.default.removeItem(at: audioURL)
            } else {
                let voiceMessage = ChatMessage(text: transcript, isUser: true, messageType: .voice, audioURL: audioURL)
                chatStore.appendNow(voiceMessage)
            }
            streamAssistantReply()
        } catch {
            chatStore.statusText = nil
            chatStore.setLoading(false)
            chatStore.addMessage(text: String(format: L("panel.transcriptionFailed"), error.localizedDescription), isUser: false, messageType: .system)
            // The recording file persists — Retry re-runs transcription + send.
            pendingRetry = .transcription(audioURL)
        }
    }
}

// MARK: - Pending Attachment Preview

private struct PendingAttachmentPreview: View {
    let attachment: ChatAttachment
    let isExtractingText: Bool
    let canExtractText: Bool
    let removeAction: () -> Void
    let extractTextAction: () -> Void
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
            } else if attachment.mimeType.hasPrefix("image") {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(width: 180, height: 120)
                    .overlay(ThinkingEqualizer().scaleEffect(0.8))
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "doc.fill")
                        .foregroundColor(.secondary)
                    Text(attachment.filename)
                        .font(.callout)
                }
            }

            HStack {
                Text(attachment.filename)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if canExtractText {
                    Button(isExtractingText ? L("panel.extracting") : L("panel.extractText")) {
                        extractTextAction()
                    }
                    .buttonStyle(.link)
                    .disabled(isExtractingText)
                    .help(L("tooltip.extract"))
                }
                Button(L("keys.remove")) {
                    removeAction()
                }
                .buttonStyle(.link)
                .help(L("tooltip.removeAttachment"))
            }
        }
        // On the container, not the placeholder: the pending attachment can
        // be REPLACED while this view lives — the id-keyed task both resets
        // the stale preview and kicks off the new decode.
        .task(id: attachment.id) {
            decodedImage = AttachmentImageCache.cachedImage(for: attachment)
            decodedImage = await AttachmentImageCache.image(for: attachment)
        }
    }
}
