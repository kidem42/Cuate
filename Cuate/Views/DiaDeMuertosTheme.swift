import SwiftUI

// Día de Muertos ("Ofrenda") ornaments, ported verbatim from the design tool's
// inline SVG (viewBox coords + hex are 1:1 with `Cuate Themes.html`).
// Rendered natively (Shapes/Canvas) and animated by the ornament engine —
// no WebView at runtime. Dark/light chosen by the environment color scheme.

private func drgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Color {
    Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
}
private func dhex(_ v: UInt) -> Color { Color(rgb: v) }

// MARK: - Papel picado pennant (single flag with skull + diamond cut-outs)

/// Trapezoid flag with a 5-tooth sawtooth bottom and evenodd cut-outs
/// (skull head + jaw, two side diamonds, two small diamonds). Built in the
/// design's 40×27 space and scaled to the view.
struct PapelPicadoPennant: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 40, sy = rect.height / 27
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
        var path = Path()

        // Body: rectangle with sawtooth bottom.
        path.move(to: p(0, 0)); path.addLine(to: p(40, 0)); path.addLine(to: p(40, 19))
        for x: CGFloat in stride(from: 36, through: 4, by: -4) {
            let up = Int((40 - x) / 4) % 2 == 1   // valleys at 36,28,20,12,4
            path.addLine(to: p(x, up ? 23 : 19))
        }
        path.addLine(to: p(0, 19)); path.closeSubpath()

        // Skull head (circle center (20,8) r3.4)
        path.addEllipse(in: CGRect(x: (20 - 3.4) * sx, y: (8 - 3.4) * sy, width: 6.8 * sx, height: 6.8 * sy))
        // Skull jaw
        addPoly(&path, [(17.9, 11.6), (22.1, 11.6), (22.1, 14.0), (21.1, 14.9), (20.0, 14.0), (18.9, 14.9), (17.9, 14.0)], p)
        // Side diamonds
        addPoly(&path, [(8, 5.6), (10.3, 8.7), (8, 11.8), (5.7, 8.7)], p)
        addPoly(&path, [(32, 5.6), (34.3, 8.7), (32, 11.8), (29.7, 8.7)], p)
        // Small diamonds
        addPoly(&path, [(5, 14.8), (6.5, 16.3), (5, 17.8), (3.5, 16.3)], p)
        addPoly(&path, [(35, 14.8), (36.5, 16.3), (35, 17.8), (33.5, 16.3)], p)
        return path
    }

    private func addPoly(_ path: inout Path, _ pts: [(CGFloat, CGFloat)], _ p: (CGFloat, CGFloat) -> CGPoint) {
        guard let first = pts.first else { return }
        path.move(to: p(first.0, first.1))
        for pt in pts.dropFirst() { path.addLine(to: p(pt.0, pt.1)) }
        path.closeSubpath()
    }
}

// MARK: - Sugar skull (assistant icon)

struct SugarSkull: View {
    let dark: Bool
    /// Design SVG is 24×26; displayed at 16×17.
    var body: some View {
        Canvas { ctx, size in
            let sx = size.width / 24, sy = size.height / 26
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
            func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: (cx - r) * sx, y: (cy - r) * sy, width: 2 * r * sx, height: 2 * r * sy))
            }
            // Skull base
            var base = Path()
            base.move(to: pt(12, 1))
            base.addCurve(to: pt(2.5, 10.3), control1: pt(6.2, 1), control2: pt(2.5, 5))
            base.addCurve(to: pt(5.8, 17.5), control1: pt(2.5, 13.6), control2: pt(3.9, 16.0))
            base.addLine(to: pt(5.8, 21))
            base.addCurve(to: pt(8.2, 23.4), control1: pt(5.8, 22.3), control2: pt(6.9, 23.4))
            base.addLine(to: pt(15.8, 23.4))
            base.addCurve(to: pt(18.2, 21), control1: pt(17.1, 23.4), control2: pt(18.2, 22.3))
            base.addLine(to: pt(18.2, 17.5))
            base.addCurve(to: pt(21.5, 10.3), control1: pt(20.1, 16.0), control2: pt(21.5, 13.6))
            base.addCurve(to: pt(12, 1), control1: pt(21.5, 5), control2: pt(17.8, 1))
            ctx.fill(base, with: .color(dark ? dhex(0xFFF4E4) : dhex(0xFFFDF8)))
            if !dark { ctx.stroke(base, with: .color(drgba(120, 60, 10, 0.3)), lineWidth: 0.6) }

            // Eyes
            ctx.fill(circle(8.2, 10, 2.1), with: .color(dark ? dhex(0xEC407A) : dhex(0xD81B60)))
            ctx.fill(circle(15.8, 10, 2.1), with: .color(dark ? dhex(0x26A69A) : dhex(0x00897B)))
            // Marigold dots around eyes
            let dot = dark ? dhex(0xFFB300) : dhex(0xF59E00)
            for (cx, cy) in [(8.2, 6.6), (4.9, 10.0), (8.2, 13.4), (15.8, 6.6), (19.1, 10.0), (15.8, 13.4)] {
                ctx.fill(circle(cx, cy, 0.7), with: .color(dot))
            }
            // Nose
            var nose = Path()
            nose.move(to: pt(12, 13.4)); nose.addLine(to: pt(10.8, 15.4)); nose.addLine(to: pt(13.2, 15.4)); nose.closeSubpath()
            ctx.fill(nose, with: .color(dhex(0x5C2A47)))
            // Mouth + teeth
            var mouth = Path()
            mouth.move(to: pt(8.4, 19.2)); mouth.addLine(to: pt(15.6, 19.2))
            for x: CGFloat in [9.8, 12, 14.2] { mouth.move(to: pt(x, 18)); mouth.addLine(to: pt(x, 20.4)) }
            ctx.stroke(mouth, with: .color(dhex(0x5C2A47)), lineWidth: 0.95 * sx)
            // Forehead flower dot
            ctx.fill(circle(12, 4.4, 0.9), with: .color(dark ? dhex(0xEC407A) : dhex(0xD81B60)))
        }
        .frame(width: 16, height: 17)
    }
}

