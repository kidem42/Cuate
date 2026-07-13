# Voice Messages - Implementation Guide

## Overview

We have implemented full functionality for recording, playback, and sending voice messages in the AI Spotlight app for macOS. The system records audio in M4A (AAC) format, sends it to a webhook as multipart form data, and allows playback of voice messages directly in the chat.

## New Features

### ✅ File Lifecycle Management
- Audio files are saved until the end of the app session
- All files are automatically deleted when the app closes
- On new startup, undeleted files from the previous session are checked and cleaned
- File tracking via UserDefaults with key `audioRecorderSessionFiles`

### ✅ Voice Message Playback
- Player with play/pause button directly in chat
- Playback progress visualization with waveform
- Display of current time and total duration
- Support for both user and assistant voice messages

### ✅ Enhanced Recording Control
- **Regular click**: start/stop recording and send
- **Long press**: show recording cancel button
- **Cancel button**: abort recording without sending
- **Auto-hide**: cancel button disappears after 3 seconds

### ✅ Improved User Interface
- Extended recording status with instructions
- Pulsating animation on recording button
- Visual feedback for all states
- Text input blocked during recording

## Architecture

### 1. AudioRecorder.swift (extended)
- Main class for audio recording and playback
- Uses AVAudioRecorder for recording in M4A (AAC) format
- Manages session file lifecycle
- Handles microphone permissions
- **New**: Cancel recording function `cancelRecording()`
- **New**: Session file tracking via UserDefaults
- **New**: Automatic cleanup on app startup and termination

### 2. VoiceMessagePlayer.swift (new)
- Component for playing voice messages in chat
- Play/pause support with visual feedback
- Waveform-like visualization with progress indication
- Display of playback time and total duration
- Adaptive design for user and assistant messages

### 3. EnhancedVoiceButton.swift (new)
- Enhanced recording button with long press support
- Display of cancel button on long press
- Pulsating animation during recording
- Automatic hiding of cancel button after 3 seconds

### 4. RecordingStatusView.swift (updated)
- Extended recording status with user hints
- Recording timer with high resolution
- Instructions for canceling recording
- Improved design with more informative interface

### 5. ChatModels.swift (updated)
- **New field**: `audioURL: URL?` in `ChatMessage` structure
- Support for encoding/decoding audio file URLs
- Extended initializer for voice messages

### 6. MessageRow.swift (updated)
- Integration of voice message player
- Conditional display of text or player depending on message type
- Support for voice messages from both user and assistant

### 7. APIClient.swift (no changes)
- Function `sendVoiceMessage(audioURL:)` remains the same
- Sends audio as multipart form data
- Includes metadata: userId, messageType: "voice", etc.

## Data Sending Format

Audio is sent to the webhook as multipart/form-data:

```
Content-Type: multipart/form-data; boundary=<UUID>

--<boundary>
Content-Disposition: form-data; name="userId"

<telegram_user_id>
--<boundary>
Content-Disposition: form-data; name="client"

AISpotlight
--<boundary>
Content-Disposition: form-data; name="platform"

macOS
--<boundary>
Content-Disposition: form-data; name="messageType"

voice
--<boundary>
Content-Disposition: form-data; name="audio"; filename="voice_message.m4a"
Content-Type: audio/m4a

<binary_audio_data>
--<boundary>--
```

## Setting up n8n for Voice Message Processing

In your n8n workflow you need to:

1. **Configure webhook to accept multipart data**:
   ```json
   {
     "httpMethod": "POST",
     "responseMode": "responseNode"
   }
   ```

2. **Extract audio file**:
   ```javascript
   // In Code node
   const audioFile = $input.all()[0].binary.audio;
   return [{
     json: {
       messageType: $input.all()[0].json.messageType,
       userId: $input.all()[0].json.userId
     },
     binary: {
       audio: audioFile
     }
   }];
   ```

3. **Integration with OpenAI Whisper**:
   - Use HTTP Request node
   - Endpoint: `https://api.openai.com/v1/audio/transcriptions`
   - Method: POST
   - Headers: `Authorization: Bearer YOUR_API_KEY`
   - Body Type: Form-Data
   - Attach binary file as `file`
   - Add parameter `model: whisper-1`

## Example n8n Workflow

```
Webhook (multipart)
    ↓
Code (extract audio)
    ↓
HTTP Request (OpenAI Whisper)
    ↓
Code (process transcription)
    ↓
HTTP Request (OpenAI Chat Completion)
    ↓
Respond to Webhook
```

## Testing

### Recording voice messages:
1. Launch the app
2. **Regular recording**: Click microphone button → speak → click stop button
3. **Cancel recording**: Start recording → long press on microphone button → press "Cancel"
4. **Automatic cleanup**: Close app and restart - old files should disappear

### Playing voice messages:
1. Send a voice message
2. A player with play button will appear in chat
3. Click play button for playback
4. Watch progress on waveform and time counter

### Session file management:
1. Record several voice messages
2. Check for files in Documents Directory
3. Close the app
4. Verify that files are deleted
5. Restart the app - cleanup of remaining files should occur

## System Requirements

- macOS 15.0+
- Microphone permission
- Internet connection for sending to webhook

## Security

- **Session file management**: Audio files exist only during the app session
- **Automatic cleanup**: All files are deleted when app closes
- **Leak protection**: On restart, remaining files are checked and deleted
- **Cancel recording**: Ability to immediately delete unwanted recordings
- **HTTPS**: All data is transmitted over secure connection
- **Local storage**: No audio data is stored permanently

## Possible Improvements

1. **Audio compression**: Add additional compression to save bandwidth
2. **Level visualization**: Show sound level during recording in real-time
3. **Offline mode**: Save recordings locally when offline with subsequent sync
4. **Maximum duration**: Limit recording time (e.g., 60 seconds) with visual warning
5. **Recording preview**: Ability to listen to recording before sending
6. **Playback speed**: Playback speed adjustment (1x, 1.5x, 2x)
7. **Keyboard shortcuts**: Hotkeys for quick recording (e.g., Space for push-to-talk)
8. **Automatic transcription**: Local transcription with text display under player
9. **Waveform from real data**: Generate actual waveform based on audio data
10. **Voice commands**: Recognition of commands like "send", "cancel" directly in voice message

## Technical Diagnostics

### Debug logs:
- All recording and playback errors are logged to console
- File lifecycle tracking with name prints
- Microphone permission logging

### Session file check:
```swift
// For debugging, you can check active session files
let sessionFiles = UserDefaults.standard.stringArray(forKey: "audioRecorderSessionFiles") ?? []
print("Active session files: \(sessionFiles)")
```

### Memory monitoring:
- AudioRecorder properly releases resources via deinit
- Timers are stopped when recording/playback ends
- No retain cycles in AVAudioRecorder and AVAudioPlayer delegates
