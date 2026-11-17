import AppKit
import SwiftUI

/// 0–255 rgba helper, matching the design spec verbatim (local copy — the one
/// in AppTheme is file-private).
private func drgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Color {
    Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
}

/// A text glyph drawn as its vector outline. Text is laid out on whole
/// pixels (crisp type), so a floating `Text` moved in 0.5 pt steps — ~5
/// jumps a second on a 6 pt float. The outline comes from the very font
/// the system falls back to for the glyph (Zapf Dingbats for ❀ ✿ ✦), and
/// an invisible copy of the text keeps the original box and baseline.
private struct GlyphOutline: View {
    let glyph: String
    let size: CGFloat
    let color: Color

    var body: some View {
        Text(glyph)
            .font(.system(size: size))
            .hidden()
            .overlay(alignment: Alignment(horizontal: .leading, vertical: .firstTextBaseline)) {
                BaselinePath(path: Self.outline(glyph, size: size))
                    .fill(color)
                    .frame(width: 1, height: 1) // zero-size views are not drawn
                    .alignmentGuide(.firstTextBaseline) { _ in 0 }
            }
    }

    /// The glyph run's outlines with the baseline at y = 0, y pointing down.
    private static func outline(_ glyph: String, size: CGFloat) -> Path {
        let key = "\(glyph)|\(size)"
        if let cached = cache[key] { return cached }
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: glyph, attributes: [.font: NSFont.systemFont(ofSize: size)]))
        let path = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let font = attributes[kCTFontAttributeName] else { continue }
            let ctFont = font as! CTFont
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for i in 0..<count {
                var flip = CGAffineTransform(translationX: positions[i].x, y: -positions[i].y)
                    .scaledBy(x: 1, y: -1)
                if let outline = CTFontCreatePathForGlyph(ctFont, glyphs[i], &flip) {
                    path.addPath(outline)
                }
            }
        }
        let result = Path(path)
        cache[key] = result
        return result
    }

    private static var cache: [String: Path] = [:]
}

/// A path whose origin is the frame's origin; drawn unclipped around it.
private struct BaselinePath: Shape {
    let path: Path
    func path(in rect: CGRect) -> Path {
        path.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// A glyph floating up 6 pt and back on a `duration/2` ease-in-out loop
/// (the design's `floaty`), its `anchor` corner resting on `at`.
private func floatingGlyph(_ glyph: String, size: CGFloat, color: Color, duration: Double,
                           at: OrnamentPlacement, anchor: UnitPoint) -> Ornament {
    .symbol(at: at, anchor: anchor, pose: { t in
        MotionPose(offset: CGSize(width: 0, height: -6 * MotionCurve.pingPong(t, half: duration / 2)))
    }) {
        GlyphOutline(glyph: glyph, size: size, color: color)
    }
}

/// Sakura's floating cherry-blossom petals (❀ / ✿) at the spec's positions.
struct SakuraDecorations: View {
    @Environment(\.colorScheme) private var colorScheme
    private var dark: Bool { colorScheme == .dark }

    var body: some View {
        OrnamentLayer(scene: Self.scene(dark: dark), spriteKey: "sakura.\(dark)")
    }

    static func scene(dark: Bool) -> OrnamentScene {
        /// Petal tint at a given opacity — pink in dark, deeper rose in light.
        func petal(_ opacity: Double) -> Color {
            dark ? drgba(255, 150, 195, opacity) : drgba(230, 100, 150, opacity)
        }
        return OrnamentScene(fps: 60, ornaments: [
            floatingGlyph("❀", size: 14, color: petal(dark ? 0.35 : 0.40), duration: 5,
                          at: .topTrailing(22, 34), anchor: .topTrailing),
            floatingGlyph("❀", size: 10, color: petal(dark ? 0.22 : 0.28), duration: 7,
                          at: .topLeading(30, 90), anchor: .topLeading),
            floatingGlyph("✿", size: 12, color: petal(dark ? 0.18 : 0.22), duration: 6,
                          at: .topTrailing(60, 150), anchor: .topTrailing),
        ])
    }
}

/// Pastel's floating sparkles (✦) — lavender + peach, at the spec's positions.
struct PastelDecorations: View {
    @Environment(\.colorScheme) private var colorScheme
    private var dark: Bool { colorScheme == .dark }

    var body: some View {
        OrnamentLayer(scene: Self.scene(dark: dark), spriteKey: "pastel.\(dark)")
    }

    static func scene(dark: Bool) -> OrnamentScene {
        OrnamentScene(fps: 60, ornaments: [
            floatingGlyph("✦", size: 12,
                          color: dark ? drgba(200, 175, 255, 0.40) : drgba(150, 110, 210, 0.45),
                          duration: 5, at: .topTrailing(26, 40), anchor: .topTrailing),
            floatingGlyph("✦", size: 9,
                          color: dark ? drgba(255, 171, 145, 0.35) : drgba(255, 140, 110, 0.40),
                          duration: 7, at: .topLeading(34, 110), anchor: .topLeading),
        ])
    }
}
