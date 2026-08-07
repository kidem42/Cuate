import SwiftUI

/// 0–255 rgba helper, matching the design spec verbatim (local copy — the one
/// in AppTheme is file-private).
private func drgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Color {
    Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
}

/// Yule's decorations, 1:1 with the approved mock (Cuate New Themes, §1a):
/// a row of garland bulbs hugging the panel's top edge — no wire, each
/// twinkling on its own period — plus snow falling the full panel height
/// with a gentle side-to-side sway.
struct YuleDecorations: View {
    /// World Time: bulbs hug the very edge (and are smaller), there is less
    /// snow and it is translucent — the data board stays readable.
    var worldTime: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    private var dark: Bool { colorScheme == .dark }

    /// Bulb palette from the mock: red / gold / green / ice blue.
    private static let bulbColors: [Color] = [
        Color(rgb: 0xE5484D), Color(rgb: 0xF2C14E),
        Color(rgb: 0x58B368), Color(rgb: 0x6FB7E8),
    ]
    /// Mock's hand-tuned bulb drops (px from the top), one per 10% of width.
    private static let bulbTops: [CGFloat] = [10, 17, 21, 18, 11, 16, 22, 17, 10, 15]
    /// Mock's snowflakes: (x fraction, fall duration s, phase offset s).
    private static let flakes: [(x: CGFloat, duration: Double, phase: Double)] = [
        (0.08, 11, 0), (0.24, 14, 3), (0.43, 9, 6), (0.58, 13, 1.5), (0.72, 10, 4.5),
        (0.88, 12, 7.5), (0.33, 15, 9), (0.80, 12, 10), (0.50, 12, 2.2), (0.16, 10, 7),
    ]
    private static let wtFlakes: [(x: CGFloat, duration: Double, phase: Double)] = [
        (0.06, 13, 0), (0.50, 16, 6), (0.92, 14, 11),
    ]

    private var flakes: [(x: CGFloat, duration: Double, phase: Double)] {
        worldTime ? Self.wtFlakes : Self.flakes
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(0..<Self.bulbTops.count, id: \.self) { i in
                    TwinklingBulb(color: Self.bulbColors[i % 4],
                                  glowAlpha: dark ? 0.8 : 0.47,
                                  period: 2 + Double(i % 3) * 0.5,
                                  phase: Double(i) * 0.35,
                                  scale: worldTime ? 0.8 : 1)
                        .offset(x: geo.size.width * (0.05 + CGFloat(i) * 0.10),
                                y: Self.bulbTops[i] - (worldTime ? 9 : 0))
                }
                // Snow rides one shared clock: each flake's y is a phase-shifted
                // loop over the panel height, x sways around its lane.
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let travel = geo.size.height + 40
                    Canvas { ctx, size in
                        var color = dark ? drgba(255, 255, 255, 0.85) : drgba(120, 150, 170, 0.8)
                        if worldTime { color = color.opacity(0.5) }
                        for flake in flakes {
                            let progress = ((t + flake.phase) / flake.duration)
                                .truncatingRemainder(dividingBy: 1)
                            let sway = sin((t + flake.phase) / (flake.duration / 3.2) * 2 * .pi) * 4.5
                            let point = CGPoint(x: size.width * flake.x + sway,
                                                y: progress * travel - 24)
                            ctx.draw(Text("❄").font(.system(size: 7)).foregroundColor(color),
                                     at: point)
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// One garland bulb, 1:1 with the mock's `box-shadow: 0 0 8px 1.5px` +
/// `twinkle`: a blurred halo LAYER behind the drop (SwiftUI's .shadow has no
/// spread and reads as nothing at this size), swelling and fading in step
/// with the bulb's own brightness.
private struct TwinklingBulb: View {
    let color: Color
    let glowAlpha: Double
    let period: Double
    let phase: Double
    var scale: CGFloat = 1
    @State private var dim = false

    private var drop: some Shape {
        UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(
            topLeading: 2.7, bottomLeading: 3, bottomTrailing: 3, topTrailing: 2.7))
    }

    var body: some View {
        ZStack {
            // CSS halo: 1.5px spread + 8px blur → a blurred drop slightly larger
            // than the bulb itself; at the peak of the breath it swells and brightens.
            Ellipse()
                .fill(color)
                .frame(width: 10, height: 12)
                .blur(radius: 5)
                .scaleEffect(dim ? 0.75 : 1.3)
                .opacity(dim ? glowAlpha * 0.35 : glowAlpha)
            drop
                .fill(color)
                .frame(width: 6, height: 8)
                .opacity(dim ? 0.5 : 1)
        }
        .frame(width: 6, height: 8)   // the halo must not shift the layout
        .scaleEffect(scale)
        .onAppear {
            withAnimation(.easeInOut(duration: period / 2)
                .repeatForever(autoreverses: true)
                .delay(phase)) {
                dim = true
            }
        }
    }
}
