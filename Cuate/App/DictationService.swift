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
/// recording, a black island flush with the camera housing shows the live
/// spectrum and glows in the theme's recording color, and the transcript
/// (optionally cleaned up or translated by a fast LLM) is pasted into
/// whatever text field currently has focus — phrase by phrase while speaking
/// (chunked mode, default) or all at once on stop. In translate mode the
/// island shows a chip with the target language's ISO code; clicking it
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
    /// The one pending warm-up retry (see `retryCaptureDuringWarmup`):
    /// cancelled when the session ends or a new one starts, so a stale
    /// timer never fires a capture start into the next session (field log
    /// 2026-09-07: leftover retries from one session hammered the next
    /// one faster than the backoff allows).
    private var pendingCaptureRetry: Task<Void, Never>?
    /// Bumped on every session start and cancel. A `stopAndProcess` that
    /// resumes after an await compares against it and keeps its hands off
    /// a session that has since replaced the one it was finishing.
    private var sessionGeneration = 0
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
            self.cancelPendingCaptureRetry()
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
            // A second press while the pill is still spinning abandons the
            // session: nothing that hasn't been typed yet will be, and the
            // pill goes away. The way out of a wedged stop (field log
            // 2026-09-07: the capture queue sat inside CoreAudio for six
            // minutes while a Bluetooth aggregate was rebuilt) and of a
            // slow cleanup model.
            Diagnostics.log("dictation", "cancel.processing")
            cancel()
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
            sessionGeneration += 1
            cancelPendingCaptureRetry()
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
        cancelPendingCaptureRetry()
        pendingCaptureRetry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.phase == .recording, !self.micReady,
                  let url = self.fileURL else { return }
            self.pendingCaptureRetry = nil
            self.capture.beginRecording(to: url, deviceUID: AppSettings.shared.dictationMicUID)
        }
        return true
    }

    private func cancelPendingCaptureRetry() {
        pendingCaptureRetry?.cancel()
        pendingCaptureRetry = nil
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
        cancelPendingCaptureRetry()

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
        sessionGeneration += 1  // a stop in flight must not touch the pill again
        cancelPendingCaptureRetry()
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
        cancelPendingCaptureRetry()
        guard let finishedURL = fileURL else {
            // Stop arrived before the mic even spun up (the pill shows
            // optimistically) — nothing was captured, treat as cancel.
            cancel()
            return
        }
        fileURL = nil
        phase = .processing
        let generation = sessionGeneration

        // The segment file is finalized on the capture queue — wait for that
        // before handing it to the transcriber. The unit itself either keeps
        // running warm (Settings → keep mic ready) or releases the mic.
        let keepWarm = TimeInterval(AppSettings.shared.dictationWarmMinutes) * 60
        let finalized = await releaseCapture(finishedURL, keepWarmSeconds: keepWarm)
        guard generation == sessionGeneration else {
            // Cancelled from the hotkey while waiting: the session is over,
            // only the finalized file is left to clean up.
            if finalized { try? FileManager.default.removeItem(at: finishedURL) }
            return
        }
        guard finalized else {
            // The capture queue is wedged inside CoreAudio (a device mid-
            // reconfiguration): there is no file to transcribe and no telling
            // when there will be. Abandon the session rather than hold the
            // pill hostage; the late completion deletes the file.
            Diagnostics.log("dictation", "capture.stop.abandoned — capture queue did not release the file")
            teardownStreaming()
            NSSound.beep()
            finishSession(generation)
            return
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
            finishSession(generation)
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
            guard generation == sessionGeneration else {
                try? FileManager.default.removeItem(at: finishedURL)
                return
            }
            if let tail, !tail.isEmpty {
                enqueueStreamText(tail)
            }
            if streamEnqueuedCount > 0 {
                Diagnostics.log("dictation", "stream.final spans=\(streamEnqueuedCount) audio_s=\(String(format: "%.1f", audioSeconds))")
                try? FileManager.default.removeItem(at: finishedURL)
                await processingChain?.value
                finishSession(generation)
                return
            }
            Diagnostics.log("dictation", "stream.empty — batch fallback")
        }

        if chunkedMode {
            // Queue the final segment and wait for the ordered pipeline to drain.
            enqueueSegment(finishedURL)
            await processingChain?.value
            finishSession(generation)
            return
        }

        defer {
            try? FileManager.default.removeItem(at: finishedURL)
            finishSession(generation)
        }

        do {
            let transcript = try await TranscriptionService.transcribe(audioURL: finishedURL)
            guard generation == sessionGeneration else { return }
            guard !transcript.isEmpty else { NSSound.beep(); return }

            var text = transcript
            let settings = AppSettings.shared
            if mode == .translate || settings.dictationCleanup {
                if let processed = try? await postProcess(transcript) {
                    text = processed
                }
                // Post-processing is best-effort: on failure the raw transcript is used.
                guard generation == sessionGeneration else { return }
            }

            TextInserter.insert(text)
        } catch {
            NSSound.beep()
        }
    }

    /// Ends the session's UI state — unless the session was already replaced
    /// (cancelled from the hotkey, or a new one started): then the pill
    /// belongs to that session and stays untouched.
    private func finishSession(_ generation: Int) {
        guard generation == sessionGeneration else { return }
        processingChain = nil
        phase = .idle
        hideWidget()
    }

    /// Ends the capture and waits for the segment file to be finalized on
    /// the capture queue — but not forever: a device mid-reconfiguration can
    /// hold that queue inside CoreAudio for minutes (field log 2026-09-07:
    /// six minutes, pill spinning, hotkey dead). After `timeout` the wait is
    /// given up (returns false); the completion that eventually arrives then
    /// only deletes the file nobody is going to transcribe.
    private func releaseCapture(_ url: URL, keepWarmSeconds: TimeInterval,
                                timeout: TimeInterval = 3) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let gate = StopGate(continuation)
            capture.endRecording(keepWarmSeconds: keepWarmSeconds) {
                if !gate.resume(true) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if gate.resume(false) {
                    Diagnostics.log("dictation", "capture.stop.timeout ms=\(Int(timeout * 1000))")
                }
            }
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

    // MARK: - Widget (the island under the camera housing)

    /// The tab is 34 pt tall like the old capsule was.
    static let tabHeight: CGFloat = 34
    /// Room the recording glow needs beyond the tab's sides and bottom.
    static let glowMargin: CGFloat = 24
    /// On a display without a camera housing the island floats: this far
    /// below the menu bar, as a capsule with the glow all around.
    static let floatingGap: CGFloat = 4
    /// The docked island's growth from the screen's top edge through the
    /// housing's column and out of the seam, and the retraction back.
    static let revealDuration: TimeInterval = 0.4

    /// The content's fade once the tab has landed (and before it leaves).
    static let contentFadeDuration: TimeInterval = 0.15
    /// Extra width over the API's gap, 1.5 pt a side. The gap is not
    /// symmetric about the physical cutout (a 14" ran ~2 px wide on one side
    /// and short on the other); black over black is invisible, a sliver of
    /// menu bar beside the housing is not, so err wide — boring.notch adds 4.
    static let notchOvershoot: CGFloat = 3

    /// Width of the camera housing on the screen the widget shows on; nil on
    /// displays without one. Apple publishes no table of housing sizes; the
    /// API is the only source, and it is the one the notch utilities
    /// (DynamicNotchKit, boring.notch) use — the gap between the two
    /// auxiliary areas. It runs a hair wide of the physical cutout, which is
    /// why the docked island's black starts at the screen's top edge and
    /// covers the housing's whole column (see `seamInset`): an overshoot then
    /// only makes the housing look a pixel wider, never a step at the seam.
    private var notchWidth: CGFloat? {
        guard let gap = notchGap else { return nil }
        return gap.maxX - gap.minX + Self.notchOvershoot
    }

    /// The housing's column between the two auxiliary areas, in screen
    /// coordinates; nil on displays without a housing.
    private var notchGap: (minX: CGFloat, maxX: CGFloat)? {
        guard let screen = NSScreen.main,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              right.minX > left.maxX else { return nil }
        return (left.maxX, right.minX)
    }

    /// Height of the housing's column (the safe-area inset: the housing plus
    /// the menu bar band under it) on the current screen.
    private var notchHeight: CGFloat { NSScreen.main?.safeAreaInsets.top ?? 0 }

    /// Docked when the screen has a camera housing: the tab takes the
    /// housing's width and sits flush under it, so the housing visibly grows
    /// by 34 pt while you speak. Elsewhere (external displays) a black tab
    /// hanging from a light menu bar reads as a foreign block, so the island
    /// floats there instead: a capsule `floatingGap` below the menu bar.
    var isDocked: Bool { notchWidth != nil }

    /// The tab: the housing's width when docked, the old capsule widths when
    /// floating (wider in translate mode to fit the language chip).
    var tabSize: NSSize {
        NSSize(width: notchWidth ?? (mode == .translate ? 182 : 148), height: Self.tabHeight)
    }

    /// Distance from the panel's top edge down to the seam. Docked, the
    /// panel starts at the screen's top edge and the seam is the housing's
    /// bottom: the black above it fills the column — no pixels there except
    /// the ears beside the cutout's rounded corners, which is the point.
    /// Floating, the panel's top IS the menu bar line. The glow is zero
    /// above the seam either way.
    var seamInset: CGFloat { isDocked ? notchHeight : 0 }

    /// Where the visible tab starts below the panel's top edge.
    var tabInset: CGFloat { isDocked ? notchHeight : Self.floatingGap }

    /// False until the panel is on screen and again before it leaves: the
    /// docked island's black grows from the screen's top edge through the
    /// housing's column and out of the seam, and retracts the same way,
    /// `revealDuration` each way. The floating capsule has nothing to grow
    /// out of and appears at once, as the old pill did.
    @Published private(set) var widgetRevealed = false {
        didSet { if oldValue != widgetRevealed { widgetRevealFlipped = Date() } }
    }
    /// When `widgetRevealed` last flipped — the clock the docked island's
    /// growth and retraction run on (see `DockedIslandBlack`).
    @Published private(set) var widgetRevealFlipped = Date.distantPast
    /// The content (bars, dots, chip) is shown only once the docked tab has
    /// landed and hidden before it leaves, so nothing ever sits outside the
    /// outline: parts of it (the language menu) are AppKit-hosted and would
    /// not follow the slide.
    @Published private(set) var widgetContentShown = false
    /// Bumped by every show and hide; a delayed step of an older transition
    /// finds it changed and does nothing.
    private var widgetTransition = 0

    /// The panel: the tab plus the glow's room at the sides and below, plus
    /// the overlap or the floating gap above the tab.
    var panelSize: NSSize {
        NSSize(width: tabSize.width + 2 * Self.glowMargin,
               height: tabInset + Self.tabHeight + Self.glowMargin)
    }

    private func showWidget() {
        if panel == nil {
            let panel = NonKeyPanel(
                contentRect: NSRect(origin: .zero, size: panelSize),
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
            // The tab draws its own shadow and glow, both confined to its
            // sides and bottom; a window shadow would wrap the whole panel
            // including the glow's transparent room.
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let hosting = NSHostingView(rootView: DictationWidgetView(service: self))
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
            panel.contentView = hosting
            self.panel = panel
        }

        // Follow the app's theme override (Auto/Light/Dark) for the language
        // menu; the island itself is always black. Non-activating panels
        // don't reliably inherit NSApp.appearance, so sync explicitly on
        // every show.
        panel?.appearance = NSApp.appearance

        // The panel is reused across sessions; the size depends on the mode
        // and on the screen's housing.
        panel?.setContentSize(panelSize)
        positionUnderNotch()
        panel?.orderFrontRegardless()
        widgetTransition += 1
        let transition = widgetTransition
        if isDocked {
            // The first frame renders with nothing below the seam; the flip
            // on the next turn of the loop is what animates the growth, and
            // the content follows once the tab has landed.
            widgetRevealed = false
            widgetContentShown = false
            DispatchQueue.main.async { [weak self] in
                guard let self, self.widgetTransition == transition else { return }
                self.widgetRevealed = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealDuration) { [weak self] in
                guard let self, self.widgetTransition == transition else { return }
                self.widgetContentShown = true
            }
        } else {
            widgetRevealed = true
            widgetContentShown = true
        }
    }

    private func positionUnderNotch() {
        guard let panel, let screen = NSScreen.main else { return }
        let size = panel.frame.size
        // Docked, the panel starts at the screen's top edge (the seam is
        // `seamInset` below it) and is centered on the housing's column as
        // the API reports it, not on the screen; floating, it hangs from
        // the menu bar's bottom line at the screen's center.
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        let centerX = notchGap.map { ($0.minX + $0.maxX) / 2 } ?? screen.frame.midX
        let x = centerX - size.width / 2
        let y = screen.frame.maxY - (isDocked ? 0 : menuBar) - size.height
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func hideWidget() {
        level = 0
        widgetTransition += 1
        let transition = widgetTransition
        guard isDocked else {
            widgetRevealed = false
            widgetContentShown = false
            panel?.orderOut(nil)
            return
        }
        // Content out, then the tab retracts into the seam, then the panel
        // leaves — unless a new session started the island again meanwhile.
        widgetContentShown = false
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.contentFadeDuration) { [weak self] in
            guard let self, self.widgetTransition == transition else { return }
            self.widgetRevealed = false
        }
        let leave = Self.contentFadeDuration + Self.revealDuration + 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + leave) { [weak self] in
            guard let self, self.widgetTransition == transition else { return }
            self.panel?.orderOut(nil)
        }
    }
}

