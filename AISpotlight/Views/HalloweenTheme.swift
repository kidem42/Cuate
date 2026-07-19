import SwiftUI

// Halloween ("Spooky season") ornaments, ported verbatim from the design
// tool's inline SVG (viewBox coords + hex are 1:1 with `AISpotlight
// Themes.html`, §2a/§3a). Rendered natively (Shapes/Canvas) and animated with
// native SwiftUI loops — no WebView at runtime. Dark/light chosen by the
// environment color scheme.

private func hrgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Color {
    Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
}
private func hhex(_ v: UInt) -> Color { Color(rgb: v) }

// MARK: - Spiderweb (corner web with radial threads + arc rings)

/// Corner spiderweb anchored at the view's top-leading corner. Five radial
/// threads from (0,0) plus up to three concentric arc rings, in the design's
/// 90×90 space. `rings` limits the ring count (the small mirrored web draws 2).
struct SpiderWebShape: Shape {
    var rings: Int = 3

    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 90, sy = rect.height / 90
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
        var path = Path()

        // Radial threads
        for end: (CGFloat, CGFloat) in [(88, 8), (74, 46), (64, 64), (46, 74), (8, 88)] {
            path.move(to: p(0, 0))
            path.addLine(to: p(end.0, end.1))
        }

        // Arc rings (quad-curve chains, verbatim from the SVG)
        let ringPaths: [[(CGFloat, CGFloat, CGFloat, CGFloat)]] = [
            // (control x, control y, end x, end y); first tuple is the move-to (x,y in end slots)
            [(27.9, 2.4, 27.9, 2.4), (26.5, 9, 23.7, 14.8), (22, 17.5, 19.8, 19.8),
             (17.5, 22, 14.8, 23.7), (9, 26.5, 2.4, 27.9)],
            [(51.8, 4.5, 51.8, 4.5), (49, 17, 44, 27.5), (40.8, 33, 36.8, 36.8),
             (33, 40.8, 27.5, 44), (17, 49, 4.5, 51.8)],
            [(75.7, 6.6, 75.7, 6.6), (72, 25, 64.4, 40.3), (59.5, 48.5, 53.7, 53.7),
             (48.5, 59.5, 40.3, 64.4), (25, 72, 6.6, 75.7)],
        ]
        for ring in ringPaths.prefix(rings) {
            guard let first = ring.first else { continue }
            path.move(to: p(first.2, first.3))
            for seg in ring.dropFirst() {
                path.addQuadCurve(to: p(seg.2, seg.3), control: p(seg.0, seg.1))
            }
        }
        return path
    }
}

// MARK: - Spider on a thread (dangle loop)

/// Dangling spider: thread, body + head, six curved legs, two amber eyes.
/// Design SVG is 16×34; the thread runs off the top edge.
private struct HalloweenSpider: View {
    let dark: Bool
    @State private var dropped = false

    private var bodyColor: Color { dark ? hhex(0x3b2154) : hhex(0x4A2B6B) }
    private var threadColor: Color { dark ? hrgba(255, 200, 140, 0.5) : hrgba(130, 65, 15, 0.5) }
    private var eyeColor: Color { dark ? hhex(0xFF9E4F) : hhex(0xFFB74D) }

