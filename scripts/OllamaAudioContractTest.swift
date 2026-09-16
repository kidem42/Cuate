import Foundation
import AVFoundation

// Isolated contracts: synthetic audio only, no server, mic, app or credentials.
@main
struct OllamaAudioContractTest {
    static var checks = 0
    static func expect(_ value: Bool, _ name: String) {
        guard value else { fatalError(name) }
        checks += 1
    }

    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try wireContracts()
        try audioContracts(directory)
        try await queueContracts()
        print("Ollama audio: \(checks) checks passed")
    }

    static func wireContracts() throws {
        for caps in [["completion", "audio"], ["completion", "audio", "thinking"]] {
            expect(OllamaCompatibility.supportsTranscription(capabilities: caps, remote: false), "local audio model")
            expect(!OllamaCompatibility.supportsTranscription(capabilities: caps, remote: true), "cloud model excluded")
            expect(!OllamaCompatibility.supportsTranscription(capabilities: caps, remote: nil), "old cache requires refresh")
        }
        for caps in [[], ["audio"], ["completion"], ["embedding"], ["image"]] {
            expect(!OllamaCompatibility.supportsTranscription(capabilities: caps, remote: false), "not a transcription model")
        }
        expect(OllamaCompatibility.displayCapabilities(["audio", "reasoning", "thinking", "vision", "future", "audio"])
               == ["vision", "thinking", "audio", "future"], "all capabilities retained, normalized and deduplicated")
        let wav = OllamaTranscriptionWire.wav(samples: [Int16(-32768), 0, 32767][...])
        expect(Array(wav.suffix(6)) == [0, 128, 0, 0, 255, 127], "PCM16 little endian")
        let request = try OllamaTranscriptionWire.request(endpoint: "http://localhost:11434/proxy/v1/",
            model: "my/audio-model:custom", wav: wav, thinking: true)
        expect(request.url?.absoluteString == "http://localhost:11434/proxy/v1/chat/completions", "preserve configured base path")
        expect(request.value(forHTTPHeaderField: "Authorization") == nil, "no cloud credentials")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        expect(body["model"] as? String == "my/audio-model:custom", "custom aliases preserved")
        expect(body["reasoning_effort"] as? String == "none", "transcription disables thinking")
        expect(body["tools"] == nil && body["stream"] as? Bool == false, "no chat tools or streaming state")
        let messages = body["messages"] as! [[String: Any]]
        let content = messages[1]["content"] as! [[String: Any]]
        let audio = content[0]["input_audio"] as! [String: Any]
        expect(Data(base64Encoded: audio["data"] as! String) == wav && audio["format"] as? String == "wav", "actual WAV reaches audio input")
        let plain = try OllamaTranscriptionWire.request(endpoint: "http://localhost:11434/v1", model: "voice", wav: wav, thinking: false)
        let plainJSON = try JSONSerialization.jsonObject(with: plain.httpBody!) as! [String: Any]
        expect(plainJSON["reasoning_effort"] == nil, "no thinking parameter for non-thinking model")
        for url in ["file:///tmp/audio", "invalid", "https://user:secret@example.com/v1", "http://localhost/v1?token=secret"] {
            do {
                _ = try OllamaTranscriptionWire.request(endpoint: url, model: "voice", wav: wav, thinking: false)
                fatalError("invalid URL accepted")
            } catch { expect(true, "invalid endpoint rejected") }
        }
        let success = Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"  Привет! Hello! Hola!  ","reasoning":"not speech"}}]}"#.utf8)
        expect(try OllamaTranscriptionWire.transcript(success) == "Привет! Hello! Hola!", "only final transcript is inserted")
        for json in [#"{"choices":[]}"#, #"{"choices":[{"message":{"content":"partial"},"finish_reason":"length"}]}"#,
                     #"{"choices":[{"message":{"content":"partial"}}]}"#,
                     #"{"choices":[{"message":{"content":"","tool_calls":[{}]},"finish_reason":"stop"}]}"#] {
            do { _ = try OllamaTranscriptionWire.transcript(Data(json.utf8)); fatalError("bad response accepted") }
            catch { expect(true, "partial/malformed response refused") }
        }
    }

    static func audioContracts(_ directory: URL) throws {
        // 65 s exceeds two chunks. Preserve every sample once and cut in silence.
        var original = [Int16](repeating: 1000, count: 65 * 16_000)
        for i in (27 * 16_000)..<(28 * 16_000) { original[i] = 0 }
        let source = directory.appendingPathComponent("long.wav")
        try OllamaTranscriptionWire.wav(samples: original[...]).write(to: source)
        let originalData = try Data(contentsOf: source)
        FileHandle.standardError.write(Data("Reading synthetic PCM WAV (\(originalData.count) bytes)\n".utf8))
        let reader = try OllamaAudioReader(url: source)
        var restored: [Int16] = []
        var sizes: [Int] = []
        while let wav = try reader.next() {
            let payload = Array(wav.dropFirst(44))
            let samples = stride(from: 0, to: payload.count, by: 2).map {
                Int16(bitPattern: UInt16(payload[$0]) | UInt16(payload[$0 + 1]) << 8)
            }
            sizes.append(samples.count)
            expect(samples.count <= 30 * 16_000, "bounded audio input")
            restored += samples
        }
        expect(sizes.count == 3, "all long recording chunks processed")
        expect(sizes[0] >= 27 * 16_000 && sizes[0] <= 28 * 16_000, "cut placed in quiet span")
        expect(restored == original, "no missing, repeated or modified samples at boundaries")
        expect(try Data(contentsOf: source) == originalData, "original untouched")

        // Actual AAC files match both capture paths, including stereo/high rates
        // and Bluetooth 8/16 kHz. Converter output must remain mono 16 kHz WAV.
        for (rate, channels) in [(8000.0, 1), (16000.0, 1), (44100.0, 1), (48000.0, 2)] {
            FileHandle.standardError.write(Data("Checking AAC \(rate) Hz / \(channels) channels\n".utf8))
            let url = directory.appendingPathComponent("\(Int(rate))-\(channels).m4a")
            try makeAAC(url, rate: rate, channels: AVAudioChannelCount(channels))
            let reader = try OllamaAudioReader(url: url)
            var bytes = 0
            while let wav = try reader.next() {
                expect(String(data: wav.prefix(4), encoding: .utf8) == "RIFF", "AAC converted to WAV")
                expect(Array(wav[22..<28]) == [1, 0, 128, 62, 0, 0], "mono 16000 Hz")
                bytes += wav.count - 44
            }
            expect(abs(Double(bytes) / 32000 - 1) < 0.15, "AAC duration preserved across sample rates")
        }
        let empty = directory.appendingPathComponent("empty.wav")
        try OllamaTranscriptionWire.wav(samples: [Int16]()[...]).write(to: empty)
        do { _ = try OllamaAudioReader(url: empty).next(); fatalError("empty recording accepted") }
        catch { expect(true, "empty input refused") }
        let bad = directory.appendingPathComponent("bad.m4a")
        try Data("not audio".utf8).write(to: bad)
        do { _ = try OllamaAudioReader(url: bad).next(); fatalError("invalid recording accepted") }
        catch { expect(true, "corrupt input refused") }
    }

    static func makeAAC(_ url: URL, rate: Double, channels: AVAudioChannelCount) throws {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: min(64000, Int(rate) * Int(channels) * 2)
        ])
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(rate))!
        buffer.frameLength = buffer.frameCapacity
        for c in 0..<Int(channels) {
            for i in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![c][i] = Float(sin(2 * .pi * 440 * Double(i) / rate)) * 0.1
            }
        }
        try file.write(from: buffer)
    }

    actor Gate {
        var started = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            started = true
            await withCheckedContinuation { continuation = $0 }
        }
        func open() { continuation?.resume(); continuation = nil }
        func isStarted() -> Bool { started }
    }

    static func queueContracts() async throws {
        let queue = OllamaTranscriptionQueue()
        let gate = Gate()
        let first = Task { try await queue.run { await gate.wait(); return "first" } }
        while !(await gate.isStarted()) { await Task.yield() }
        let cancelled = Task { try await queue.run { fatalError("cancelled queued job sent audio") } }
        cancelled.cancel()
        let thirdGate = Gate()
        let third = Task { try await queue.run { await thirdGate.wait(); return "third" } }
        try await Task.sleep(nanoseconds: 30_000_000)
        expect(!(await thirdGate.isStarted()), "local jobs never overlap")
        await gate.open()
        expect(try await first.value == "first", "queued cancellation preserves active job")
        do { _ = try await cancelled.value; fatalError("cancel ignored") }
        catch is CancellationError { expect(true, "queued cancellation propagated") }
        while !(await thirdGate.isStarted()) { await Task.yield() }
        await thirdGate.open()
        expect(try await third.value == "third", "queue advances after cancellation")

        let activeGate = Gate()
        let active = Task {
            try await queue.run {
                await activeGate.wait()
                try Task.checkCancellation()
                return "unexpected"
            }
        }
        while !(await activeGate.isStarted()) { await Task.yield() }
        active.cancel()
        await activeGate.open()
        do { _ = try await active.value; fatalError("active cancel ignored") }
        catch is CancellationError { expect(true, "active cancellation propagated") }
        expect(try await queue.run { "recovered" } == "recovered", "queue reusable after active cancellation")
    }
}