/// Resumes a continuation exactly once, from whichever of two main-thread
/// paths gets there first, and tells the caller whether it was the one.
@MainActor
private final class StopGate {
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Bool) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(returning: value)
        return true
    }
}

/// A panel that can never become key or main — so showing it doesn't pull
/// keyboard focus away from the app the user is dictating into.
private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Widget view

/// The island under the camera: a black tab flush with the housing, so the
/// two read as one object that grows while you speak (design study
/// `design/dictation/pill-studies.html`, 1b·B); on a display without a
/// housing, a dark floating capsule 4 pt under the menu bar with a hairline
/// that takes the recording color (study 1). Live spectrum bars while
/// recording (click = stop), warm-up dots before the mic hears, a running
/// line while the transcript is processed. In translate mode a chip with the
/// translate glyph and the target's ISO code; clicking it (or right-clicking
/// the tab) switches the language mid-dictation.
///
/// The recording marker is light, not a dot: a glow in the theme's recording
/// color breathes on its own clock (the bars already show the audio) —
/// around the docked tab's sides and bottom, fading in below the seam so
/// nothing reaches the housing; all around the floating capsule. Because
/// the ground is always dark, the island colors itself from the theme's
/// DARK palette in both appearances.
private struct DictationWidgetView: View {
    @ObservedObject var service: DictationService
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The dictation panel is a separate window; it reads the selected theme
    /// straight from settings, always in its dark variant.
    private var palette: ThemePalette { ThemePalette.palette(for: settings.theme, scheme: .dark) }

