import SwiftUI
import Combine
import AppKit
import Foundation

extension Notification.Name {
    static let chatWindowDidBecomeVisible = Notification.Name("chatWindowDidBecomeVisible")
}

struct ChatWindow: View {
    @ObservedObject private var chatStore = ChatStore()
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var audioRecorder = AudioRecorder()
    @State private var handledAutoStopToken: UUID = UUID()
    @State private var messageText = ""
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
    /// Whether the scroll position is near the newest message.
    @State private var isNearBottom = true
    /// Keyboard control of voice recording: Space stops, double-Space cancels.
    @State private var voiceKeyMonitor: Any?
    @State private var pendingVoiceSend: DispatchWorkItem?
    /// When we last auto-scrolled — used to tell a real user scroll-up from a
    /// transient "content grew underneath us" geometry blip during streaming.
    @State private var lastAutoScroll = Date.distantPast
    @FocusState private var isInputFocused: Bool
    @State private var textEditorHeight: CGFloat = 27 // Default height for one line

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
                GeometryReader { geo in
                ScrollViewReader { proxy in
                    ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(chatStore.messages) { message in
                                MessageRow(
                                    message: message,
                                    maxBubbleWidth: max(320, geo.size.width * 0.75)
                                )
                                .id(message.id)
                            }

                            // "Thinking" indicator while waiting for the first streamed
                            // chunk; also shows live tool activity (web search).
                            if showThinkingIndicator {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text(chatStore.statusText ?? L("panel.thinking"))
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .id("thinking-indicator")
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .background(.clear)
                    .trackNearBottom { nearBottom in
                        if nearBottom {
                            isNearBottom = true
                        } else if Date().timeIntervalSince(lastAutoScroll) > 0.5 {
                            // Only a scroll-up that happens well after our own
                            // auto-scroll counts as the user leaving the bottom.
                            // (During streaming, content growth momentarily
                            // reports "not at bottom" right before we re-scroll —
                            // treating that as user intent froze auto-follow.)
                            isNearBottom = false
                        }
                    }
                    .onChange(of: chatStore.messages.count) {
                        // Own messages always jump down; incoming ones don't
                        // yank the view while the user is reading history.
                        if isNearBottom || chatStore.messages.last?.isUser == true {
                            scrollToBottom(proxy)
                        }
                    }
                    .onChange(of: chatStore.messages.last?.text) {
                        // Follow streamed text as it grows
                        if isNearBottom {
                            scrollToBottom(proxy, animated: false)
                        }
                    }
                    .onChange(of: showThinkingIndicator) { _, visible in
                        // Reveal the "Thinking…" pill when it appears below
                        // the last message.
                        if visible, isNearBottom {
                            DispatchQueue.main.async { scrollToBottom(proxy) }
                        }
                    }
                    .onAppear {
                        // Land on the latest message when the view first loads
                        // persisted history (LazyVStack needs a beat to lay out).
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            scrollToBottom(proxy, animated: false)
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .chatWindowDidBecomeVisible)) { _ in
                        // Every time the panel is summoned, show the newest message.
                        DispatchQueue.main.async {
                            scrollToBottom(proxy, animated: false)
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
                }

                // Input area (also acts as a drag region)
                VStack(spacing: 8) {
                    // Recording status (shown when recording)
                    RecordingStatusView(isRecording: $audioRecorder.isRecording)

                    Divider()

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
                            canExtractText: MistralOCRService.isAvailable && attachment.mimeType.hasPrefix("image"),
                            removeAction: clearCurrentAttachment,
                            extractTextAction: { extractText(from: attachment) }
                        )
                        .padding(.horizontal, 12)
                    }

                    HStack(alignment: .bottom, spacing: 8) {
                        // Multi-line text input
                        ZStack(alignment: .topLeading) {
                            if messageText.isEmpty {
                                Text(L("panel.typeMessage"))
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary.opacity(0.5))
                                    .padding(.leading, 7)
                                    .padding(.top, 7)
                                    .allowsHitTesting(false)
                            }

                            CustomTextEditor(
                                text: $messageText,
                                measuredHeight: $textEditorHeight,
                                onSubmit: sendMessage,
                                isDisabled: audioRecorder.isRecording
                            )
                            .frame(height: textEditorHeight)
                            .focused($isInputFocused)
                            .help(L("tooltip.input"))
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                        // System material keeps text legible on any wallpaper
                        // and adapts to Reduce Transparency automatically.
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.ultraThinMaterial)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
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
                        .help(audioRecorder.isRecording ? L("tooltip.voice.stop") : L("tooltip.voice.start"))

                        // Send button
                        Button(action: sendMessage) {
                            ZStack {
                                Circle()
                                    .fill(Color.accentColor.opacity(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.3 : 1.0))
                                    .frame(width: 32, height: 32)

                                Image(systemName: "paperplane.fill")
                                    .foregroundColor(.white)
                                    .font(.system(size: 14, weight: .medium))
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || audioRecorder.isRecording)
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
            // Untinted regular glass: heavy tints flatten the material by
            // muting its refraction and specular edge highlights — the depth
            // IS the glass. Legibility comes from the bubbles' materials.
            .adaptiveGlass(cornerRadius: 18)
        }
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
            self.pendingAttachment = appState.pendingAttachment
            installVoiceKeyMonitor()
        }
        .onReceive(appState.$pendingAttachment) { attachment in
            self.pendingAttachment = attachment
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
                        chatStore.addMessage(text: "Recording reached the limit of \(limitMinutes) minutes and was sent automatically.", isUser: false, messageType: .system)
                    }
                } else {
                    _ = await MainActor.run {
                        chatStore.addMessage(text: "Recording reached the limit of \(limitMinutes) minutes and was stopped.", isUser: false, messageType: .system)
                    }
                }
            }
        }
    }

    private func welcomeText() -> String {
        L("panel.welcome")
    }

    /// Chat providers that currently have an API key — for the quick switcher.
    private var availableProviders: [ProviderID] {
        ProviderID.allCases.filter { APIKeyStore.hasKey(for: $0) }
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
            presetMenuItems(settings.allPresets)
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
        let presets = settings.allPresets
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
        chatStore.clearMessages()
        chatStore.addMessage(text: welcomeText(), isUser: false)
    }

    /// Whether the "Thinking…" pill is currently in the list.
    private var showThinkingIndicator: Bool {
        chatStore.isLoading && (chatStore.statusText != nil || chatStore.messages.last?.isUser == true)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        // The thinking pill sits below the last message — when visible,
        // it is the true bottom of the list.
        let target: AnyHashable? = showThinkingIndicator
            ? "thinking-indicator"
            : chatStore.messages.last?.id
        guard let target else { return }
        lastAutoScroll = Date()
        isNearBottom = true
        // Always animate: large jumps glide with easeOut, while per-chunk
        // stream following uses a short linear tween — successive calls
        // retarget the animation, so the chat scrolls continuously instead
        // of snapping in steps.
        let animation: Animation = animated
            ? .easeOut(duration: 0.3)
            : .linear(duration: 0.12)
        withAnimation(animation) {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    // MARK: - Sending

    /// Verifies the active chat provider is configured; posts a hint otherwise.
    private func ensureChatConfigured() -> Bool {
        guard APIKeyStore.hasKey(for: settings.chatProvider) else {
            chatStore.addMessage(text: L("panel.noProviderKey"), isUser: false, messageType: .system)
            return false
        }
        guard settings.selectedModel(for: settings.chatProvider) != nil else {
            chatStore.addMessage(text: L("panel.noModelSelected"), isUser: false, messageType: .system)
            return false
        }
        return true
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard ensureChatConfigured() else {
            messageText = ""
            return
        }

        // Add user message immediately (synchronously, so the history snapshot includes it)
        let attachmentToSend = pendingAttachment
        let attachments = attachmentToSend.map { [$0] } ?? []
        let userMessage = ChatMessage(text: text, isUser: true, attachments: attachments)
        chatStore.appendNow(userMessage)
        messageText = "" // the editor re-measures itself back to one line
        clearCurrentAttachment()

        streamAssistantReply()
    }

    /// Streams the assistant reply for the current history into the chat,
    /// then triggers best-effort context compression.
    private func streamAssistantReply() {
        chatStore.setLoading(true)
        chatStore.statusText = nil
        pendingRetry = nil
        let history = chatStore.activeContextMessages
        let summary = chatStore.conversationSummary

        Task { @MainActor in
            var assistantID: UUID?
            // Coalesce streamed chunks before touching the store: every
            // mutation republishes `messages`, re-diffs the whole list and
            // re-parses the growing bubble's Markdown — per-chunk that adds
            // up to O(answer²) of main-thread work and froze the panel on
            // long replies. Flushing at ~8 Hz keeps streaming visually live
            // at a constant UI cost per second regardless of answer length.
            var pendingText = ""
            var lastFlush = ContinuousClock.now
            func flush() {
                guard !pendingText.isEmpty else { return }
                if let id = assistantID {
                    chatStore.appendChunk(pendingText, to: id)
                } else {
                    let message = ChatMessage(text: pendingText, isUser: false)
                    chatStore.appendNow(message)
                    assistantID = message.id
                }
                pendingText = ""
                lastFlush = .now
            }
            do {
                let stream = try await ChatService.streamReply(history: history, summary: summary)
                for try await event in stream {
                    switch event {
                    case .text(let chunk):
                        // Text is flowing — the thinking/search pill must go
                        // away (otherwise it lingers *below* the growing
                        // answer bubble, since it renders after the messages).
                        if chatStore.statusText != nil {
                            chatStore.statusText = nil
                        }
                        pendingText += chunk
                        // The first chunk flushes immediately so the bubble
                        // appears the moment text starts flowing.
                        if assistantID == nil || lastFlush.duration(to: .now) > .milliseconds(120) {
                            flush()
                        }
                    case .status(let status):
                        flush() // keep text/status ordering intact
                        chatStore.statusText = status
                    }
                }
                flush()
                if assistantID == nil {
                    chatStore.addMessage(text: "(empty reply)", isUser: false)
                }
            } catch {
                flush()
                if let id = assistantID {
                    chatStore.appendChunk("\n\n⚠️ \(error.localizedDescription)", to: id)
                } else {
                    chatStore.addMessage(text: error.localizedDescription, isUser: false, messageType: .system)
                }
                pendingRetry = .chat
            }
            chatStore.statusText = nil
            chatStore.setLoading(false)

            // Fold older turns into the rolling summary when the context grows.
            await ChatService.compressHistoryIfNeeded(store: chatStore)
        }
    }

    // MARK: - Attachments / OCR

    private func clearCurrentAttachment() {
        pendingAttachment = nil
        appState.clearPendingAttachment()
    }

    /// Runs Mistral OCR on the pending image. The result is structured
    /// markdown (headings, lists, tables mirror the original layout): it is
    /// shown rendered in the chat and the raw markdown is copied to the
    /// clipboard for pasting into editors.
    private func extractText(from attachment: ChatAttachment) {
        guard !isExtractingText else { return }
        isExtractingText = true

        Task { @MainActor in
            do {
                let markdown = try await MistralOCRService.extractText(
                    imageBase64: attachment.base64,
                    mimeType: attachment.mimeType
                )
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(markdown, forType: .string)
                clearCurrentAttachment()
                // Show the source screenshot in the chat, then the extracted text.
                chatStore.appendNow(ChatMessage(text: "", isUser: true, attachments: [attachment]))
                chatStore.addMessage(text: markdown, isUser: false)
                chatStore.addMessage(text: "Extracted with OCR — structure preserved as Markdown, raw text copied to the clipboard.", isUser: false, messageType: .system)
            } catch {
                chatStore.addMessage(text: "OCR failed: \(error.localizedDescription)", isUser: false, messageType: .system)
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
                    chatStore.addMessage(text: "Failed to start recording. Please check microphone permissions in System Settings.", isUser: false, messageType: .system)
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

        chatStore.setLoading(true)
        pendingRetry = nil
        do {
            let transcript = try await TranscriptionService.transcribe(audioURL: audioURL)
            guard !transcript.isEmpty else {
                chatStore.setLoading(false)
                chatStore.addMessage(text: "The recording contained no recognizable speech.", isUser: false, messageType: .system)
                return
            }
            let voiceMessage = ChatMessage(text: transcript, isUser: true, messageType: .voice, audioURL: audioURL)
            chatStore.appendNow(voiceMessage)
            streamAssistantReply()
        } catch {
            chatStore.setLoading(false)
            chatStore.addMessage(text: "Transcription failed: \(error.localizedDescription)", isUser: false, messageType: .system)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if attachment.mimeType.hasPrefix("image"),
               let data = attachment.data,
               let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
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
}
