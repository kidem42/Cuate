import Combine
import SwiftUI

struct EnhancedVoiceButton: View {
    @Binding var isRecording: Bool
    let startRecording: () -> Void
    let stopRecording: () -> Void
    let cancelRecording: () -> Void

    @State private var isPulsing = false
    // No STT provider has an API key: the mic can't do anything, so it shows
    // a badge and explains itself in a popover instead of failing on tap.
    // Self-contained: checks on appear and re-checks on every key change.
    @State private var sttKeyMissing = false
    @State private var showKeyPopover = false
    @Environment(\.themePalette) private var palette
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            if sttKeyMissing, !isRecording {
                missingKeyButton
            } else {
                recordButton
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
            refreshKeyPresence()
            if isRecording {
                startPulse()
            }
        }
        // Cache-only check: a cold APIKeyStore cache reports "no key" and warms
        // in the background, then republishes — this re-check picks it up.
        // The notification can arrive off-main (warm/repair path).
        .onReceive(NotificationCenter.default.publisher(for: .apiKeysDidChange).receive(on: RunLoop.main)) { _ in
            refreshKeyPresence()
        }
    }

    // MARK: - Normal record button

    private var recordButton: some View {
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

                buttonChrome

                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .foregroundColor(isRecording ? .white : (palette.isGlass ? .primary : (palette.micGlyphColor ?? palette.micColor ?? palette.accent)))
                    .font(.system(size: 14, weight: .medium))
            }
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(isRecording ? 1.05 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isRecording)
        .help(isRecording ? L("tooltip.voice.stop") : L("tooltip.voice.start"))
        .onTapGesture(count: 2) {
            // Double tap to cancel
            if isRecording {
                cancelRecording()
            }
        }
    }

    // MARK: - Missing-key state

    /// Same footprint and theme chrome as the idle mic, but the glyph is dimmed
    /// and wears a small exclamation badge. Tapping opens a popover that
    /// explains the requirement and deep-links into Settings → API Keys.
    private var missingKeyButton: some View {
        Button {
            showKeyPopover = true
        } label: {
            ZStack {
                buttonChrome

                Image(systemName: "mic.fill")
                    .foregroundColor(palette.isGlass ? .primary : (palette.micGlyphColor ?? palette.micColor ?? palette.accent))
                    .font(.system(size: 14, weight: .medium))
                    .opacity(0.4)

                ZStack {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 13, height: 13)
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                }
                .offset(x: 11, y: -11)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .help(L("voice.noKey.tooltip"))
        .popover(isPresented: $showKeyPopover, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("voice.noKey.text"))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 230, alignment: .leading)
                Button(L("voice.noKey.open")) {
                    showKeyPopover = false
                    NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
                    // Posted after the window request so the deep link lands on
                    // a Settings window that already exists (the gear pattern).
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .revealSpeechKeySection, object: nil)
                    }
                }
                .controlSize(.small)
            }
            .padding(12)
        }
    }

    /// The 32pt button chrome, shared by the normal and missing-key states so
    /// the composer's rhythm never shifts. While recording it collapses to the
    /// red circle regardless of theme (the original behavior).
    @ViewBuilder
    private var buttonChrome: some View {
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
    }

    private func refreshKeyPresence() {
        sttKeyMissing = !STTProviderID.allCases.contains { $0.hasKey }
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
