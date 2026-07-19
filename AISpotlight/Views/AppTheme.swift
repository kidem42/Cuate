import SwiftUI
import Combine

/// A visual theme for the chat panel. `current` is the existing Liquid Glass
/// look and is the default — it renders through the system materials exactly as
/// before; every other case swaps in a `ThemePalette` of solid colors, fonts
/// and signature effects (see `ThemePalette.palette(for:scheme:)`).
///
/// Themes are a presentation layer over the panel only — the Settings window
/// keeps the standard system look.
enum AppTheme: String, CaseIterable, Identifiable, Codable {
    case current
    case blueprint
    case terminal
    case synthwave
    case sakura
    case pastel
    case halloween
    case diaDeMuertos

    var id: String { rawValue }

    /// Whether this theme keeps the existing Liquid Glass / material rendering.
    /// Views branch on this to leave the `current` look untouched.
    var isGlass: Bool { self == .current }

    var displayName: String {
        switch self {
        case .current: return "Liquid Glass"
        case .blueprint: return "Blueprint"
        case .terminal: return "Terminal"
        case .synthwave: return "Synthwave"
        case .sakura: return "Sakura"
        case .pastel: return "Pastel"
        case .halloween: return "Halloween"
        case .diaDeMuertos: return "Día de Muertos"
        }
    }
}

// MARK: - Color helpers

extension Color {
    /// 0xRRGGBB → opaque Color.
    init(rgb: UInt) {
        self.init(.sRGB,
                  red: Double((rgb >> 16) & 0xff) / 255,
                  green: Double((rgb >> 8) & 0xff) / 255,
                  blue: Double(rgb & 0xff) / 255,
                  opacity: 1)
    }
}

/// rgba() with 0–255 channels, matching the design spec verbatim.
private func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Color {
    Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
}

private func hex(_ v: UInt) -> Color { Color(rgb: v) }

/// tl,tr,br,bl → RectangleCornerRadii (SwiftUI uses leading/trailing naming).
private func rr(_ tl: CGFloat, _ tr: CGFloat, _ br: CGFloat, _ bl: CGFloat) -> RectangleCornerRadii {
    RectangleCornerRadii(topLeading: tl, bottomLeading: bl, bottomTrailing: br, topTrailing: tr)
}
private func rr(_ all: CGFloat) -> RectangleCornerRadii { rr(all, all, all, all) }

// MARK: - Supporting types

/// Per-theme timestamp presentation (a signature detail in the spec).
enum ThemeTimestamp {
    case glass              // system default (HH:mm short)
    case bracketed          // [22:08]
    case seconds            // 22:08:14
    case uppercaseMeridiem  // 22:08 PM  (letter-spaced, in caller)
    case flowerSuffix       // 10:08 ✿
    case lowercaseMeridiem  // 10:08 p.m.
    case plain              // 10:08
}

struct BubbleStroke {
    enum Edge { case all, bottom }
    var color: Color
    var width: CGFloat = 1
    var dash: [CGFloat] = []   // empty = solid
    /// `.all` = full border (Blueprint dashed, Terminal solid); `.bottom` = a
    /// dotted underline hugging the bubble's bottom edge (Día de Muertos).
    var edge: Edge = .all
}

/// The bubble's bottom border only — the straight bottom edge plus the two
/// rounded bottom corners (CSS `border-bottom` on a rounded rect). `inset` is
/// the corner radius. Dots are laid out by hand so they can TAPER along the
/// corner curls — in CSS the border width interpolates to zero across the
/// rounded corner, so the dots shrink toward the tips (spec's Día bubbles).
struct TaperedDottedBottomEdge: View {
    var inset: CGFloat
    var color: Color
    /// Dot diameter on the straight run (the CSS border width).
    var width: CGFloat = 2
    /// Half the stroke width, so the 2px dots sit fully inside the bubble.
    var lift: CGFloat = 1

    private func quad(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x,
                       y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }

    var body: some View {
        Canvas { ctx, size in
            // Cap the corner curl so a narrow bubble's underline stays mostly a
            // flat run of dots instead of curling into a "U".
            let r = max(0, min(inset, size.height / 2, size.width * 0.32))
            let y = size.height - lift
            let minScale: CGFloat = 0.3   // dot size at the very tips

            // Sample the edge as a polyline with a per-point taper factor:
            // left curl (taper up) → straight run (full) → right curl (down).
            var samples: [(CGPoint, CGFloat)] = []
            let n = 10
            let lp0 = CGPoint(x: lift, y: y - r), lc = CGPoint(x: lift, y: y), lp1 = CGPoint(x: r, y: y)
            for i in 0...n {
                let t = CGFloat(i) / CGFloat(n)
                samples.append((quad(lp0, lc, lp1, t), minScale + (1 - minScale) * t))
            }
            samples.append((CGPoint(x: size.width - r, y: y), 1))
            let rp0 = CGPoint(x: size.width - r, y: y)
            let rc = CGPoint(x: size.width - lift, y: y)
            let rp1 = CGPoint(x: size.width - lift, y: y - r)
            for i in 1...n {
                let t = CGFloat(i) / CGFloat(n)
                samples.append((quad(rp0, rc, rp1, t), 1 - (1 - minScale) * t))
            }

            // Cumulative arc length, then walk it dropping a dot every period.
            var cum: [CGFloat] = [0]
            for i in 1..<samples.count {
                cum.append(cum[i - 1] + hypot(samples[i].0.x - samples[i - 1].0.x,
                                              samples[i].0.y - samples[i - 1].0.y))
            }
            guard let total = cum.last, total > 0 else { return }

            let spacing = width * 2   // ≈ CSS `dotted` period (2px dot / 2px gap)
            var d = spacing / 2
            var seg = 1
            while d < total {
                while seg < samples.count - 1 && cum[seg] < d { seg += 1 }
                let t = (d - cum[seg - 1]) / max(cum[seg] - cum[seg - 1], 0.001)
                let p = CGPoint(x: samples[seg - 1].0.x + (samples[seg].0.x - samples[seg - 1].0.x) * t,
                                y: samples[seg - 1].0.y + (samples[seg].0.y - samples[seg - 1].0.y) * t)
                let dia = width * (samples[seg - 1].1 + (samples[seg].1 - samples[seg - 1].1) * t)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - dia / 2, y: p.y - dia / 2, width: dia, height: dia)),
                         with: .color(color))
                d += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

/// Signature background decoration, rendered by `ThemedBackground` (iteration 2
/// fills these in; iteration 1 renders the gradient only).
enum ThemePattern: Equatable {
    case none
    case blueprintGrid(Color, CGFloat)   // line color, spacing
    case scanlines(Color)                // 3px horizontal
    case synthwaveHorizon(Color)         // perspective grid at the bottom
}

/// Resolved design tokens for a theme + color scheme. All values are verbatim
/// from the design spec (Theme Explorations).
struct ThemePalette {
    var isGlass: Bool = false
    /// Which theme produced this palette — lets views pick theme-specific
    /// custom components (sugar-skull icon, marigold send button, decorations).
    var themeID: AppTheme = .current

