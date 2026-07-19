import SwiftUI

struct EnhancedVoiceButton: View {
    @Binding var isRecording: Bool
    let startRecording: () -> Void
    let stopRecording: () -> Void
    let cancelRecording: () -> Void
    
    @State private var isPulsing = false
    @Environment(\.themePalette) private var palette
    @Environment(\.colorScheme) private var colorScheme

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
                    
                    if !isRecording, !palette.isGlass {
                        // Shape follows composerButtonRadius: nil → circle (16 on a
                        // 32pt button), Blueprint → 6, Terminal → 4. micDashed picks
                        // the dashed (Día) vs solid (Blueprint/Terminal/Synthwave) outline.
                        let radius = palette.composerButtonRadius ?? 16
                        let shape = RoundedRectangle(cornerRadius: radius)
                        let border = palette.micStroke ?? palette.micColor ?? palette.accent
                        if palette.micDashed {
                            let fill: Color = colorScheme == .dark ? border.opacity(0.15) : Color.white.opacity(0.5)
                            shape.fill(fill).frame(width: 32, height: 32)
                            shape.strokeBorder(border.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [1, 3]))
                                .frame(width: 32, height: 32)
                        } else {
                            // Solid outline: themed fill + input-field border, matching
                            // the composer's send button.
                            shape.fill(palette.micFill ?? AnyShapeStyle(Color.white.opacity(0.5)))
                                .frame(width: 32, height: 32)
                            shape.strokeBorder(palette.micStroke ?? palette.inputStroke, lineWidth: 1)
                                .frame(width: 32, height: 32)
                        }
                    } else {
                        Circle()
                            .fill(isRecording ? Color.red : Color.gray.opacity(0.2))
                            .frame(width: 32, height: 32)
                    }

                    Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                        .foregroundColor(isRecording ? .white : (palette.isGlass ? .primary : (palette.micGlyphColor ?? palette.micColor ?? palette.accent)))
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
