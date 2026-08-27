import Foundation

/// Live transcription over Deepgram's streaming WebSocket
/// (`wss://api.deepgram.com/v1/listen`): raw linear16 PCM goes in as binary
/// frames, JSON `Results` messages come back with interim and final
/// transcripts.
///
/// Dictation's streaming mode feeds it straight from the microphone tap, so
/// transcription happens WHILE the user speaks — the stop only waits for the
/// tail to flush (`CloseStream` → final results → server close), not for a
/// whole-session upload. One instance serves exactly one dictation session.
///
/// Threading: everything is confined to a private serial queue; `feed` is
/// called from the capture path and only enqueues. The socket opens lazily on
/// the first chunk — that's when the actual sample rate is known. A failure
/// at any point flips `didFail` (observed by the owner via `onFailure`) and
/// the session falls back to the recorded file + batch transcription.
final class DeepgramLiveTranscriber: NSObject, @unchecked Sendable {

    /// Fired once (on the queue → dispatched to main) when the stream breaks;
    /// the owner marks the session for the batch fallback.
    var onFailure: (@Sendable (String) -> Void)?

    /// Fired (dispatched to main, in order) for every FINALIZED transcript
    /// span — Deepgram closes a span every few seconds of speech and at
    /// pauses (`endpointing`), so the owner can insert text WHILE the user
    /// is still dictating. When set, `finish()` returns only the trailing
    /// never-finalized interim; the spans delivered here are not repeated.
    var onFinal: (@Sendable (String) -> Void)?

    private let apiKey: String
    private let model: String
    private let queue = DispatchQueue(label: "cuate.deepgram.live")

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var openedSampleRate = 0

    private var finals: [String] = []
    private var lastInterim = ""
    /// Audio seconds actually covered by final results (each final `Results`
    /// message reports the `duration` of the span it transcribed) — the
    /// basis for the spend record; streaming bills at its own per-minute
    /// rate (`PricingCatalog.sttStreamingPerMinute`), distinct from batch.
    private var coveredSeconds: Double = 0
    private var failed = false
    private var failureLogged = false
    private var finishContinuation: CheckedContinuation<String?, Never>?

    /// Best-effort audio duration for spend accounting (0 until finals arrive).
    var audioSeconds: Double {
        queue.sync { coveredSeconds }
    }

    var didFail: Bool {
        queue.sync { failed }
    }

    init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    // MARK: - Audio in

    /// Called with each capture buffer (any thread); opens the socket on the
    /// first chunk. A mid-session sample-rate change (device swap) cannot be
    /// renegotiated on a linear16 stream — it fails the session instead of
    /// feeding garbage.
    func feed(pcm: Data, sampleRate: Int) {
        queue.async { [self] in
            guard !failed, finishContinuation == nil else { return }
            if task == nil {
                open(sampleRate: sampleRate)
            }
            guard sampleRate == openedSampleRate else {
                fail("sample rate changed \(openedSampleRate)→\(sampleRate)")
                return
            }
            task?.send(.data(pcm)) { [weak self] error in
                guard let self, let error else { return }
                self.queue.async { self.fail("send: \(error.localizedDescription)") }
            }
        }
    }

    /// Queue-confined. `language=multi` matches the batch path (nova-3
    /// multilingual code-switching, supported for streaming; Deepgram
    /// recommends endpointing=100 with it). `interim_results` keeps results
    /// flowing continuously instead of one blob at close.
    private func open(sampleRate: Int) {
        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "language", value: "multi"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "endpointing", value: "100"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        openedSampleRate = sampleRate
        task.resume()
        receiveNext()
        Diagnostics.log("dictation", "stream.open model=\(model) rate=\(sampleRate)")
    }

    // MARK: - Results in

    private func receiveNext() {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .success(let message):
                    self.handle(message)
                    self.receiveNext()
                case .failure(let error):
                    // Expected termination point after CloseStream — the
                    // server closes once the tail is flushed. Any other time
                    // it's a real failure.
                    if self.finishContinuation != nil {
                        self.completeFinish()
                    } else {
                        self.fail("receive: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    /// Queue-confined.
    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let text): data = text.data(using: .utf8)
        case .data(let raw): data = raw
        @unknown default: data = nil
        }
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "Results",
              let channel = json["channel"] as? [String: Any],
              let alternatives = channel["alternatives"] as? [[String: Any]],
              let transcript = alternatives.first?["transcript"] as? String else { return }

        if json["is_final"] as? Bool == true {
            coveredSeconds += json["duration"] as? Double ?? 0
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if let onFinal {
                    // Main-queue FIFO keeps spans in spoken order, and the
                    // finish() continuation (also main-bound) lands after the
                    // last span dispatched before the server close.
                    DispatchQueue.main.async { onFinal(trimmed) }
                } else {
                    finals.append(trimmed)
                }
            }
            lastInterim = ""
        } else {
            lastInterim = transcript
        }
    }

    // MARK: - Finish / cancel

    /// Flushes the stream (`CloseStream` → remaining finals → server close)
    /// and returns the full transcript, or nil/empty when the stream saw
    /// nothing — the caller then falls back to the recorded file.
    func finish() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let task, !failed else {
                    continuation.resume(returning: assembled())
                    teardown()
                    return
                }
                finishContinuation = continuation
                task.send(.string(#"{"type":"CloseStream"}"#)) { [weak self] error in
                    guard let self, error != nil else { return }
                    self.queue.async { self.completeFinish() }
                }
                // Safety net: never hold the pill hostage on a wedged close.
                queue.asyncAfter(deadline: .now() + 6) { [weak self] in
                    guard let self, self.finishContinuation != nil else { return }
                    Diagnostics.log("dictation", "stream.close timeout — using accumulated text")
                    self.completeFinish()
                }
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            failed = true
            teardown()
        }
    }

    /// Queue-confined; idempotent (the timeout and the close race here).
    private func completeFinish() {
        guard let continuation = finishContinuation else { return }
        finishContinuation = nil
        let text = assembled()
        teardown()
        continuation.resume(returning: text)
    }

    /// Queue-confined: finals in order; a trailing interim covers words the
    /// endpointer hadn't finalized when the socket died (normal close flushes
    /// them as finals, so this only matters on failures).
    private func assembled() -> String? {
        var parts = finals
        let tail = lastInterim.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { parts.append(tail) }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }

    /// Queue-confined.
    private func fail(_ reason: String) {
        guard !failed else { return }
        failed = true
        if !failureLogged {
            failureLogged = true
            Diagnostics.log("dictation", "stream.error \(String(reason.prefix(160)))")
            onFailure?(reason)
        }
        // A failure mid-finish must still resolve the continuation.
        if finishContinuation != nil { completeFinish() } else { teardown() }
    }

    /// Queue-confined.
    private func teardown() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }
}