    var backgroundStyle: AnyShapeStyle = AnyShapeStyle(Color.clear)
    /// Semi-transparent "glass panel" tint laid over the material, so the theme
    /// COLORS the liquid glass instead of replacing it (the desktop still blurs
    /// through). Value is the spec's glass-panel rgba.
    var panelTint: Color = .clear
    var pattern: ThemePattern = .none

    var userFill: AnyShapeStyle = AnyShapeStyle(Color.clear)
    var userText: Color = .primary
    var userStroke: BubbleStroke? = nil
    var userCorners: RectangleCornerRadii = rr(16)

    var assistantFill: AnyShapeStyle = AnyShapeStyle(Color.clear)
    var assistantText: Color = .primary
    var assistantStroke: BubbleStroke? = nil
    var assistantCorners: RectangleCornerRadii = rr(16)

    /// Assistant bubble icon — a literal glyph (⊿ ❯ ▲ ❀ 🎃 💀), replacing the
    /// default `brain` SF Symbol.
    var assistantGlyph: String = "❯"
    var glyphColor: Color = .accentColor

    var accent: Color = .accentColor
    var primaryText: Color = .primary
    var secondaryText: Color = .secondary

    var inputFill: AnyShapeStyle = AnyShapeStyle(.ultraThinMaterial)
    var inputStroke: Color = Color.secondary.opacity(0.2)
    var inputRadius: CGFloat = 6
    var placeholderColor: Color = Color.secondary.opacity(0.5)
    var placeholderText: String? = nil

    var timestampColor: Color = .secondary
    var timestamp: ThemeTimestamp = .glass

    var fontDesign: Font.Design = .default

    var codeFill: AnyShapeStyle = AnyShapeStyle(Color.secondary.opacity(0.12))
    var codeText: Color = .primary
    /// Dictation equalizer bar colors, cycled per bar. Empty → [accent].
    var dictationColors: [Color] = []
    /// Bullet-list marker glyph (Día uses ✿).
    var bulletGlyph: String = "•"
    /// Blockquote accent bar (defaults to accent).
    var quoteColor: Color? = nil

    var sendFill: AnyShapeStyle = AnyShapeStyle(Color.accentColor)
    var sendGlyphColor: Color = .white
    var sendGlow: Color? = nil
    /// Mic-button glyph tint (Día uses light teal). nil → accent.
    var micColor: Color? = nil
    /// Mic-button border/fill base tint (Día uses base teal, darker than glyph).
    var micStroke: Color? = nil
    /// Mic-button interior fill for the solid (non-dashed) composer style. nil → derived.
    var micFill: AnyShapeStyle? = nil
    /// Mic-button glyph tint override (nil → micColor ?? accent).
    var micGlyphColor: Color? = nil
    /// Themed mic look: `true` = dashed circle (Día), `false` = solid rounded
    /// square (Blueprint's engineering composer buttons).
    var micDashed: Bool = true

    /// Composer send/mic button shape: nil → circle; a value → rounded square
    /// of that corner radius (Blueprint uses 6).
    var composerButtonRadius: CGFloat? = nil
    /// Monospaced timestamps (Blueprint's mono-таймстампы).
    var timestampMono: Bool = false
    /// Reference-cross marks in the four panel corners (Blueprint's
    /// крестики-реперы). nil → none.
    var cornerMarkColor: Color? = nil
    /// Composer top divider. nil → system `Divider`; set → a themed line
    /// (dashed for Blueprint) in this color/width/dash.
    var divider: BubbleStroke? = nil
    /// Panel border override. nil → accent @0.3 hairline; set → 1px in this color.
    var panelBorder: Color? = nil
    /// Blinking block caret after the composer placeholder (Terminal's signature
    /// «мигающий курсор»). nil/false → none.
    var placeholderCaret: Bool = false
    /// Neon glow cast around the whole panel (Synthwave). nil → none.
    var panelGlow: Color? = nil
    /// Neon glow around the user bubble (Synthwave dark). nil → none.
    var userGlow: Color? = nil
    /// Themed liquid glass: blur the desktop and lay a translucent tint over it
    /// (the design keeps the glass — themes only color it). Día uses this;
    /// other themes currently render a solid fill.
    var glassSurface: Bool = false
    /// Deep "ink" accent for links, bullets, icons and text actions where the
    /// bright marigold accent is too low-contrast (Día light: #C77800). nil →
    /// accent.
    var accentInk: Color? = nil
    /// Inline-code chip background (nil → secondary @0.08, the Current look).
    var inlineCodeFill: Color? = nil
    /// Inline-code chip text, when it differs from the code-block text (the
    /// spec gives Halloween/Día distinct inline vs block colors). nil → codeText.
    var inlineCodeText: Color? = nil
    /// Bullet-marker tint override (Halloween's plain "•" is text-colored in
    /// the spec, not accent-colored). nil → ink.
    var bulletColor: Color? = nil
    /// Recording-indicator dot color (solid, per spec). nil → quoteColor → accent.
    var recordingAccent: Color? = nil
    /// Voice-message waveform played-portion tint (Día dark: marigold #FFD54F,
    /// per spec §3b). nil → the default light/dark contrast colors.
    var voiceProgress: Color? = nil

    /// Resolved ink accent: `accentInk` when set, else the plain accent.
    var ink: Color { accentInk ?? accent }

    // MARK: Factory

    static func palette(for theme: AppTheme, scheme: ColorScheme) -> ThemePalette {
        var resolved = resolve(theme, scheme)
        resolved.themeID = theme
        return resolved
    }

