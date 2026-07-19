import SwiftUI

/// Compact recording indicator in the Liquid Glass language: a small centered
/// capsule on system material — pulsing dot, monospaced timer, subtle hint.
/// (Dense colored bands don't fit the glass panel; content sits on materials.)
struct RecordingStatusView: View {
    @Binding var isRecording: Bool
    @State private var recordingStart = Date()
    @State private var isPulsing = false
    @Environment(\.themePalette) private var palette

    /// Recording accent: red for Current, the theme's recording color otherwise
    /// (Día = magenta).
    private var dotColor: Color {
        palette.isGlass ? .red : (palette.recordingAccent ?? palette.quoteColor ?? palette.accent)
    }

    var body: some View {
        if isRecording {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor)
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
            // Themed popover pill: glass keeps the material; other themes use the
            // panel's own tint so it reads as a compact popover on the solid panel.
            .background(
                Capsule().fill(palette.isGlass ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(palette.panelTint))
            )
            .overlay(
                Capsule().stroke(dotColor.opacity(palette.isGlass ? 0.3 : 0.5), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.14), radius: 5, x: 0, y: 2)
            // Pin to content size so the pill is a compact popover, never a
            // full-width band; the outer frame only centers it in the composer.
            .fixedSize()
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
