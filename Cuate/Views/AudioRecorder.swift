import AVFoundation
import Foundation
import Combine
import AppKit

class AudioRecorder: NSObject, ObservableObject {
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    
    private var maxDurationTimer: Timer?
    @Published var autoStoppedDueToLimit: Bool = false
    
    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var recordingURL: URL?
    
    // Static methods for session file management
    private static let sessionFilesKey = "audioRecorderSessionFiles"
    
    override init() {
        super.init()
        cleanupOldSessionFiles()
        
        // Register for app termination to cleanup files
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        cleanupSessionFiles()
        maxDurationTimer?.invalidate()
    }
    
    func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }
    
    func startRecording() async -> Bool {
        // Stop any current recording first
        if isRecording {
            cancelRecording()
        }
        
        guard await requestMicrophonePermission() else {
            print("Microphone permission denied")
            showPermissionError()
            return false
        }
        
        // Recordings live in Application Support and are kept as long as the
        // chat message referencing them exists (history is persistent now).
        let recordingsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cuate/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        let audioFilename = recordingsDir.appendingPathComponent("recording_\(Date().timeIntervalSince1970).m4a")
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            // 64 kbps is plenty for speech and keeps files well under provider
            // upload limits (OpenAI: 25 MB/file → ~50 min at this bitrate).
            AVEncoderBitRateKey: 64000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.record()
            
            DispatchQueue.main.async {
                self.isRecording = true
                self.recordingURL = audioFilename
            }
            
            // Add to session files tracking
            addToSessionFiles(audioFilename)
            
            // Schedule auto-stop by max duration
            maxDurationTimer?.invalidate()
            autoStoppedDueToLimit = false
            maxDurationTimer = Timer.scheduledTimer(withTimeInterval: Config.maxVoiceRecordingDuration, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                // Auto-stop recording when limit is reached
                self.audioRecorder?.stop()
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.autoStoppedDueToLimit = true
                }
            }
            
            return true
        } catch {
            print("Failed to start recording: \(error)")
            return false
        }
    }
    
    func stopRecording() {
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil
        audioRecorder?.stop()
        DispatchQueue.main.async {
            self.isRecording = false
        }
    }
    
    func cancelRecording() {
        if isRecording {
            maxDurationTimer?.invalidate()
            maxDurationTimer = nil
            audioRecorder?.stop()
            DispatchQueue.main.async {
                self.isRecording = false
            }
            // Delete the cancelled recording immediately
            if let url = recordingURL {
                deleteFile(at: url)
                removeFromSessionFiles(url)
                DispatchQueue.main.async {
                    self.recordingURL = nil
                }
            }
        }
    }
    
    func playRecording(url: URL) async -> Bool {
        // Stop any current playback
        stopPlayback()
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.play()
            
            DispatchQueue.main.async {
                self.isPlaying = true
            }
            
            return true
        } catch {
            print("Failed to play recording: \(error)")
            return false
        }
    }
    
    func stopPlayback() {
        audioPlayer?.stop()
        DispatchQueue.main.async {
            self.isPlaying = false
        }
    }
    
    func deleteRecording() {
        guard let url = recordingURL else { return }
        deleteFile(at: url)
        removeFromSessionFiles(url)
        DispatchQueue.main.async {
            self.recordingURL = nil
        }
    }
    
    // MARK: - Session File Management
    
    private func addToSessionFiles(_ url: URL) {
        var sessionFiles = getSessionFiles()
        sessionFiles.append(url.path)
        UserDefaults.standard.set(sessionFiles, forKey: Self.sessionFilesKey)
    }
    
    private func removeFromSessionFiles(_ url: URL) {
        var sessionFiles = getSessionFiles()
        sessionFiles.removeAll { $0 == url.path }
        UserDefaults.standard.set(sessionFiles, forKey: Self.sessionFilesKey)
    }
    
    private func getSessionFiles() -> [String] {
        return UserDefaults.standard.stringArray(forKey: Self.sessionFilesKey) ?? []
    }
    
    private func cleanupOldSessionFiles() {
        let sessionFiles = getSessionFiles()
        for filePath in sessionFiles {
            let url = URL(fileURLWithPath: filePath)
            if FileManager.default.fileExists(atPath: filePath) {
                deleteFile(at: url)
                print("Cleaned up old session file: \(url.lastPathComponent)")
            }
        }
        // Clear the session files list
        UserDefaults.standard.removeObject(forKey: Self.sessionFilesKey)
    }
    
    private func cleanupSessionFiles() {
        let sessionFiles = getSessionFiles()
        for filePath in sessionFiles {
            let url = URL(fileURLWithPath: filePath)
            deleteFile(at: url)
        }
        UserDefaults.standard.removeObject(forKey: Self.sessionFilesKey)
    }
    
    private func deleteFile(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            print("Failed to delete file at \(url.path): \(error)")
        }
    }
    
    @objc private func appWillTerminate() {
        cleanupSessionFiles()
    }
    
    @MainActor
    private func showPermissionError() {
        // This could be used to show an alert or notification
        // For now, we'll just print the error
        print("Microphone permission is required for voice messages. Please grant permission in System Settings > Privacy & Security > Microphone.")
    }
}

// MARK: - AVAudioRecorderDelegate
extension AudioRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isRecording = false
        }
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil

        if flag {
            // Successful recording becomes permanent: untrack it so the
            // session cleanup (exit/next launch) no longer deletes it —
            // it is referenced by a persisted chat message.
            removeFromSessionFiles(recorder.url)
        } else {
            print("Recording failed")
            if let url = recordingURL {
                deleteFile(at: url)
                removeFromSessionFiles(url)
                DispatchQueue.main.async {
                    self.recordingURL = nil
                }
            }
        }
    }
    
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        print("Recording encode error: \(String(describing: error))")
        DispatchQueue.main.async {
            self.isRecording = false
        }
    }
}

// MARK: - AVAudioPlayerDelegate
extension AudioRecorder: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isPlaying = false
        }
    }
    
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        print("Audio player error: \(String(describing: error))")
        DispatchQueue.main.async {
            self.isPlaying = false
        }
    }
}