    private static func resolve(_ theme: AppTheme, _ scheme: ColorScheme) -> ThemePalette {
        let dark = scheme == .dark
        switch theme {
        case .current:
            return ThemePalette(isGlass: true)
        case .blueprint:
            return tinted(dark ? blueprintDark : blueprintLight, dark ? rgba(14, 26, 38, 0.40) : rgba(240, 248, 255, 0.5))
        case .terminal:
            return tinted(dark ? terminalDark : terminalLight, dark ? rgba(6, 20, 12, 0.45) : rgba(244, 252, 246, 0.5))
        case .synthwave:
            return tinted(dark ? synthwaveDark : synthwaveLight, dark ? rgba(24, 10, 44, 0.42) : rgba(255, 248, 253, 0.5))
        case .sakura:
            return tinted(dark ? sakuraDark : sakuraLight, dark ? rgba(40, 20, 34, 0.42) : rgba(255, 250, 252, 0.5))
        case .pastel:
            return tinted(dark ? pastelDark : pastelLight, dark ? rgba(35, 28, 50, 0.42) : rgba(255, 252, 255, 0.5))
        case .halloween:
            return tinted(dark ? halloweenDark : halloweenLight, dark ? rgba(30, 16, 48, 0.45) : rgba(255, 249, 242, 0.5))
        case .diaDeMuertos:
            return tinted(dark ? diaDark : diaLight, dark ? rgba(38, 16, 44, 0.45) : rgba(255, 250, 240, 0.5))
        }
    }

    /// Attaches the semi-transparent glass-panel tint to a base palette.
    private static func tinted(_ base: ThemePalette, _ tint: Color) -> ThemePalette {
        var p = base
        p.panelTint = tint
        return p
    }

