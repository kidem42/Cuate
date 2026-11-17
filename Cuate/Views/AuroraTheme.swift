import SwiftUI

/// Aurora's decorations, 1:1 with the approved mock (Cuate New Themes, §2a):
/// blurred aurora ribbons breathing across the panel's top, twinkling stars
/// (dark only) and a shooting star streaking down-left once every 12 s.
/// One ornament scene; the ribbons are panel-sized blurs, rendered once per
/// settled panel size and only moved, stretched and faded per frame.
struct AuroraDecorations: View {
    /// World Time: ribbons and stars stay, shooting stars are chat-only
    /// (a streak across the data would read as an artifact).
    var worldTime: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    private var dark: Bool { colorScheme == .dark }

    var body: some View {
        OrnamentLayer(scene: Self.scene(dark: dark, worldTime: worldTime),
                      spriteKey: "aurora.\(dark).\(worldTime)")
    }

    /// Mock's star field: (x fraction, y px, diameter px).
    private static let stars: [(x: CGFloat, y: CGFloat, d: CGFloat)] = [
        (0.12, 34, 2), (0.30, 16, 1.5), (0.52, 28, 2), (0.76, 20, 1.5), (0.88, 48, 2),
        (0.22, 66, 1.5), (0.64, 58, 1.5), (0.41, 46, 1.5), (0.83, 84, 1.5), (0.08, 96, 1.5),
    ]

    /// A curtain of light: color, drift period/phase, size and top-leading
    /// corner as fractions of the panel (the mock's percentages).
    private struct Ribbon {
        let color: Color
        let period: Double
        let phase: Double
        let width: CGFloat, height: CGFloat
        let x: CGFloat, y: CGFloat
    }