// MARK: - Marigold flower (send button + floating décor)

/// Layered marigold: 4 outer petals + optional rotated inner 4 + center disc +
/// optional white sparkle. Design SVG is 24×24.
struct MarigoldFlower: View {
    let dark: Bool
    var withInner: Bool = true
    var withSparkle: Bool = false
    var centerRadius: CGFloat = 5.2
    var centerColor: Color? = nil

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 24
            ZStack {
                petals(color: dark ? dhex(0xFFB300) : dhex(0xF59E00), s: s)
                if withInner {
                    petals(color: dark ? dhex(0xFF8F00) : dhex(0xE65100), s: s, inner: true)
                        .rotationEffect(.degrees(45))
                }
                Circle()
                    .fill(centerColor ?? dhex(0x4A1030))
                    .frame(width: centerRadius * 2 * s, height: centerRadius * 2 * s)
                if withSparkle {
                    sparkle(s: s)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    @ViewBuilder
    private func petals(color: Color, s: CGFloat, inner: Bool = false) -> some View {
        let specs: [(CGFloat, CGFloat, CGFloat, CGFloat)] = inner
            ? [(12, 5.5, 2.6, 4), (12, 18.5, 2.6, 4), (5.5, 12, 4, 2.6), (18.5, 12, 4, 2.6)]
            : [(12, 5, 3, 4.5), (12, 19, 3, 4.5), (5, 12, 4.5, 3), (19, 12, 4.5, 3)]
        ZStack {
            ForEach(Array(specs.enumerated()), id: \.offset) { _, e in
                Ellipse()
                    .fill(color)
                    .frame(width: e.2 * 2 * s, height: e.3 * 2 * s)
                    .position(x: e.0 * s, y: e.1 * s)
            }
        }
    }

    private func sparkle(s: CGFloat) -> some View {
        Path { p in
            p.move(to: CGPoint(x: 14.85 * s, y: 9.47 * s))
            p.addLine(to: CGPoint(x: 9.56 * s, y: 11.66 * s))
            p.addLine(to: CGPoint(x: 11.53 * s, y: 12.45 * s))
            p.addLine(to: CGPoint(x: 12.33 * s, y: 14.43 * s))
            p.closeSubpath()
        }
        .fill(.white)
    }
}

// MARK: - Candle

/// The candle itself — static, so the flicker only fades and scales it.
private struct CandleGlyph: View {
    let dark: Bool

    var body: some View {
        Canvas { ctx, size in
            let sx = size.width / 12, sy = size.height / 22
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
            // Body
            let body = Path(roundedRect: CGRect(x: 3 * sx, y: 8 * sy, width: 6 * sx, height: 13 * sy), cornerRadius: 1.5 * sx)
            ctx.fill(body, with: .color(dark ? drgba(255, 245, 225, 0.85) : .white))
            if !dark { ctx.stroke(body, with: .color(drgba(120, 60, 10, 0.25)), lineWidth: 0.5) }
            // Flame
            var flame = Path()
            flame.move(to: pt(6, 1.2))
            flame.addCurve(to: pt(6, 6.4), control1: pt(7.6, 3), control2: pt(8, 4.4))
            flame.addCurve(to: pt(6, 1.2), control1: pt(4, 4.4), control2: pt(4.4, 3))
            ctx.fill(flame, with: .color(dark ? dhex(0xFFB300) : dhex(0xF59E00)))
            ctx.fill(Path(ellipseIn: CGRect(x: 5 * sx, y: 3.6 * sy, width: 2 * sx, height: 2 * sy)), with: .color(dhex(0xFFF3C4)))
        }
    }
}

// MARK: - Dictation island ornaments

/// Five pennants from the banner hanging from the dictation island's bottom
/// edge — the edge is the string — 13×9 each, in the banner's first five
/// colors, swaying ±2° at the top half a second apart. Clocked by a
/// TimelineView, not a repeatForever animation: the island's content comes
/// and goes inside transactions of its own (see `RecordingStatusView`).
struct DiaIslandPennants: View {
    /// False under Reduce Motion: the pennants hang straight.
    let swaying: Bool
    private static let colors: [UInt] = [0xEC407A, 0xFFB300, 0x26A69A, 0xAB47BC, 0xFF7043]

    var body: some View {
        MotionTimeline(minimumInterval: 1.0 / 30.0, paused: !swaying) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 0) {
                ForEach(0..<Self.colors.count, id: \.self) { i in
                    PapelPicadoPennant()
                        .fill(dhex(Self.colors[i]), style: FillStyle(eoFill: true))
                        .frame(width: 13, height: 9)
                        // SwayingPennant's 2 s ease-in-out autoreverse = a 4 s sine.
                        .rotationEffect(.degrees(swaying ? 2 * sin((t - Double(i) * 0.5) * .pi / 2) : 0),
                                        anchor: .top)
                    if i < Self.colors.count - 1 { Spacer(minLength: 0) }
                }
            }
            .padding(.horizontal, 22)
        }
        .allowsHitTesting(false)
    }
}

