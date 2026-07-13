import SwiftUI
import AVFoundation
import Combine

// MARK: - Waveform analysis (real audio envelope)

/// Extracts the real amplitude envelope of an audio file: decodes PCM,
/// computes per-bucket RMS, normalizes with a perceptual curve. Results are
/// cached per file so a message re-render never re-decodes.
enum WaveformAnalyzer {
    @MainActor private static var cache: [String: [Float]] = [:]

    @MainActor
    static func levels(for url: URL, buckets: Int = 56) async -> [Float]? {
        if let cached = cache[url.path] { return cached }
        let computed = await Task.detached(priority: .utility) {
            compute(url: url, buckets: buckets)
        }.value
        if let computed { cache[url.path] = computed }
        return computed
    }

    private static func compute(url: URL, buckets: Int) -> [Float]? {
        guard buckets > 0, let file = try? AVAudioFile(forReading: url) else { return nil }
        let totalFrames = Int(file.length)
        guard totalFrames > 0 else { return nil }

        let framesPerBucket = max(1, totalFrames / buckets)
        var sumSquares = [Double](repeating: 0, count: buckets)
        var counts = [Int](repeating: 0, count: buckets)

        let chunkSize: AVAudioFrameCount = 65536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkSize) else {
            return nil
        }

        var frameOffset = 0
        let stride = 4 // sampling every 4th frame is plenty for an envelope
        while file.framePosition < file.length {
            do { try file.read(into: buffer) } catch { break }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channel = buffer.floatChannelData?[0] else { break }
            var i = 0
            while i < frames {
                let bucket = min(buckets - 1, (frameOffset + i) / framesPerBucket)
                let sample = Double(channel[i])
                sumSquares[bucket] += sample * sample
                counts[bucket] += 1
                i += stride
            }
            frameOffset += frames
        }

        var levels = [Float](repeating: 0, count: buckets)
        for b in 0..<buckets where counts[b] > 0 {
            levels[b] = Float((sumSquares[b] / Double(counts[b])).squareRoot())
        }
        let peak = max(levels.max() ?? 0, 0.0001)
        // Normalize and lift quiet parts (perceptual curve) so speech reads well.
        return levels.map { powf($0 / peak, 0.6) }
    }
}

struct VoiceMessagePlayer: View {
    let audioURL: URL
    let isUserMessage: Bool
    @StateObject private var audioPlayer = AudioPlayerManager()
    @State private var playbackProgress: Double = 0
    @State private var duration: TimeInterval = 0
    @State private var waveformLevels: [Float]?
    @Environment(\.colorScheme) private var colorScheme
    
    private let playButtonSize: CGFloat = 32
    private let waveformHorizontalInset: CGFloat = 44 // reserve space for play button (left) and balance on the right
    
    // Dynamic colors for light/dark themes to ensure sufficient contrast
    private var baseTrackColor: Color {
        if isUserMessage {
            return colorScheme == .dark ? Color.white.opacity(0.35) : Color.black.opacity(0.25)
        } else {
            return colorScheme == .dark ? Color.white.opacity(0.25) : Color.black.opacity(0.20)
        }
    }

    private var fillWaveColor: Color {
        if isUserMessage {
            return colorScheme == .dark ? Color.white : Color.black.opacity(0.8)
        } else {
            return .accentColor
        }
    }

    private var playButtonColor: Color {
        if isUserMessage {
            return colorScheme == .dark ? .white : .primary
        } else {
            return .accentColor
        }
    }

    private var timeLabelColor: Color {
        if isUserMessage {
            return colorScheme == .dark ? Color.white.opacity(0.8) : .secondary
        } else {
            return .secondary
        }
    }
    
