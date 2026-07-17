import SwiftUI

/// Simplified, recognizable mockups of real usage scenarios for the tour.
/// Not pixel-perfect — just enough for the user to "get" each feature.
enum OnboardingScene: String {
    case panel, keys, selection, screenshot, voice, dictation, layoutfix, tips
}

struct OnboardingIllustration: View {
    let scene: OnboardingScene

    var body: some View {
        ZStack {
            // A faint "wallpaper" so glass/overlays read as floating on a desktop
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [Color.teal.opacity(0.25), Color.green.opacity(0.22)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )

            switch scene {
            case .panel: panelScene
            case .keys: keysScene
            case .selection: selectionScene
            case .screenshot: screenshotScene
            case .voice: voiceScene
            case .dictation: dictationScene
            case .layoutfix: layoutfixScene
            case .tips: tipsScene
            }
        }
        .frame(width: 300, height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
    }

    // MARK: Helpers

    private func bubble(_ text: String, user: Bool) -> some View {
        Text(text)
            .font(.system(size: 8))
            .foregroundColor(.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(user ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity, alignment: user ? .trailing : .leading)
    }

    private var miniPanel: some View {
        VStack(spacing: 5) {
            bubble("How do I center a div?", user: true)
            bubble("Use `display: flex` with…", user: false)
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 16)
                Circle().fill(Color.accentColor).frame(width: 16, height: 16)
            }
        }
        .padding(8)
        .frame(width: 180)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
    }

    // MARK: Scenes

