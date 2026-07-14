import Foundation
import AppKit
import AVFoundation
import SwiftUI
import Combine
import Carbon

/// System-wide dictation (Superwhisper-style): a global hotkey starts
/// recording, a tiny Liquid Glass pill under the camera notch shows live mic
/// levels, and on stop the transcript (optionally cleaned up or translated by
/// a fast LLM) is pasted into whatever text field currently has focus.
@MainActor
final class DictationService: NSObject, ObservableObject {
    static let shared = DictationService()

    enum Mode {
        case transcribe
        case translate
    }

    enum Phase: Equatable {
        case idle
        case recording
        case processing
    }

    @Published var phase: Phase = .idle
    /// Normalized mic level 0…1 for the equalizer.
    @Published var level: Float = 0

    private var mode: Mode = .transcribe
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var fileURL: URL?
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()

    // Chunked (phrase-by-phrase) mode: pause detection + ordered processing
    private var chunkedMode = false
    private var segmentStart = Date()
    private var speechDetected = false
    private var silenceBegan: Date?
    private var processingChain: Task<Void, Never>?
    private var sessionCancelled = false

    /// VAD thresholds on raw meter dB: below `silenceDB` counts as a pause,
    /// above `speechDB` marks that the segment actually contains speech.
    private let silenceDB: Float = -38
    private let speechDB: Float = -28
    private let pauseDuration: TimeInterval = 0.9
    private let minSegmentDuration: TimeInterval = 1.5