    /// The glow comes and goes with the content, so it never rings a tab
    /// that is still growing out of the seam.
    private var glowing: Bool { service.phase == .recording && service.micReady && service.widgetContentShown }

    var body: some View {
        let docked = service.isDocked
        let tab = service.tabSize
        let panel = service.panelSize
        let tabInset = service.tabInset
        let shape = dictationIslandShape(docked: docked)
        let recording = dictationRecordingColor(palette)
        ZStack(alignment: .top) {
            if glowing {
                RecordingGlow(color: recording, breathing: !reduceMotion, docked: docked,
                              tabSize: tab, panelSize: panel,
                              seamInset: service.seamInset, tabInset: tabInset)
            }
            island(docked: docked, tab: tab, tabInset: tabInset, shape: shape, recording: recording)
        }
        .frame(width: panel.width, height: panel.height, alignment: .top)
        .clipped()
        // Outside the animated tree on purpose: on macOS a context menu
        // hosts its view in AppKit, which does not follow SwiftUI's
        // animations — inside, the bars would jump to their final place
        // while the outline was still moving.
        .contextMenu {
            if service.mode == .translate {
                languagePicker
            }
        }
        .help(L("tooltip.dictation.stop"))
    }

    /// The tab with its content, shadow and (floating) hairline.
    private func island(docked: Bool, tab: NSSize, tabInset: CGFloat,
                        shape: AnyShape, recording: Color) -> some View {
            HStack(spacing: 8) {
                if service.phase == .processing {
                    // Transcription/cleanup in flight: indeterminate running line.
                    RunningLine(palette: palette)
                } else if !service.micReady {
                    // Mic hardware still spinning up: pulsing dots say "not
                    // hearing yet" — they flip to live bars on the first buffer.
                    WarmupDots(palette: palette)
                } else {
                    EqualizerBars(level: service.level, spectrum: service.spectrum, palette: palette)
                }
                if service.mode == .translate {
                    // Left-clicking the chip opens the language menu (the
                    // rest of the tab still stops on click).
                    Menu {
                        languagePicker
                    } label: {
                        TranslateChip(
                            palette: palette,
                            code: AppSettings.dictationISOCode(for: settings.dictationTargetLanguage)
                        )
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(L("tooltip.dictation.language"))
                }
            }
            // Docked: in only after the tab has landed, out before it leaves.
            .opacity(service.widgetContentShown ? 1 : 0)
            .animation(docked && !reduceMotion ? .easeOut(duration: DictationService.contentFadeDuration) : nil,
                       value: service.widgetContentShown)
            .frame(width: tab.width, height: tab.height)
            // The content sits below the seam (docked) or the gap (floating).
            .padding(.top, tabInset)
            .background(alignment: .top) {
                // The island's own shadow: the panel has no window shadow.
                // Docked: the housing's black, `notchOvershoot` wider than
                // the API's gap, grows from the screen's top edge through
                // the column and out of the seam. Floating: the tour's dark
                // tint over the material, below the gap, at once.
                if docked {
                    // One shape, grown from the screen's top edge: it runs
                    // down the housing's column first (only the overshoot
                    // beside the housing and the ears at its corners are
                    // real pixels there), then out of the seam. Hide is the
                    // exact reverse.
                    DockedIslandBlack(
                        shape: shape, width: tab.width, fullHeight: tabInset + tab.height, seam: tabInset,
                        revealed: service.widgetRevealed, since: service.widgetRevealFlipped,
                        animated: !reduceMotion
                    )
                } else {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(Color(red: 0.078, green: 0.086, blue: 0.11).opacity(0.86))
                    }
                    .padding(.top, tabInset)
                    .shadow(color: .black.opacity(0.45), radius: 10, y: 8)
                }
            }
            .overlay {
                // The floating capsule's hairline: white at rest, the
                // recording color while the mic hears (the docked tab has
                // no edge of its own — it is the housing's).
                if !docked {
                    shape.stroke(glowing ? recording.opacity(0.55) : Color.white.opacity(0.16), lineWidth: 1)
                        .padding(.top, tabInset)
                }
            }
            .contentShape(shape)
            .onTapGesture {
                if service.phase == .recording {
                    Task { await service.stopAndProcess() }
                }
            }
    }

