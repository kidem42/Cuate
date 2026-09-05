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

    // Streaming mode (Deepgram live WebSocket): finalized spans are inserted
    // WHILE speaking (through the same ordered cleanup chain as chunked
    // phrases); the recorded file is kept as the batch fallback for a broken
    // stream. Replaces phrase chunking for the session when armed.
    private var liveTranscriber: DeepgramLiveTranscriber?
    private var streamingFailed = false
    /// Spans handed to the insert chain this session — the fallback decision:
    /// 0 means nothing reached the screen and the recorded file may be
    /// batch-transcribed whole; >0 means the file's start is already typed
    /// and must never be transcribed again.
    private var streamEnqueuedCount = 0

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
            streamingFailed = false
            streamEnqueuedCount = 0
            await APIKeyStore.warmIfNeeded() // streamingConfig reads the key cache
            if let config = streamingConfig() {
                chunkedMode = false // the stream IS the realtime path
                armStreaming(apiKey: config.apiKey, model: config.model)
            }
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
        // Backoff, not a hammer: a Bluetooth hands-free link takes real time
        // to come up, and re-arming every ~0.5 s only re-triggered the
        // profile switch (field log 2026-09-04) — 0.5 s, 0.75 s, 1.1 s,
        // 1.7 s, 2.5 s, then 3 s steps; ~15 s in total before giving up.
        let delay = min(3, 0.5 * pow(1.5, Double(captureRetries - 1)))
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

        // A restarted engine may come back at a different sample rate, which
        // an open linear16 stream cannot renegotiate — abandon streaming and
        // let the classic salvage below own the rest of the session. When
        // live-inserted spans already cover the fragment's audio, the
        // fragment is discarded instead of salvaged (transcribing it again
        // would type the same words twice).
        var discardSalvage = false
        if liveTranscriber != nil {
            discardSalvage = streamEnqueuedCount > 0
            Diagnostics.log("dictation", "stream.abandoned on engine death — \(discardSalvage ? "fragment already typed live" : "batch salvage")")
            teardownStreaming()
            streamingFailed = true
        }
        // A fragment the VAD never flagged as speech (chunked mode), or one
        // whose raw peak never left digital silence, is the engine's own
        // spin-up — transcribing it only bills a request that comes back
        // empty (`stt.empty after retry` in the log).
        if (chunkedMode && !speechDetected) || capture.sessionPeakDB() <= -80 {
            discardSalvage = true
            Diagnostics.log("dictation", "capture.recover: fragment had no speech — discarded")
        }

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
        capture.endRecording(keepWarmSeconds: 0, releaseHold: false) { [weak self] in
            if discardSalvage {
                try? FileManager.default.removeItem(at: finishedURL)
            } else {
                self?.enqueueSegment(finishedURL)
            }
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

    // MARK: - Streaming mode (Deepgram live)

    /// Streaming is an explicit opt-in and only for Deepgram Nova-3 (the one
    /// provider/model pair with a documented raw-WebSocket live API here);
    /// anything else runs the classic file paths.
    private func streamingConfig() -> (apiKey: String, model: String)? {
        let settings = AppSettings.shared
        guard settings.dictationStreaming, settings.sttProvider == .deepgram else { return nil }
        let model = settings.sttModel(for: .deepgram)
        guard model.hasPrefix("nova-3"), let apiKey = STTProviderID.deepgram.apiKey else { return nil }
        return (apiKey, model)
    }

    private func armStreaming(apiKey: String, model: String) {
        let transcriber = DeepgramLiveTranscriber(apiKey: apiKey, model: model)
        // Finalized spans are inserted as they arrive — the "live" in live
        // streaming. NOT gated on the transcriber identity: the tail spans
        // flushed by CloseStream land after the stop already detached the
        // transcriber, and they belong in the text. Stale spans from a dead
        // session can't fire (teardown kills the receive loop) and the chain
        // itself honors `sessionCancelled`.
        transcriber.onFinal = { [weak self] span in
            // Delivered via DispatchQueue.main.async (see the transcriber) —
            // assumeIsolated instead of another hop, preserving span order
            // relative to the finish() continuation.
            MainActor.assumeIsolated {
                self?.enqueueStreamText(span)
            }
        }
        transcriber.onFailure = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.liveTranscriber === transcriber else { return }
                self.streamingFailed = true
                self.teardownStreaming()
                guard self.phase == .recording else { return }
                // Degrade to phrase chunking for the rest of the session.
                self.chunkedMode = true
                if self.streamEnqueuedCount > 0 {
                    // The recorded file's start is already typed — cut it off
                    // here and let chunking own only the speech from now on.
                    // (The last unfinalized words around the break may drop.)
                    self.discardCurrentSegmentAndContinue()
                }
                // Nothing inserted yet: keep the file whole — the chunked
                // machinery batch-transcribes it (rotation or stop).
            }
        }
        liveTranscriber = transcriber
        capture.setPCMSink { [weak transcriber] pcm, rate in
            transcriber?.feed(pcm: pcm, sampleRate: rate)
        }
    }

    /// Streaming spans skip STT (they already are text) but share the ordered
    /// cleanup+insert chain with chunked segments — spoken order guaranteed,
    /// cleanup serialized (provider rate limits, see `enqueueSegment`).
    private func enqueueStreamText(_ text: String) {
        streamEnqueuedCount += 1
        let previous = processingChain
        processingChain = Task { [weak self] in
            await previous?.value
            guard let self, !self.sessionCancelled else { return }
            var output = text
            let settings = AppSettings.shared
            if self.mode == .translate || settings.dictationCleanup {
                if let processed = await self.postProcessWithRetry(text) {
                    output = processed
                }
            }
            guard !self.sessionCancelled else { return }
            TextInserter.insert(output + " ")
        }
    }

    /// Rotates recording onto a fresh segment and DELETES the finished one —
    /// used when its audio is already represented on screen by live-inserted
    /// streaming spans and must never reach a transcriber again.
    private func discardCurrentSegmentAndContinue() {
        guard let finishedURL = fileURL else { return }
        let url = Self.segmentURL()
        fileURL = url
        segmentStart = Date()
        speechDetected = false
        silenceBegan = nil
        capture.rotate(to: url) {
            try? FileManager.default.removeItem(at: finishedURL)
        }
    }

    /// Detaches and cancels the live stream, recording its spend (Deepgram
    /// bills the audio it processed whether or not the session completed).
    private func teardownStreaming() {
        capture.setPCMSink(nil)
        guard let live = liveTranscriber else { return }
        liveTranscriber = nil
        recordStreamingSpend(model: AppSettings.shared.sttModel(for: .deepgram),
                             seconds: live.audioSeconds)
        live.cancel()
    }

    /// Streaming bills at Deepgram's live rate, not the prerecorded one —
    /// recorded under a distinct model label so the spend analytics keep the
    /// two prices apart.
    private func recordStreamingSpend(model: String, seconds: Double) {
        guard seconds > 0 else { return }
        let minutes = seconds / 60
        SpendStore.shared.record(
            kind: .stt, provider: STTProviderID.deepgram.rawValue,
            model: model + " (stream)",
            units: minutes,
            costUSD: PricingCatalog.sttStreamingPerMinute[.deepgram].map { $0 * minutes }
        )
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
              !transcript.isEmpty else {
            // A phrase dropped here is invisible to the user (chunked mode
            // inserts nothing and stays silent) — leave a trace, otherwise
            // "dictation lost a sentence" is only reconstructable from the
            // duplicate spend records.
            Diagnostics.log("dictation", "stt.empty after retry — phrase dropped")
            return nil
        }
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
        teardownStreaming()
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

        // Dead-input guard: a session whose RAW peak never left digital
        // silence would bill STT for real minutes and come back empty — the
        // log's mystery `stt.empty after retry` drops (live 2026-08-14: a
        // Bluetooth headset became the default input with its mic profile
        // never engaging, streaming zeros). Real mics never flatline (room
        // tone ≫ -80 dBFS), so this only fires on genuinely dead inputs;
        // quiet speech goes to STT exactly as before. ≥2s so an accidental
        // tap-toggle doesn't nag. Chunked sessions can only reach here
        // flatlined in full: rotation requires detected speech.
        let sessionPeak = capture.sessionPeakDB()
        if sessionPeak <= -80, Date().timeIntervalSince(segmentStart) >= 2 {
            Diagnostics.log("dictation", "silence.session peak=\(Int(sessionPeak))dB — stt skipped, input device likely dead")
            teardownStreaming()
            NSSound.beep()
            NotificationService.shared.postDictationSilentInput()
            try? FileManager.default.removeItem(at: finishedURL)
            processingChain = nil
            phase = .idle
            hideWidget()
            return
        }

        // Streaming: the spans were inserted while speaking — flush the tail
        // (CloseStream finalizes the last words, which arrive through the
        // same onFinal path) and drain the insert chain. A stream that saw
        // nothing falls through to the classic batch path on the recorded
        // file, so no audio is ever lost.
        if let live = liveTranscriber {
            capture.setPCMSink(nil)
            liveTranscriber = nil
            let tail = await live.finish()   // never-finalized interim only
            let audioSeconds = live.audioSeconds
            recordStreamingSpend(model: AppSettings.shared.sttModel(for: .deepgram),
                                 seconds: audioSeconds)
            if let tail, !tail.isEmpty {
                enqueueStreamText(tail)
            }
            if streamEnqueuedCount > 0 {
                Diagnostics.log("dictation", "stream.final spans=\(streamEnqueuedCount) audio_s=\(String(format: "%.1f", audioSeconds))")
                try? FileManager.default.removeItem(at: finishedURL)
                await processingChain?.value
                processingChain = nil
                phase = .idle
                hideWidget()
                return
            }
            Diagnostics.log("dictation", "stream.empty — batch fallback")
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

    /// Fast, cheap LLM pass: cleans fillers/punctuation, or translates. The
    /// prompt shape and the reply shaping live in `DictationTextShaping`
    /// (pure, contract-tested): instruction in the system slot, the bare
    /// transcript as the user turn, and the reply stripped of the lead-ins,
    /// quotes and Markdown small models add before it is typed anywhere.
    private func postProcess(_ transcript: String) async throws -> String {
        let settings = AppSettings.shared
        await APIKeyStore.warmIfNeeded() // key lookups below are cache-only

        // Settings → Voice → Dictation owns this choice; `resolvedDictationCleanup`
        // is the same call the settings caption renders, so the model shown
        // there is the model that runs. No usable provider = raw transcript.
        guard let choice = settings.resolvedDictationCleanup() else { return transcript }
        let provider = ProviderRegistry.provider(for: choice.provider)
        let model = choice.model
        let apiKey = (try? settings.resolvedAPIKey(for: choice.provider)) ?? ""

        let pass: DictationTextShaping.Pass
        switch mode {
        case .transcribe: pass = .cleanup
        case .translate: pass = .translate(into: settings.dictationTargetLanguage)
        }

        var result = ""
        let started = Date()
        let stream = provider.streamChat(
            messages: [LLMMessage(role: .user, text: DictationTextShaping.userMessage(transcript))],
            model: model,
            systemPrompt: DictationTextShaping.systemPrompt(for: pass),
            options: ChatRequestOptions(maxTokens: 4096, reasoning: .fast, preferNoReasoning: true),
            apiKey: apiKey
        )
        do {
            for try await event in stream {
                if case .text(let chunk) = event { result += chunk }
            }
        } catch {
            // The callers degrade to the raw transcript on failure; without
            // this line a blocked provider (a zeroed rate limit, 2026-09-04)
            // is indistinguishable from a model that ignored the instruction.
            Diagnostics.log("dictation", "cleanup.failed \(choice.provider.rawValue)/\(model) \(String(error.localizedDescription.prefix(120)))")
            throw error
        }
        // Cleanup runs once per phrase and strictly in order, so a slow model
        // here is what keeps the pill spinning after the stop — the timing is
        // the only way to tell that apart from a slow transcription.
        Diagnostics.log("dictation", "cleanup \(choice.provider.rawValue)/\(model) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
        return DictationTextShaping.shape(result, fallback: transcript)
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
    /// Queue-confined: keeps a Bluetooth headset's hands-free link up across
    /// engine restarts (see `BluetoothInputHold` for the field diagnosis).
    private let hold = BluetoothInputHold()
    /// Queue-confined: the mic choice of the last start, so an idle recovery
    /// re-arms on the SAME device instead of silently reverting to the
    /// system default.
    private var lastDeviceUID = ""

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
                // The hold stays up: the service restarts capture at once,
                // and a restart on a link that is still up is what settles.
                shutdownEngine(releaseHold: false)
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
                try ensureRunning(deviceUID: lastDeviceUID)
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
        /// RAW peak dB (RMS, absolute) since `beginRecording` — the dead-input
        /// detector. A live mic never flatlines: room tone sits far above
        /// -80 dBFS, while a Bluetooth mic whose HFP profile never engaged
        /// streams exact zeros (clamped to -90/-160 below).
        var rawPeakDB: Float = -160
        /// Live-streaming tap: every buffer, converted to linear16 mono, goes
        /// here as well as into the file (the file stays the batch fallback).
        var pcmSink: (@Sendable (_ pcm: Data, _ sampleRate: Int) -> Void)?
    }

    /// Installs/removes the linear16 side-tap (dictation streaming mode).
    func setPCMSink(_ sink: (@Sendable (_ pcm: Data, _ sampleRate: Int) -> Void)?) {
        state.lock.lock()
        state.pcmSink = sink
        state.lock.unlock()
    }

    // MARK: Control plane (serialized, off the main thread)

    /// RAW peak dB of the current/last recording session (dead-input check).
    func sessionPeakDB() -> Float {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.rawPeakDB
    }

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
                state.rawPeakDB = -160
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
    /// `releaseHold: false` keeps a Bluetooth hands-free link up through an
    /// engine-death recovery — the restart that follows must land on a link
    /// that is still up (see `BluetoothInputHold`).
    func endRecording(keepWarmSeconds: TimeInterval, releaseHold: Bool = true,
                      completion: (@MainActor () -> Void)? = nil) {
        queue.async { [self] in
            state.lock.lock()
            state.file = nil
            state.awaitingFirstBuffer = false
            state.lock.unlock()
            if keepWarmSeconds > 0 {
                scheduleCooldown(after: keepWarmSeconds)
            } else {
                shutdownEngine(releaseHold: releaseHold)
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
        lastDeviceUID = deviceUID
        // Bluetooth input: raise and hold the hands-free link BEFORE the
        // engine builds its aggregate, so the aggregate is born settled.
        armBluetoothHold(deviceUID: deviceUID)
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

    /// Resolves the input the engine is about to bind (the chosen mic, else
    /// the system default). For a Bluetooth device the hold is started
    /// first and given up to 1.5 s to actually hear the mic — the moment
    /// after which a fresh engine no longer sees a configuration change.
    /// Anything else releases a stale hold.
    private func armBluetoothHold(deviceUID: String) {
        let chosen = deviceUID.isEmpty ? nil : AudioInputDevices.deviceID(forUID: deviceUID)
        guard let input = chosen ?? AudioInputDevices.defaultInputDeviceID(),
              AudioInputDevices.isBluetooth(input) else {
            if hold.deviceID != nil {
                hold.stop()
                Diagnostics.log("dictation", "capture.hold.stop input is not bluetooth")
            }
            return
        }
        if hold.deviceID != input {
            let started = hold.start(deviceID: input)
            Diagnostics.log("dictation", "capture.hold.\(started ? "start" : "failed") device=\(AudioInputDevices.uid(input) ?? "?")")
            guard started else { return }
        }
        waitForHandsFreeLink(input: input)
    }

    /// Waits (1.5 s at most) until the hold hears the mic — the SCO link is
    /// up and the headset's output has already moved to the hands-free
    /// format — then a short grace for the tail of the switch. The output
    /// rate is logged for the record when the system output is the same
    /// headset (its nominal rate flips at the REQUEST, ~0.9 s early, which
    /// is why it is not the readiness signal).
    private func waitForHandsFreeLink(input: AudioDeviceID) {
        let began = CFAbsoluteTimeGetCurrent()
        while !hold.linkHeard, CFAbsoluteTimeGetCurrent() - began < 1.5 {
            usleep(25_000)
        }
        let heard = hold.linkHeard
        if heard { usleep(150_000) }
        let ms = Int((CFAbsoluteTimeGetCurrent() - began) * 1000)
        var outNote = ""
        if let output = AudioInputDevices.defaultOutputDeviceID(),
           let inUID = AudioInputDevices.uid(input),
           let outUID = AudioInputDevices.uid(output),
           let address = Self.bluetoothAddress(inUID),
           address == Self.bluetoothAddress(outUID) {
            outNote = " out=\(Int(AudioInputDevices.nominalSampleRate(output) ?? 0))"
        }
        Diagnostics.log("dictation", "capture.hold.link \(heard ? "heard" : "timeout") ms=\(ms)\(outNote)")
    }

    /// "88-C9-E8-3A-AC-D5:input" → "88-C9-E8-3A-AC-D5": a Bluetooth
    /// headset's input and output devices share the address part. UIDs
    /// without a colon (built-in, USB) never match anything.
    private static func bluetoothAddress(_ uid: String) -> String? {
        guard let colon = uid.lastIndex(of: ":") else { return nil }
        return String(uid[..<colon])
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

    private func shutdownEngine(releaseHold: Bool = true) {
        cooldown?.cancel()
        cooldown = nil
        if releaseHold, hold.deviceID != nil {
            hold.stop()
            Diagnostics.log("dictation", "capture.hold.stop")
        }
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
        let pcmSink = state.pcmSink
        state.lock.unlock()

        // Streaming side-tap: EVERY buffer (not just the throttled UI frames)
        // — dropped buffers would be dropped words. The sink only enqueues.
        if let pcmSink, let pcm = linear16Data(from: buffer) {
            pcmSink(pcm, Int(buffer.format.sampleRate))
        }

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
        state.rawPeakDB = max(state.rawPeakDB, db)
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

    /// Channel 0 as 16-bit signed little-endian PCM (Deepgram `linear16`).
    /// vDSP on ≤2048 frames is microseconds — safe on the audio thread.
    private static func linear16Data(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return nil }
        var scaled = [Float](repeating: 0, count: count)
        var scale = Float(Int16.max)
        vDSP_vsmul(channel, 1, &scale, &scaled, 1, vDSP_Length(count))
        var low = Float(Int16.min), high = Float(Int16.max)
        vDSP_vclip(scaled, 1, &low, &high, &scaled, 1, vDSP_Length(count))
        var ints = [Int16](repeating: 0, count: count)
        vDSP_vfix16(scaled, 1, &ints, 1, vDSP_Length(count))
        return ints.withUnsafeBufferPointer { Data(buffer: $0) }
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

    static func defaultInputDeviceID() -> AudioDeviceID? {
        systemDevice(kAudioHardwarePropertyDefaultInputDevice)
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        systemDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func uid(_ id: AudioDeviceID) -> String? {
        stringProperty(id, kAudioDevicePropertyDeviceUID)
    }

    /// Classic or LE Bluetooth transport — a headset's hands-free mic.
    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyTransportType)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return false }
        return value == kAudioDeviceTransportTypeBluetooth || value == kAudioDeviceTransportTypeBluetoothLE
    }

    static func nominalSampleRate(_ id: AudioDeviceID) -> Double? {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func systemDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var addr = address(selector)
        var id: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
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
