import SwiftUI

/// World Time's own theme tokens — the "day ramp" (midnight / night /
/// shoulder / work cell fills) plus the column frames, separators and the
/// small chrome around the grid. The chat's `ThemePalette` has no such
/// tokens: its palette is about message bubbles, while the grid encodes
/// DATA in color (night vs working hours), so each theme expresses the day
/// with its own pair of poles here. Values are 1:1 with the approved
/// mockups (World Time × Темы, вариант C: дефолты + ручные переопределения
/// для полярных тем; Blueprint — вариант A «чистое поле»).
///
/// The `current` (Liquid Glass) tokens reproduce the panel's original
/// hardcoded colors exactly — the glass look stays untouched.
struct WorldTimeTheme {
    var isGlass: Bool = false

    // Day ramp (cell fills)
    var midnight: Color
    var night: Color
    var shoulder: Color
    var work: Color
    /// Cell text over the dark fills (midnight/night); light fills use `text`.
    var cellDarkText: Color = .white
    /// Día's signature dotted [1,3] border around the midnight date chip.
    var midnightStroke: Color? = nil

    // Text
    var text: Color = .primary
    var secondary: Color = .secondary

    // Band chrome
    var sep: Color
    var bandStroke: Color
    var bandRadius: CGFloat = 12

    // Column frames
    var selStroke: Color
    var selFill: Color
    var selDash: [CGFloat] = []
    var selGlow: Color? = nil
    var hoverStroke: Color

    // "Right now" underline
    var now: Color
    var nowDash: [CGFloat] = [3, 2.5]

    // Chrome around the grid
    var weekend: Color
    var capsule: Color       // search field / close button fill
    var chip: Color          // timezone abbreviation badge
    var daySel: Color        // selected day pill in the date strip
    var rail: Color          // busy lane track
    var link: Color          // "Open Calendar" link + text buttons

    // MARK: Factory