    /// Shared between the chip's click menu and the tab's right-click menu.
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

/// The island's silhouette: docked — square on top where it meets the
/// housing, a capsule's round ends below; floating — a capsule.
private func dictationIslandShape(docked: Bool) -> AnyShape {
    docked
        ? AnyShape(UnevenRoundedRectangle(
            bottomLeadingRadius: DictationService.tabHeight / 2,
            bottomTrailingRadius: DictationService.tabHeight / 2))
        : AnyShape(Capsule())
}

/// The docked island's black, grown and retracted on its own clock rather
/// than an implicit animation, so that opacity can follow the geometry
/// exactly: one progress value per frame gives the height, and the opacity
/// is that height over the column's, capped at 1. The black is transparent
/// while its edge is inside the housing's column, fully opaque from the
/// moment the edge reaches the seam; the tab comes out, sits and retracts
/// opaque, fading only on its way back up the column. Growth eases out
/// (fast through the column, slow landing); retraction is its mirror.
private struct DockedIslandBlack: View {
    let shape: AnyShape
    let width: CGFloat
    let fullHeight: CGFloat
    let seam: CGFloat
    let revealed: Bool
    let since: Date
    /// False under Reduce Motion: the black is simply there or not.
    let animated: Bool

    var body: some View {
        // The ticker pauses once the move has settled; any re-evaluation
        // after a flip (the flip itself re-renders) starts it again.
        let settled = !animated || Date().timeIntervalSince(since) >= DictationService.revealDuration
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: settled)) { context in
            let height = progress(at: context.date) * fullHeight
            shape.fill(Color.black)
                .frame(width: width, height: height)
                .shadow(color: .black.opacity(0.45), radius: 10, y: 8)
                .opacity(min(1, height / max(1, seam)))
        }
    }

    /// 0 = fully inside the housing, 1 = fully out.
    private func progress(at date: Date) -> Double {
        guard animated else { return revealed ? 1 : 0 }
        let u = min(1, max(0, date.timeIntervalSince(since) / DictationService.revealDuration))
        return revealed ? 1 - (1 - u) * (1 - u) : 1 - u * u
    }
}

/// The theme's recording color — the chat's rule (`RecordingStatusView`):
/// red on Current, else `recordingAccent` → `quoteColor` → `accent`.
private func dictationRecordingColor(_ palette: ThemePalette) -> Color {
    palette.isGlass
        ? Color(red: 1, green: 0.271, blue: 0.227)
        : (palette.recordingAccent ?? palette.quoteColor ?? palette.accent)
}

/// Bar/dot colors: white on Current (the ground is black), the theme's
/// dictation colors otherwise, cycled per element (Día: marigold/magenta/teal).
private func dictationBarColor(_ index: Int, palette: ThemePalette) -> Color {
    if palette.isGlass { return Color.white.opacity(0.92) }
    let colors = palette.dictationColors.isEmpty ? [palette.accent] : palette.dictationColors
    return colors[index % colors.count]
}