/// The island's warm-up in Día: three marigolds blooming in turn — scale
/// 0.8 → 1.15 with a slight turn — on the dots' own clock and stagger, so
/// "not hearing yet" speaks the theme's language.
struct DiaIslandMarigolds: View {
    /// False under Reduce Motion: the flowers hold a middle bloom.
    let blooming: Bool

    var body: some View {
        MotionTimeline(minimumInterval: 1.0 / 30.0, paused: !blooming) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    let pulse = blooming ? 0.5 + 0.5 * sin(t * 5.2 - Double(i) * 1.9) : 0.6
                    MarigoldFlower(dark: true, withInner: true, centerRadius: 4.2)
                        .frame(width: 9, height: 9)
                        .scaleEffect(0.8 + 0.35 * pulse)
                        .rotationEffect(.degrees(20 * pulse))
                        .opacity(0.5 + 0.5 * pulse)
                }
            }
        }
    }
}

/// While the mic hears: four small marigolds rising from below the island's
/// edge through the glow and fading — the chat's floating marigolds as an
/// offering. Lives in the panel's room under the tab; off under Reduce
/// Motion (the caller does not show it).
struct DiaIslandPetals: View {
    /// The panel's width and the height the petals travel.
    let width: CGFloat
    let rise: CGFloat
    private static let petals: [(x: CGFloat, size: CGFloat, duration: Double, phase: Double)] = [
        (0.14, 7, 3.2, 0), (0.28, 5, 4.0, 1.4), (0.68, 6, 3.6, 0.7), (0.84, 5, 4.4, 2.3),
    ]

    var body: some View {
        MotionTimeline(minimumInterval: 1.0 / 30.0) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .bottomLeading) {
                ForEach(0..<Self.petals.count, id: \.self) { i in
                    let p = Self.petals[i]
                    let u = ((t + p.phase) / p.duration).truncatingRemainder(dividingBy: 1)
                    let eased = 1 - (1 - u) * (1 - u)
                    let opacity = u < 0.15 ? u / 0.15 * 0.9 : 0.9 * (1 - (u - 0.15) / 0.85)
                    MarigoldFlower(dark: true, withInner: true, centerRadius: 3, centerColor: dhex(0xE65100))
                        .frame(width: p.size, height: p.size)
                        .rotationEffect(.degrees(90 * eased))
                        .opacity(opacity)
                        .offset(x: width * p.x, y: -rise * eased)
                }
            }
            .frame(width: width, alignment: .bottomLeading)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Full decoration overlay

/// Papel picado banner (top), two floating marigolds, two candles (bottom-
/// right) — one ornament scene. Placement is the original stack's, measured
/// from the panel edges, with one deliberate change: the big marigold rests
/// 24 pt in from the TRAILING edge as designed (the old stack's stray
/// `.position(0, 0)` parked it half outside the leading edge).
struct DiaDecorations: View {
    @Environment(\.colorScheme) private var colorScheme
    private var dark: Bool { colorScheme == .dark }

