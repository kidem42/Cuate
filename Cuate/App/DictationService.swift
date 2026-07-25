import Foundation
import Accelerate
import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import SwiftUI
import Combine
import Carbon

/// System-wide dictation (Superwhisper-style): a global hotkey starts
/// recording, a tiny Liquid Glass pill under the camera notch shows live mic
/// levels, and the transcript (optionally cleaned up or translated by a fast
/// LLM) is pasted into whatever text field currently has focus — phrase by
/// phrase while speaking (chunked mode, default) or all at once on stop. In
/// translate mode the pill shows the target language's ISO badge; clicking it
/// switches the language mid-dictation.
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

    /// Published so the widget can show the translate-mode language badge.
    @Published private(set) var mode: Mode = .transcribe
    /// False from the hotkey until the first audio buffer actually arrives:
    /// the pill shows warm-up dots instead of the equalizer while the mic
    /// hardware spins up (~100–300 ms built-in, seconds on Bluetooth), so
    /// the user doesn't speak into a mic that isn't hearing yet.
    @Published private(set) var micReady = false
    /// Warm-up capture retries used this session (see `retryCaptureDuringWarmup`).
    private var captureRetries = 0
    /// Bluetooth profile flaps can hold the input hostage for several
    /// seconds; the growing backoff below spans ~8 s in total.
    private static let maxCaptureRetries = 8
    /// Mid-recording engine deaths recovered this session (see
    /// `recoverFromMidRecordingDeath`).
    private var engineDeaths = 0
    private static let maxEngineDeaths = 5
    /// Normalized 0…1 magnitudes of `MicCapture.bandCount` log-spaced voice
    /// bands — the pill's equalizer renders the REAL input spectrum.
    @Published private(set) var spectrum: [Float] = Array(repeating: 0, count: MicCapture.bandCount)
    private let capture = MicCapture()
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

    /// VAD thresholds on the dB EXCESS over the adaptive noise floor (the
    /// capture reports gain-independent values — absolute dBFS thresholds
    /// silently stopped detecting speech when the metering source changed,
    /// which killed phrase chunking): above `speechDB` marks speech, below
    /// `silenceDB` counts as a pause.
    private let silenceDB: Float = 8
    private let speechDB: Float = 15
    /// 0.7 s: every phrase the VAD cuts DURING dictation is a phrase the
    /// stop doesn't have to wait for — the tail after stop is at most one
    /// short segment. 0.9 felt safer against splitting slow speech, but it
    /// grew the tail; with the gapless rotation a split now costs nothing.
    private let pauseDuration: TimeInterval = 0.7
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

        // Real audio drives the pill and the VAD.
        capture.onCaptureStarted = { [weak self] in
            guard let self else { return }
            self.micReady = true
            self.captureRetries = 0
            // The phrase timer starts when audio actually flows — hardware
            // spin-up must not eat into the minimum segment length.
            self.segmentStart = Date()
        }
        capture.onAudio = { [weak self] dbExcess, bands in
            guard let self else { return }
            // dbExcess is "how far over the room's noise floor" — ~0 in
            // silence, ~15–40 while speaking, on any mic at any gain.
            self.level = max(0, min(1, dbExcess / 40))
            // Fast attack / slower release per band: raw FFT frames are
            // jumpy, this keeps the bars lively without flicker.
            self.spectrum = zip(self.spectrum, bands).map { old, new in
                new > old ? old + (new - old) * 0.6 : old + (new - old) * 0.25
            }
            if self.chunkedMode, self.phase == .recording {
                self.voiceActivityTick(db: dbExcess)
            }
        }
        capture.onError = { [weak self] in
            guard let self, self.phase == .recording else { return }
            // A start that failed before the first buffer is the same
            // device-settling window as an early engine death — retry
            // silently before giving up with a beep.
            if self.retryCaptureDuringWarmup("start.error") { return }
            NSSound.beep()
            self.cancel()
        }

        // Warm window turned off / mic changed in Settings: release the idle
        // engine (the next start re-arms with the new device). Mid-recording
        // changes apply to the NEXT session — never yank a live capture.
        AppSettings.shared.$dictationWarmMinutes
            .dropFirst()
            .sink { [weak self] minutes in
                guard let self, self.phase == .idle, minutes <= 0 else { return }
                self.capture.shutdown()
            }
            .store(in: &cancellables)
        AppSettings.shared.$dictationMicUID
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, self.phase == .idle else { return }
                self.capture.shutdown()
            }
            .store(in: &cancellables)
        // The capture engine actually DIED mid-session (device unplugged):
        // salvage what was recorded so far. Spurious configuration-change
        // notifications (initial device pick, aggregate reshuffles) are
        // filtered inside MicCapture — they used to kill the session right
        // after the warm-up animation.
        capture.onEngineDied = { [weak self] in
            guard let self else { return }
            guard self.phase == .recording else { return }
            // Death BEFORE the first buffer isn't a lost recording — it's a
            // Bluetooth mic mid-profile-switch (A2DP↔HFP): the input appears,
            // the engine starts, and ~100 ms later the device reconfigures
            // under it (log signature: engine.start at 16 kHz → died in
            // 130 ms, three sessions in a row). There is nothing to salvage,
            // so keep the session alive in its warm-up state and retry until
            // the device settles.
            if self.retryCaptureDuringWarmup("engine.died") { return }
            // Death AFTER audio flowed: same flap, one negotiation later
            // (field log: retried start runs ~0.8 s of real capture, then the
            // route reconfigures again). Treat it as a forced phrase boundary
            // — salvage the fragment into the pipeline and keep the session
            // recording on a fresh segment — instead of ending the dictation
            // with a stub.
            if self.recoverFromMidRecordingDeath() { return }
            Task { @MainActor in await self.stopAndProcess() }
        }
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

        // Open the TLS connection to the STT provider while the user is still
        // speaking — the first phrase's transcription then skips the ~200–500 ms
        // DNS+TCP+TLS handshake (HTTPClient.session pools the connection).
        TranscriptionService.prewarmConnection()

        // Mic already authorized (the common case): the pill appears
        // IMMEDIATELY in its warm-up state (pulsing dots) and flips to the
        // live equalizer only when the first real buffer arrives. The engine
        // spin-up runs off the main thread on the capture queue, so the
        // warm-up animation actually animates even while a Bluetooth mic
        // takes seconds to power up. First-ever use (system permission
        // prompt pending) keeps the conservative order — no pill flashing
        // behind a permission dialog.
        let preAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if preAuthorized {
            micReady = false
            phase = .recording
            showWidget()
        }

        Task { @MainActor in
            if !preAuthorized {
                guard await requestMicPermission() else {
                    NSSound.beep()
                    return
                }
            }
            // A lightning double-tap may have cancelled while we yielded.
            if preAuthorized, phase != .recording { return }

            chunkedMode = AppSettings.shared.dictationChunked
            sessionCancelled = false
            captureRetries = 0
            engineDeaths = 0
            processingChain = nil
            speechDetected = false
            silenceBegan = nil
            spectrum = Array(repeating: 0, count: MicCapture.bandCount)
            if !preAuthorized {
                micReady = false
                phase = .recording
                showWidget()
            }
            let url = Self.segmentURL()
            fileURL = url
            segmentStart = Date()
            capture.beginRecording(to: url, deviceUID: AppSettings.shared.dictationMicUID)
        }
    }

    /// While no real audio has arrived yet (`micReady == false`), a dead or
    /// failed capture engine is treated as "the input device hasn't settled"
    /// — the session stays in its warm-up state (pulsing dots) and capture
    /// is retried with a growing delay instead of ending the session. Only
    /// once the retries are spent does the failure surface. Returns whether
    /// a retry was scheduled.
    private func retryCaptureDuringWarmup(_ reason: String) -> Bool {
        guard phase == .recording, !micReady,
              captureRetries < Self.maxCaptureRetries else { return false }
        captureRetries += 1
        let delay = 0.3 + 0.15 * Double(captureRetries) // 0.45 s … 1.5 s
        Diagnostics.log("dictation", "capture.retry #\(captureRetries) after \(reason)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.phase == .recording, !self.micReady,
                  let url = self.fileURL else { return }
            self.capture.beginRecording(to: url, deviceUID: AppSettings.shared.dictationMicUID)
        }
        return true
    }

    /// Engine death after real audio arrived = the device flap outlived the
    /// warm-up. The captured fragment is queued for transcription exactly
    /// like a phrase boundary, and capture restarts on a fresh segment —
    /// the session keeps going instead of ending on a stub. Bounded per
    /// session so a hopeless device eventually surfaces the failure.
    /// Returns whether the session was kept alive.
    private func recoverFromMidRecordingDeath() -> Bool {
        guard phase == .recording, engineDeaths < Self.maxEngineDeaths,
              let finishedURL = fileURL else { return false }
        engineDeaths += 1
        Diagnostics.log("dictation", "capture.recover #\(engineDeaths): salvage segment, restart capture")

        // Non-chunked sessions degrade to phrase-by-phrase from here on:
        // fragments across an engine death cannot be joined into one file,
        // and the ordered pipeline already knows how to type them in order.
        chunkedMode = true

        // Back to the warm-up state: pill shows dots, and if the restarted
        // engine dies before audio flows again, the warm-up retry ladder
        // (fresh budget) handles it with backoff.
        micReady = false
        captureRetries = 0

        let url = Self.segmentURL()
        fileURL = url
        segmentStart = Date()
        speechDetected = false
        silenceBegan = nil

        // endRecording on the (already dead) engine is a barrier on the
        // capture queue: its completion runs after the finished file's
        // handle is released, so the fragment is finalized and safe to
        // upload. The subsequent beginRecording is queued behind it.
        capture.endRecording(keepWarmSeconds: 0) { [weak self] in
            self?.enqueueSegment(finishedURL)
        }
        capture.beginRecording(to: url, deviceUID: AppSettings.shared.dictationMicUID)
        return true
    }

    private static func segmentURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation_\(UUID().uuidString).m4a")
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

    /// Closes the current audio segment (cut inside a pause) and queues it
    /// for ordered processing. The file swap happens under the running tap —
    /// recording continues into the fresh file with no gap, so no words are
    /// lost at phrase boundaries.
    private func rotateSegment() {
        guard let finishedURL = fileURL else { return }
        let url = Self.segmentURL()
        fileURL = url
        segmentStart = Date()
        speechDetected = false
        silenceBegan = nil
        capture.rotate(to: url) { [weak self] in
            // Runs after the finished file is finalized — safe to upload.
            self?.enqueueSegment(finishedURL)
        }
    }

    /// Each segment's STT starts IMMEDIATELY (parallel — that's where the
    /// stop-tail latency win lives); the LLM cleanup + insertion stay
    /// CHAINED in spoken order. Sequential cleanup is not just about
    /// ordering: when cleanups ran in parallel they tripped the provider's
    /// rate limit (Mistral: ~1 req/s), the 429 was swallowed and phrases
    /// silently fell back to the raw unpunctuated transcript — sentences
    /// randomly lost their periods and dashes.
    private func enqueueSegment(_ url: URL) {
        let stt = Task { await self.transcribeSegment(url) }
        let previous = processingChain
        processingChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            guard let transcript = await stt.value, !self.sessionCancelled else { return }
            var text = transcript
            let settings = AppSettings.shared
            if self.mode == .translate || settings.dictationCleanup {
                if let processed = await self.postProcessWithRetry(transcript) {
                    text = processed
                }
            }
            guard !self.sessionCancelled else { return }
            TextInserter.insert(text + " ")
        }
    }

    /// STT for one segment (parallel-safe). One retry after a short backoff:
    /// a transient 429/network hiccup must not DROP the phrase entirely.
    private func transcribeSegment(_ url: URL) async -> String? {
        defer { try? FileManager.default.removeItem(at: url) }
        guard !sessionCancelled else { return nil }
        if let transcript = try? await TranscriptionService.transcribe(audioURL: url),
           !transcript.isEmpty {
            return transcript
        }
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard !sessionCancelled else { return nil }
        guard let transcript = try? await TranscriptionService.transcribe(audioURL: url),
              !transcript.isEmpty else { return nil }
        return transcript
    }

    /// One retry after a short backoff: a transient failure must not degrade
    /// a phrase to the raw unpunctuated transcript.
    private func postProcessWithRetry(_ transcript: String) async -> String? {
        if let processed = try? await postProcess(transcript) { return processed }
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard !sessionCancelled else { return nil }
        return try? await postProcess(transcript)
    }

    func cancel() {
        sessionCancelled = true // pending segments will skip insertion
        processingChain = nil
        let keepWarm = TimeInterval(AppSettings.shared.dictationWarmMinutes) * 60
        if let url = fileURL {
            // Delete only after the capture queue released the file handle.
            capture.endRecording(keepWarmSeconds: keepWarm) {
                try? FileManager.default.removeItem(at: url)
            }
        } else {
            capture.endRecording(keepWarmSeconds: keepWarm)
        }
        fileURL = nil
        micReady = false
        phase = .idle
        hideWidget()
    }

    // MARK: - Stop → transcribe → post-process → paste

    func stopAndProcess() async {
        guard phase == .recording else { return }
        guard let finishedURL = fileURL else {
            // Stop arrived before the mic even spun up (the pill shows
            // optimistically) — nothing was captured, treat as cancel.
            cancel()
            return
        }
        fileURL = nil
        phase = .processing

        // The segment file is finalized on the capture queue — wait for that
        // before handing it to the transcriber. The engine itself either
        // keeps running warm (Settings → keep mic ready) or releases the mic.
        let keepWarm = TimeInterval(AppSettings.shared.dictationWarmMinutes) * 60
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            capture.endRecording(keepWarmSeconds: keepWarm) { continuation.resume() }
        }

        if chunkedMode {
            // Queue the final segment and wait for the ordered pipeline to drain.
            enqueueSegment(finishedURL)
            await processingChain?.value
            processingChain = nil
            phase = .idle
            hideWidget()
            return
        }

        defer {
            try? FileManager.default.removeItem(at: finishedURL)
            phase = .idle
            hideWidget()
        }

        do {
            let transcript = try await TranscriptionService.transcribe(audioURL: finishedURL)
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
        await APIKeyStore.warmIfNeeded() // key lookups below are cache-only

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
Clean up this dictated text: remove filler words (um, uh, эм, эээ, ну, короче as filler), false starts and accidental repetitions; fix spelling and punctuation. Keep the original language, meaning and tone. Do not add anything. Never use the "—" character. Output ONLY the cleaned text, nothing else.

\(transcript)
"""
        case .translate:
            prompt = """
Translate this dictated text into \(settings.dictationTargetLanguage). First mentally clean it up (drop filler words, false starts, accidental repetitions), then produce a natural, well-punctuated translation. Never use the "—" character. Output ONLY the translated text, nothing else.

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
        let trimmed = Self.stripEmDashes(from: result.trimmingCharacters(in: .whitespacesAndNewlines))
        return trimmed.isEmpty ? transcript : trimmed
    }

    /// Models sprinkle em dashes no matter what the prompt says, and the
    /// app-wide rule (`AppSettings.mandatoryPromptRules`) bans them — enforce
    /// it mechanically: "app—text" / "app — text" both become "app - text".
    private static func stripEmDashes(from text: String) -> String {
        guard text.contains("—") else { return text }
        return text
            .replacingOccurrences(of: "[ \\t]*—[ \\t]*", with: " - ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Widget (Liquid Glass pill under the camera notch)

    /// Wider in translate mode to fit the language badge.
    var widgetSize: NSSize {
        NSSize(width: mode == .translate ? 182 : 148, height: 34)
    }

    private func showWidget() {
        if panel == nil {
            let panel = NonKeyPanel(
                contentRect: NSRect(origin: .zero, size: widgetSize),
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

        // The panel is reused across sessions; the width depends on the mode.
        panel?.setContentSize(widgetSize)
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
/// tiny spinner while processing. In translate mode also shows the target
/// language's ISO code; right-click switches the language mid-dictation.
private struct DictationWidgetView: View {
    @ObservedObject var service: DictationService
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var scheme

    /// The dictation panel is a separate window; it reads the selected theme
    /// straight from settings (the panel's appearance drives `colorScheme`).
    private var palette: ThemePalette { ThemePalette.palette(for: settings.theme, scheme: scheme) }

    var body: some View {
        AdaptiveGlassContainer {
            HStack(spacing: 8) {
                if service.phase == .processing {
                    // Transcription/cleanup in flight: indeterminate running line.
                    RunningLine()
                } else if !service.micReady {
                    // Mic hardware still spinning up: pulsing dots say "not
                    // hearing yet" — they flip to live bars on the first buffer.
                    WarmupDots()
                } else {
                    EqualizerBars(level: service.level, spectrum: service.spectrum)
                }
                if service.mode == .translate {
                    // Left-clicking the badge opens the language menu (the
                    // rest of the pill still stops on click).
                    Menu {
                        languagePicker
                    } label: {
                        Text(AppSettings.dictationISOCode(for: settings.dictationTargetLanguage))
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(palette.isGlass ? AnyShapeStyle(.secondary) : AnyShapeStyle(palette.ink))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(Capsule().fill(palette.isGlass ? Color.primary.opacity(0.08) : palette.accent.opacity(0.15)))
                            .overlay(
                                Capsule().stroke(palette.isGlass ? Color.clear : palette.accent.opacity(0.4), lineWidth: 1)
                            )
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(L("tooltip.dictation.language"))
                }
            }
            .frame(width: service.widgetSize.width, height: service.widgetSize.height)
            .contentShape(Capsule())
            .onTapGesture {
                if service.phase == .recording {
                    Task { await service.stopAndProcess() }
                }
            }
            .contextMenu {
                if service.mode == .translate {
                    languagePicker
                }
            }
            // Themed tint sits between the glass material and the content, so the
            // pill picks up the theme's color (same panelTint the chat panel uses);
            // glass themes stay untinted.
            .background {
                if !palette.isGlass {
                    Capsule().fill(palette.panelTint)
                }
            }
            .adaptiveGlassCapsule()
            // Themed pill border over the glass (Día: marigold hairline).
            .overlay {
                if !palette.isGlass {
                    Capsule().stroke(palette.ink.opacity(0.4), lineWidth: 1)
                }
            }
        }
        .help(L("tooltip.dictation.stop"))
    }

    /// Shared between the badge's click menu and the pill's right-click menu.
    /// Takes effect immediately: postProcess reads the setting per segment,
    /// so upcoming phrases use the new language.
    private var languagePicker: some View {
        Picker(L("dictation.translateTo"), selection: $settings.dictationTargetLanguage) {
            ForEach(AppSettings.dictationLanguages, id: \.self) { language in
                Text(language).tag(language)
            }
        }
        .pickerStyle(.inline)
    }
}

/// Shared color logic for the pill's indicators: the dictation panel is a
/// separate window, so the theme is read straight from settings (the panel's
/// appearance drives `colorScheme`). Themes with a multi-color dictation
/// palette cycle their colors per element (Día: marigold/magenta/teal).
private func dictationBarColor(_ index: Int, theme: AppTheme, scheme: ColorScheme) -> Color {
    let palette = ThemePalette.palette(for: theme, scheme: scheme)
    if palette.isGlass { return Color.primary.opacity(0.75) }
    let colors = palette.dictationColors.isEmpty ? [palette.accent] : palette.dictationColors
    return colors[index % colors.count]
}

/// Live spectrum bars: each bar is a real log-spaced frequency band of the
/// input (80 Hz … 8 kHz via FFT), not a synthetic wobble — bass on the left,
/// sibilants on the right, and the picture follows the actual voice timbre.
private struct EqualizerBars: View {
    let level: Float
    var spectrum: [Float] = []
    private let barCount = MicCapture.bandCount
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(dictationBarColor(index, theme: settings.theme, scheme: colorScheme))
                    .frame(width: 2.5, height: barHeight(index))
            }
        }
        .animation(.linear(duration: 0.06), value: spectrum)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        // The band magnitude leads; the broadband level keeps a faint floor
        // while speaking so quiet bands never look fully dead.
        let band = index < spectrum.count ? CGFloat(spectrum[index]) : 0
        let value = max(band, CGFloat(level) * 0.12)
        return 3 + 15 * min(1, value)
    }
}

/// Warm-up state: three pulsing dots (typing-indicator style) while the mic
/// hardware spins up — deliberately unlike the equalizer, so "not hearing
/// yet" and "recording" can't be confused. No sound cues by design.
private struct WarmupDots: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 7) {
                ForEach(0..<3, id: \.self) { index in
                    let pulse = 0.5 + 0.5 * sin(time * 5.2 - Double(index) * 1.9)
                    Circle()
                        .fill(dictationBarColor(index, theme: settings.theme, scheme: colorScheme))
                        .frame(width: 7, height: 7)
                        .scaleEffect(0.8 + 0.35 * pulse)
                        .opacity(0.35 + 0.65 * pulse)
                }
            }
        }
    }
}

