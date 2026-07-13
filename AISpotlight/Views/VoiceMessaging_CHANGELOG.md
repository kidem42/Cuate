# Changelog - Voice Messages v2.0

## New Features ✅

### 1. File Lifecycle Management
- **Session storage**: Files live only during the app session
- **Automatic cleanup**: All files are deleted when the app closes
- **Leak protection**: Remaining files from previous sessions are cleaned on startup
- **UserDefaults tracking**: Reliable tracking of active files

### 2. Voice Message Playback
- **Built-in player**: Play/pause button directly in chat
- **Waveform visualization**: Visual audio representation with progress
- **Time information**: Current time and total duration
- **Adaptive design**: Different colors for user and assistant

### 3. Enhanced Recording Management
- **Cancel recording**: Long press → Cancel button
- **Smart button**: Automatic hiding of Cancel after 3 seconds
- **Visual feedback**: Pulsating animation during recording
- **UI blocking**: Text input blocked during recording

## Updated Components 🔄

### AudioRecorder.swift
```swift
// New methods:
func cancelRecording()                    // Cancel with file deletion
func playRecording(url: URL) -> Bool      // Playback
func stopPlayback()                       // Stop playback

// New properties:
@Published var isPlaying = false          // Playback state
```

### ChatMessage
```swift
// New field:
var audioURL: URL?                        // Audio file reference

// Updated initializer:
init(text: String, isUser: Bool, messageType: MessageType = .text, audioURL: URL? = nil)
```

### ChatWindow.swift
```swift
// New methods:
private func handleVoiceRecordingStart()  // Start recording
private func handleVoiceRecordingStop()   // Stop and send
private func handleVoiceRecordingCancel() // Cancel recording
```

## New Files 📁

1. **VoiceMessagePlayer.swift** - Player for playback
2. **EnhancedVoiceButton.swift** - Enhanced button with cancel
3. **DataExtensions.swift** - Extensions for Data operations
4. **Updated tests** - Extended test suite

## Architectural Improvements 🏗️

### Separation of Concerns
- **AudioRecorder**: Only recording and playback
- **VoiceMessagePlayer**: Only player UI in chat
- **EnhancedVoiceButton**: Only recording control UI
- **SessionFileManager**: Built into AudioRecorder

### Improved Error Handling
- Graceful handling of microphone permissions
- Validation of audio files
- Logging of all operations

### Memory Management
- Proper cleanup of all Timers
- Release of AVAudioPlayer/Recorder resources
- No retain cycles in delegates

## User Experience 👤

### Intuitive Controls
- **Click**: Regular record/stop
- **Long press**: Show cancel option
- **Cancel button**: Instant recording cancellation

### Visual Feedback
- Pulsating animation during recording
- Waveform with playback progress
- Informative statuses and hints
- Disabled unavailable elements

### Accessibility
- Proper help (tooltips) for all buttons
- Keyboard navigation support
- Screen reader friendly labels

## Compatibility 🔄

- **macOS 15.0+**: No changes to requirements
- **Existing n8n workflows**: Full backward compatibility
- **API endpoints**: No API changes
- **Data format**: M4A (AAC) remains unchanged

## Migration 📋

No action required:
- Existing n8n workflows will continue to work
- Old voice messages remain accessible
- Webhook format stays the same
- Configuration unchanged
