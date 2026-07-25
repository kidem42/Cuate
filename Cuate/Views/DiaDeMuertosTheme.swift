import SwiftUI

// Día de Muertos ("Ofrenda") ornaments, ported verbatim from the design tool's
// inline SVG (viewBox coords + hex are 1:1 with `Cuate Themes.html`).
// Rendered natively (Shapes/Canvas) and animated with native SwiftUI loops —
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

private struct SwayingPennant: View {
    let color: Color
    let delay: Double
    @State private var swayed = false

    var body: some View {
        PapelPicadoPennant()
            .fill(color, style: FillStyle(eoFill: true))
            .frame(width: 40, height: 27)
            .rotationEffect(.degrees(swayed ? 2 : -2), anchor: .top)
            .onAppear {
                withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true).delay(delay)) {
                    swayed = true
                }
            }
    }
}

struct PapelPicadoBanner: View {
    let dark: Bool
    private var colors: [Color] {
        dark
            ? [0xEC407A, 0xFFB300, 0x26A69A, 0xAB47BC, 0xFF7043, 0xEC407A, 0xFFB300, 0x26A69A].map(dhex)
            : [0xD81B60, 0xF59E00, 0x00897B, 0x8E24AA, 0xF4511E, 0xD81B60, 0xF59E00, 0x00897B].map(dhex)
    }
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(colors.enumerated()), id: \.offset) { i, c in
                SwayingPennant(color: c, delay: Double(i) * 0.5)
                if i < colors.count - 1 { Spacer(minLength: 0) }
            }
        }
        .padding(.horizontal, 10)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(dark ? drgba(255, 235, 190, 0.55) : drgba(120, 60, 10, 0.45))
                .frame(height: 1.5)
        }
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

struct DiaCandle: View {
    let dark: Bool
    let delay: Double
    @State private var flickering = false

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
        .opacity(flickering ? 0.55 : 1)
        .scaleEffect(flickering ? 0.9 : 1, anchor: .bottom)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true).delay(delay)) {
                flickering = true
            }
        }
    }
}

// MARK: - Floating marigold (floaty loop)

private struct FloatingMarigold: View {
    let dark: Bool
    let size: CGFloat
    let withInner: Bool
    let duration: Double
    let opacity: Double
    @State private var up = false

    var body: some View {
        MarigoldFlower(dark: dark, withInner: withInner, withSparkle: false, centerRadius: 3,
                       centerColor: dark ? dhex(0xE65100) : dhex(0xBF360C))
            .frame(width: size, height: size)
            .opacity(opacity)
            .offset(y: up ? -6 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: duration / 2).repeatForever(autoreverses: true)) { up = true }
            }
    }
}

// MARK: - Full decoration overlay

/// Papel picado banner (top), two floating marigolds, two candles (bottom-
/// right). Non-interactive — placed over the glass, under the chat content's
/// hit-testing.
struct DiaDecorations: View {
    @Environment(\.colorScheme) private var colorScheme
    private var dark: Bool { colorScheme == .dark }

    var body: some View {
        ZStack(alignment: .topLeading) {
            PapelPicadoBanner(dark: dark)
                .frame(height: 27)
                .frame(maxWidth: .infinity, alignment: .top)
                .frame(maxHeight: .infinity, alignment: .top)

            // Floating marigold (top-right) + cross marigold (upper-left)
            FloatingMarigold(dark: dark, size: 18, withInner: true, duration: 6, opacity: 1)
                .position(x: 0, y: 0)
                .offset(x: 0, y: 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.trailing, 24).padding(.top, 70)

            FloatingMarigold(dark: dark, size: 12, withInner: false, duration: 8, opacity: dark ? 0.8 : 0.85)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 30).padding(.top, 130)

            // Candles bottom-right
            HStack(alignment: .bottom, spacing: 6) {
                DiaCandle(dark: dark, delay: 0.7).frame(width: 10, height: 18)
                DiaCandle(dark: dark, delay: 0).frame(width: 12, height: 22)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 20).padding(.bottom, 66)
        }
        .allowsHitTesting(false)
    }
}
