import Foundation
import AVFoundation

/// Confined to one transcription worker. Decodes AAC (including Bluetooth
/// rates/stereo) and resamples incrementally; memory stays bounded to ~30 s.
/// The original recording is never modified and no temporary audio is written.
nonisolated final class OllamaAudioReader {
    enum Failure: Error { case conversion, emptyAudio }
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let output: AVAudioPCMBuffer
    private var samples: [Int16] = []
    private var finished = false
    private var emitted = false

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: Double(OllamaTranscriptionWire.sampleRate),
                                       channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw Failure.conversion
        }
        self.converter = converter
        self.output = output
    }

    func next() throws -> Data? {
        while !finished && samples.count <= OllamaTranscriptionWire.maxSamples {
            try Task.checkCancellation()
            var conversionError: NSError?
            var readError: Error?
            let result = converter.convert(to: output, error: &conversionError) { [file] count, status in
                do {
                    try Task.checkCancellation()
                    guard file.framePosition < file.length else {
                        status.pointee = .endOfStream
                        return nil
                    }
                    guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                      frameCapacity: min(count, 8192)) else {
                        throw Failure.conversion
                    }
                    let remaining = AVAudioFrameCount(min(Int64(input.frameCapacity), file.length - file.framePosition))
                    try file.read(into: input, frameCount: remaining)
                    status.pointee = input.frameLength == 0 ? .endOfStream : .haveData
                    return input.frameLength == 0 ? nil : input
                } catch {
                    readError = error
                    status.pointee = .endOfStream
                    return nil
                }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            guard result != .error else { throw Failure.conversion }
            if let pcm = output.int16ChannelData?[0], output.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: pcm, count: Int(output.frameLength)))
            }
            if result == .endOfStream { finished = true }
            if output.frameLength == 0 && result != .endOfStream { throw Failure.conversion }
        }
        try Task.checkCancellation()
        guard !samples.isEmpty else {
            if !emitted { throw Failure.emptyAudio }
            return nil
        }
        let cut = OllamaTranscriptionWire.cutSample(in: samples)
        let wav = OllamaTranscriptionWire.wav(samples: samples[..<cut])
        samples.removeFirst(cut)
        emitted = true
        return wav
    }
}
