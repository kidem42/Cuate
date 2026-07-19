import SwiftUI

/// A single glyph that gently bobs up and down (the design's `floaty` loop).
/// Used for Sakura petals (❀/✿) and Pastel sparkles (✦). Non-interactive,
/// placed over the panel gradient and under the chat content.
private struct FloatingGlyph: View {
    let glyph: String
    let size: CGFloat
    let color: Color
    let duration: Double
    @State private var up = false

    var body: some View {
        Text(glyph)
            .font(.system(size: size))
            .foregroundColor(color)
            .offset(y: up ? -6 : 0)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeInOut(duration: duration / 2).repeatForever(autoreverses: true)) {
                    up = true
                }
            }
    }
}

/// 0–255 rgba helper, matching the design spec verbatim (local copy — the one
/// in AppTheme is file-private).
private func drgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Color {
    Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
}

/// Sakura's floating cherry-blossom petals (❀ / ✿) at the spec's positions.
struct SakuraDecorations: View {
    @Environment(\.colorScheme) private var colorScheme
    private var dark: Bool { colorScheme == .dark }

    /// Petal tint at a given opacity — pink in dark, deeper rose in light.
    private func petal(_ opacity: Double) -> Color {
        dark ? drgba(255, 150, 195, opacity) : drgba(230, 100, 150, opacity)
    }

    var body: some View {
        ZStack {
            FloatingGlyph(glyph: "❀", size: 14, color: petal(dark ? 0.35 : 0.40), duration: 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.trailing, 22).padding(.top, 34)

            FloatingGlyph(glyph: "❀", size: 10, color: petal(dark ? 0.22 : 0.28), duration: 7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 30).padding(.top, 90)

            FloatingGlyph(glyph: "✿", size: 12, color: petal(dark ? 0.18 : 0.22), duration: 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.trailing, 60).padding(.top, 150)
        }
        .allowsHitTesting(false)
    }
}

/// Pastel's floating sparkles (✦) — lavender + peach, at the spec's positions.
struct PastelDecorations: View {
    @Environment(\.colorScheme) private var colorScheme
    private var dark: Bool { colorScheme == .dark }

    var body: some View {
        ZStack {
            FloatingGlyph(glyph: "✦", size: 12,
                          color: dark ? drgba(200, 175, 255, 0.40) : drgba(150, 110, 210, 0.45),
                          duration: 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.trailing, 26).padding(.top, 40)

            FloatingGlyph(glyph: "✦", size: 9,
                          color: dark ? drgba(255, 171, 145, 0.35) : drgba(255, 140, 110, 0.40),
                          duration: 7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 34).padding(.top, 110)
        }
        .allowsHitTesting(false)
    }
}