/// The recording marker: a blurred copy of the island's silhouette in the
/// recording color, breathing on a clock — 0.8 s up, 0.8 s down, the same
/// sine the chat's recording dot uses — independent of the audio, which the
/// bars already show. Masked so it is zero above and on the seam (the
/// housing's bottom, or the menu bar's) and full 14 pt below it: around the
/// docked tab it can only show at the sides and bottom; around the floating
/// capsule it surrounds it and fades out toward the menu bar instead of
/// being cut. Clocked by a TimelineView, not a repeatForever animation, for
/// the reason `RecordingStatusView` records.
private struct RecordingGlow: View {
    let color: Color
    /// False under Reduce Motion: the glow holds a middle value instead.
    let breathing: Bool
    let docked: Bool
    let tabSize: NSSize
    let panelSize: NSSize
    /// Panel top → seam, and panel top → the visible tab.
    let seamInset: CGFloat
    let tabInset: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !breathing)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let pulse = breathing ? 0.5 + 0.5 * sin(time * (.pi / 0.8)) : 0.6
            dictationIslandShape(docked: docked)
                .fill(color)
                .frame(width: tabSize.width, height: tabSize.height)
                .scaleEffect(x: 1 + 0.08 * pulse, y: 1 + (docked ? 0.2 : 0.12) * pulse,
                             anchor: docked ? .top : .center)
                .opacity(0.45 + 0.5 * pulse)
                .blur(radius: 10)
        }
        .padding(.top, tabInset)
        .frame(width: panelSize.width, height: panelSize.height, alignment: .top)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: seamInset / panelSize.height),
                    .init(color: .black, location: (seamInset + 14) / panelSize.height)
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
        .allowsHitTesting(false)
    }
}

/// Live spectrum bars: each bar is a real log-spaced frequency band of the
/// input (80 Hz … 8 kHz via FFT), not a synthetic wobble — bass on the left,
/// sibilants on the right, and the picture follows the actual voice timbre.
/// Each bar fades toward its ends; neon themes (Synthwave's `panelGlow`)
/// cast the bar's light around it.
private struct EqualizerBars: View {
    let level: Float
    var spectrum: [Float] = []
    let palette: ThemePalette
    private let barCount = MicCapture.bandCount

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<barCount, id: \.self) { index in
                let color = dictationBarColor(index, palette: palette)
                Capsule()
                    .fill(LinearGradient(
                        stops: [
                            .init(color: color.opacity(0.45), location: 0),
                            .init(color: color, location: 0.35),
                            .init(color: color, location: 0.65),
                            .init(color: color.opacity(0.45), location: 1)
                        ],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(width: 2.5, height: barHeight(index))
                    .shadow(color: palette.panelGlow == nil ? .clear : color.opacity(0.7),
                            radius: palette.panelGlow == nil ? 0 : 2)
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
    let palette: ThemePalette

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 7) {
                ForEach(0..<3, id: \.self) { index in
                    let pulse = 0.5 + 0.5 * sin(time * 5.2 - Double(index) * 1.9)
                    Circle()
                        .fill(palette.isGlass ? Color.white.opacity(0.6) : dictationBarColor(index, palette: palette))
                        .frame(width: 7, height: 7)
                        .scaleEffect(0.8 + 0.35 * pulse)
                        .opacity(0.35 + 0.65 * pulse)
                }
            }
        }
    }
}

/// Processing state: a thin indeterminate track with a running segment
/// (replaces the system spinner — same semantics, island-native look).
private struct RunningLine: View {
    let palette: ThemePalette

    private let trackWidth: CGFloat = 74
    private let runnerWidth: CGFloat = 26

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let phase = time.truncatingRemainder(dividingBy: 1.3) / 1.3
            let color = palette.isGlass ? Color.white : dictationBarColor(0, palette: palette)
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

/// Translate mode: the translate glyph and the target's ISO code on a
/// rounded chip — white on Current, the theme's ink on its accent otherwise;
/// monospaced on Terminal, rounded everywhere else.
private struct TranslateChip: View {
    let palette: ThemePalette
    let code: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "translate")
                .font(.system(size: 9, weight: .semibold))
            Text(code)
                .font(.system(size: 10, weight: .bold,
                              design: palette.fontDesign == .monospaced ? .monospaced : .rounded))
        }
        .foregroundStyle(palette.isGlass ? Color.white.opacity(0.92) : palette.ink)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(palette.isGlass ? Color.white.opacity(0.14) : palette.accent.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(palette.isGlass ? Color.clear : palette.accent.opacity(0.35), lineWidth: 1)
        )
    }
}

// MARK: - Microphone capture engine

/// Microphone capture on an input-only HAL output unit (AUHAL) bound to
/// the chosen device. Replaces the `AVAudioEngine` input node — and before
/// that AVAudioRecorder — because it can do what those can't:
/// - record from a CHOSEN input device (Settings → Voice → Microphone),
///   silently falling back to the system default when that device is gone.
///   The engine's input node is born on an automatic aggregate of the
///   default input and the default output and keeps that aggregate's
///   stream format: switching the unit underneath it to another device
///   left the tap at the aggregate's format, and with a Bluetooth headset
///   (16 kHz mono) as the default input every start on a 48 kHz USB mic
///   failed with -10868 "formats don't match" (field log 2026-09-07). The
///   aggregate's output half was also what pulled the headset's A2DP↔HFP
///   flip into the capture (see `BluetoothInputHold`). A unit bound to one
///   input device has neither problem: it takes the device's own format
///   and never sees the output side;
/// - keep the input running after a session ("warm window") so the next
///   dictation starts with zero hardware spin-up — CoreAudio power-up costs
///   ~100–300 ms on the built-in mic and SECONDS on Bluetooth (HFP switch),
///   which is exactly where the first dictated words were being lost;
/// - rotate segment files under the running capture (gapless phrase chunking);
/// - expose raw buffers, so the pill's equalizer can show the REAL voice
///   spectrum (log-spaced bands via vDSP FFT) instead of a synthetic wobble.
///
/// Threading: control methods hop onto a private serial queue and never
/// block the caller — a cold Bluetooth start takes seconds and must not
/// freeze the warm-up animation. The HAL IO thread only renders into
/// buffers allocated for the unit's lifetime and accumulates 2048-frame
/// chunks; each full chunk is copied and handed to a serial processing
/// queue where the file write, the FFT and the streaming side-tap run
/// (`handle`) — off the realtime thread, as the engine's tap used to be.
/// Device listeners are delivered on the control queue. UI callbacks fire
/// on the main thread.
/// Recoverable capture failures — thrown (and caught) instead of letting
/// CoreAudio abort the process.
enum MicCaptureError: LocalizedError {
    /// No usable input device, or the bound device reports an empty format
    /// (device switching / not ready).
    case deviceNotReady
    /// A HAL unit setup step failed (the step's name and its OSStatus).
    case unit(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .deviceNotReady: return "input device not ready"
        case .unit(let step, let status): return "HAL unit \(step) status=\(status)"
        }
    }
}