    private static func radial(_ colors: [Color]) -> AnyShapeStyle {
        AnyShapeStyle(RadialGradient(colors: colors, center: UnitPoint(x: 0.25, y: 0.10), startRadius: 0, endRadius: 480))
    }
    private static func linearV(_ colors: [Color]) -> AnyShapeStyle {
        AnyShapeStyle(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
    }
    private static func linear120(_ colors: [Color]) -> AnyShapeStyle {
        AnyShapeStyle(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    // MARK: Blueprint
    static let blueprintDark = ThemePalette(
        backgroundStyle: radial([hex(0x1d3346), hex(0x122334), hex(0x0a141f)]),
        pattern: .blueprintGrid(rgba(110, 190, 255, 0.06), 24),
        userFill: AnyShapeStyle(rgba(38, 110, 165, 0.5)), userText: hex(0xeaf6ff),
        userStroke: BubbleStroke(color: rgba(140, 210, 255, 0.45), dash: [4, 3]), userCorners: rr(10),
        assistantFill: AnyShapeStyle(rgba(20, 42, 62, 0.6)), assistantText: hex(0xeaf6ff),
        assistantStroke: BubbleStroke(color: rgba(140, 210, 255, 0.3), dash: [4, 3]), assistantCorners: rr(10),
        assistantGlyph: "⊿", glyphColor: hex(0x4FC3F7),
        accent: hex(0x4FC3F7), primaryText: hex(0xeaf6ff), secondaryText: rgba(150, 215, 255, 0.6),
        inputFill: AnyShapeStyle(rgba(120, 200, 255, 0.06)), inputStroke: rgba(140, 210, 255, 0.3), inputRadius: 4,
        placeholderColor: rgba(150, 215, 255, 0.4), placeholderText: "— annotate drawing…",
        timestampColor: rgba(150, 215, 255, 0.6), timestamp: .bracketed,
        codeFill: AnyShapeStyle(rgba(120, 200, 255, 0.14)), codeText: hex(0x9fd7ff),
        bulletGlyph: "—", quoteColor: rgba(79, 195, 247, 0.6),
        sendFill: AnyShapeStyle(hex(0x4FC3F7)), sendGlyphColor: hex(0x06233a),
        micFill: AnyShapeStyle(rgba(120, 200, 255, 0.12)), micGlyphColor: hex(0xbfe4ff), micDashed: false,
        composerButtonRadius: 6, timestampMono: true,
        cornerMarkColor: rgba(120, 200, 255, 0.5),
        divider: BubbleStroke(color: rgba(140, 210, 255, 0.25), width: 1, dash: [4, 3]),
        panelBorder: rgba(120, 200, 255, 0.28)
    )
    static let blueprintLight = ThemePalette(
        backgroundStyle: radial([hex(0xdbeaf5), hex(0xbcd7ea), hex(0x8fb8d6)]),
        pattern: .blueprintGrid(rgba(30, 110, 170, 0.07), 24),
        userFill: AnyShapeStyle(rgba(120, 195, 245, 0.5)), userText: hex(0x0c2233),
        userStroke: BubbleStroke(color: rgba(15, 90, 150, 0.4), dash: [4, 3]), userCorners: rr(10),
        assistantFill: AnyShapeStyle(rgba(255, 255, 255, 0.65)), assistantText: hex(0x0c2233),
        assistantStroke: BubbleStroke(color: rgba(15, 90, 150, 0.3), dash: [4, 3]), assistantCorners: rr(10),
        assistantGlyph: "⊿", glyphColor: hex(0x0288D1),
        accent: hex(0x0288D1), primaryText: hex(0x0c2233), secondaryText: rgba(15, 90, 150, 0.7),
        inputFill: AnyShapeStyle(rgba(255, 255, 255, 0.55)), inputStroke: rgba(15, 90, 150, 0.35), inputRadius: 4,
        placeholderColor: rgba(15, 90, 150, 0.45), placeholderText: "— annotate drawing…",
        timestampColor: rgba(15, 90, 150, 0.6), timestamp: .bracketed,
        codeFill: AnyShapeStyle(rgba(30, 110, 170, 0.12)), codeText: hex(0x085a8c),
        bulletGlyph: "—", quoteColor: rgba(2, 136, 209, 0.6),
        sendFill: AnyShapeStyle(hex(0x0288D1)), sendGlyphColor: .white,
        micFill: AnyShapeStyle(rgba(255, 255, 255, 0.55)), micGlyphColor: hex(0x0b5c94), micDashed: false,
        composerButtonRadius: 6, timestampMono: true,
        cornerMarkColor: rgba(20, 100, 160, 0.5),
        divider: BubbleStroke(color: rgba(15, 90, 150, 0.3), width: 1, dash: [4, 3]),
        panelBorder: rgba(255, 255, 255, 0.7)
    )

    // MARK: Terminal
    static let terminalDark = ThemePalette(
        backgroundStyle: radial([hex(0x12241a), hex(0x0b1712), hex(0x050c08)]),
        pattern: .scanlines(rgba(51, 255, 102, 0.035)),
        userFill: AnyShapeStyle(rgba(30, 120, 60, 0.45)), userText: hex(0xd8ffe4),
        userStroke: BubbleStroke(color: rgba(51, 255, 102, 0.3)), userCorners: rr(8),
        assistantFill: AnyShapeStyle(rgba(8, 30, 16, 0.65)), assistantText: hex(0xd8ffe4),
        assistantStroke: BubbleStroke(color: rgba(51, 255, 102, 0.2)), assistantCorners: rr(8),
        assistantGlyph: "❯", glyphColor: hex(0x33FF66),
        accent: hex(0x33FF66), primaryText: hex(0xd8ffe4), secondaryText: rgba(120, 255, 160, 0.6),
        inputFill: AnyShapeStyle(rgba(51, 255, 102, 0.05)), inputStroke: rgba(51, 255, 102, 0.3), inputRadius: 4,
        placeholderColor: rgba(120, 255, 160, 0.5), placeholderText: "$ type your message",
        timestampColor: rgba(120, 255, 160, 0.5), timestamp: .seconds, fontDesign: .monospaced,
        codeFill: AnyShapeStyle(rgba(51, 255, 102, 0.08)), codeText: hex(0x7dffa5),
        bulletGlyph: "❯",
        sendFill: AnyShapeStyle(hex(0x33FF66)), sendGlyphColor: hex(0x042010), sendGlow: rgba(51, 255, 102, 0.5),
        micFill: AnyShapeStyle(rgba(51, 255, 102, 0.1)), micGlyphColor: hex(0x7dffa5), micDashed: false,
        composerButtonRadius: 4,
        divider: BubbleStroke(color: rgba(51, 255, 102, 0.18), width: 1, dash: []),
        panelBorder: rgba(51, 255, 102, 0.25), placeholderCaret: true
    )
    static let terminalLight = ThemePalette(
        backgroundStyle: radial([hex(0xe4efe6), hex(0xcfe2d3), hex(0xa8c9b0)]),
        pattern: .scanlines(rgba(10, 120, 50, 0.04)),
        userFill: AnyShapeStyle(rgba(90, 210, 130, 0.4)), userText: hex(0x08240f),
        userStroke: BubbleStroke(color: rgba(10, 120, 50, 0.3)), userCorners: rr(8),
        assistantFill: AnyShapeStyle(rgba(255, 255, 255, 0.65)), assistantText: hex(0x08240f),
        assistantStroke: BubbleStroke(color: rgba(10, 120, 50, 0.22)), assistantCorners: rr(8),
        assistantGlyph: "❯", glyphColor: hex(0x0B8A3A),
        accent: hex(0x0B8A3A), primaryText: hex(0x08240f), secondaryText: rgba(10, 90, 40, 0.7),
        inputFill: AnyShapeStyle(rgba(255, 255, 255, 0.55)), inputStroke: rgba(10, 120, 50, 0.35), inputRadius: 4,
        placeholderColor: rgba(10, 90, 40, 0.5), placeholderText: "$ type your message",
        timestampColor: rgba(10, 90, 40, 0.55), timestamp: .seconds, fontDesign: .monospaced,
        codeFill: AnyShapeStyle(rgba(10, 120, 50, 0.1)), codeText: hex(0x0B8A3A),
        bulletGlyph: "❯",
        sendFill: AnyShapeStyle(hex(0x0B8A3A)), sendGlyphColor: .white,
        micFill: AnyShapeStyle(rgba(255, 255, 255, 0.55)), micGlyphColor: hex(0x0B8A3A), micDashed: false,
        composerButtonRadius: 4,
        divider: BubbleStroke(color: rgba(10, 120, 50, 0.25), width: 1, dash: []),
        panelBorder: rgba(255, 255, 255, 0.7), placeholderCaret: true
    )

    // MARK: Synthwave
    static let synthwaveDark = ThemePalette(
        backgroundStyle: linearV([hex(0x1b1035), hex(0x2a1048), hex(0x3d0f4e)]),
        pattern: .none,   // horizon grid lives behind the panel in the design, not across the chat — omit
        userFill: linear120([rgba(255, 46, 151, 0.5), rgba(140, 60, 255, 0.5)]), userText: hex(0xffeaf6),
        userStroke: nil, userCorners: rr(16),
        assistantFill: AnyShapeStyle(rgba(30, 12, 55, 0.65)), assistantText: hex(0xffeaf6),
        assistantStroke: BubbleStroke(color: rgba(0, 229, 255, 0.25)), assistantCorners: rr(16),
        assistantGlyph: "▲", glyphColor: hex(0xFF2E97),
        accent: hex(0xFF2E97), primaryText: hex(0xffeaf6), secondaryText: rgba(255, 180, 220, 0.75),
        inputFill: AnyShapeStyle(rgba(255, 46, 151, 0.07)), inputStroke: rgba(0, 229, 255, 0.3), inputRadius: 8,
        placeholderColor: rgba(255, 180, 220, 0.45), placeholderText: nil,
        timestampColor: rgba(0, 229, 255, 0.6), timestamp: .uppercaseMeridiem,
        codeFill: AnyShapeStyle(rgba(255, 46, 151, 0.12)), codeText: hex(0xff9ecf),
        dictationColors: [hex(0xFF2E97), hex(0x00E5FF)],
        sendFill: AnyShapeStyle(LinearGradient(colors: [hex(0xFF2E97), hex(0x7C4DFF), hex(0x00E5FF)], startPoint: .topLeading, endPoint: .bottomTrailing)),
        sendGlyphColor: .white, sendGlow: rgba(255, 46, 151, 0.55),
        micFill: AnyShapeStyle(rgba(0, 229, 255, 0.12)), micGlyphColor: hex(0x8de9ff), micDashed: false,
        divider: BubbleStroke(color: rgba(255, 46, 151, 0.25), width: 1, dash: []),
        panelBorder: rgba(255, 46, 151, 0.35),
        panelGlow: rgba(255, 46, 151, 0.18), userGlow: rgba(255, 46, 151, 0.3)
    )
    static let synthwaveLight = ThemePalette(
        backgroundStyle: linearV([hex(0xffe3ef), hex(0xe8d6ff), hex(0xcfeffb)]),
        pattern: .none,   // horizon grid lives behind the panel in the design, not across the chat — omit
        userFill: linear120([rgba(255, 120, 190, 0.5), rgba(170, 120, 255, 0.5)]), userText: hex(0x3a0a26),
        userStroke: nil, userCorners: rr(16),
        assistantFill: AnyShapeStyle(rgba(255, 255, 255, 0.68)), assistantText: hex(0x3a0a26),
        assistantStroke: BubbleStroke(color: rgba(0, 172, 193, 0.3)), assistantCorners: rr(16),
        assistantGlyph: "▲", glyphColor: hex(0xE91E8C),
        accent: hex(0xE91E8C), primaryText: hex(0x3a0a26), secondaryText: rgba(190, 30, 110, 0.7),
        inputFill: AnyShapeStyle(rgba(255, 255, 255, 0.55)), inputStroke: rgba(0, 172, 193, 0.35), inputRadius: 8,
        placeholderColor: rgba(190, 30, 110, 0.4), placeholderText: nil,
        timestampColor: rgba(0, 150, 170, 0.7), timestamp: .uppercaseMeridiem,
        codeFill: AnyShapeStyle(rgba(233, 30, 140, 0.1)), codeText: hex(0xad1465),
        dictationColors: [hex(0xE91E8C), hex(0x00ACC1)],
        sendFill: AnyShapeStyle(LinearGradient(colors: [hex(0xE91E8C), hex(0x7C4DFF), hex(0x00ACC1)], startPoint: .topLeading, endPoint: .bottomTrailing)),
        sendGlyphColor: .white, sendGlow: rgba(233, 30, 140, 0.35),
        micFill: AnyShapeStyle(rgba(0, 172, 193, 0.12)), micGlyphColor: hex(0x00838F), micDashed: false,
        divider: BubbleStroke(color: rgba(233, 30, 140, 0.25), width: 1, dash: []),
        panelBorder: rgba(255, 255, 255, 0.75),
        panelGlow: rgba(255, 46, 151, 0.12)
    )

    // MARK: Sakura
    static let sakuraDark = ThemePalette(
        backgroundStyle: radial([hex(0x3a2233), hex(0x2a1626), hex(0x170b13)]),
        userFill: AnyShapeStyle(rgba(230, 90, 140, 0.45)), userText: hex(0xffeef5),
        userStroke: nil, userCorners: rr(20, 20, 6, 20),
        assistantFill: AnyShapeStyle(rgba(60, 28, 48, 0.6)), assistantText: hex(0xffeef5),
        assistantStroke: nil, assistantCorners: rr(20, 20, 20, 6),
        assistantGlyph: "❀", glyphColor: hex(0xF48FB1),
        accent: hex(0xF06292), primaryText: hex(0xffeef5), secondaryText: rgba(255, 190, 215, 0.75),
        inputFill: AnyShapeStyle(rgba(255, 170, 205, 0.08)), inputStroke: rgba(255, 170, 205, 0.3), inputRadius: 15,
        placeholderColor: rgba(255, 190, 215, 0.45), placeholderText: "Напиши что-нибудь милое…",
        timestampColor: rgba(255, 190, 215, 0.55), timestamp: .flowerSuffix,
        codeFill: AnyShapeStyle(rgba(255, 170, 205, 0.12)), codeText: hex(0xffb7cf),
        dictationColors: [hex(0xF48FB1)], bulletGlyph: "❀",
        sendFill: AnyShapeStyle(hex(0xF06292)), sendGlyphColor: .white, sendGlow: rgba(240, 98, 146, 0.45),
        micFill: AnyShapeStyle(rgba(255, 170, 205, 0.12)), micGlyphColor: hex(0xffc3d8), micDashed: false,
        divider: BubbleStroke(color: rgba(255, 170, 205, 0.2), width: 1, dash: []),
        panelBorder: rgba(255, 170, 205, 0.28)
    )
    static let sakuraLight = ThemePalette(
        backgroundStyle: radial([hex(0xffe9f1), hex(0xfdd9e6), hex(0xf2b9cf)]),
        userFill: AnyShapeStyle(rgba(245, 140, 175, 0.5)), userText: hex(0x42101f),
        userStroke: nil, userCorners: rr(20, 20, 6, 20),
        assistantFill: AnyShapeStyle(rgba(255, 255, 255, 0.68)), assistantText: hex(0x42101f),
        assistantStroke: nil, assistantCorners: rr(20, 20, 20, 6),
        assistantGlyph: "❀", glyphColor: hex(0xEC5F8F),
        accent: hex(0xEC5F8F), primaryText: hex(0x42101f), secondaryText: rgba(190, 70, 115, 0.75),
        inputFill: AnyShapeStyle(rgba(255, 255, 255, 0.6)), inputStroke: rgba(230, 100, 150, 0.3), inputRadius: 15,
        placeholderColor: rgba(190, 70, 115, 0.45), placeholderText: "Напиши что-нибудь милое…",
        timestampColor: rgba(190, 70, 115, 0.6), timestamp: .flowerSuffix,
        codeFill: AnyShapeStyle(rgba(230, 100, 150, 0.1)), codeText: hex(0xa33361),
        dictationColors: [hex(0xEC5F8F)], bulletGlyph: "❀",
        sendFill: AnyShapeStyle(hex(0xEC5F8F)), sendGlyphColor: .white, sendGlow: rgba(236, 95, 143, 0.4),
        micFill: AnyShapeStyle(rgba(255, 255, 255, 0.6)), micGlyphColor: hex(0xD8447A), micDashed: false,
        divider: BubbleStroke(color: rgba(230, 100, 150, 0.25), width: 1, dash: []),
        panelBorder: rgba(255, 255, 255, 0.75)
    )

    // MARK: Pastel
    static let pastelDark = ThemePalette(
        backgroundStyle: radial([hex(0x2e2840), hex(0x231d33), hex(0x141020)]),
        userFill: linear120([rgba(179, 157, 219, 0.5), rgba(255, 171, 145, 0.45)]), userText: hex(0xf7f0ff),
        userStroke: nil, userCorners: rr(22),
        assistantFill: AnyShapeStyle(rgba(50, 40, 70, 0.6)), assistantText: hex(0xf7f0ff),
        assistantStroke: nil, assistantCorners: rr(22),
        assistantGlyph: "♡", glyphColor: hex(0xCDB6F5),
        accent: hex(0xB39DDB), primaryText: hex(0xf7f0ff), secondaryText: rgba(215, 195, 255, 0.6),
        inputFill: AnyShapeStyle(rgba(200, 175, 255, 0.08)), inputStroke: rgba(200, 175, 255, 0.3), inputRadius: 18,
        placeholderColor: rgba(215, 195, 255, 0.5), placeholderText: nil,
        timestampColor: rgba(215, 195, 255, 0.55), timestamp: .plain, fontDesign: .rounded,
        codeFill: AnyShapeStyle(rgba(200, 175, 255, 0.14)), codeText: hex(0xd5c3ff),
        dictationColors: [hex(0xB39DDB), hex(0xF48FB1), hex(0xFFAB91)], bulletGlyph: "✦",
        sendFill: AnyShapeStyle(LinearGradient(colors: [hex(0xB39DDB), hex(0xF48FB1)], startPoint: .topLeading, endPoint: .bottomTrailing)),
        sendGlyphColor: .white, sendGlow: rgba(179, 157, 219, 0.45),
        micFill: AnyShapeStyle(rgba(200, 175, 255, 0.14)), micGlyphColor: hex(0xe2d4ff), micDashed: false,
        divider: BubbleStroke(color: rgba(200, 175, 255, 0.2), width: 1, dash: []),
        panelBorder: rgba(200, 175, 255, 0.28)
    )
    static let pastelLight = ThemePalette(
        backgroundStyle: radial([hex(0xf3ecff), hex(0xecdcf5), hex(0xdcc4ea)]),
        userFill: linear120([rgba(179, 157, 219, 0.55), rgba(255, 171, 145, 0.5)]), userText: hex(0x2d1846),
        userStroke: nil, userCorners: rr(22),
        assistantFill: AnyShapeStyle(rgba(255, 255, 255, 0.7)), assistantText: hex(0x2d1846),
        assistantStroke: nil, assistantCorners: rr(22),
        assistantGlyph: "♡", glyphColor: hex(0x9575CD),
        accent: hex(0x9575CD), primaryText: hex(0x2d1846), secondaryText: rgba(120, 85, 180, 0.65),
        inputFill: AnyShapeStyle(rgba(255, 255, 255, 0.6)), inputStroke: rgba(150, 110, 210, 0.3), inputRadius: 18,
        placeholderColor: rgba(120, 85, 180, 0.5), placeholderText: nil,
        timestampColor: rgba(120, 85, 180, 0.6), timestamp: .plain, fontDesign: .rounded,
        codeFill: AnyShapeStyle(rgba(150, 110, 210, 0.1)), codeText: hex(0x6a44a8),
        dictationColors: [hex(0x9575CD), hex(0xF06292), hex(0xFF8A65)], bulletGlyph: "✦",
        sendFill: AnyShapeStyle(LinearGradient(colors: [hex(0x9575CD), hex(0xF06292)], startPoint: .topLeading, endPoint: .bottomTrailing)),
        sendGlyphColor: .white, sendGlow: rgba(149, 117, 205, 0.4),
        micFill: AnyShapeStyle(rgba(255, 255, 255, 0.6)), micGlyphColor: hex(0x7E57C2), micDashed: false,
        divider: BubbleStroke(color: rgba(150, 110, 210, 0.22), width: 1, dash: []),
        panelBorder: rgba(255, 255, 255, 0.8)
    )

    // MARK: Halloween
    static let halloweenDark = ThemePalette(
        backgroundStyle: radial([hex(0x2b1d3e), hex(0x1c1130), hex(0x0d0618)]),
        userFill: AnyShapeStyle(rgba(230, 110, 20, 0.45)), userText: hex(0xfff2e4),
        userStroke: nil, userCorners: rr(16),
        assistantFill: AnyShapeStyle(rgba(45, 24, 66, 0.65)), assistantText: hex(0xfff2e4),
        assistantStroke: BubbleStroke(color: rgba(255, 140, 60, 0.2)), assistantCorners: rr(16),
        assistantGlyph: "🎃", glyphColor: hex(0xFF9E4F),
        accent: hex(0xFF7A1A), primaryText: hex(0xfff2e4), secondaryText: rgba(255, 190, 130, 0.8),
        inputFill: AnyShapeStyle(rgba(255, 140, 60, 0.07)), inputStroke: rgba(255, 140, 60, 0.3), inputRadius: 6,
        placeholderColor: rgba(255, 190, 130, 0.45), placeholderText: "Whisper something spooky…",
        timestampColor: rgba(255, 190, 130, 0.6), timestamp: .lowercaseMeridiem,
        codeFill: AnyShapeStyle(rgba(255, 190, 130, 0.12)), codeText: hex(0xFFD9B8),
        dictationColors: [hex(0xFF9E4F)], quoteColor: rgba(255, 122, 26, 0.6),
        sendFill: AnyShapeStyle(hex(0xFF7A1A)), sendGlyphColor: hex(0xFFE082), sendGlow: rgba(255, 150, 40, 0.7),
        micStroke: rgba(186, 104, 200, 0.55), micFill: AnyShapeStyle(rgba(171, 71, 188, 0.18)),
        micGlyphColor: hex(0xE1BEE7), micDashed: false,
        divider: BubbleStroke(color: rgba(255, 140, 60, 0.22), width: 1, dash: []),
        panelBorder: rgba(255, 140, 60, 0.3),
        glassSurface: true, accentInk: hex(0xFF9E4F),
        inlineCodeFill: rgba(255, 190, 130, 0.14), inlineCodeText: hex(0xFFB27A),
        bulletColor: hex(0xfff2e4), recordingAccent: hex(0xFF7A1A)
    )
    static let halloweenLight = ThemePalette(
        backgroundStyle: radial([hex(0xffe9d2), hex(0xf7d4b0), hex(0xe0ab84)]),
        userFill: AnyShapeStyle(rgba(255, 150, 60, 0.5)), userText: hex(0x3c1a02),
        userStroke: nil, userCorners: rr(16),
        assistantFill: AnyShapeStyle(rgba(255, 255, 255, 0.68)), assistantText: hex(0x3c1a02),
        assistantStroke: BubbleStroke(color: rgba(150, 70, 20, 0.18)), assistantCorners: rr(16),
        assistantGlyph: "🎃", glyphColor: hex(0xB4560E),
        accent: hex(0xE8650F), primaryText: hex(0x3c1a02), secondaryText: rgba(150, 70, 20, 0.8),
        inputFill: AnyShapeStyle(rgba(255, 255, 255, 0.55)), inputStroke: rgba(200, 100, 30, 0.35), inputRadius: 6,
        placeholderColor: rgba(150, 70, 20, 0.5), placeholderText: "Whisper something spooky…",
        timestampColor: rgba(150, 70, 20, 0.65), timestamp: .lowercaseMeridiem,
        codeFill: AnyShapeStyle(rgba(200, 100, 30, 0.1)), codeText: hex(0x7a3a05),
        dictationColors: [hex(0xB4560E)], quoteColor: rgba(232, 101, 15, 0.6),
        sendFill: AnyShapeStyle(hex(0xE8650F)), sendGlyphColor: .white, sendGlow: rgba(232, 101, 15, 0.5),
        micStroke: rgba(123, 31, 162, 0.45), micFill: AnyShapeStyle(rgba(255, 255, 255, 0.55)),
        micGlyphColor: hex(0x7B1FA2), micDashed: false,
        divider: BubbleStroke(color: rgba(200, 100, 30, 0.3), width: 1, dash: []),
        panelBorder: rgba(255, 255, 255, 0.75),
        glassSurface: true, accentInk: hex(0xB4560E),
        inlineCodeFill: rgba(200, 100, 30, 0.12), inlineCodeText: hex(0x9c4a08),
        bulletColor: hex(0x3c1a02), recordingAccent: hex(0xE8650F)
    )

    // MARK: Día de Muertos
    static let diaDark = ThemePalette(
        backgroundStyle: radial([hex(0x33163a), hex(0x25102e), hex(0x120718)]),
        userFill: AnyShapeStyle(rgba(216, 40, 100, 0.48)), userText: hex(0xfff0e0),
        userStroke: BubbleStroke(color: rgba(255, 179, 0, 0.6), width: 2, dash: [1, 3], edge: .bottom), userCorners: rr(16),
        assistantFill: AnyShapeStyle(rgba(50, 22, 58, 0.68)), assistantText: hex(0xfff0e0),
        assistantStroke: BubbleStroke(color: rgba(38, 166, 154, 0.6), width: 2, dash: [1, 3], edge: .bottom), assistantCorners: rr(16),
        assistantGlyph: "💀", glyphColor: hex(0xFFB300),
        accent: hex(0xFFB300), primaryText: hex(0xfff0e0), secondaryText: rgba(255, 210, 120, 0.8),
        inputFill: AnyShapeStyle(rgba(255, 179, 0, 0.07)), inputStroke: rgba(255, 179, 0, 0.3), inputRadius: 6,
        placeholderColor: rgba(255, 210, 120, 0.45), placeholderText: "Escribe algo, mi alma…",
        timestampColor: rgba(255, 210, 120, 0.6), timestamp: .plain,
        codeFill: AnyShapeStyle(rgba(255, 210, 120, 0.12)), codeText: hex(0xFFE3AE),
        dictationColors: [hex(0xFFB300), hex(0xEC407A), hex(0x26A69A)], bulletGlyph: "✿", quoteColor: rgba(236, 64, 122, 0.7),
        sendFill: AnyShapeStyle(hex(0xFFB300)), sendGlyphColor: hex(0x4A1030), sendGlow: rgba(255, 179, 0, 0.5),
        micColor: hex(0x7fd8cf), micStroke: hex(0x26A69A),
        divider: BubbleStroke(color: rgba(255, 179, 0, 0.35), width: 2, dash: [1, 3]),
        panelBorder: rgba(255, 179, 0, 0.32),
        glassSurface: true, accentInk: hex(0xFFB300),
        inlineCodeFill: rgba(255, 210, 120, 0.14), inlineCodeText: hex(0xFFCE7A),
        recordingAccent: hex(0xEC407A), voiceProgress: hex(0xFFD54F)
    )
    static let diaLight = ThemePalette(
        backgroundStyle: radial([hex(0xffe9c4), hex(0xffd9a8), hex(0xf0ae74)]),
        userFill: AnyShapeStyle(rgba(240, 110, 160, 0.5)), userText: hex(0x3d0d20),
        userStroke: BubbleStroke(color: rgba(200, 110, 0, 0.6), width: 2, dash: [1, 3], edge: .bottom), userCorners: rr(16),
        assistantFill: AnyShapeStyle(rgba(255, 255, 255, 0.7)), assistantText: hex(0x3d0d20),
        assistantStroke: BubbleStroke(color: rgba(0, 137, 123, 0.55), width: 2, dash: [1, 3], edge: .bottom), assistantCorners: rr(16),
        assistantGlyph: "💀", glyphColor: hex(0xF59E00),
        accent: hex(0xF59E00), primaryText: hex(0x3d0d20), secondaryText: rgba(170, 80, 10, 0.85),
        inputFill: AnyShapeStyle(rgba(255, 255, 255, 0.55)), inputStroke: rgba(200, 110, 0, 0.35), inputRadius: 6,
        placeholderColor: rgba(170, 80, 10, 0.5), placeholderText: "Escribe algo, mi alma…",
        timestampColor: rgba(170, 80, 10, 0.65), timestamp: .plain,
        codeFill: AnyShapeStyle(rgba(200, 110, 0, 0.1)), codeText: hex(0x7a4a00),
        dictationColors: [hex(0xF59E00), hex(0xD81B60), hex(0x00897B)], bulletGlyph: "✿", quoteColor: rgba(216, 27, 96, 0.6),
        sendFill: AnyShapeStyle(hex(0xF59E00)), sendGlyphColor: .white, sendGlow: rgba(216, 27, 96, 0.4),
        micColor: hex(0x00897B), micStroke: hex(0x00897B),
        divider: BubbleStroke(color: rgba(200, 110, 0, 0.4), width: 2, dash: [1, 3]),
        panelBorder: rgba(255, 255, 255, 0.78),
        glassSurface: true, accentInk: hex(0xC77800),
        inlineCodeFill: rgba(200, 110, 0, 0.12), inlineCodeText: hex(0x9a5c00),
        recordingAccent: hex(0xD81B60)
    )
}

// MARK: - Environment

private struct ThemePaletteKey: EnvironmentKey {
    static let defaultValue = ThemePalette(isGlass: true)
}

extension EnvironmentValues {
    var themePalette: ThemePalette {
        get { self[ThemePaletteKey.self] }
        set { self[ThemePaletteKey.self] = newValue }
    }
}

// MARK: - Panel surface

extension View {
    /// The panel's backing surface. `current` keeps the existing Liquid Glass;
    /// every other theme fills the panel with its gradient (plus signature
    /// pattern) instead of the glass material.
    @ViewBuilder
    func themedPanelSurface(_ palette: ThemePalette, cornerRadius: CGFloat) -> some View {
        if palette.isGlass {
            self.adaptiveGlass(cornerRadius: cornerRadius)
        } else {
            self
                .background {
                    ZStack {
                        if palette.glassSurface {
                            // Hybrid glass (Halloween/Día): keep the desktop
                            // blur, but lay the spec's radial gradient over it
                            // at high opacity — the deep theme colors match the
                            // design on any wallpaper, while a hint of the
                            // desktop still breathes through the glass.
                            Rectangle().fill(.ultraThinMaterial)
                            Rectangle().fill(palette.backgroundStyle).opacity(0.85)
                            // The spec's panel wash over the backdrop gradient
                            // (light: milky rgba(255,250,240,0.5) — the panel
                            // interior reads creamier than the raw gradient).
                            Rectangle().fill(palette.panelTint)
                        } else {
                            // Solid themed fill (other themes).
                            Rectangle().fill(palette.backgroundStyle)
                        }
                        ThemePatternOverlay(pattern: palette.pattern)
                        ThemeDecorations(themeID: palette.themeID)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(palette.panelBorder ?? palette.accent.opacity(0.3),
                                lineWidth: palette.panelBorder == nil ? 0.5 : 1)
                )
                // Blueprint's reference crosses in the four panel corners.
                .overlay {
                    if let markColor = palette.cornerMarkColor {
                        BlueprintCornerMarks(color: markColor)
                    }
                }
                // Synthwave's neon halo around the panel; nil → invisible.
                .shadow(color: palette.panelGlow ?? .clear, radius: 12)
        }
    }

    /// Composer text-field surface — material for Current, themed fill/border
    /// (with the theme's corner radius) otherwise.
    @ViewBuilder
    func themedInputField(_ palette: ThemePalette) -> some View {
        if palette.isGlass {
            self
                .background(RoundedRectangle(cornerRadius: 6).fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
        } else {
            self
                .background(RoundedRectangle(cornerRadius: palette.inputRadius).fill(palette.inputFill))
                .overlay(RoundedRectangle(cornerRadius: palette.inputRadius).stroke(palette.inputStroke, lineWidth: 1))
        }
    }
}

/// Message-bubble surface. Current theme keeps material + accent (user) /
/// material (assistant); themed variants use a solid/gradient fill with the
/// theme's corner radii and optional border.
struct ThemedBubble: ViewModifier {
    let palette: ThemePalette
    let isUser: Bool

    func body(content: Content) -> some View {
        if palette.isGlass {
            if isUser {
                content
                    .background(.regularMaterial)
                    .background(Color.accentColor.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                content
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        } else {
            let corners = isUser ? palette.userCorners : palette.assistantCorners
            let stroke = isUser ? palette.userStroke : palette.assistantStroke
            content
                // Solid themed fill (glass is kept only for Current).
                .background(isUser ? palette.userFill : palette.assistantFill)
                .clipShape(UnevenRoundedRectangle(cornerRadii: corners, style: .continuous))
                .overlay {
                    if let stroke {
                        switch stroke.edge {
                        case .all:
                            UnevenRoundedRectangle(cornerRadii: corners, style: .continuous)
                                .strokeBorder(stroke.color, style: StrokeStyle(lineWidth: stroke.width, dash: stroke.dash))
                        case .bottom:
                            TaperedDottedBottomEdge(inset: corners.bottomLeading,
                                                    color: stroke.color, width: stroke.width)
                        }
                    }
                }
        }
    }
}

/// Per-theme decorative ornament overlay (papel picado, marigolds, candles…),
/// placed behind the chat content and over the glass. Empty for themes without
/// ornaments yet.
struct ThemeDecorations: View {
    let themeID: AppTheme
    var body: some View {
        switch themeID {
        case .halloween: HalloweenDecorations()
        case .diaDeMuertos: DiaDecorations()
        case .sakura: SakuraDecorations()
        case .pastel: PastelDecorations()
        default: Color.clear
        }
    }
}

/// Blueprint's engineering reference crosses: a small `+` reper in each of the
/// four panel corners (a signature detail — «крестики-реперы в углах»). Inset
/// matches the design spec (8pt horizontal, 6pt vertical); purely decorative.
struct BlueprintCornerMarks: View {
    let color: Color
    private let corners: [Alignment] = [.topLeading, .topTrailing, .bottomLeading, .bottomTrailing]
    var body: some View {
        ZStack {
            ForEach(0..<corners.count, id: \.self) { i in
                Text("+")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corners[i])
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .allowsHitTesting(false)
    }
}

/// Composer top divider. Current/default themes keep the system `Divider`;
/// themes that define `palette.divider` get a themed line (dashed for
/// Blueprint) in their own accent.
struct ThemedComposerDivider: View {
    let palette: ThemePalette
    var body: some View {
        if let d = palette.divider, !palette.isGlass {
            // Round caps so Día's [1,3] dash reads as round dots (Blueprint's
            // [4,3] still reads as dashes).
            ComposerRuleShape()
                .stroke(d.color, style: StrokeStyle(lineWidth: d.width, lineCap: .round, dash: d.dash))
                .frame(height: max(1, d.width))
        } else {
            Divider()
        }
    }
}

/// A single horizontal line spanning the view's width (for the themed composer
/// divider — a `Shape` so it can carry a dashed stroke).
private struct ComposerRuleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

/// Terminal's signature blinking block caret, shown after the composer
/// placeholder («$ type your message▮»). A hard on/off blink (step-end) every
/// 0.55s, matching the design spec's `blink 1.1s step-end`.
struct BlinkingCaret: View {
    var color: Color
    var width: CGFloat = 7
    var height: CGFloat = 14
    @State private var visible = true
    private let timer = Timer.publish(every: 0.55, on: .main, in: .common).autoconnect()
    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(color)
            .frame(width: width, height: height)
            .opacity(visible ? 1 : 0)
            .onReceive(timer) { _ in visible.toggle() }
    }
}

/// Signature background decoration drawn over the gradient (blueprint grid,
/// terminal scanlines, synthwave horizon). Cheap `Canvas` drawing.
struct ThemePatternOverlay: View {
    let pattern: ThemePattern

    var body: some View {
        switch pattern {
        case .none:
            Color.clear
        case let .blueprintGrid(color, spacing):
            Canvas { ctx, size in
                var path = Path()
                var x: CGFloat = 0
                while x <= size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += spacing }
                var y: CGFloat = 0
                while y <= size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += spacing }
                ctx.stroke(path, with: .color(color), lineWidth: 1)
            }
            .allowsHitTesting(false)
        case let .scanlines(color):
            Canvas { ctx, size in
                var path = Path()
                var y: CGFloat = 0
                while y <= size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += 3 }
                ctx.stroke(path, with: .color(color), lineWidth: 1)
            }
            .allowsHitTesting(false)
        case let .synthwaveHorizon(color):
            // Retro perspective floor confined to the very bottom: verticals
            // converge to a vanishing point on the horizon, horizontals recede
            // with growing spacing. Kept short so it reads as a ground grid
            // behind the composer, not stray lines across the messages.
            Canvas { ctx, size in
                let floorH: CGFloat = 96
                let horizonY = size.height - floorH
                let vanishX = size.width / 2
                var grid = Path()
                let cols = 14
                for i in 0...cols {
                    let x = size.width * CGFloat(i) / CGFloat(cols)
                    grid.move(to: CGPoint(x: x, y: size.height))
                    grid.addLine(to: CGPoint(x: vanishX, y: horizonY))
                }
                var y = horizonY
                var step: CGFloat = 5
                while y < size.height {
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                    step *= 1.4
                    y += step
                }
                ctx.stroke(grid, with: .color(color), lineWidth: 1)
            }
            .allowsHitTesting(false)
        }
    }
}