    static func tokens(for theme: AppTheme, scheme: ColorScheme) -> WorldTimeTheme {
        let dark = scheme == .dark
        switch theme {
        case .current:
            // The original hardcoded panel colors, verbatim.
            return WorldTimeTheme(
                isGlass: true,
                midnight: Color(red: 0.15, green: 0.20, blue: 0.63).opacity(0.85),
                night: Color(red: 0.25, green: 0.33, blue: 0.82).opacity(0.55),
                shoulder: Color(red: 0.98, green: 0.80, blue: 0.39).opacity(0.38),
                work: Color.white.opacity(0.32),
                sep: Color.white.opacity(0.22),
                bandStroke: Color.primary.opacity(0.08),
                selStroke: Color.primary.opacity(0.8),
                selFill: Color.primary.opacity(0.05),
                hoverStroke: Color.primary.opacity(0.35),
                now: Color.primary.opacity(0.5),
                weekend: Color.red.opacity(0.8),
                capsule: Color.primary.opacity(0.06),
                chip: Color.secondary.opacity(0.15),
                daySel: Color.primary.opacity(0.1),
                rail: Color.primary.opacity(0.07),
                link: Color.accentColor
            )

        case .blueprint:
            return dark ? WorldTimeTheme(
                midnight: wrgba(11, 42, 69, 0.92), night: wrgba(24, 64, 104, 0.60),
                shoulder: wrgba(79, 195, 247, 0.16), work: wrgba(234, 246, 255, 0.26),
                cellDarkText: whex(0xeaf6ff),
                text: whex(0xeaf6ff), secondary: wrgba(150, 215, 255, 0.6),
                sep: wrgba(140, 210, 255, 0.22), bandStroke: wrgba(140, 210, 255, 0.30),
                selStroke: whex(0x4FC3F7), selFill: wrgba(79, 195, 247, 0.08), selDash: [4, 3],
                hoverStroke: wrgba(79, 195, 247, 0.45),
                now: wrgba(140, 210, 255, 0.9),
                weekend: whex(0xff9a8f), capsule: wrgba(120, 200, 255, 0.08),
                chip: wrgba(140, 210, 255, 0.15), daySel: wrgba(234, 246, 255, 0.12),
                rail: wrgba(150, 215, 255, 0.15), link: whex(0x4FC3F7)
            ) : WorldTimeTheme(
                midnight: wrgba(15, 77, 121, 0.90), night: wrgba(15, 90, 150, 0.45),
                shoulder: wrgba(2, 136, 209, 0.14), work: wrgba(255, 255, 255, 0.60),
                cellDarkText: whex(0xeaf6ff),
                text: whex(0x0c2233), secondary: wrgba(15, 90, 150, 0.7),
                sep: wrgba(15, 90, 150, 0.18), bandStroke: wrgba(15, 90, 150, 0.30),
                selStroke: whex(0x0288D1), selFill: wrgba(2, 136, 209, 0.07), selDash: [4, 3],
                hoverStroke: wrgba(2, 136, 209, 0.45),
                now: wrgba(8, 90, 140, 0.85),
                weekend: whex(0xc62828), capsule: wrgba(255, 255, 255, 0.55),
                chip: wrgba(15, 90, 150, 0.14), daySel: wrgba(15, 90, 150, 0.12),
                rail: wrgba(15, 90, 150, 0.14), link: whex(0x0288D1)
            )

        case .terminal:
            // No blue at all — the day lives in phosphor. Weekends are amber
            // (red would break the monochrome).
            return dark ? WorldTimeTheme(
                midnight: wrgba(3, 22, 11, 0.95), night: wrgba(8, 44, 22, 0.72),
                shoulder: wrgba(51, 255, 102, 0.10), work: wrgba(120, 255, 160, 0.24),
                cellDarkText: whex(0xd8ffe4),
                text: whex(0xd8ffe4), secondary: wrgba(120, 255, 160, 0.6),
                sep: wrgba(51, 255, 102, 0.18), bandStroke: wrgba(51, 255, 102, 0.22),
                selStroke: whex(0x33FF66), selFill: wrgba(51, 255, 102, 0.06),
                selGlow: wrgba(51, 255, 102, 0.45),
                hoverStroke: wrgba(51, 255, 102, 0.45),
                now: wrgba(51, 255, 102, 0.9),
                weekend: whex(0xffcc66), capsule: wrgba(51, 255, 102, 0.05),
                chip: wrgba(51, 255, 102, 0.12), daySel: wrgba(51, 255, 102, 0.12),
                rail: wrgba(120, 255, 160, 0.14), link: whex(0x33FF66)
            ) : WorldTimeTheme(
                midnight: wrgba(9, 54, 27, 0.88), night: wrgba(10, 80, 40, 0.50),
                shoulder: wrgba(11, 138, 58, 0.12), work: wrgba(255, 255, 255, 0.62),
                cellDarkText: whex(0xd8ffe4),
                text: whex(0x08240f), secondary: wrgba(10, 90, 40, 0.7),
                sep: wrgba(10, 120, 50, 0.18), bandStroke: wrgba(10, 120, 50, 0.25),
                selStroke: whex(0x0B8A3A), selFill: wrgba(11, 138, 58, 0.07),
                hoverStroke: wrgba(11, 138, 58, 0.45),
                now: wrgba(11, 138, 58, 0.85),
                weekend: whex(0xb26a00), capsule: wrgba(255, 255, 255, 0.55),
                chip: wrgba(10, 120, 50, 0.14), daySel: wrgba(10, 120, 50, 0.12),
                rail: wrgba(10, 120, 50, 0.14), link: whex(0x0B8A3A)
            )

        case .synthwave:
            // Retro sunset: violet night → pink shoulder (the sunset is the
            // hero — the one theme where shoulders outshine work hours) →
            // cool cyan day.
            return dark ? WorldTimeTheme(
                midnight: wrgba(18, 8, 46, 0.95), night: wrgba(48, 20, 92, 0.70),
                shoulder: wrgba(255, 46, 151, 0.22), work: wrgba(210, 245, 255, 0.20),
                cellDarkText: whex(0xffeaf6),
                text: whex(0xffeaf6), secondary: wrgba(255, 180, 220, 0.75),
                sep: wrgba(0, 229, 255, 0.18), bandStroke: wrgba(0, 229, 255, 0.22),
                selStroke: whex(0xFF2E97), selFill: wrgba(255, 46, 151, 0.08),
                selGlow: wrgba(255, 46, 151, 0.5),
                hoverStroke: wrgba(0, 229, 255, 0.5),
                now: wrgba(0, 229, 255, 0.85),
                weekend: whex(0xffd166), capsule: wrgba(255, 46, 151, 0.07),
                chip: wrgba(0, 229, 255, 0.14), daySel: wrgba(255, 234, 246, 0.12),
                rail: wrgba(0, 229, 255, 0.15), link: whex(0x00E5FF)
            ) : WorldTimeTheme(
                midnight: wrgba(58, 16, 96, 0.88), night: wrgba(110, 70, 190, 0.42),
                shoulder: wrgba(233, 30, 140, 0.16), work: wrgba(255, 255, 255, 0.60),
                cellDarkText: whex(0xffeaf6),
                text: whex(0x3a0a26), secondary: wrgba(190, 30, 110, 0.7),
                sep: wrgba(0, 172, 193, 0.20), bandStroke: wrgba(0, 172, 193, 0.28),
                selStroke: whex(0xE91E8C), selFill: wrgba(233, 30, 140, 0.07),
                hoverStroke: wrgba(0, 172, 193, 0.55),
                now: wrgba(0, 150, 170, 0.85),
                weekend: whex(0xad1457), capsule: wrgba(255, 255, 255, 0.55),
                chip: wrgba(0, 172, 193, 0.15), daySel: wrgba(58, 10, 38, 0.10),
                rail: wrgba(0, 172, 193, 0.16), link: whex(0x00838F)
            )

        case .sakura:
            return dark ? WorldTimeTheme(
                midnight: wrgba(40, 13, 28, 0.95), night: wrgba(96, 44, 74, 0.60),
                shoulder: wrgba(244, 143, 177, 0.20), work: wrgba(255, 238, 245, 0.24),
                cellDarkText: whex(0xffeef5),
                text: whex(0xffeef5), secondary: wrgba(255, 190, 215, 0.75),
                sep: wrgba(255, 170, 205, 0.20), bandStroke: wrgba(255, 170, 205, 0.22),
                bandRadius: 14,
                selStroke: whex(0xF06292), selFill: wrgba(240, 98, 146, 0.08),
                hoverStroke: wrgba(244, 143, 177, 0.5),
                now: wrgba(244, 143, 177, 0.9),
                weekend: whex(0xff8fb0), capsule: wrgba(255, 170, 205, 0.08),
                chip: wrgba(255, 170, 205, 0.15), daySel: wrgba(255, 238, 245, 0.12),
                rail: wrgba(255, 190, 215, 0.15), link: whex(0xF48FB1)
            ) : WorldTimeTheme(
                midnight: wrgba(122, 37, 69, 0.88), night: wrgba(190, 70, 115, 0.42),
                shoulder: wrgba(236, 95, 143, 0.14), work: wrgba(255, 255, 255, 0.65),
                cellDarkText: whex(0xffeef5),
                text: whex(0x42101f), secondary: wrgba(190, 70, 115, 0.75),
                sep: wrgba(230, 100, 150, 0.18), bandStroke: wrgba(230, 100, 150, 0.25),
                bandRadius: 14,
                selStroke: whex(0xEC5F8F), selFill: wrgba(236, 95, 143, 0.07),
                hoverStroke: wrgba(236, 95, 143, 0.5),
                now: wrgba(216, 68, 122, 0.85),
                weekend: whex(0xc2185b), capsule: wrgba(255, 255, 255, 0.6),
                chip: wrgba(230, 100, 150, 0.14), daySel: wrgba(66, 16, 31, 0.10),
                rail: wrgba(190, 70, 115, 0.16), link: whex(0xD8447A)
            )

        case .pastel:
            // Lavender night, peach dawn shoulders — the theme's own accent
            // pair, no manual tuning needed.
            return dark ? WorldTimeTheme(
                midnight: wrgba(30, 22, 52, 0.95), night: wrgba(94, 74, 148, 0.55),
                shoulder: wrgba(255, 171, 145, 0.22), work: wrgba(247, 240, 255, 0.22),
                cellDarkText: whex(0xf7f0ff),
                text: whex(0xf7f0ff), secondary: wrgba(215, 195, 255, 0.6),
                sep: wrgba(200, 175, 255, 0.20), bandStroke: wrgba(200, 175, 255, 0.22),
                bandRadius: 16,
                selStroke: whex(0xB39DDB), selFill: wrgba(179, 157, 219, 0.10),
                hoverStroke: wrgba(200, 175, 255, 0.5),
                now: wrgba(255, 171, 145, 0.9),
                weekend: whex(0xFFAB91), capsule: wrgba(200, 175, 255, 0.08),
                chip: wrgba(200, 175, 255, 0.15), daySel: wrgba(247, 240, 255, 0.12),
                rail: wrgba(215, 195, 255, 0.15), link: whex(0xCDB6F5)
            ) : WorldTimeTheme(
                midnight: wrgba(74, 54, 112, 0.85), night: wrgba(120, 85, 180, 0.35),
                shoulder: wrgba(255, 140, 110, 0.22), work: wrgba(255, 255, 255, 0.65),
                cellDarkText: whex(0xf7f0ff),
                text: whex(0x2d1846), secondary: wrgba(120, 85, 180, 0.65),
                sep: wrgba(150, 110, 210, 0.18), bandStroke: wrgba(150, 110, 210, 0.22),
                bandRadius: 16,
                selStroke: whex(0x9575CD), selFill: wrgba(149, 117, 205, 0.08),
                hoverStroke: wrgba(149, 117, 205, 0.5),
                now: wrgba(230, 90, 50, 0.75),
                weekend: whex(0xe64a19), capsule: wrgba(255, 255, 255, 0.6),
                chip: wrgba(150, 110, 210, 0.14), daySel: wrgba(45, 24, 70, 0.10),
                rail: wrgba(120, 85, 180, 0.16), link: whex(0x7E57C2)
            )

        case .halloween:
            return dark ? WorldTimeTheme(
                midnight: wrgba(20, 9, 38, 0.95), night: wrgba(48, 26, 84, 0.70),
                shoulder: wrgba(255, 122, 26, 0.22), work: wrgba(255, 242, 228, 0.20),
                cellDarkText: whex(0xfff2e4),
                text: whex(0xfff2e4), secondary: wrgba(255, 190, 130, 0.8),
                sep: wrgba(255, 140, 60, 0.20), bandStroke: wrgba(255, 140, 60, 0.22),
                selStroke: whex(0xFF7A1A), selFill: wrgba(255, 122, 26, 0.08),
                selGlow: wrgba(255, 150, 40, 0.4),
                hoverStroke: wrgba(255, 158, 79, 0.5),
                now: wrgba(255, 158, 79, 0.9),
                weekend: whex(0xff7043), capsule: wrgba(255, 140, 60, 0.07),
                chip: wrgba(255, 190, 130, 0.15), daySel: wrgba(255, 242, 228, 0.12),
                rail: wrgba(255, 190, 130, 0.15), link: whex(0xFF9E4F)
            ) : WorldTimeTheme(
                midnight: wrgba(60, 26, 2, 0.88), night: wrgba(94, 52, 132, 0.42),
                shoulder: wrgba(232, 101, 15, 0.16), work: wrgba(255, 255, 255, 0.60),
                cellDarkText: whex(0xfff2e4),
                text: whex(0x3c1a02), secondary: wrgba(150, 70, 20, 0.8),
                sep: wrgba(200, 100, 30, 0.20), bandStroke: wrgba(200, 100, 30, 0.28),
                selStroke: whex(0xE8650F), selFill: wrgba(232, 101, 15, 0.07),
                hoverStroke: wrgba(232, 101, 15, 0.5),
                now: wrgba(180, 86, 14, 0.85),
                weekend: whex(0xbf360c), capsule: wrgba(255, 255, 255, 0.55),
                chip: wrgba(150, 70, 20, 0.14), daySel: wrgba(60, 26, 2, 0.10),
                rail: wrgba(150, 70, 20, 0.15), link: whex(0xB4560E)
            )

        case .diaDeMuertos:
            // Marigold shoulders; the "now" marker and the midnight chip
            // carry the theme's dotted [1,3] signature.
            return dark ? WorldTimeTheme(
                midnight: wrgba(35, 8, 46, 0.95), night: wrgba(76, 22, 88, 0.70),
                shoulder: wrgba(255, 179, 0, 0.22), work: wrgba(255, 240, 224, 0.20),
                cellDarkText: whex(0xfff0e0),
                midnightStroke: wrgba(255, 179, 0, 0.6),
                text: whex(0xfff0e0), secondary: wrgba(255, 210, 120, 0.8),
                sep: wrgba(255, 179, 0, 0.20), bandStroke: wrgba(255, 179, 0, 0.24),
                selStroke: whex(0xFFB300), selFill: wrgba(255, 179, 0, 0.08),
                selGlow: wrgba(255, 179, 0, 0.35),
                hoverStroke: wrgba(38, 166, 154, 0.6),
                now: wrgba(255, 179, 0, 0.95), nowDash: [1, 3],
                weekend: whex(0xF06292), capsule: wrgba(255, 179, 0, 0.07),
                chip: wrgba(255, 210, 120, 0.15), daySel: wrgba(255, 240, 224, 0.12),
                rail: wrgba(255, 210, 120, 0.15), link: whex(0x26A69A)
            ) : WorldTimeTheme(
                midnight: wrgba(90, 16, 48, 0.88), night: wrgba(130, 34, 96, 0.45),
                shoulder: wrgba(245, 158, 0, 0.20), work: wrgba(255, 255, 255, 0.62),
                cellDarkText: whex(0xfff0e0),
                midnightStroke: wrgba(200, 110, 0, 0.6),
                text: whex(0x3d0d20), secondary: wrgba(170, 80, 10, 0.85),
                sep: wrgba(200, 110, 0, 0.20), bandStroke: wrgba(200, 110, 0, 0.28),
                selStroke: whex(0xC77800), selFill: wrgba(245, 158, 0, 0.08),
                hoverStroke: wrgba(0, 137, 123, 0.55),
                now: wrgba(199, 120, 0, 0.9), nowDash: [1, 3],
                weekend: whex(0xC2185B), capsule: wrgba(255, 255, 255, 0.55),
                chip: wrgba(170, 80, 10, 0.14), daySel: wrgba(61, 13, 32, 0.10),
                rail: wrgba(170, 80, 10, 0.15), link: whex(0x00897B)
            )
        }
    }
}

// Local copies of AppTheme's file-private color helpers (the drgba pattern
// used by the decoration files).
private func wrgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Color {
    Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
}
private func whex(_ v: UInt) -> Color { Color(rgb: v) }