    var body: some View {
        Canvas { ctx, size in
            let sx = size.width / 16, sy = size.height / 34
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
            func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: (cx - r) * sx, y: (cy - r) * sy, width: 2 * r * sx, height: 2 * r * sy))
            }
            // Thread (extends above the frame in the design; clipped by the panel)
            var thread = Path()
            thread.move(to: pt(8, -20)); thread.addLine(to: pt(8, 18))
            ctx.stroke(thread, with: .color(threadColor), lineWidth: 0.8)
            // Body + head
            ctx.fill(circle(8, 22, 3.6), with: .color(bodyColor))
            ctx.fill(circle(8, 17.2, 2), with: .color(bodyColor))
            // Legs (three per side, curved outward)
            var legs = Path()
            let legSegs: [((CGFloat, CGFloat), (CGFloat, CGFloat), (CGFloat, CGFloat))] = [
                ((5, 20), (2, 18), (1, 15)), ((5, 22.5), (1.5, 22.5), (0.5, 25.5)), ((5.5, 24.5), (3, 26.5), (3, 29.5)),
                ((11, 20), (14, 18), (15, 15)), ((11, 22.5), (14.5, 22.5), (15.5, 25.5)), ((10.5, 24.5), (13, 26.5), (13, 29.5)),
            ]
            for (start, ctrl, end) in legSegs {
                legs.move(to: pt(start.0, start.1))
                legs.addQuadCurve(to: pt(end.0, end.1), control: pt(ctrl.0, ctrl.1))
            }
            ctx.stroke(legs, with: .color(bodyColor), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            // Eyes
            ctx.fill(circle(6.8, 21.2, 0.7), with: .color(eyeColor))
            ctx.fill(circle(9.2, 21.2, 0.7), with: .color(eyeColor))
        }
        .frame(width: 16, height: 34)
        .offset(y: dropped ? 9 : 0)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.25).repeatForever(autoreverses: true)) {
                dropped = true
            }
        }
    }
}

// MARK: - Bat (floaty + sway loops)

/// Bat silhouette in the design's 32×16 space: scalloped wings, round head.
struct BatShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 32, sy = rect.height / 16
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
        var path = Path()
        path.move(to: p(2, 9))
        path.addQuadCurve(to: p(12, 6), control: p(6, 2))       // left wing top
        path.addQuadCurve(to: p(16, 3), control: p(13.5, 3))    // head left
        path.addQuadCurve(to: p(20, 6), control: p(18.5, 3))    // head right
        path.addQuadCurve(to: p(30, 9), control: p(26, 2))      // right wing top
        path.addQuadCurve(to: p(22.5, 11), control: p(25, 8))   // right wing scallop
        path.addLine(to: p(20.5, 9)); path.addLine(to: p(18.5, 12))
        path.addLine(to: p(16, 9.5)); path.addLine(to: p(13.5, 12))
        path.addLine(to: p(11.5, 9)); path.addLine(to: p(9.5, 11))
        path.addQuadCurve(to: p(2, 9), control: p(7, 8))        // left wing scallop
        path.closeSubpath()
        return path
    }
}

private struct FloatingBat: View {
    let dark: Bool
    let width: CGFloat
    let duration: Double
    let opacity: Double
    var sways: Bool = false
    var stroked: Bool = false
    @State private var up = false
    @State private var swayed = false

    private var fill: Color { dark ? hhex(0x3b2154) : hhex(0x4A2B6B) }

    var body: some View {
        ZStack {
            BatShape().fill(fill)
            if stroked && dark {
                BatShape().stroke(hrgba(255, 170, 90, 0.35), lineWidth: 0.6)
            }
        }
        .frame(width: width, height: width / 2)
        .rotationEffect(.degrees(sways ? (swayed ? 2 : -2) : 0))
        .opacity(opacity)
        .offset(y: up ? -6 : 0)
        .onAppear {
            withAnimation(.easeInOut(duration: duration / 2).repeatForever(autoreverses: true)) { up = true }
            if sways {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { swayed = true }
            }
        }
    }
}

// MARK: - Ghost (floaty loop)

/// Ghost silhouette in the design's 20×24 space: dome top, wavy hem, two eyes.
private struct HalloweenGhost: View {
    let dark: Bool
    @State private var up = false