nonisolated final class MicCapture: @unchecked Sendable {

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
    /// The capture STOPPED for real mid-session (the bound device vanished
    /// or changed its format) — main thread. Listener chatter that leaves
    /// the bound input unchanged never reaches this.
    var onEngineDied: (@MainActor () -> Void)?

    /// Equalizer resolution; matches the pill's bar count.
    static let bandCount = 14
    private static let fftSize = 1024
    /// Frames per chunk handed to `handle`: the FFT window with headroom,
    /// and the ~45 ms cadence (at 48 kHz) the VAD, the level meter and the
    /// gapless file rotation were tuned on. The HAL delivers whatever the
    /// device's IO buffer size is (typically 512 frames), so callbacks are
    /// accumulated up to this size.
    private static let chunkFrames: AVAudioFrameCount = 2048
    /// Upper bound on frames per HAL callback; anything larger is dropped.
    private static let maxRenderFrames: AVAudioFrameCount = 8192
    /// Voice band edges: 80 Hz … 8 kHz, log-spaced.
    private static let bandLowHz: Float = 80
    private static let bandHighHz: Float = 8000

    private let queue = DispatchQueue(label: "cuate.mic.capture")
    /// Serial and off the realtime thread: file writes, the FFT and the
    /// streaming side-tap run here.
    private let processingQueue = DispatchQueue(label: "cuate.mic.process", qos: .userInteractive)
    private let state = State()
    /// Queue-confined: pending warm-window expiry.
    private var cooldown: DispatchWorkItem?
    /// Queue-confined: keeps a Bluetooth headset's hands-free link up across
    /// unit restarts (see `BluetoothInputHold` for the field diagnosis).
    private let hold = BluetoothInputHold()
    /// Queue-confined: the mic choice of the last start, so an idle recovery
    /// re-arms on the SAME device instead of silently reverting to the
    /// system default.
    private var lastDeviceUID = ""
    /// Queue-confined: the live unit and everything the IO thread touches;
    /// nil while no unit exists.
    private var io: IOContext?
    /// Queue-confined: what the unit is bound to — compared against the
    /// device on every listener callback to tell a real change from chatter.
    private var boundDevice: AudioDeviceID = kAudioObjectUnknown
    private var boundToDefault = false
    private var boundRate: Double = 0
    private var boundChannels = 0
    /// Queue-confined: the property listeners registered for the live unit.
    private var listeners: [DeviceListener] = []

    private struct DeviceListener {
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    /// The HAL IO thread's world: allocated once per unit and never mutated
    /// by the control queue after `AudioOutputUnitStart`. `AudioOutputUnitStop`
    /// is synchronous with the IO cycle, so once it returns no callback is
    /// running and the context can be dropped.
    private final class IOContext: @unchecked Sendable {
        let unit: AudioUnit
        /// Client format: Float32 deinterleaved at the device's own rate
        /// (AUHAL does not resample on input), the device's channels capped
        /// at two.
        let format: AVAudioFormat
        /// One callback's frames land here before being accumulated.
        private let landing: AVAudioPCMBuffer
        /// Accumulates callbacks up to `chunkFrames`; IO thread only.
        private let chunk: AVAudioPCMBuffer
        private var chunkFill: AVAudioFrameCount = 0
        private var consecutiveRenderErrors = 0
        private var renderFailureReported = false
        /// Full chunks go here — a fresh copy per chunk, so the accumulator
        /// is reused while the copy travels to the processing queue.
        private let onChunk: (AVAudioPCMBuffer) -> Void
        /// Repeated render failures: the device is gone or reconfigured.
        private let onRenderFailure: (OSStatus) -> Void

        init?(unit: AudioUnit, format: AVAudioFormat,
              chunkFrames: AVAudioFrameCount, maxRenderFrames: AVAudioFrameCount,
              onChunk: @escaping (AVAudioPCMBuffer) -> Void,
              onRenderFailure: @escaping (OSStatus) -> Void) {
            guard let landing = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maxRenderFrames),
                  let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { return nil }
            self.unit = unit
            self.format = format
            self.landing = landing
            self.chunk = chunk
            self.onChunk = onChunk
            self.onRenderFailure = onRenderFailure
        }

        static let inputProc: AURenderCallback = { refCon, flags, timestamp, bus, frames, _ in
            Unmanaged<IOContext>.fromOpaque(refCon).takeUnretainedValue()
                .render(flags: flags, timestamp: timestamp, bus: bus, frames: frames)
        }

        private func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            timestamp: UnsafePointer<AudioTimeStamp>,
                            bus: UInt32, frames: UInt32) -> OSStatus {
            guard frames > 0, frames <= landing.frameCapacity else { return noErr }
            landing.frameLength = frames
            let status = AudioUnitRender(unit, flags, timestamp, bus, frames, landing.mutableAudioBufferList)
            guard status == noErr else {
                consecutiveRenderErrors += 1
                // One glitch is not a dead device; ten in a row is.
                if consecutiveRenderErrors >= 10, !renderFailureReported {
                    renderFailureReported = true
                    onRenderFailure(status)
                }
                return noErr
            }
            consecutiveRenderErrors = 0
            append(frames)
            return noErr
        }

        /// Copies the landed frames into the accumulator, emitting a copy of
        /// every full chunk (a callback may straddle a chunk boundary).
        private func append(_ frames: AVAudioFrameCount) {
            guard let source = landing.floatChannelData, let target = chunk.floatChannelData else { return }
            let channels = Int(format.channelCount)
            var consumed: AVAudioFrameCount = 0
            while consumed < frames {
                let count = min(chunk.frameCapacity - chunkFill, frames - consumed)
                for channel in 0..<channels {
                    (target[channel] + Int(chunkFill)).update(from: source[channel] + Int(consumed), count: Int(count))
                }
                chunkFill += count
                consumed += count
                guard chunkFill == chunk.frameCapacity else { continue }
                chunk.frameLength = chunkFill
                if let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFill),
                   let into = copy.floatChannelData {
                    copy.frameLength = chunkFill
                    for channel in 0..<channels {
                        into[channel].update(from: target[channel], count: Int(chunkFill))
                    }
                    onChunk(copy)
                }
                chunkFill = 0
            }
        }
    }

    /// Lock-guarded state shared with the processing queue.
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

    /// Starts (or reuses, when warm) the unit and begins writing to `url`.
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
    /// stopping the unit — buffers keep flowing into the new file, so no
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

    /// Stops writing. With `keepWarmSeconds > 0` the unit keeps running and
    /// discards samples (the orange mic indicator stays on) so the next start
    /// is instant; a cooldown then releases the mic. `completion` (main
    /// thread) runs after the recording file is finalized.
    /// `releaseHold: false` keeps a Bluetooth hands-free link up through a
    /// capture-death recovery — the restart that follows must land on a link
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

    // MARK: Unit lifecycle (queue-confined)

    private func ensureRunning(deviceUID: String) throws {
        state.lock.lock()
        let running = state.engineRunning
        state.lock.unlock()
        guard !running else { return }

        // Cold start: ALWAYS on a fresh unit, bound to the input that is live
        // right now — a unit left over from a device that has since gone is
        // dropped first. The warm window is untouched: a running unit never
        // reaches this path.
        stopUnit()
        lastDeviceUID = deviceUID
        // Bluetooth input: raise and hold the hands-free link BEFORE the
        // unit binds, so the unit is born on a settled link.
        armBluetoothHold(deviceUID: deviceUID)

        // Selected mic; an unresolved UID (device unplugged) falls through
        // to the system default input.
        let chosen = deviceUID.isEmpty ? nil : AudioInputDevices.deviceID(forUID: deviceUID)
        guard let device = chosen ?? AudioInputDevices.defaultInputDeviceID() else {
            throw MicCaptureError.deviceNotReady
        }
        let context = try makeUnit(device: device)
        let format = context.format
        state.lock.lock()
        state.sampleRate = Float(format.sampleRate)
        if state.fft == nil {
            state.fft = vDSP_create_fftsetup(vDSP_Length(log2(Float(Self.fftSize))), FFTRadix(kFFTRadix2))
            var curve = [Float](repeating: 0, count: Self.fftSize)
            vDSP_hann_window(&curve, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
            state.windowCurve = curve
        }
        state.lock.unlock()

        io = context
        boundDevice = device
        boundToDefault = chosen == nil
        boundRate = AudioInputDevices.nominalSampleRate(device) ?? format.sampleRate
        boundChannels = AudioInputDevices.inputChannelCount(device)
        let status = AudioOutputUnitStart(context.unit)
        guard status == noErr else {
            stopUnit()
            throw MicCaptureError.unit("start", status)
        }
        installListeners(device: device, watchDefault: chosen == nil)
        state.lock.lock()
        state.engineRunning = true
        state.lock.unlock()
        Diagnostics.log("dictation", "capture.engine.start device=\(deviceUID.isEmpty ? "auto" : "custom") rate=\(Int(format.sampleRate)) ch=\(format.channelCount) frames=\(AudioInputDevices.bufferFrameSize(device))")
    }

    /// Creates, configures and initializes — but does not start — an
    /// input-only HAL output unit on `device`, in TN2091's order: enable and
    /// disable IO, bind the device, read the device format, set the client
    /// format and the input callback, initialize.
    private func makeUnit(device: AudioDeviceID) throws -> IOContext {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw MicCaptureError.unit("component", -1)
        }
        var instance: AudioUnit?
        let created = AudioComponentInstanceNew(component, &instance)
        guard created == noErr, let unit = instance else {
            throw MicCaptureError.unit("instance", created)
        }
        func discard() {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        func step(_ name: String, _ status: OSStatus) throws {
            guard status == noErr else {
                discard()
                throw MicCaptureError.unit(name, status)
            }
        }

        var enable: UInt32 = 1
        var disable: UInt32 = 0
        var target = device
        let flagSize = UInt32(MemoryLayout<UInt32>.size)
        try step("enableInput", AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, flagSize))
        try step("disableOutput", AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, flagSize))
        try step("device", AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &target,
            UInt32(MemoryLayout<AudioDeviceID>.size)))

        var deviceFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try step("deviceFormat", AudioUnitGetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &deviceFormat, &formatSize))
        // The format a device reports mid-switch (or before a just-selected
        // mic is ready) can be empty: bail cleanly and let the warm-up retry
        // ladder come back once it settles.
        guard deviceFormat.mSampleRate > 0, deviceFormat.mChannelsPerFrame > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: deviceFormat.mSampleRate,
                                         channels: min(2, deviceFormat.mChannelsPerFrame)) else {
            discard()
            throw MicCaptureError.deviceNotReady
        }
        var clientFormat = format.streamDescription.pointee
        try step("clientFormat", AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &clientFormat, formatSize))

        let processing = processingQueue
        let shared = state
        guard let context = IOContext(
            unit: unit, format: format,
            chunkFrames: Self.chunkFrames, maxRenderFrames: Self.maxRenderFrames,
            onChunk: { [weak self] buffer in
                processing.async {
                    Self.handle(buffer: buffer, state: shared) { db, spectrum, isFirst in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            if isFirst { self.onCaptureStarted?() }
                            self.onAudio?(db, spectrum)
                        }
                    }
                }
            },
            onRenderFailure: { [weak self] status in
                guard let self else { return }
                self.queue.async {
                    Diagnostics.log("dictation", "capture.render.error status=\(status)")
                    self.handleDeviceChange("render", force: true)
                }
            }
        ) else {
            discard()
            throw MicCaptureError.deviceNotReady
        }
        var callback = AURenderCallbackStruct(
            inputProc: IOContext.inputProc,
            inputProcRefCon: Unmanaged.passUnretained(context).toOpaque()
        )
        try step("callback", AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
        try step("initialize", AudioUnitInitialize(unit))
        return context
    }

    /// Stops and disposes the unit (idempotent). Listeners go first, so the
    /// teardown's own property chatter cannot re-enter.
    private func stopUnit() {
        removeListeners()
        guard let context = io else { return }
        // Stop is synchronous with the IO cycle: no callback runs after it.
        AudioOutputUnitStop(context.unit)
        AudioUnitUninitialize(context.unit)
        AudioComponentInstanceDispose(context.unit)
        io = nil
        boundDevice = kAudioObjectUnknown
    }

    /// Watches the bound device (alive, nominal rate, input streams) and —
    /// when the unit follows the system default — the default input itself.
    /// Blocks are delivered on the control queue.
    private func installListeners(device: AudioDeviceID, watchDefault: Bool) {
        var watched: [(AudioObjectID, AudioObjectPropertyAddress, String)] = [
            (device, AudioInputDevices.address(kAudioDevicePropertyDeviceIsAlive), "alive"),
            (device, AudioInputDevices.address(kAudioDevicePropertyNominalSampleRate), "rate"),
            (device, AudioInputDevices.address(kAudioDevicePropertyStreamConfiguration,
                                               scope: kAudioDevicePropertyScopeInput), "streams"),
        ]
        if watchDefault {
            watched.append((AudioObjectID(kAudioObjectSystemObject),
                            AudioInputDevices.address(kAudioHardwarePropertyDefaultInputDevice), "default"))
        }
        for (object, address, reason) in watched {
            var mutable = address
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.handleDeviceChange(reason)
            }
            guard AudioObjectAddPropertyListenerBlock(object, &mutable, queue, block) == noErr else { continue }
            listeners.append(DeviceListener(object: object, address: address, block: block))
        }
    }

    private func removeListeners() {
        for listener in listeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &address, queue, listener.block)
        }
        listeners = []
    }

    /// A device change is only fatal when the bound input really changed:
    /// it is gone, its format moved, or (following the default) the default
    /// input is now another device. Listener chatter that leaves the bound
    /// input as it was is ignored — that kind of notification used to kill
    /// the dictation right after the warm-up animation. A warm idle unit
    /// re-binds silently to whatever input is now current; a live RECORDING
    /// can't continue (the open file carries the old format), so it's
    /// surfaced as dead and the service salvages what was captured so far.
    private func handleDeviceChange(_ reason: String, force: Bool = false) {
        state.lock.lock()
        let running = state.engineRunning
        let recording = state.file != nil
        state.lock.unlock()
        guard running, io != nil else { return }
        let device = boundDevice
        let alive = AudioInputDevices.isAlive(device)
        let rate = AudioInputDevices.nominalSampleRate(device) ?? 0
        let channels = AudioInputDevices.inputChannelCount(device)
        let defaultMoved = boundToDefault && AudioInputDevices.defaultInputDeviceID() != device
        guard force || !alive || defaultMoved || rate != boundRate || channels != boundChannels else { return }
        Diagnostics.log("dictation", "capture.device.change \(reason) alive=\(alive) rate=\(Int(rate)) ch=\(channels) defaultMoved=\(defaultMoved)")
        if recording {
            Diagnostics.log("dictation", "capture.engine.died mid-recording")
            // The hold stays up: the service restarts capture at once,
            // and a restart on a link that is still up is what settles.
            shutdownEngine(releaseHold: false)
            DispatchQueue.main.async { self.onEngineDied?() }
            return
        }
        shutdownEngine(releaseHold: false)
        do {
            try ensureRunning(deviceUID: lastDeviceUID)
            Diagnostics.log("dictation", "capture.engine.recovered")
        } catch {
            Diagnostics.log("dictation", "capture.engine.died \(String(error.localizedDescription.prefix(120)))")
            shutdownEngine()
        }
    }

    /// Resolves the input the unit is about to bind (the chosen mic, else
    /// the system default). For a Bluetooth device the hold is started
    /// first and given up to 1.5 s to actually hear the mic — the moment
    /// after which a fresh unit no longer sees the device reconfigure.
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
        guard let format = io?.format else { throw MicCaptureError.deviceNotReady }
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
        stopUnit()
        if wasRunning {
            Diagnostics.log("dictation", "capture.engine.stop")
        }
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
        // The chunk carries the unit's client format — take the rate from
        // it, keeping the FFT bins honest regardless of what was read at
        // bind time.
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

    /// False once the device has been unplugged (or asked about after it
    /// went away — the property read fails).
    static func isAlive(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyDeviceIsAlive)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    /// The device's IO buffer size in frames — what one HAL callback carries.
    static func bufferFrameSize(_ id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyBufferFrameSize)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return Int(value)
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

    static func address(_ selector: AudioObjectPropertySelector,
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

    static func inputChannelCount(_ id: AudioDeviceID) -> Int {
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
