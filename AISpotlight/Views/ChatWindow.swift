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
    /// In-flight assistant reply. Survives conversation switches (the reply
    /// keeps streaming in the background into its origin chat); cancelled
    /// only when the origin chat itself is deleted.
    @State private var streamingTask: Task<Void, Never>?
    /// Which conversation the in-flight reply belongs to.
    @State private var streamingOrigin: ChatStore.ConversationID?
    /// Whether the scroll position is near the newest message.
    @State private var isNearBottom = true
    /// Whether the chat content fits the viewport (no scrolling possible) —
    /// see `trackContentFits` for why the intent monitor needs it.
    @State private var scrollContentFits = true
    /// Keyboard control of voice recording: Space stops, double-Space cancels.
    @State private var voiceKeyMonitor: Any?
    @State private var scrollIntentMonitor: Any?
    @State private var pendingVoiceSend: DispatchWorkItem?
    /// When we last auto-scrolled — used to tell a real user scroll-up from a
    /// transient "content grew underneath us" geometry blip during streaming.
    @State private var lastAutoScroll = Date.distantPast
    @FocusState private var isInputFocused: Bool
    @State private var textEditorHeight: CGFloat = 27 // Default height for one line
    /// Providers offered by the header switcher (see `refreshAvailableProviders`).
    @State private var availableProviders: [ProviderID] = []

    /// Windowed history rendering: only the newest `visibleCount` messages
    /// live in the view tree, so the bottom-anchored layout lands on the
    /// latest message instantly. Scrolling to the top backfills another page.
    /// Purely presentation — the full history stays in ChatStore (and in the
    /// API context).
    private static let historyPageSize = 30
    @State private var visibleCount = ChatWindow.historyPageSize
    /// Guards against cascading backfills while one is restoring the scroll.
    @State private var isBackfilling = false
    /// Pending collapse of the widened history window (see `scheduleWindowCollapse`).
    @State private var collapseWork: DispatchWorkItem?

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

    var body: some View {
        // Liquid Glass: the panel itself is a transient overlay (functional
        // layer), so a single glassEffect wraps everything. Content inside
        // (message bubbles, input field) stays on opaque backings — no
        // glass-on-glass stacking. Pre-macOS 26 the same surface renders as
        // a translucent material (see AdaptiveGlass.swift).
        AdaptiveGlassContainer(spacing: 24) {
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
                        // Quick chat-provider switcher — only providers with keys
                        let available = availableProviders
                        if available.count > 1 {
                            Menu {
                                ForEach(available) { provider in
                                    Button {
                                        settings.chatProvider = provider
                                        // Loads the provider's model list, or the
                                        // OpenRouter catalog for manual entry —
                                        // never clobbers a user-typed slug.
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
                    }
                    .frame(height: 20)
                    .padding(.horizontal, 12)
                    .padding(.top, 5)
                }
                .frame(height: 22)

                // Chat messages area
                ScrollViewReader { proxy in
                    ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            // Backfill trigger: materializes when the user
                            // scrolls up to the oldest rendered message, and
                            // widens the window by another page — first from
                            // the in-memory history, then by paging older
                            // rows in from the store (windowed load).
                            if chatStore.messages.count > visibleCount || chatStore.hasOlderMessages {
                                HStack {
                                    Spacer()
                                    ThinkingEqualizer()
                                        .scaleEffect(0.8)
                                    Spacer()
                                }
                                .frame(height: 24)
                                .onAppear { loadOlderMessages(proxy) }
                            }

                            ForEach(visibleMessages) { message in
                                MessageRow(
                                    message: message,
                                    maxBubbleWidth: max(320, bubbleContainerWidth * 0.75),
                                    isStreamingReply: chatStore.isLoading
                                        && !message.isUser
                                        && message.id == chatStore.messages.last?.id
                                )
                                .id(message.id)
                            }

                            // "Thinking" indicator while waiting for the first streamed
                            // chunk; also shows live tool activity (web search).
                            if showThinkingIndicator {
                                HStack(spacing: 8) {
                                    ThinkingEqualizer()
                                    Text(chatStore.statusText ?? L("panel.thinking"))
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                    // ImageAddon: cancels a running image
                                    // operation; hidden otherwise.
                                    ImageOperationCancelButton()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .id("thinking-indicator")
                            }

                            // In-chat "start this local model?" prompt (assistant
                            // bubble + Yes/No), shown instead of sending straight away.
                            if let pending = pendingLocalStart {
                                localStartConfirmBubble(pending)
                                    .id("local-start-confirm")
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    // Bottom-anchored layout: freshly (re)loaded history —
                    // launch, conversation switch — is laid out already AT the
                    // newest message. Post-hoc proxy.scrollTo can't do this
                    // reliably: unrendered LazyVStack ids no-op, estimated row
                    // heights land short, and the user sees the view travel.
                    // While scrolled away from the bottom the anchor is
                    // inactive, so reading history is not yanked around.
                    .defaultScrollAnchor(.bottom)
                    // Width probe: reads the viewport width without wrapping the
                    // content in a GeometryReader (see `bubbleContainerWidth`).
                    // A no-op when the width is unchanged, so a display
                    // reconfigure that doesn't resize the window costs nothing.
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { updateContainerWidth(proxy.size.width) }
                                .onChange(of: proxy.size.width) { _, newWidth in
                                    updateContainerWidth(newWidth)
                                }
                        }
                    )
                    .trackContentFits { fits in
                        scrollContentFits = fits
                    }
                    .trackNearBottom { nearBottom in
                        if nearBottom {
                            isNearBottom = true
                            scheduleWindowCollapse()
                        } else if Date().timeIntervalSince(lastAutoScroll) > 0.5 {
                            // Only a scroll-up that happens well after our own
                            // auto-scroll counts as the user leaving the bottom.
                            // (During streaming, content growth momentarily
                            // reports "not at bottom" right before we re-scroll —
                            // treating that as user intent froze auto-follow.)
                            isNearBottom = false
                        }
                    }
                    .onChange(of: chatStore.messages.count) { oldCount, _ in
                        if oldCount == 0 {
                            // Wholesale history arrival (launch, conversation
                            // switch): render only the newest page — combined
                            // with the bottom-anchored layout the view OPENS
                            // at the last message instead of travelling there.
                            visibleCount = Self.historyPageSize
                            isBackfilling = false
                            scrollToBottom(proxy, pace: .instant)
                            // The immediate scroll runs before the LazyVStack has
                            // measured its rows; with variable-height rows the
                            // estimated content height overshoots and leaves a
                            // gap below the last message. Re-assert the bottom
                            // once (and again) after layout settles — both
                            // instant, so it reads as a single correct landing.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                scrollToBottom(proxy, pace: .instant)
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                scrollToBottom(proxy, pace: .instant)
                            }
                        } else if !isBackfilling, isNearBottom || chatStore.messages.last?.isUser == true {
                            // Own messages always jump down; incoming ones don't
                            // yank the view while the user is reading history.
                            // (A store backfill PREPENDS — it also changes the
                            // count, but must never move the viewport down.)
                            scrollToBottom(proxy)
                        }
                    }
                    .onChange(of: chatStore.messages.last?.text) {
                        // Follow streamed text as it grows
                        if isNearBottom {
                            scrollToBottom(proxy, pace: .follow)
                        }
                    }
                    .onChange(of: showThinkingIndicator) { _, visible in
                        // Reveal the "Thinking…" pill when it appears below
                        // the last message. Deferred a beat so the pill is
                        // actually laid out (scrollTo an unrendered id is a
                        // silent no-op in a LazyVStack) — and re-asserted once
                        // more after layout settles: under load (tall markdown
                        // row, attachment) 50ms is not enough and the single
                        // attempt used to no-op, leaving the pill below the
                        // fold. Same idiom as the history landing above.
                        if visible, isNearBottom {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                scrollToBottom(proxy)
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                if showThinkingIndicator, isNearBottom {
                                    scrollToBottom(proxy)
                                }
                            }
                        }
                    }
                    .onChange(of: chatStore.statusText) { _, status in
                        // A NEW status (image operation, web search) must
                        // bring the progress pill into view — its text can
                        // appear/change without the indicator toggling.
                        guard status != nil,
                              isNearBottom || chatStore.messages.last?.isUser == true else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            scrollToBottom(proxy)
                        }
                    }
                    .onChange(of: pendingLocalStart != nil) { _, visible in
                        // The local-model start confirmation appears below the
                        // last message with NO store change (the send is
                        // intercepted before performSend), so none of the other
                        // scroll triggers fire. Always scroll — it answers the
                        // user's own send. Deferred + re-asserted like the
                        // thinking pill (scrollTo an unrendered LazyVStack id
                        // is a silent no-op).
                        guard visible else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            scrollToBottom(proxy)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            if pendingLocalStart != nil {
                                scrollToBottom(proxy)
                            }
                        }
                    }
                    .onAppear {
                        // Land on the latest message when the view first loads
                        // persisted history (LazyVStack needs a beat to lay out).
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            scrollToBottom(proxy, pace: .instant)
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .chatWindowDidBecomeVisible)) { _ in
                        // Every time the panel is summoned, show the newest message.
                        DispatchQueue.main.async {
                            scrollToBottom(proxy, pace: .instant)
                        }
                    }

                    // Floating "jump to latest" button (Telegram-style)
                    if !isNearBottom {
                        Button {
                            scrollToBottom(proxy)
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
                }

                // Input area (also acts as a drag region)
                VStack(spacing: 8) {
                    // Recording status (shown when recording)
                    RecordingStatusView(isRecording: $audioRecorder.isRecording)

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
            // Untinted regular glass for the Current theme; the other themes
            // fill the panel with their gradient + signature pattern instead
            // (see themedPanelSurface). Legibility comes from the bubbles.
            .themedPanelSurface(palette, cornerRadius: 18)
        }
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
            installVoiceKeyMonitor()
            installScrollIntentMonitor()
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
            if let monitor = voiceKeyMonitor {
                NSEvent.removeMonitor(monitor)
                voiceKeyMonitor = nil
            }
            if let monitor = scrollIntentMonitor {
                NSEvent.removeMonitor(monitor)
                scrollIntentMonitor = nil
            }
        }
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
        .onReceive(NotificationCenter.default.publisher(for: .presetDeleted)) { note in
            guard let name = note.object as? String else { return }
            handlePresetDeleted(name)
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
            guard audioRecorder.autoStoppedDueToLimit == true else { return }
            // When the recorder auto-stops due to limit, send the message automatically
            Task {
                let limitMinutes = Int(Config.maxVoiceRecordingDuration / 60)
                // Small delay to ensure file is finalized
                try? await Task.sleep(nanoseconds: 300_000_000)
                if let audioURL = audioRecorder.recordingURL {
                    await sendVoiceMessage(audioURL: audioURL)
                    _ = await MainActor.run {
                        chatStore.addMessage(text: String(format: L("panel.recordLimitSent"), limitMinutes), isUser: false, messageType: .system)
                    }
                } else {
                    _ = await MainActor.run {
                        chatStore.addMessage(text: String(format: L("panel.recordLimitStopped"), limitMinutes), isUser: false, messageType: .system)
                    }
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
        let resolved = ProviderID.allCases.filter { settings.isAvailable($0) }
        if resolved != availableProviders { availableProviders = resolved }
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
    @ViewBuilder
    private func presetMenuItems(_ presets: [AppSettings.PromptPreset]) -> some View {
        ForEach(presets) { preset in
            Button {
                settings.applyPreset(named: preset.name)
            } label: {
                if preset.name == settings.activePresetName {
                    Label(preset.name, systemImage: "checkmark")
                } else {
                    Text(preset.name)
                }
            }
        }
    }

    /// Classic dropdown: icon + active preset name.
    private var presetMenu: some View {
        Menu {
            presetMenuItems(settings.switcherPresets)
        } label: {
            headerControlLabel(text: settings.activePresetName) {
                Image(systemName: "person.crop.square")
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
    private var presetChipsRow: some View {
        let presets = settings.switcherPresets
        let visible = Array(presets.prefix(Self.maxVisiblePresetChips))
        let overflow = Array(presets.dropFirst(Self.maxVisiblePresetChips))
        return HStack(spacing: 6) {
            ForEach(visible) { preset in
                Button {
                    settings.applyPreset(named: preset.name)
                } label: {
                    presetChipIcon(preset, isActive: preset.name == settings.activePresetName)
                }
                .buttonStyle(PlainButtonStyle())
                .help(preset.name)
            }
            if !overflow.isEmpty {
                let hiddenActive = overflow.first { $0.name == settings.activePresetName }
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
            chatStore.statusText = nil
            chatStore.setLoading(false)
        }
        chatStore.clearMessages()
        chatStore.addMessage(text: welcomeText(), isUser: false)
    }

    // MARK: - Isolated preset chats

    /// The conversation the active preset should be showing.
    private func targetConversation() -> ChatStore.ConversationID {
        settings.isPresetIsolated(named: settings.activePresetName)
            ? .preset(settings.activePresetName)
            : .general
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

    /// Widens the history window by one page and pins the viewport to the
    /// row that was the oldest on screen — without this the prepended rows
    /// push the content and the view visibly jumps. Two tiers: first widen
    /// over the in-memory history; once that is exhausted, page older rows
    /// in from the store (ChatStore keeps only a suffix window loaded).
    private func loadOlderMessages(_ proxy: ScrollViewProxy) {
        guard !isBackfilling else { return }
        let anchorID = visibleMessages.first?.id
        if chatStore.messages.count > visibleCount {
            isBackfilling = true
            visibleCount = min(visibleCount + Self.historyPageSize, chatStore.messages.count)
            restoreBackfillAnchor(proxy, anchorID)
        } else if chatStore.hasOlderMessages {
            isBackfilling = true
            chatStore.loadOlderPage(Self.historyPageSize) { added in
                guard added > 0 else {
                    isBackfilling = false
                    return
                }
                visibleCount = min(visibleCount + added, chatStore.messages.count)
                restoreBackfillAnchor(proxy, anchorID)
            }
        }
    }

    /// Shrinks the rendered window back to a single page once the user is
    /// parked at the newest message again.
    ///
    /// Reading history widens the window a page at a time — and it used to stay
    /// wide for the rest of the session, because nothing ever reset it. The
    /// rows themselves stay cheap (a LazyVStack only builds what is near the
    /// viewport — measured: +200 rows in the window cost ~3 MB), but the
    /// per-item passes are not lazy: `updateItemPhases`, `measureEstimates` and
    /// `applyNodes` walk EVERY item of the list on every transaction — and in
    /// the field hang report those three are most of a main thread pinned at
    /// 100% while a message was being sent. Bounding the list bounds that work.
    /// The full history stays in the store (and in the API context); this is
    /// purely how much of it is in the view tree, and scrolling up pages it
    /// back in.
    private func scheduleWindowCollapse() {
        collapseWork?.cancel()
        guard visibleCount > Self.historyPageSize else { return }
        let work = DispatchWorkItem {
            // Only while genuinely idle at the bottom of a scrollable chat: over
            // content that FITS the viewport the backfill trigger is on screen,
            // so collapsing would just re-trigger it in a loop.
            guard isNearBottom, !isBackfilling, !scrollContentFits,
                  !chatStore.isLoading, visibleCount > Self.historyPageSize else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                visibleCount = Self.historyPageSize
            }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    /// Stores the probed viewport width; persisted so the next launch's first
    /// layout starts from the real width instead of the fallback.
    private func updateContainerWidth(_ width: CGFloat) {
        guard width > 0, width != bubbleContainerWidth else { return }
        bubbleContainerWidth = width
        UserDefaults.standard.set(Double(width), forKey: Self.containerWidthDefaultsKey)
    }

    /// Re-pins the viewport to the pre-backfill anchor row after the widened
    /// window has laid out, then re-arms the backfill guard.
    private func restoreBackfillAnchor(_ proxy: ScrollViewProxy, _ anchorID: UUID?) {
        DispatchQueue.main.async { // after the widened window is laid out
            if let anchorID {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(anchorID, anchor: .top)
                }
            }
            DispatchQueue.main.async { isBackfilling = false }
        }
    }

    /// How a scroll-to-bottom should move.
    private enum ScrollPace {
        /// Large easeOut glide — a message was appended to a visible chat.
        case glide
        /// Short linear tween — per-chunk stream following; successive calls
        /// retarget the animation, so the chat scrolls continuously instead
        /// of snapping in steps.
        case follow
        /// No animation at all — landing on freshly loaded history (launch,
        /// conversation switch): the view must simply START at the bottom,
        /// not visibly travel there.
        case instant
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, pace: ScrollPace = .glide) {
        // The thinking pill and the local-start confirmation sit below the
        // last message — when visible, they are the true bottom of the list
        // (the confirm bubble renders below the pill, so it wins).
        let target: AnyHashable?
        if pendingLocalStart != nil {
            target = "local-start-confirm"
        } else if showThinkingIndicator {
            target = "thinking-indicator"
        } else {
            target = chatStore.messages.last?.id
        }
        guard let target else { return }
        lastAutoScroll = Date()
        isNearBottom = true
        switch pace {
        case .glide:
            withAnimation(.easeOut(duration: 0.3)) {
                proxy.scrollTo(target, anchor: .bottom)
            }
        case .follow:
            withAnimation(.linear(duration: 0.12)) {
                proxy.scrollTo(target, anchor: .bottom)
            }
        case .instant:
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(target, anchor: .bottom)
            }
        }
    }

    // MARK: - Sending

    /// Verifies the active chat provider is configured; posts a hint otherwise.
    private func ensureChatConfigured() -> Bool {
        // Key lookups are cache-only. In the first moments of a session the
        // cache may still be filling (or waiting on authorization), and
        // answering "no key" there would be a lie — the send path awaits the
        // warm and reports a real, specific error if the key is truly missing.
        guard APIKeyStore.isWarm else { return true }
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
        if settings.chatProvider.isLocal {
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

        streamingTask = Task { @MainActor in
            // Local canonical copy of the reply (stable UUID). The store is
            // synced from it only while `origin` is on screen; while detached
            // it just accumulates and is delivered at the end.
            var reply: ChatMessage?
            var isLive: Bool { chatStore.conversation == origin }
            // Coalesce streamed chunks before touching the store: every
            // mutation republishes `messages`, re-diffs the whole list and
            // re-parses the growing bubble's Markdown — per-chunk that adds
            // up to O(answer²) of main-thread work and froze the panel on
            // long replies. Flushing at ~8 Hz keeps streaming visually live
            // at a constant UI cost per second regardless of answer length.
            var pendingText = ""
            var lastFlush = ContinuousClock.now
            func syncToStore() {
                // Cancellation (new chat / preset deleted) must not write the
                // partial back — the catch path still calls flush() once.
                guard !Task.isCancelled,
                      let current = reply, isLive, chatStore.isHistoryLoaded else { return }
                if chatStore.messages.contains(where: { $0.id == current.id }) {
                    // Full-text replace also covers the return mid-stream:
                    // the store's copy (reloaded from disk) holds only the
                    // partial text flushed before the switch-away.
                    chatStore.setText(current.text, for: current.id)
                } else {
                    chatStore.appendNow(current)
                }
            }
            func flush() {
                guard !pendingText.isEmpty else { return }
                if var current = reply {
                    current.text += pendingText
                    reply = current
                } else {
                    reply = ChatMessage(text: pendingText, isUser: false)
                }
                pendingText = ""
                lastFlush = .now
                syncToStore()
            }
            do {
                let stream = try await ChatService.streamReply(history: history, summary: summary, store: chatStore)
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
                        if reply == nil || lastFlush.duration(to: .now) > .milliseconds(120) {
                            flush()
                        }
                    case .status(let status):
                        flush() // keep text/status ordering intact
                        if isLive { chatStore.statusText = status }
                    case .toolContext(let context):
                        // Arrives once, at the end of the turn. Stored on the
                        // reply (never rendered) so follow-up turns keep the
                        // search results as grounding.
                        flush() // materialize `reply` if text is still pending
                        if var current = reply {
                            current.toolContext = context
                            reply = current
                        }
                    }
                }
                flush()
                if !Task.isCancelled {
                    if let finished = reply {
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
            if isLive {
                chatStore.statusText = nil
                chatStore.setLoading(false)
                // Fold older turns into the rolling summary when the context
                // grows. Skipped on cancellation (the chat is being deleted).
                if !Task.isCancelled {
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
        guard let window = NSApp.windows.first(where: { $0 is FloatingPanelWindow }) else { return }
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

    /// An upward wheel/trackpad scroll in the panel is an explicit "let me
    /// read history" gesture — it must stop the streaming auto-follow at once.
    /// The time-based guard in `trackNearBottom` alone can't see it: during
    /// streaming the auto-scroll re-fires on every flush, so its 0.5s window
    /// never opens and the user's scroll was overridden on the next chunk —
    /// the panel felt frozen (a field `sample` showed a perpetual
    /// NSScrollAnimationHelper animation retargeting the bottom every frame).
    private func installScrollIntentMonitor() {
        guard scrollIntentMonitor == nil else { return }
        scrollIntentMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // Only when the content can actually scroll: over a fitting chat a
            // wheel-up changes no geometry, so nothing would ever re-arm
            // auto-follow — it would stay off until the next sent message.
            if event.window is FloatingPanelWindow, event.scrollingDeltaY > 0, !scrollContentFits {
                isNearBottom = false // trackNearBottom re-arms it at the bottom
            }
            return event
        }
    }

    // MARK: - Keyboard control while recording (Space / double-Space / Esc)

    /// While recording, Space stops (send after a short grace window),
    /// a second Space within that window cancels, Esc cancels immediately.
    /// The text editor is disabled during recording, so Space is free.
    private func installVoiceKeyMonitor() {
        guard voiceKeyMonitor == nil else { return }
        voiceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let plainKey = event.modifierFlags
                .intersection([.command, .option, .control, .shift])
                .isEmpty

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
            // Esc (keyCode 53) — instant cancel while recording
            if event.keyCode == 53, audioRecorder.isRecording {
                audioRecorder.cancelRecording()
                return nil
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

/// Scroll-position tracking with a macOS 14 fallback.
private extension View {
    /// Reports whether the scroll position is near the bottom (within ~80pt).
    /// Uses `onScrollGeometryChange` on macOS 15+; on macOS 14 the callback
    /// never fires, so `isNearBottom` keeps its default `true` — the view
    /// simply always auto-follows new messages (and the "jump to latest"
    /// button never shows).
    @ViewBuilder
    func trackNearBottom(_ onChange: @escaping (Bool) -> Void) -> some View {
        if #available(macOS 15.0, *) {
            self.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - 80
            } action: { _, nearBottom in
                onChange(nearBottom)
            }
        } else {
            self
        }
    }

    /// Reports whether the content fits the viewport (no scrolling possible).
    /// The scroll-intent monitor uses it: a wheel-up over content that cannot
    /// scroll must NOT disable auto-follow — nothing re-arms it afterwards
    /// (the scroll geometry never changes), so the chat would silently stop
    /// following until the next sent message. macOS 14 keeps the default
    /// `true`, matching its always-follow behavior.
    @ViewBuilder
    func trackContentFits(_ onChange: @escaping (Bool) -> Void) -> some View {
        if #available(macOS 15.0, *) {
            self.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height <= geometry.containerSize.height + 1
            } action: { _, fits in
                onChange(fits)
            }
        } else {
            self
        }
    }
}