    var body: some View {
        Canvas { ctx, size in
            let sx = size.width / 20, sy = size.height / 24
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
            var body = Path()
            body.move(to: pt(2, 22))
            body.addLine(to: pt(2, 10))
            // Top dome: a8 8 0 0 1 16 0 (semicircle over the top)
            body.addArc(center: pt(10, 10), radius: 8 * sx,
                        startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            body.addLine(to: pt(18, 22))
            // Wavy hem: l-2.7-2.4 -2.6 2.4 -2.7-2.4 -2.6 2.4 -2.7-2.4
            body.addLine(to: pt(15.3, 19.6)); body.addLine(to: pt(12.7, 22))
            body.addLine(to: pt(10.0, 19.6)); body.addLine(to: pt(7.4, 22))
            body.addLine(to: pt(4.7, 19.6))
            body.closeSubpath()
            if dark {
                ctx.fill(body, with: .color(hrgba(255, 255, 255, 0.16)))
            } else {
                ctx.fill(body, with: .color(hrgba(255, 255, 255, 0.85)))
                ctx.stroke(body, with: .color(hrgba(130, 65, 15, 0.25)), lineWidth: 0.6)
            }
            let eye = dark ? hrgba(13, 6, 24, 0.8) : hhex(0x4A2B6B)
            for cx: CGFloat in [7, 13] {
                ctx.fill(Path(ellipseIn: CGRect(x: (cx - 1.3) * sx, y: 8.7 * sy, width: 2.6 * sx, height: 2.6 * sy)),
                         with: .color(eye))
            }
        }
        .frame(width: 22, height: 26)
        .offset(y: up ? -6 : 0)
        .onAppear {
            withAnimation(.easeInOut(duration: 3.25).repeatForever(autoreverses: true)) { up = true }
        }
    }
}

// MARK: - Pumpkin (assistant bubble icon)

/// Plain pumpkin (no face): green stem, orange body, two rib ellipses.
/// Design SVG is 24×24; displayed at 15×15 in the assistant bubble.
struct PumpkinIcon: View {
    let dark: Bool
    var body: some View {
        Canvas { ctx, size in
            let sx = size.width / 24, sy = size.height / 24
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
            // Stem: M12 5c0-2 1-3.5 3-3.5 0 2-1 3.5-3 3.5z
            var stem = Path()
            stem.move(to: pt(12, 5))
            stem.addCurve(to: pt(15, 1.5), control1: pt(12, 3), control2: pt(13, 1.5))
            stem.addCurve(to: pt(12, 5), control1: pt(15, 3.5), control2: pt(14, 5))
            stem.closeSubpath()
            ctx.fill(stem, with: .color(dark ? hhex(0x7CB342) : hhex(0x689F38)))
            // Body + ribs
            func ellipse(_ rx: CGFloat, _ ry: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: (12 - rx) * sx, y: (14 - ry) * sy, width: 2 * rx * sx, height: 2 * ry * sy))
            }
            ctx.fill(ellipse(9.5, 8.5), with: .color(dark ? hhex(0xFF8A2A) : hhex(0xF0700F)))
            let rib = dark ? hhex(0xE06A0E) : hhex(0xC55A08)
            ctx.stroke(ellipse(6.5, 8.5), with: .color(rib), lineWidth: 1.2 * sx)
            ctx.stroke(ellipse(2.8, 8.5), with: .color(rib), lineWidth: 1.2 * sx)
        }
        .frame(width: 15, height: 15)
    }
}

// MARK: - Jack-o'-lantern (send button)