    var body: some View {
        OrnamentLayer(scene: Self.scene(dark: dark), spriteKey: "dia.\(dark)")
    }

    static func scene(dark: Bool) -> OrnamentScene {
        let pennantColors = (dark
            ? [0xEC407A, 0xFFB300, 0x26A69A, 0xAB47BC, 0xFF7043, 0xEC407A, 0xFFB300, 0x26A69A]
            : [0xD81B60, 0xF59E00, 0x00897B, 0x8E24AA, 0xF4511E, 0xD81B60, 0xF59E00, 0x00897B]).map(dhex)
        let stringColor = dark ? drgba(255, 235, 190, 0.55) : drgba(120, 60, 10, 0.45)
        var ornaments: [Ornament] = []

        // Banner: eight 40×27 pennants spread over the width (10 pt side
        // margins, equal gaps), each swaying ±2° from its top on a 2 s
        // ease-in-out, half a second after its neighbor.
        let count = pennantColors.count
        for (i, color) in pennantColors.enumerated() {
            ornaments.append(.symbol(at: .custom { size in
                let gap = max(0, (size.width - 20 - CGFloat(count) * 40) / CGFloat(count - 1))
                return CGPoint(x: 10 + CGFloat(i) * (40 + gap) + 20, y: 0)
            }, anchor: .top, pose: { t in
                MotionPose(rotation: .degrees(MotionCurve.lerp(-2, 2,
                    MotionCurve.pingPong(t, half: 2, delay: Double(i) * 0.5))))
            }) {
                PapelPicadoPennant()
                    .fill(color, style: FillStyle(eoFill: true))
                    .frame(width: 40, height: 27)
            })
        }
        // The string, over the pennants' tops.
        ornaments.append(.draw { ctx, frame in
            ctx.fill(Path(CGRect(x: 0, y: 0, width: frame.size.width, height: 1.5)), with: .color(stringColor))
        })

        // Floating marigolds: up 6 pt and back on duration/2.
        func marigold(size: CGFloat, inner: Bool, duration: Double, opacity: Double,
                      at: OrnamentPlacement) -> Ornament {
            .symbol(at: at, pose: { t in
                MotionPose(offset: CGSize(width: 0, height: -6 * MotionCurve.pingPong(t, half: duration / 2)))
            }) {
                MarigoldFlower(dark: dark, withInner: inner, withSparkle: false, centerRadius: 3,
                               centerColor: dark ? dhex(0xE65100) : dhex(0xBF360C))
                    .frame(width: size, height: size)
                    .opacity(opacity)
            }
        }
        ornaments.append(marigold(size: 18, inner: true, duration: 6, opacity: 1,
                                  at: .topTrailing(24 + 9, 70 + 9)))
        ornaments.append(marigold(size: 12, inner: false, duration: 8, opacity: dark ? 0.8 : 0.85,
                                  at: .topLeading(30 + 6, 130 + 6)))

        // Candles, bottom-right (20 pt in, 66 pt up), bottoms aligned, 6 pt
        // apart: a 1.2 s flicker — fading to 0.55 and dipping to 0.9 from
        // the base.
        func candle(width: CGFloat, height: CGFloat, delay: Double, at: OrnamentPlacement) -> Ornament {
            .symbol(at: at, anchor: .bottom, pose: { t in
                let flicker = MotionCurve.pingPong(t, half: 1.2, delay: delay)
                return MotionPose(scale: MotionCurve.lerp(1, 0.9, flicker),
                                  opacity: MotionCurve.lerp(1, 0.55, flicker))
            }) {
                CandleGlyph(dark: dark).frame(width: width, height: height)
            }
        }
        ornaments.append(candle(width: 10, height: 18, delay: 0.7, at: .bottomTrailing(20 + 12 + 6 + 5, 66)))
        ornaments.append(candle(width: 12, height: 22, delay: 0, at: .bottomTrailing(20 + 6, 66)))

        return OrnamentScene(fps: 60, ornaments: ornaments)
    }
}