    var body: some View {
        VStack(spacing: 6) {
            // Top row: centered waveform with play button pinned to the left
            ZStack {
                // Centered waveform across full width (real audio envelope)
                WaveformView(
                    progress: playbackProgress,
                    levels: waveformLevels,
                    baseColor: baseTrackColor,
                    fillColor: fillWaveColor
                )
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, waveformHorizontalInset)

                // Play/Pause button pinned to the leading edge
                HStack {
                    Button(action: togglePlayback) {
                        Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(playButtonColor)
                            .frame(width: playButtonSize, height: playButtonSize)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help(L("tooltip.play"))

                    Spacer()
                }
            }

            // Bottom row: time labels stretched full width
            HStack {
                Spacer()
                Text(formatTime(duration))
                    .font(.caption2)
                    .foregroundColor(timeLabelColor)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .onAppear {
            loadAudioDuration()
            Task { @MainActor in
                waveformLevels = await WaveformAnalyzer.levels(for: audioURL)
            }
        }
        .onReceive(audioPlayer.$currentTime) { currentTime in
            if duration > 0 {
                playbackProgress = currentTime / duration
            }
        }
    }
    
    private func togglePlayback() {
        if audioPlayer.isPlaying {
            audioPlayer.pause()
        } else {
            Task {
                await audioPlayer.play(url: audioURL)
            }
        }
    }
    
    private func loadAudioDuration() {
        do {
            let audioFile = try AVAudioFile(forReading: audioURL)
            let sampleRate = audioFile.fileFormat.sampleRate
            let sampleCount = audioFile.length
            duration = Double(sampleCount) / sampleRate
        } catch {
            print("Failed to load audio duration: \(error)")
            duration = 0
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Full-width Waveform View
private struct WaveformView: View {
    let progress: Double       // 0...1
    let levels: [Float]?       // real audio envelope; nil while loading
    let baseColor: Color
    let fillColor: Color

    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 2
    private let minHeight: CGFloat = 4
    private let maxHeight: CGFloat = 18
    
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let count = max(8, Int((width + spacing) / (barWidth + spacing)))
            let clamped = max(0, min(1, progress))
            let filledWidth = width * clamped
            
            ZStack(alignment: .leading) {
                // Base bars (track)
                HStack(spacing: spacing) {
                    ForEach(0..<count, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(baseColor)
                            .frame(width: barWidth, height: barHeight(i, count: count))
                    }
                }
                
                // Filled portion grows from the leading edge
                HStack(spacing: spacing) {
                    ForEach(0..<count, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(fillColor)
                            .frame(width: barWidth, height: barHeight(i, count: count))
                    }
                }
                .frame(width: filledWidth, alignment: .leading)
                .clipped()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 24)
    }
    
    private func barHeight(_ i: Int, count: Int) -> CGFloat {
        // Real envelope: resample the analyzed buckets to the bar count.
        if let levels, !levels.isEmpty {
            let index = min(levels.count - 1, i * levels.count / max(1, count))
            let value = Double(levels[index])
            return CGFloat(minHeight + (maxHeight - minHeight) * value)
        }
        // Placeholder while the file is being analyzed: flat quiet bars.
        return minHeight + 2
    }
}

// MARK: - Audio Player Manager
class AudioPlayerManager: NSObject, ObservableObject {
    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?
    
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    
    deinit {
        stop()
    }
    
    func play(url: URL) async -> Bool {
        stop() // Stop any current playback
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            
            let success = audioPlayer?.play() ?? false
            if success {
                await MainActor.run {
                    isPlaying = true
                    startTimer()
                }
            }
            return success
        } catch {
            print("Failed to play audio: \(error)")
            return false
        }
    }
    
    func pause() {
        audioPlayer?.pause()
        isPlaying = false
        stopTimer()
    }
    
    func stop() {
        audioPlayer?.stop()
        isPlaying = false
        currentTime = 0
        stopTimer()
    }
    
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.currentTime = self?.audioPlayer?.currentTime ?? 0
            }
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - AVAudioPlayerDelegate
extension AudioPlayerManager: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isPlaying = false
            self.currentTime = 0
            self.stopTimer()
        }
    }
    
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        print("Audio playback error: \(String(describing: error))")
        DispatchQueue.main.async {
            self.isPlaying = false
            self.currentTime = 0
            self.stopTimer()
        }
    }
}