    static func scene(dark: Bool, worldTime: Bool) -> OrnamentScene {
        let ribbons: [Ribbon] = dark ? [
            Ribbon(color: drgba(61, 232, 176, 0.40), period: 11, phase: 0, width: 0.85, height: 0.48, x: -0.18, y: -0.10),
            Ribbon(color: drgba(125, 108, 255, 0.34), period: 14, phase: 2.5, width: 0.90, height: 0.54, x: 0.32, y: -0.06),
            Ribbon(color: drgba(111, 227, 255, 0.22), period: 9, phase: 5, width: 0.70, height: 0.36, x: 0.16, y: -0.04),
        ] : [
            Ribbon(color: drgba(64, 196, 160, 0.26), period: 12, phase: 0, width: 0.80, height: 0.42, x: -0.14, y: -0.08),
            Ribbon(color: drgba(150, 130, 255, 0.24), period: 15, phase: 3, width: 0.85, height: 0.48, x: 0.33, y: -0.02),
        ]
        let sprites = ribbons.enumerated().map { i, ribbon in
            OrnamentSpriteSpec("ribbon\(i)", radius: 11,
                               size: { CGSize(width: $0.width * ribbon.width, height: $0.height * ribbon.height) }) { _ in
                Ellipse()
                    .fill(RadialGradient(colors: [ribbon.color, .clear],
                                         center: .center, startRadius: 0, endRadius: 130))
            }
        }

        var ornaments: [Ornament] = []
        // Ribbons (the mock's `ribbon` keyframe: x ±14, a slight vertical
        // swell, opacity breathing) — one smooth cycle per period.
        ornaments.append(.draw { ctx, frame in
            let size = frame.size
            for (i, ribbon) in ribbons.enumerated() {
                guard let sprite = frame.sprite("ribbon\(i)") else { continue }
                let w = size.width * ribbon.width, h = size.height * ribbon.height
                let u = (frame.t + ribbon.phase).truncatingRemainder(dividingBy: ribbon.period) / ribbon.period
                let angle = u * 2 * .pi
                let drift = sin(angle) * 14
                let swell = 1 + sin(angle + .pi / 3) * 0.10
                let breath = 0.82 + sin(angle + .pi / 6) * 0.18
                // While the panel is being resized the sprite may still be
                // the previous size's: it is stretched to the current one.
                let iw = w + 2 * sprite.padding, ih = (h + 2 * sprite.padding) * swell
                let center = CGPoint(x: size.width * ribbon.x + w / 2 + drift, y: size.height * ribbon.y + h / 2)
                var layer = ctx
                layer.opacity = breath
                layer.draw(Image(decorative: sprite.image, scale: frame.displayScale),
                           in: CGRect(x: center.x - iw / 2, y: center.y - ih / 2, width: iw, height: ih))
            }
        })
        guard dark else { return OrnamentScene(fps: 60, sprites: sprites, ornaments: ornaments) }

        // Stars: pin-pricks pulsing between bright and faint (the mock's
        // `starTw`), each on its own ease-in-out breath.
        ornaments.append(.draw { ctx, frame in
            for (i, star) in stars.enumerated() {
                let period = 2 + Double(i % 4) * 0.7
                let dim = MotionCurve.pingPong(frame.t, half: period / 2, delay: Double(i) * 0.5)
                let d = star.d * MotionCurve.lerp(1, 0.75, dim)
                let cx = frame.size.width * star.x + star.d / 2, cy = star.y + star.d / 2
                ctx.fill(Path(ellipseIn: CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)),
                         with: .color(.white.opacity(MotionCurve.lerp(0.9, 0.25, dim))))
            }
        })
        if !worldTime {
            // Two shooting stars on offset cycles: each flares at a RANDOM
            // point anywhere in the window.
            ornaments.append(.draw { ctx, frame in
                for seed in [0.0, 7.0] { drawShootingStar(&ctx, frame: frame, cycle: 12, seed: seed) }
            })
        }
        return OrnamentScene(fps: 60, sprites: sprites, ornaments: ornaments)
    }

    /// Invisible for most of its cycle, then a bright streak slides
    /// down-left (−90, +54) and fades. Each flight starts at a NEW
    /// pseudo-random point — the cycle index seeds a hash, so the spot
    /// changes every pass without any stored state.
    private static func drawShootingStar(_ ctx: inout GraphicsContext, frame: OrnamentFrame,
                                         cycle: Double, seed: Double) {
        let visibleFrom = 0.92 // the visible tail of the cycle (last 8 %, as in the mock)
        let raw = frame.t + seed * cycle / 2
        let pass = (raw / cycle).rounded(.down)
        let t = raw.truncatingRemainder(dividingBy: cycle) / cycle
        let p = max(0, (t - visibleFrom) / (1 - visibleFrom))
        guard p > 0 else { return }
        let opacity = p < 0.2 ? p * 5 * 0.9 : 0.9 * (1 - (p - 0.2) / 0.8)
        func hash(_ v: Double) -> CGFloat {
            let s = sin(v) * 43758.5453
            return CGFloat(s - s.rounded(.down))
        }
        let startX = frame.size.width * (0.18 + 0.72 * hash(pass * 12.9898 + seed))
        let startY = frame.size.height * (0.06 + 0.72 * hash(pass * 78.233 + seed * 3))
        // A 46×1.5 streak whose top-leading corner sits at the moving point,
        // turned 150° about its trailing edge's midpoint.
        let origin = CGPoint(x: startX - 90 * p, y: startY + 54 * p)
        var layer = ctx
        layer.opacity = opacity
        layer.translateBy(x: origin.x + 46, y: origin.y + 0.75)
        layer.rotate(by: .degrees(150))
        let streak = CGRect(x: -46, y: -0.75, width: 46, height: 1.5)
        layer.fill(Path(roundedRect: streak, cornerRadius: 1),
                   with: .linearGradient(Gradient(colors: [.white.opacity(0.9), .clear]),
                                         startPoint: CGPoint(x: streak.minX, y: 0),
                                         endPoint: CGPoint(x: streak.maxX, y: 0)))
    }
}

/// 0–255 rgba helper (local copy — AppTheme's is file-private).
private func drgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Color {
    Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
}
