import SwiftUI

/// Compact recording indicator in the Liquid Glass language: a small centered
/// capsule on system material — pulsing dot, monospaced timer, subtle hint.
/// (Dense colored bands don't fit the glass panel; content sits on materials.)
struct RecordingStatusView: View {
    @Binding var isRecording: Bool
    @State private var recordingStart = Date()
    @State private var isPulsing = false

    var body: some View {
        if isRecording {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 7, height: 7)
                    .scaleEffect(isPulsing ? 1.0 : 0.6)
                    .opacity(isPulsing ? 1.0 : 0.45)
                    .animation(
                        .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                        value: isPulsing
                    )

                // Timer driven by TimelineView — no manual Timer bookkeeping
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    Text(formatDuration(context.date.timeIntervalSince(recordingStart)))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundColor(.primary)
                }

                Text("·")
                    .foregroundColor(.secondary)

                Text(L("recording.hint"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule().stroke(Color.red.opacity(0.25), lineWidth: 1)
            )
            .frame(maxWidth: .infinity, alignment: .center)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .onAppear {
                recordingStart = Date()
                isPulsing = true
            }
            .onDisappear {
                isPulsing = false
            }
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let clamped = max(0, duration)
        let minutes = Int(clamped) / 60
        let seconds = Int(clamped) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
    VStack(spacing: 20) {
        RecordingStatusView(isRecording: .constant(true))
        RecordingStatusView(isRecording: .constant(false))
    }
    .padding()
}
