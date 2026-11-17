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

    var body: some View {
        OrnamentLayer(scene: Self.scene(dark: dark, worldTime: worldTime),
                      spriteKey: "yule.\(dark).\(worldTime)")
    }

    /// Garland and snow as one ornament scene: each halo a pre-rendered blur,
    /// the flake a glyph rasterized once — per frame only placement changes.
    static func scene(dark: Bool, worldTime: Bool) -> OrnamentScene {
        var flakeColor = dark ? drgba(255, 255, 255, 0.85) : drgba(120, 150, 170, 0.8)
        if worldTime { flakeColor = flakeColor.opacity(0.5) }
        let flakes = worldTime ? Self.wtFlakes : Self.flakes
        let glowAlpha = dark ? 0.8 : 0.47
        let bulbScale: CGFloat = worldTime ? 0.8 : 1
        let flakeBox = CGSize(width: 10, height: 10)

        var sprites = bulbColors.enumerated().map { i, color in
            OrnamentSpriteSpec("halo\(i)", radius: 5, fixed: CGSize(width: 10, height: 12)) {
                Ellipse().fill(color)
            }
        }
        sprites.append(OrnamentSpriteSpec("flake", radius: 0, fixed: flakeBox) {
            Text("❄").font(.system(size: 7)).foregroundColor(flakeColor)
        })

        let garlandAndSnow = Ornament.draw { ctx, frame in
            let t = frame.t
            let size = frame.size
            // Bulbs, 1:1 with the mock's `box-shadow: 0 0 8px 1.5px` +
            // `twinkle`: a blurred halo behind the drop, swelling and fading
            // with the bulb's own brightness — each on its own ease-in-out
            // breath, phase-shifted along the row.
            for i in 0..<bulbTops.count {
                let period = 2 + Double(i % 3) * 0.5
                let dim = MotionCurve.pingPong(t, half: period / 2, delay: Double(i) * 0.35)
                let center = CGPoint(x: size.width * (0.05 + CGFloat(i) * 0.10) + 3,
                                     y: bulbTops[i] - (worldTime ? 9 : 0) + 4)
                if let halo = frame.sprite("halo\(i % 4)") {
                    let k = bulbScale * MotionCurve.lerp(1.3, 0.75, dim)
                    let w = (10 + 2 * halo.padding) * k, h = (12 + 2 * halo.padding) * k
                    var layer = ctx
                    layer.opacity = MotionCurve.lerp(glowAlpha, glowAlpha * 0.35, dim)
                    layer.draw(Image(decorative: halo.image, scale: frame.displayScale),
                               in: CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h))
                }
                let drop = dropShape
                    .path(in: CGRect(x: -3, y: -4, width: 6, height: 8))
                    .applying(CGAffineTransform(translationX: center.x, y: center.y)
                        .scaledBy(x: bulbScale, y: bulbScale))
                ctx.fill(drop, with: .color(bulbColors[i % 4].opacity(MotionCurve.lerp(1, 0.5, dim))))
            }
            // Snow: each flake's y is a phase-shifted loop over the panel
            // height, x sways around its lane.
            guard let flake = frame.sprite("flake") else { return }
            let image = Image(decorative: flake.image, scale: frame.displayScale)
            let travel = size.height + 40
            for f in flakes {
                let progress = ((t + f.phase) / f.duration).truncatingRemainder(dividingBy: 1)
                let sway = sin((t + f.phase) / (f.duration / 3.2) * 2 * .pi) * 4.5
                let c = CGPoint(x: size.width * f.x + sway, y: progress * travel - 24)
                // Pixel-aligned: a resampled 7 pt glyph goes soft and gray.
                // The fall (~1.3 px a frame) hides the whole-pixel steps.
                let s = frame.displayScale
                let origin = CGPoint(x: ((c.x - flakeBox.width / 2) * s).rounded() / s,
                                     y: ((c.y - flakeBox.height / 2) * s).rounded() / s)
                ctx.draw(image, in: CGRect(origin: origin, size: flakeBox))
            }
        }
        return OrnamentScene(fps: 60, sprites: sprites, ornaments: [garlandAndSnow])
    }

    /// The bulb's drop silhouette (6×8 pt).
    private static let dropShape = UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(
        topLeading: 2.7, bottomLeading: 3, bottomTrailing: 3, topTrailing: 2.7))
}