    override init() {
        super.init()
        // Keep the widget in sync if the theme changes while it's on screen.
        // (async: @Published fires before NSApp.appearance is actually updated)
        AppSettings.shared.$appearanceMode
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.panel?.appearance = NSApp.appearance
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Hotkey entry point

    /// Same hotkey starts and stops. A second mode's hotkey while recording
    /// also stops (whatever is captured gets processed in the started mode).
    func toggle(mode: Mode) {
        Diagnostics.log("dictation", "toggle mode=\(mode) phase=\(phase)")
        switch phase {
        case .idle:
            start(mode: mode)
        case .recording:
            Task { await stopAndProcess() }
        case .processing:
            break
        }
    }

    // MARK: - Recording

    private func start(mode: Mode) {
        self.mode = mode

        // Prompt for Accessibility up front (needed to paste into other apps).
        _ = TextInserter.checkAccessibility(promptIfNeeded: true)

        Task { @MainActor in
            guard await requestMicPermission() else {
                NSSound.beep()
                return
            }

            chunkedMode = AppSettings.shared.dictationChunked
            sessionCancelled = false
            processingChain = nil
            speechDetected = false
            silenceBegan = nil

            do {
                let (recorder, url) = try makeSegmentRecorder()
                self.recorder = recorder
                self.fileURL = url
                self.segmentStart = Date()
                self.phase = .recording
                showWidget()
                startMetering()
            } catch {
                NSSound.beep()
            }
        }
    }

    private func makeSegmentRecorder() throws -> (AVAudioRecorder, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation_\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.record()
        return (recorder, url)
    }

    private func requestMicPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default: return false
        }
    }

    private func startMetering() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                let db = recorder.averagePower(forChannel: 0) // -160…0 dB
                self.level = max(0, min(1, (db + 50) / 50))
                if self.chunkedMode, self.phase == .recording {
                    self.voiceActivityTick(db: db)
                }
            }
        }
    }

    // MARK: - Chunked mode (phrase-by-phrase)

    /// Pause detection: once the segment contains speech and a ≥0.9 s pause
    /// is observed, the segment is rotated out for processing while recording
    /// continues seamlessly on a fresh file.
    private func voiceActivityTick(db: Float) {
        if db > speechDB {
            speechDetected = true
            silenceBegan = nil
            return
        }
        if db < silenceDB {
            if silenceBegan == nil { silenceBegan = Date() }
        } else {
            silenceBegan = nil
        }

        guard speechDetected,
              let silenceBegan,
              Date().timeIntervalSince(silenceBegan) >= pauseDuration,
              Date().timeIntervalSince(segmentStart) >= minSegmentDuration else { return }
        rotateSegment()
    }

    /// Closes the current audio segment (cut inside a pause), immediately
    /// starts a new one, and queues the finished file for ordered processing.
    private func rotateSegment() {
        guard let finishedURL = fileURL else { return }
        recorder?.stop()
        do {
            let (recorder, url) = try makeSegmentRecorder()
            self.recorder = recorder
            self.fileURL = url
        } catch {
            self.recorder = nil
            self.fileURL = nil
        }
        segmentStart = Date()
        speechDetected = false
        silenceBegan = nil
        enqueueSegment(finishedURL)
    }

    /// Segments are processed strictly in order (each task awaits the previous
    /// one), so phrases are inserted in the order they were spoken.
    private func enqueueSegment(_ url: URL) {
        let previous = processingChain
        processingChain = Task { [weak self] in
            await previous?.value
            await self?.processSegment(url)
        }
    }

    private func processSegment(_ url: URL) async {
        defer { try? FileManager.default.removeItem(at: url) }
        guard !sessionCancelled else { return }

        guard let transcript = try? await TranscriptionService.transcribe(audioURL: url),
              !transcript.isEmpty else { return }

        var text = transcript
        let settings = AppSettings.shared
        if mode == .translate || settings.dictationCleanup {
            if let processed = try? await postProcess(transcript) {
                text = processed
            }
        }

        guard !sessionCancelled else { return }
        TextInserter.insert(text + " ")
    }

    func cancel() {
        sessionCancelled = true // pending segments will skip insertion
        processingChain = nil
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
        recorder = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        phase = .idle
        hideWidget()
    }

    // MARK: - Stop → transcribe → post-process → paste

    func stopAndProcess() async {
        guard phase == .recording, let fileURL else { return }
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
        recorder = nil
        phase = .processing

        if chunkedMode {
            // Queue the final segment and wait for the ordered pipeline to drain.
            self.fileURL = nil
            enqueueSegment(fileURL)
            await processingChain?.value
            processingChain = nil
            phase = .idle
            hideWidget()
            return
        }

        defer {
            try? FileManager.default.removeItem(at: fileURL)
            self.fileURL = nil
            phase = .idle
            hideWidget()
        }

        do {
            let transcript = try await TranscriptionService.transcribe(audioURL: fileURL)
            guard !transcript.isEmpty else { NSSound.beep(); return }

            var text = transcript
            let settings = AppSettings.shared
            if mode == .translate || settings.dictationCleanup {
                if let processed = try? await postProcess(transcript) {
                    text = processed
                }
                // Post-processing is best-effort: on failure the raw transcript is used.
            }

            TextInserter.insert(text)
        } catch {
            NSSound.beep()
        }
    }

    /// Fast, cheap LLM pass: cleans fillers/punctuation, or translates.
    /// Uses mistral-small when a Mistral key exists, otherwise the active chat model.
    private func postProcess(_ transcript: String) async throws -> String {
        let settings = AppSettings.shared

        let provider: LLMProvider
        let model: String
        let apiKey: String
        if let mistralKey = APIKeyStore.key(for: .mistral) {
            provider = OpenAICompatibleProvider.mistral
            model = "mistral-small-latest"
            apiKey = mistralKey
        } else if let chatKey = APIKeyStore.key(for: settings.chatProvider),
                  let chatModel = settings.selectedModel(for: settings.chatProvider) {
            provider = ProviderRegistry.provider(for: settings.chatProvider)
            model = chatModel
            apiKey = chatKey
        } else {
            return transcript
        }

        let prompt: String
        switch mode {
        case .transcribe:
            prompt = """
Clean up this dictated text: remove filler words (um, uh, эм, эээ, ну, короче as filler), false starts and accidental repetitions; fix spelling and punctuation. Keep the original language, meaning and tone. Do not add anything. Output ONLY the cleaned text, nothing else.

\(transcript)
"""
        case .translate:
            prompt = """
Translate this dictated text into \(settings.dictationTargetLanguage). First mentally clean it up (drop filler words, false starts, accidental repetitions), then produce a natural, well-punctuated translation. Output ONLY the translated text, nothing else.

\(transcript)
"""
        }

        var result = ""
        let stream = provider.streamChat(
            messages: [LLMMessage(role: .user, text: prompt)],
            model: model,
            systemPrompt: nil,
            options: ChatRequestOptions(maxTokens: 4096, reasoning: .fast),
            apiKey: apiKey
        )
        for try await event in stream {
            if case .text(let chunk) = event { result += chunk }
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? transcript : trimmed
    }

    // MARK: - Widget (Liquid Glass pill under the camera notch)

    private func showWidget() {
        if panel == nil {
            let panel = NonKeyPanel(
                contentRect: NSRect(x: 0, y: 0, width: 148, height: 34),
                // .nonactivatingPanel + a canBecomeKey=false subclass guarantee
                // the widget never steals focus from the field being dictated
                // into (borderless panels can otherwise become key).
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .statusBar
            panel.hasShadow = true
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let hosting = NSHostingView(rootView: DictationWidgetView(service: self))
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
            panel.contentView = hosting
            self.panel = panel
        }

        // Follow the app's theme override (Auto/Light/Dark). Non-activating
        // panels don't reliably inherit NSApp.appearance, so sync explicitly
        // on every show.
        panel?.appearance = NSApp.appearance

        positionUnderNotch()
        panel?.orderFrontRegardless()
    }

    private func positionUnderNotch() {
        guard let panel, let screen = NSScreen.main else { return }
        let size = panel.frame.size
        // Directly under the camera housing (safe area) on notched Macs;
        // just under the menu bar on external displays.
        let topInset = screen.safeAreaInsets.top > 0
            ? screen.safeAreaInsets.top
            : (screen.frame.maxY - screen.visibleFrame.maxY)
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.maxY - topInset - size.height - 4
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func hideWidget() {
        panel?.orderOut(nil)
        level = 0
    }
}

/// A panel that can never become key or main — so showing it doesn't pull
/// keyboard focus away from the app the user is dictating into.
private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Widget view

/// Minimal Liquid Glass pill: live equalizer while recording (click = stop),
/// tiny spinner while processing. Nothing else.
private struct DictationWidgetView: View {
    @ObservedObject var service: DictationService

    var body: some View {
        AdaptiveGlassContainer {
            HStack(spacing: 8) {
                if service.phase == .processing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    EqualizerBars(level: service.level)
                }
            }
            .frame(width: 148, height: 34)
            .contentShape(Capsule())
            .onTapGesture {
                if service.phase == .recording {
                    Task { await service.stopAndProcess() }
                }
            }
            .adaptiveGlassCapsule()
        }
        .help("Click or press the dictation hotkey to stop")
    }
}

/// Live mic-level bars driven by the real input level.
private struct EqualizerBars: View {
    let level: Float
    private let barCount = 14

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(Color.primary.opacity(0.75))
                        .frame(width: 2.5, height: barHeight(index: index, time: time))
                }
            }
        }
    }

    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        // Each bar oscillates with its own phase, scaled by the real mic level.
        let wobble = 0.5 + 0.5 * sin(time * 9 + Double(index) * 1.1)
        let value = CGFloat(level) * CGFloat(0.35 + 0.65 * wobble)
        return 3 + 15 * min(1, value * 1.6)
    }
}

// MARK: - Pasting into the focused app

/// Inserts text at the current cursor location of whatever app has focus:
/// clipboard + synthesized ⌘V (the previous clipboard is restored afterwards).
/// Requires the Accessibility permission (app is not sandboxed).
enum TextInserter {
    @discardableResult
    static func checkAccessibility(promptIfNeeded: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: promptIfNeeded] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func insert(_ text: String) {
        let pasteboard = NSPasteboard.general
        let savedString = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard checkAccessibility(promptIfNeeded: false) else {
            // No permission to synthesize ⌘V — at least the text is on the
            // clipboard, the user can paste manually.
            NSSound.beep()
            return
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        // Restore the previous clipboard after the paste lands.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if let savedString {
                pasteboard.clearContents()
                pasteboard.setString(savedString, forType: .string)
            }
        }
    }
}