/// Carved pumpkin: stem, body, ribs, triangle eyes and a zigzag grin.
/// Design SVG is 30×28; the composer shows it at 34×32 with a glow.
struct JackOLantern: View {
    let dark: Bool
    var body: some View {
        Canvas { ctx, size in
            let sx = size.width / 30, sy = size.height / 28
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
            // Stem: M15 4.5c0-2.4 1.2-4 3.6-4 0 2.4-1.2 4-3.6 4z
            var stem = Path()
            stem.move(to: pt(15, 4.5))
            stem.addCurve(to: pt(18.6, 0.5), control1: pt(15, 2.1), control2: pt(16.2, 0.5))
            stem.addCurve(to: pt(15, 4.5), control1: pt(18.6, 2.9), control2: pt(17.4, 4.5))
            stem.closeSubpath()
            ctx.fill(stem, with: .color(dark ? hhex(0x7CB342) : hhex(0x689F38)))
            // Body + ribs
            func ellipse(_ rx: CGFloat, _ ry: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: (15 - rx) * sx, y: (16 - ry) * sy, width: 2 * rx * sx, height: 2 * ry * sy))
            }
            ctx.fill(ellipse(13.5, 11.5), with: .color(dark ? hhex(0xFF7A1A) : hhex(0xF0700F)))
            let rib = dark ? hhex(0xD8620C) : hhex(0xC55A08)
            ctx.stroke(ellipse(9, 11.5), with: .color(rib), lineWidth: 1.3 * sx)
            ctx.stroke(ellipse(4, 11.5), with: .color(rib), lineWidth: 1.3 * sx)
            // Face (triangle eyes + zigzag grin)
            let face = dark ? hhex(0xFFE082) : hhex(0xFFF3D6)
            var eyes = Path()
            eyes.move(to: pt(9, 13)); eyes.addLine(to: pt(11.6, 16.6)); eyes.addLine(to: pt(6.4, 16.6)); eyes.closeSubpath()
            eyes.move(to: pt(21, 13)); eyes.addLine(to: pt(23.6, 16.6)); eyes.addLine(to: pt(18.4, 16.6)); eyes.closeSubpath()
            ctx.fill(eyes, with: .color(face))
            var mouth = Path()
            mouth.move(to: pt(7.5, 20))
            mouth.addQuadCurve(to: pt(22.5, 20), control: pt(15, 25.5))
            mouth.addLine(to: pt(20.6, 22.3)); mouth.addLine(to: pt(18.4, 21.0))
            mouth.addLine(to: pt(15.9, 22.7)); mouth.addLine(to: pt(13.4, 21.0))
            mouth.addLine(to: pt(11.2, 22.3))
            mouth.closeSubpath()
            ctx.fill(mouth, with: .color(face))
        }
    }
}

// MARK: - Full decoration overlay

/// Spiderwebs in the top corners, dangling spider, two bats, a ghost.
/// Non-interactive — placed over the glass, under the chat content's
/// hit-testing. Positions are verbatim from the design spec (§2a).
struct HalloweenDecorations: View {
    @Environment(\.colorScheme) private var colorScheme
    private var dark: Bool { colorScheme == .dark }

    private var webColor: Color { dark ? hrgba(255, 200, 140, 0.55) : hrgba(130, 65, 15, 0.5) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Big web, top-left
            SpiderWebShape(rings: 3)
                .stroke(webColor, lineWidth: 1)
                .frame(width: 90, height: 90)
                .opacity(dark ? 0.5 : 0.55)

            // Small mirrored web, top-right
            SpiderWebShape(rings: 2)
                .stroke(webColor, lineWidth: 1.2)
                .frame(width: 64, height: 64)
                .scaleEffect(x: -1, y: 1)
                .opacity(dark ? 0.4 : 0.45)
                .frame(maxWidth: .infinity, alignment: .topTrailing)

            // Spider on a thread (near the small web)
            HalloweenSpider(dark: dark)
                .frame(maxWidth: .infinity, alignment: .topTrailing)
                .padding(.trailing, 34).padding(.top, 38)

            // Bats
            FloatingBat(dark: dark, width: 30, duration: 5, opacity: 1, sways: true, stroked: true)
                .padding(.leading, 120).padding(.top, 52)
            FloatingBat(dark: dark, width: 20, duration: 7, opacity: dark ? 0.75 : 0.7)
                .padding(.leading, 210).padding(.top, 96)

            // Ghost
            HalloweenGhost(dark: dark)
                .padding(.leading, 32).padding(.top, 150)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}
