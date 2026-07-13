import SwiftUI

struct EnhancedVoiceButton: View {
    @Binding var isRecording: Bool
    let startRecording: () -> Void
    let stopRecording: () -> Void
    let cancelRecording: () -> Void
    
    @State private var isPulsing = false
    
    var body: some View {
        HStack(spacing: 8) {
            // Main voice button
            Button(action: {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            }) {
                ZStack {
                    // Pulsing background when recording
                    if isRecording {
                        Circle()
                            .fill(Color.red.opacity(0.3))
                            .frame(width: 40, height: 40)
                            .scaleEffect(isPulsing ? 1.2 : 0.9)
                            .opacity(isPulsing ? 0.6 : 0.2)
                            .animation(
                                Animation.easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                                value: isPulsing
                            )
                    }
                    
                    Circle()
                        .fill(isRecording ? Color.red : Color.gray.opacity(0.2))
                        .frame(width: 32, height: 32)
                    
                    Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                        .foregroundColor(isRecording ? .white : .primary)
                        .font(.system(size: 14, weight: .medium))
                }
            }
            .buttonStyle(PlainButtonStyle())
            .scaleEffect(isRecording ? 1.05 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isRecording)
            .help(isRecording ? "Click to stop and send, double-tap to cancel" : "Click to start recording")
            .onTapGesture(count: 2) {
                // Double tap to cancel
                if isRecording {
                    cancelRecording()
                }
            }
        }
        .onChange(of: isRecording) { _, recording in
            if recording {
                startPulse()
            } else {
                stopPulse()
            }
        }
        .onAppear {
            if isRecording {
                startPulse()
            }
        }
    }
    
    private func startPulse() {
        withAnimation(.easeInOut(duration: 0.8)) {
            isPulsing = true
        }
    }
    
    private func stopPulse() {
        isPulsing = false
    }
}