/// Processing state: a thin indeterminate track with a running segment
/// (replaces the system spinner — same semantics, pill-native look).
private struct RunningLine: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var settings = AppSettings.shared

    private let trackWidth: CGFloat = 74
    private let runnerWidth: CGFloat = 26

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let phase = time.truncatingRemainder(dividingBy: 1.3) / 1.3
            let color = dictationBarColor(0, theme: settings.theme, scheme: colorScheme)
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.22))
                Capsule()
                    .fill(color)
                    .frame(width: runnerWidth)
                    .offset(x: -runnerWidth + (trackWidth + runnerWidth) * phase)
            }
            .frame(width: trackWidth, height: 3)
            .clipShape(Capsule())
        }
    }
}

// MARK: - Microphone capture engine

/// AVAudioEngine-backed microphone capture. Replaces AVAudioRecorder for
/// dictation because it can do what the recorder can't:
/// - record from a CHOSEN input device (Settings → Voice → Microphone),
///   silently falling back to the system default when that device is gone;
/// - keep the input running after a session ("warm window") so the next
///   dictation starts with zero hardware spin-up — CoreAudio power-up costs
///   ~100–300 ms on the built-in mic and SECONDS on Bluetooth (HFP switch),
///   which is exactly where the first dictated words were being lost;
/// - rotate segment files under the running tap (gapless phrase chunking);
/// - expose raw buffers, so the pill's equalizer can show the REAL voice
///   spectrum (log-spaced bands via vDSP FFT) instead of a synthetic wobble.
///
/// Threading: control methods hop onto a private serial queue and never
/// block the caller — a cold Bluetooth start takes seconds and must not
/// freeze the warm-up animation. The tap callback runs on the audio thread
/// and only touches lock-guarded state. UI callbacks fire on the main thread.
/// Recoverable capture failures — thrown (and caught) instead of letting
/// AVFAudio abort the process.
enum MicCaptureError: Error {
    /// The input node reported an empty format (device switching / not ready).
    case deviceNotReady
}