    private var panelScene: some View {
        VStack(spacing: 0) {
            // Mock menu bar so the user learns to recognize the status icon
            HStack(spacing: 12) {
                Spacer()
                Image(systemName: "wifi").font(.system(size: 9))
                Image(systemName: "battery.100").font(.system(size: 9))
                // The app's own status-bar icon, highlighted
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.accentColor)
                    .padding(3)
                    .background(Circle().fill(Color.accentColor.opacity(0.18)))
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 1))
                Image(systemName: "magnifyingglass").font(.system(size: 9))
            }
            .foregroundColor(.primary.opacity(0.6))
            .padding(.horizontal, 10)
            .frame(height: 22)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.08))

            Spacer(minLength: 0)
            miniPanel
            Spacer(minLength: 0)
        }
    }

    private var keysScene: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                ForEach([ProviderID.openai, .anthropic, .gemini, .mistral, .deepseek], id: \.self) { p in
                    ProviderLogo(provider: p, size: 22)
                }
            }
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 130, height: 18)
                    .overlay(
                        Text("sk-••••••••••")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.leading, 7),
                        alignment: .leading
                    )
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.green)
            }
        }
    }

    private var selectionScene: some View {
        VStack(spacing: 6) {
            // A document with a highlighted (selected) line
            VStack(alignment: .leading, spacing: 4) {
                textLine(width: 120)
                Text("Ce n'est pas possible !")
                    .font(.system(size: 8))
                    .padding(.horizontal, 4).padding(.vertical, 1.5)
                    .background(Color.accentColor.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                textLine(width: 96)
            }
            .padding(8)
            .frame(width: 180, alignment: .leading)
            .background(Color.white.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Image(systemName: "arrow.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)

            // The panel's input field with the selection as a styled quote
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor)
                        .frame(width: 3, height: 12)
                    Text("Ce n'est pas possible !")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
                Text("Translate|")
                    .font(.system(size: 8))
                    .foregroundColor(.primary)
            }
            .padding(7)
            .frame(width: 180, alignment: .leading)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
    }

    private var screenshotScene: some View {
        HStack(spacing: 10) {
            // A "screenshot" of a document, with a selection marquee
            VStack(alignment: .leading, spacing: 4) {
                textLine(width: 60, bold: true)
                textLine(width: 90)
                textLine(width: 78)
                textLine(width: 84)
            }
            .padding(8)
            .frame(width: 110, height: 84)
            .background(Color.white.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            )

            VStack(spacing: 2) {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.accentColor)
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
            }

            // Extracted, structured Markdown
            VStack(alignment: .leading, spacing: 4) {
                textLine(width: 55, bold: true)
                HStack(spacing: 3) { dot; textLine(width: 66) }
                HStack(spacing: 3) { dot; textLine(width: 58) }
                HStack(spacing: 3) { dot; textLine(width: 70) }
            }
            .padding(8)
            .frame(width: 110, height: 84)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
    }

    private func textLine(width: CGFloat, bold: Bool = false) -> some View {
        Capsule()
            .fill(Color.primary.opacity(bold ? 0.55 : 0.25))
            .frame(width: width, height: bold ? 5 : 3.5)
    }

    private var dot: some View {
        Circle().fill(Color.primary.opacity(0.4)).frame(width: 3, height: 3)
    }

    private var voiceScene: some View {
        VStack {
            HStack(spacing: 6) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.accentColor)
                HStack(spacing: 1.5) {
                    ForEach(0..<22, id: \.self) { i in
                        Capsule()
                            .fill(Color.primary.opacity(0.7))
                            .frame(width: 2, height: waveHeight(i))
                    }
                }
                Text("0:07").font(.system(size: 8).monospacedDigit()).foregroundColor(.secondary)
            }
            .padding(8)
            .background(Color.accentColor.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal, 16)
    }

    private func waveHeight(_ i: Int) -> CGFloat {
        let pattern: [CGFloat] = [6, 10, 16, 12, 20, 14, 8, 18, 22, 12, 7, 15, 19, 10, 6, 13, 21, 16, 9, 14, 11, 7]
        return pattern[i % pattern.count]
    }

    private var dictationScene: some View {
        VStack(spacing: 12) {
            // notch pill
            HStack(spacing: 4) {
                Circle().fill(Color.red).frame(width: 5, height: 5)
                ForEach(0..<10, id: \.self) { i in
                    Capsule().fill(Color.primary.opacity(0.7)).frame(width: 2, height: waveHeight(i) * 0.6)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.regularMaterial)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.15), radius: 3)

            Image(systemName: "arrow.down").font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)

            // target text field with inserted text
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.08))
                .frame(width: 200, height: 26)
                .overlay(
                    Text("Meeting notes: ship on Friday|")
                        .font(.system(size: 9))
                        .foregroundColor(.primary)
                        .padding(.leading, 8),
                    alignment: .leading
                )
        }
    }

    private var layoutfixScene: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("Ghbdtn! Rfr ltkf?")
                    .font(.system(size: 10, design: .monospaced))
                    .strikethrough(color: .red.opacity(0.6))
                    .foregroundColor(.secondary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.accentColor)
                Text("Привет! Как дела?")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.primary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)

            HStack(spacing: 6) {
                ForEach(["EN", "RU", "ES"], id: \.self) { code in
                    Text(code)
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2.5)
                        .background(Capsule().fill(Color.primary.opacity(0.1)))
                }
            }
        }
    }

    private var tipsScene: some View {
        VStack(spacing: 5) {
            bubble("Latest macOS version?", user: true)
            // Live web-search status
            HStack(spacing: 4) {
                Image(systemName: "globe").font(.system(size: 8))
                Text("Searching the web…").font(.system(size: 8))
            }
            .foregroundColor(.accentColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Answer with a cited source chip
            VStack(alignment: .leading, spacing: 4) {
                Text("The latest is macOS 26.")
                    .font(.system(size: 8))
                HStack(spacing: 3) {
                    Image(systemName: "link").font(.system(size: 7))
                    Text("apple.com")
                        .font(.system(size: 7.5, weight: .medium))
                }
                .foregroundColor(.accentColor)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.14))
                .clipShape(Capsule())
            }
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(Color.secondary.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(width: 200)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }
}