nonisolated final class MicCapture {

    /// Fired once per recording session when the first buffer actually
    /// arrives — the mic is REALLY hearing now (pill flips dots → bars).
    var onCaptureStarted: (@MainActor () -> Void)?
    /// ~20 Hz on the main thread: broadband dB EXCESS over the adaptive
    /// noise floor (≈0 in silence, ~15–40 while speaking, on any mic at any
    /// gain — drives the level indicator and the VAD) and the normalized
    /// 0…1 spectrum for the equalizer bars.
    var onAudio: (@MainActor (_ dbExcess: Float, _ spectrum: [Float]) -> Void)?
    /// A recording session failed to start (device trouble) — main thread.
    var onError: (@MainActor () -> Void)?
    /// The engine STOPPED for real mid-session (device vanished and a
    /// restart failed) — main thread. Spurious configuration-change
    /// notifications never reach this.
    var onEngineDied: (@MainActor () -> Void)?

    /// Equalizer resolution; matches the pill's bar count.
    static let bandCount = 14
    private static let fftSize = 1024
    /// Voice band edges: 80 Hz … 8 kHz, log-spaced.
    private static let bandLowHz: Float = 80
    private static let bandHighHz: Float = 8000

    /// Recreated on every cold start (`ensureRunning`) — see the comment
    /// there. Mutated only on `queue` after init.
    private var engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "cuate.mic.capture")
    private let state = State()
    /// Queue-confined: pending warm-window expiry.
    private var cooldown: DispatchWorkItem?
    private var configObserver: NSObjectProtocol?

    init() {
        observeConfigurationChanges()
    }

    /// OUR engine only (object:) — a global observer used to catch every
    /// engine's configuration chatter, including the benign one posted
    /// when the engine starts on a user-selected device, and killed the
    /// dictation right after the warm-up animation. Re-registered every
    /// time the engine is recreated, so the observer always tracks the
    /// live instance.
    private func observeConfigurationChanges() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    deinit {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
    }

    /// A configuration change is only fatal when the engine actually stopped
    /// (input device disappeared). A warm idle engine restarts silently on
    /// whatever input is now current; a live RECORDING can't continue (the
    /// open file carries the old device's format), so it's surfaced as dead
    /// and the service salvages what was captured so far.
    private func handleConfigurationChange() {
        queue.async { [self] in
            state.lock.lock()
            let running = state.engineRunning
            let recording = state.file != nil
            state.lock.unlock()
            guard running, !engine.isRunning else { return }
            if recording {
                Diagnostics.log("dictation", "capture.engine.died mid-recording")
                shutdownEngine()
                DispatchQueue.main.async { self.onEngineDied?() }
                return
            }
            do {
                // Warm idle: rebuild the tap for the new device's format.
                state.lock.lock()
                state.engineRunning = false
                state.bandFloors = []
                state.levelFloor = nil
                state.lock.unlock()
                engine.inputNode.removeTap(onBus: 0)
                try ensureRunning(deviceUID: "")
                Diagnostics.log("dictation", "capture.engine.recovered")
            } catch {
                Diagnostics.log("dictation", "capture.engine.died \(String(error.localizedDescription.prefix(120)))")
                shutdownEngine()
            }
        }
    }

    /// Lock-guarded state shared with the audio-thread tap.
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var file: AVAudioFile?
        var awaitingFirstBuffer = false
        var engineRunning = false
        var lastEmit: CFAbsoluteTime = 0
        var sampleRate: Float = 44100
        var fft: FFTSetup?
        var windowCurve: [Float] = []
        /// Per-band adaptive noise floor (dB, min-tracker): bars show the
        /// EXCESS over this floor, so silence sits at zero on any mic/gain
        /// and speech reads as real dynamics. Slowly rises (recovers after
        /// loud stretches), instantly drops to a new quieter floor.
        var bandFloors: [Float] = []
        /// Broadband twin of `bandFloors` — the excess over it drives the
        /// level indicator AND the VAD (gain-independent thresholds).
        var levelFloor: Float?
    }

    // MARK: Control plane (serialized, off the main thread)

    /// Starts (or reuses, when warm) the engine and begins writing to `url`.
    func beginRecording(to url: URL, deviceUID: String) {
        queue.async { [self] in
            cooldown?.cancel()
            cooldown = nil
            do {
                try ensureRunning(deviceUID: deviceUID)
                let file = try makeFile(at: url)
                state.lock.lock()
                state.file = file
                state.awaitingFirstBuffer = true
                state.lock.unlock()
            } catch {
                Diagnostics.log("dictation", "capture.start.error \(String(error.localizedDescription.prefix(120)))")
                shutdownEngine()
                DispatchQueue.main.async { self.onError?() }
            }
        }
    }

    /// Closes the current segment file and opens a fresh one at `url` WITHOUT
    /// stopping the engine — buffers keep flowing into the new file, so no
    /// audio is lost at phrase boundaries. `completion` runs on the main
    /// thread after the old file is finalized (safe to upload).
    func rotate(to url: URL, completion: @escaping @MainActor () -> Void) {
        queue.async { [self] in
            let next = try? makeFile(at: url)
            state.lock.lock()
            state.file = next // the old AVAudioFile releases here → finalized
            state.lock.unlock()
            DispatchQueue.main.async { completion() }
        }
    }

    /// Stops writing. With `keepWarmSeconds > 0` the engine keeps running and
    /// discards samples (the orange mic indicator stays on) so the next start
    /// is instant; a cooldown then releases the mic. `completion` (main
    /// thread) runs after the recording file is finalized.
    func endRecording(keepWarmSeconds: TimeInterval, completion: (@MainActor () -> Void)? = nil) {
        queue.async { [self] in
            state.lock.lock()
            state.file = nil
            state.awaitingFirstBuffer = false
            state.lock.unlock()
            if keepWarmSeconds > 0 {
                scheduleCooldown(after: keepWarmSeconds)
            } else {
                shutdownEngine()
            }
            if let completion {
                DispatchQueue.main.async { completion() }
            }
        }
    }

    /// Releases the mic now regardless of the warm window (Settings changed).
    func shutdown() {
        queue.async { [self] in shutdownEngine() }
    }

    // MARK: Engine lifecycle (queue-confined)

    private func ensureRunning(deviceUID: String) throws {
        state.lock.lock()
        let running = state.engineRunning
        state.lock.unlock()
        guard !running else { return }

        // Cold start: ALWAYS on a fresh engine. AVAudioEngine's input node
        // binds to the device that was current when the engine was FIRST
        // touched and keeps that binding — device AND cached stream format —
        // across stop(); it is never renegotiated. Unplugging/plugging
        // headphones while idle therefore left the old engine permanently
        // wedged: every start failed with -10868 (FormatNotSupported) until
        // the app was relaunched. (Setting kAudioOutputUnitProperty_-
        // CurrentDevice on the initialized unit does NOT refresh the cached
        // format — the 3.17 attempt, disproven by the field log.) A fresh
        // engine binds cleanly to whatever input is live right now, and its
        // cost is trivial next to the mic hardware spin-up a cold start
        // already pays. The warm window is untouched — a running engine
        // never reaches this path.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        observeConfigurationChanges()

        let input = engine.inputNode
        // Selected mic; an unresolved UID (device unplugged) falls through
        // to the system default input.
        if !deviceUID.isEmpty,
           let deviceID = AudioInputDevices.deviceID(forUID: deviceUID),
           let unit = input.audioUnit {
            var id = deviceID
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &id,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }

        // The format the node reports right after a device switch (or before a
        // just-selected mic is ready) can be empty. Installing a tap with a
        // 0-channel / 0 Hz format aborts the whole process inside AVFAudio, so
        // bail cleanly instead — the configuration-change observer rebuilds the
        // tap once the device settles.
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw MicCaptureError.deviceNotReady
        }
        state.lock.lock()
        state.sampleRate = Float(format.sampleRate)
        if state.fft == nil {
            state.fft = vDSP_create_fftsetup(vDSP_Length(log2(Float(Self.fftSize))), FFTRadix(kFFTRadix2))
            var curve = [Float](repeating: 0, count: Self.fftSize)
            vDSP_hann_window(&curve, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
            state.windowCurve = curve
        }
        state.lock.unlock()

        input.removeTap(onBus: 0) // stale tap from a previous device/format
        let st = state
        // Pass nil, not `format`: switching the input device reconfigures the
        // node asynchronously, so an explicit format read a moment earlier can
        // be stale by the time the tap is installed — AVFAudio then aborts with
        // "Failed to create tap due to format mismatch". nil binds the tap to
        // the node's live format atomically, immune to that race. (The buffer
        // carries its own format; `handle` reads the rate from it.)
        input.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            Self.handle(buffer: buffer, state: st) { db, spectrum, isFirst in
                DispatchQueue.main.async {
                    if isFirst { self.onCaptureStarted?() }
                    self.onAudio?(db, spectrum)
                }
            }
        }
        engine.prepare()
        try engine.start()
        state.lock.lock()
        state.engineRunning = true
        state.lock.unlock()
        Diagnostics.log("dictation", "capture.engine.start device=\(deviceUID.isEmpty ? "auto" : "custom") rate=\(Int(format.sampleRate))")
    }

    private func makeFile(at url: URL) throws -> AVAudioFile {
        let format = engine.inputNode.outputFormat(forBus: 0)
        // AAC's maximum bitrate scales with sample rate × channels. A fixed
        // 64 kbps is fine at 44.1/48 kHz but the encoder rejects it (error
        // '!dat') at the 16 kHz — or 8 kHz — mono that a Bluetooth headset mic
        // reports over HFP, i.e. exactly when a single earbud is the input.
        // Scale the target to the format so any rate encodes.
        let channels = max(1, Int(format.channelCount))
        let bitRate = min(64_000, Int(format.sampleRate) * channels * 2)
        return try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: bitRate,
            ],
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
    }

    private func scheduleCooldown(after seconds: TimeInterval) {
        cooldown?.cancel()
        let item = DispatchWorkItem { [self] in
            state.lock.lock()
            let recording = state.file != nil
            state.lock.unlock()
            if !recording { shutdownEngine() }
        }
        cooldown = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func shutdownEngine() {
        cooldown?.cancel()
        cooldown = nil
        state.lock.lock()
        let wasRunning = state.engineRunning
        state.engineRunning = false
        state.file = nil
        state.awaitingFirstBuffer = false
        // The next session may run on a different device/gain — its noise
        // floors must be learned from scratch.
        state.bandFloors = []
        state.levelFloor = nil
        state.lock.unlock()
        guard wasRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        Diagnostics.log("dictation", "capture.engine.stop")
    }

    // MARK: Audio thread

    private static func handle(buffer: AVAudioPCMBuffer, state: State,
                               emit: (Float, [Float], Bool) -> Void) {
        var isFirst = false
        state.lock.lock()
        if state.awaitingFirstBuffer {
            state.awaitingFirstBuffer = false
            isFirst = true
        }
        // The tap is installed with a nil format, so the true rate is whatever
        // the node settled on — take it from the buffer, keeping the FFT bins
        // honest regardless of what was read at install time.
        let bufRate = Float(buffer.format.sampleRate)
        if bufRate > 0 { state.sampleRate = bufRate }
        if let file = state.file {
            try? file.write(from: buffer)
        }
        let now = CFAbsoluteTimeGetCurrent()
        let due = isFirst || now - state.lastEmit >= 0.045
        if due { state.lastEmit = now }
        let fft = state.fft
        let windowCurve = state.windowCurve
        let sampleRate = state.sampleRate
        state.lock.unlock()

        guard due, let samples = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
        // Clamped like the bands: digital silence must not poison trackers.
        let db: Float = max(-90, rms > 0 ? 20 * log10(rms) : -160)

        let rawBands = spectrum(samples: samples, count: count, fft: fft,
                                windowCurve: windowCurve, sampleRate: sampleRate)
        // Normalize against adaptive noise floors (min-trackers): displayed
        // values are the EXCESS over the quiet-room level of THIS mic at
        // THIS gain — silence ≈ 0, no absolute-calibration guesswork (raw
        // FFT/RMS dB scales vary wildly between devices).
        //
        // The floors initialize RELATIVE to the first meaningful frame
        // (raw − 12 dB): if dictation starts mid-speech the bars come up at
        // a modest height and settle at the first word gap, instead of the
        // old absolute init that pegged everything at max for seconds. The
        // engine's leading all-zero buffers are skipped entirely.
        var bands = [Float](repeating: 0, count: bandCount)
        var dbExcess: Float = 0
        state.lock.lock()
        let heardSomething = db > -85 || rawBands.contains { $0 > -85 }
        if state.bandFloors.count != bandCount, heardSomething {
            state.bandFloors = rawBands.map { $0 - 12 }
        }
        if state.bandFloors.count == bandCount {
            for i in 0..<bandCount {
                let raw = rawBands[i]
                // Min-tracker with a leash: rises ~10 dB/s after loud
                // stretches, snaps down instantly, and never lags more than
                // 45 dB below the signal (self-heals after gain jumps).
                state.bandFloors[i] = min(max(state.bandFloors[i] + 0.5, raw - 45), raw)
                bands[i] = min(1, max(0, (raw - state.bandFloors[i] - 8) / 30))
            }
        }
        if state.levelFloor == nil, heardSomething {
            state.levelFloor = db - 12
        }
        if let floor = state.levelFloor {
            let updated = min(max(floor + 0.5, db - 45), db)
            state.levelFloor = updated
            dbExcess = max(0, db - updated)
        }
        state.lock.unlock()
        emit(dbExcess, bands, isFirst)
    }

    /// 1024-point real FFT → `bandCount` log-spaced voice bands, 0…1.
    /// Costs single-digit microseconds on Accelerate hardware — negligible
    /// against the ~46 ms buffer cadence.
    private static func spectrum(samples: UnsafeMutablePointer<Float>, count: Int,
                                 fft: FFTSetup?, windowCurve: [Float],
                                 sampleRate: Float) -> [Float] {
        guard let fft, count >= fftSize, windowCurve.count == fftSize else {
            return [Float](repeating: 0, count: bandCount)
        }
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(samples, 1, windowCurve, 1, &windowed, 1, vDSP_Length(fftSize))

        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { windowPtr in
                    windowPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, vDSP_Length(log2(Float(fftSize))), FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        let binWidth = sampleRate / Float(fftSize)
        let ratio = bandHighHz / bandLowHz
        var bands = [Float](repeating: 0, count: bandCount)
        for band in 0..<bandCount {
            let f0 = bandLowHz * pow(ratio, Float(band) / Float(bandCount))
            let f1 = bandLowHz * pow(ratio, Float(band + 1) / Float(bandCount))
            let b0 = max(1, Int(f0 / binWidth))
            let b1 = min(fftSize / 2 - 1, max(b0 + 1, Int(f1 / binWidth)))
            var sum: Float = 0
            for bin in b0..<b1 { sum += magnitudes[bin] }
            let mean = sum / Float(b1 - b0)
            // Raw band energy in dB (uncalibrated — the adaptive per-band
            // floor in `handle` turns it into a displayable 0…1 excess).
            // Clamped at −90: the engine's first buffers are digital SILENCE
            // (all zeros), and an unclamped log10 would report ~−3000 dB —
            // poisoning the min-tracking floor for minutes.
            bands[band] = max(-90, 10 * log10(mean + .leastNormalMagnitude))
        }
        return bands
    }
}

// MARK: - Input device enumeration (CoreAudio)

/// Lists audio input devices and resolves persisted UIDs for the dictation
/// microphone picker. UIDs are stable across reboots and replugs; numeric
/// device IDs are not — only UIDs are stored in settings.
nonisolated enum AudioInputDevices {
    struct Device: Identifiable, Equatable {
        let uid: String
        let name: String
        var id: String { uid }
    }

    static func inputDevices() -> [Device] {
        allDeviceIDs().compactMap { id in
            guard inputChannelCount(id) > 0,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
            let name = stringProperty(id, kAudioObjectPropertyName) ?? uid
            return Device(uid: uid, name: name)
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first {
            inputChannelCount($0) > 0 && stringProperty($0, kAudioDevicePropertyDeviceUID) == uid
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
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
