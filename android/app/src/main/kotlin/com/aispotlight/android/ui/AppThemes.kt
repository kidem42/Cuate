package com.aispotlight.android.ui

import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color

/**
 * Decorative chat themes — a 1:1 port of `AppTheme.swift` / `ThemePalette`.
 * Every color, corner radius, dash pattern, glow and signature detail is
 * verbatim from the macOS design spec ("Theme Explorations"). DYNAMIC keeps
 * Material You (wallpaper colors) — the Android analog of Liquid Glass — and
 * gets the same translucent "glass" treatment the mac Current theme has.
 */
enum class ChatThemeID(val id: String) {
    DYNAMIC("dynamic"),
    BLUEPRINT("blueprint"),
    TERMINAL("terminal"),
    SYNTHWAVE("synthwave"),
    SAKURA("sakura"),
    PASTEL("pastel"),
    HALLOWEEN("halloween"),
    DIA_DE_MUERTOS("diaDeMuertos");

    val displayName: String
        get() = when (this) {
            DYNAMIC -> "Material You"
            BLUEPRINT -> "Blueprint"
            TERMINAL -> "Terminal"
            SYNTHWAVE -> "Synthwave"
            SAKURA -> "Sakura"
            PASTEL -> "Pastel"
            HALLOWEEN -> "Halloween"
            DIA_DE_MUERTOS -> "Día de Muertos"
        }

    companion object {
        fun fromId(id: String?): ChatThemeID = entries.firstOrNull { it.id == id } ?: DYNAMIC
    }
}

/** Background overlay pattern (drawn behind the chat). */
enum class ThemePattern { NONE, GRID, SCANLINES }

/** Timestamp rendering style (port of ThemePalette.timestamp on macOS). */
enum class TimestampStyle { PLAIN, BRACKETED, SECONDS, UPPER_MERIDIEM, LOWER_MERIDIEM, FLOWER }

/** Which decoration overlay a theme carries (see Decorations.kt). */
enum class ThemeDecoration { NONE, SAKURA, PASTEL, HALLOWEEN, DIA }

/**
 * Bubble/divider stroke (port of macOS `BubbleStroke`). `dash` values are in
 * dp; empty = solid. `bottomOnly` = the Día tapered dotted bottom edge (CSS
 * border-bottom on a rounded rect) instead of a full border.
 */
data class BubbleStroke(
    val color: Color,
    val width: Float = 1f,
    val dash: List<Float> = emptyList(),
    val bottomOnly: Boolean = false,
)

/**
 * Per-corner radii in dp (port of `RectangleCornerRadii`). Order matches the
 * mac spec helper `rr(tl, tr, br, bl)`: topStart, topEnd, bottomEnd,
 * bottomStart in LTR terms.
 */
data class Corners(val topStart: Int, val topEnd: Int, val bottomEnd: Int, val bottomStart: Int) {
    constructor(all: Int) : this(all, all, all, all)
}

/** Resolved theme palette for one appearance (light or dark). */
data class ChatPalette(
    /** true → Material You dynamic colors + glass treatment (no overrides). */
    val isDynamic: Boolean = false,
    val themeID: ChatThemeID = ChatThemeID.DYNAMIC,
    /** Resolved appearance (set by `ChatThemes.palette`); art picks variants by it. */
    val dark: Boolean = false,

    // Panel surface
    val backgroundColors: List<Color> = emptyList(),
    val radialBackground: Boolean = true,
    /** Semi-transparent "glass panel" wash over the gradient (spec rgba). */
    val panelTint: Color = Color.Transparent,
    /** Hybrid glass (Halloween/Día): panelTint is drawn over the gradient. */
    val glassSurface: Boolean = false,
    val pattern: ThemePattern = ThemePattern.NONE,
    val patternColor: Color = Color.Transparent,
    /** Blueprint's reference crosses in the four panel corners. */
    val cornerMarkColor: Color? = null,

    // Bubbles
    val userFill: List<Color> = emptyList(),      // 1 color = solid, 2+ = 120° gradient
    val userText: Color = Color.White,
    val userStroke: BubbleStroke? = null,
    val userCorners: Corners = Corners(16),
    val assistantFill: Color = Color.Transparent,
    val assistantText: Color = Color.White,
    val assistantStroke: BubbleStroke? = null,
    val assistantCorners: Corners = Corners(16),
    /** Assistant bubble icon — a literal glyph (⊿ ❯ ▲ ❀ ♡ 🎃 💀). */
    val assistantGlyph: String = "❯",
    val glyphColor: Color = Color.White,
    /** Neon glow around the user bubble (Synthwave dark). null → none. */
    val userGlow: Color? = null,

    // Text roles
    val accent: Color = Color.White,
    val primaryText: Color = Color.White,
    val secondaryText: Color = Color.Gray,
    /** Deep "ink" accent for links/bullets/icons (Día light #C77800). */
    val accentInk: Color? = null,

    // Composer
    val inputFill: Color = Color.Transparent,
    val inputStroke: Color = Color.Gray,
    val inputRadius: Int = 6,
    val placeholderColor: Color = Color.Gray,
    val placeholder: String? = null,
    /** Terminal's blinking block caret after the placeholder. */
    val placeholderCaret: Boolean = false,
    /** Composer top divider; null → the system divider. */
    val divider: BubbleStroke? = null,
    /** Send/mic button shape: null → circle; value → rounded square radius. */
    val composerButtonRadius: Int? = null,

    // Send button
    val sendFill: List<Color> = emptyList(),
    val sendGlyph: Color = Color.White,
    val sendGlow: Color? = null,

    // Mic button
    val micColor: Color? = null,
    val micStroke: Color? = null,
    val micFill: Color? = null,
    val micGlyphColor: Color? = null,
    /** true = dashed circle (Día), false = solid themed fill. */
    val micDashed: Boolean = true,

    // Timestamps
    val timestampColor: Color = Color.Gray,
    val timestampStyle: TimestampStyle = TimestampStyle.PLAIN,
    /** Monospaced timestamps (Blueprint's мон-таймстампы). */
    val timestampMono: Boolean = false,

    // Typography / markdown
    val monospace: Boolean = false,
    val codeFill: Color = Color.Transparent,
    val codeText: Color = Color.White,
    val inlineCodeFill: Color? = null,
    val inlineCodeText: Color? = null,
    val bulletGlyph: String = "•",
    val bulletColor: Color? = null,
    val quoteColor: Color? = null,

    // Signature effects
    val dictationColors: List<Color> = emptyList(),
    val recordingAccent: Color? = null,
    val voiceProgress: Color? = null,
    val decoration: ThemeDecoration = ThemeDecoration.NONE,
) {
    /** Resolved ink accent: `accentInk` when set, else the plain accent. */
    val ink: Color get() = accentInk ?: accent

    val backgroundBrush: Brush
        get() = if (radialBackground) {
            // Mac spec: RadialGradient center (0.25, 0.10), endRadius 480pt.
            // Compose radial gradients center by fraction via Offset in px at
            // draw time; the panel surface draws this manually (ChatScreen).
            Brush.radialGradient(backgroundColors)
        } else {
            Brush.verticalGradient(backgroundColors)
        }

    /** 120° gradient (top-leading → bottom-trailing), like the mac linear120. */
    val userBrush: Brush
        get() = if (userFill.size >= 2) Brush.linearGradient(userFill)
        else Brush.linearGradient(listOf(userFill.first(), userFill.first()))

    val sendBrush: Brush
        get() = if (sendFill.size >= 2) Brush.linearGradient(sendFill)
        else Brush.linearGradient(listOf(sendFill.first(), sendFill.first()))
}

val LocalChatPalette = staticCompositionLocalOf { ChatPalette(isDynamic = true) }

private fun c(v: Long) = Color(0xFF000000 or v)
private fun c(v: Long, a: Float) = Color(v or 0xFF000000).copy(alpha = a)

/** rgba() with 0–255 channels, matching the design spec verbatim. */
private fun rgba(r: Int, g: Int, b: Int, a: Float) =
    Color(red = r / 255f, green = g / 255f, blue = b / 255f, alpha = a)

object ChatThemes {
    fun palette(theme: ChatThemeID, dark: Boolean): ChatPalette = when (theme) {
        ChatThemeID.DYNAMIC -> ChatPalette(isDynamic = true)
        ChatThemeID.BLUEPRINT -> if (dark) blueprintDark else blueprintLight
        ChatThemeID.TERMINAL -> if (dark) terminalDark else terminalLight
        ChatThemeID.SYNTHWAVE -> if (dark) synthwaveDark else synthwaveLight
        ChatThemeID.SAKURA -> if (dark) sakuraDark else sakuraLight
        ChatThemeID.PASTEL -> if (dark) pastelDark else pastelLight
        ChatThemeID.HALLOWEEN -> if (dark) halloweenDark else halloweenLight
        ChatThemeID.DIA_DE_MUERTOS -> if (dark) diaDark else diaLight
    }.copy(dark = dark)

    // MARK: Blueprint
    private val blueprintDark = ChatPalette(
        themeID = ChatThemeID.BLUEPRINT,
        backgroundColors = listOf(c(0x1d3346), c(0x122334), c(0x0a141f)),
        panelTint = rgba(14, 26, 38, 0.40f),
        pattern = ThemePattern.GRID, patternColor = rgba(110, 190, 255, 0.06f),
        cornerMarkColor = rgba(120, 200, 255, 0.5f),
        userFill = listOf(rgba(38, 110, 165, 0.5f)), userText = c(0xeaf6ff),
        userStroke = BubbleStroke(rgba(140, 210, 255, 0.45f), dash = listOf(4f, 3f)),
        userCorners = Corners(10),
        assistantFill = rgba(20, 42, 62, 0.6f), assistantText = c(0xeaf6ff),
        assistantStroke = BubbleStroke(rgba(140, 210, 255, 0.3f), dash = listOf(4f, 3f)),
        assistantCorners = Corners(10),
        assistantGlyph = "⊿", glyphColor = c(0x4FC3F7),
        accent = c(0x4FC3F7), primaryText = c(0xeaf6ff), secondaryText = rgba(150, 215, 255, 0.6f),
        inputFill = rgba(120, 200, 255, 0.06f), inputStroke = rgba(140, 210, 255, 0.3f), inputRadius = 4,
        placeholderColor = rgba(150, 215, 255, 0.4f), placeholder = "— annotate drawing…",
        divider = BubbleStroke(rgba(140, 210, 255, 0.25f), width = 1f, dash = listOf(4f, 3f)),
        composerButtonRadius = 6,
        sendFill = listOf(c(0x4FC3F7)), sendGlyph = c(0x06233a),
        micFill = rgba(120, 200, 255, 0.12f), micGlyphColor = c(0xbfe4ff), micDashed = false,
        timestampColor = rgba(150, 215, 255, 0.6f), timestampStyle = TimestampStyle.BRACKETED,
        timestampMono = true,
        codeFill = rgba(120, 200, 255, 0.14f), codeText = c(0x9fd7ff),
        bulletGlyph = "—", quoteColor = rgba(79, 195, 247, 0.6f),
    )
    private val blueprintLight = ChatPalette(
        themeID = ChatThemeID.BLUEPRINT,
        backgroundColors = listOf(c(0xdbeaf5), c(0xbcd7ea), c(0x8fb8d6)),
        panelTint = rgba(240, 248, 255, 0.5f),
        pattern = ThemePattern.GRID, patternColor = rgba(30, 110, 170, 0.07f),
        cornerMarkColor = rgba(20, 100, 160, 0.5f),
        userFill = listOf(rgba(120, 195, 245, 0.5f)), userText = c(0x0c2233),
        userStroke = BubbleStroke(rgba(15, 90, 150, 0.4f), dash = listOf(4f, 3f)),
        userCorners = Corners(10),
        assistantFill = rgba(255, 255, 255, 0.65f), assistantText = c(0x0c2233),
        assistantStroke = BubbleStroke(rgba(15, 90, 150, 0.3f), dash = listOf(4f, 3f)),
        assistantCorners = Corners(10),
        assistantGlyph = "⊿", glyphColor = c(0x0288D1),
        accent = c(0x0288D1), primaryText = c(0x0c2233), secondaryText = rgba(15, 90, 150, 0.7f),
        inputFill = rgba(255, 255, 255, 0.55f), inputStroke = rgba(15, 90, 150, 0.35f), inputRadius = 4,
        placeholderColor = rgba(15, 90, 150, 0.45f), placeholder = "— annotate drawing…",
        divider = BubbleStroke(rgba(15, 90, 150, 0.3f), width = 1f, dash = listOf(4f, 3f)),
        composerButtonRadius = 6,
        sendFill = listOf(c(0x0288D1)), sendGlyph = Color.White,
        micFill = rgba(255, 255, 255, 0.55f), micGlyphColor = c(0x0b5c94), micDashed = false,
        timestampColor = rgba(15, 90, 150, 0.6f), timestampStyle = TimestampStyle.BRACKETED,
        timestampMono = true,
        codeFill = rgba(30, 110, 170, 0.12f), codeText = c(0x085a8c),
        bulletGlyph = "—", quoteColor = rgba(2, 136, 209, 0.6f),
    )

    // MARK: Terminal
    private val terminalDark = ChatPalette(
        themeID = ChatThemeID.TERMINAL,
        backgroundColors = listOf(c(0x12241a), c(0x0b1712), c(0x050c08)),
        panelTint = rgba(6, 20, 12, 0.45f),
        pattern = ThemePattern.SCANLINES, patternColor = rgba(51, 255, 102, 0.035f),
        userFill = listOf(rgba(30, 120, 60, 0.45f)), userText = c(0xd8ffe4),
        userStroke = BubbleStroke(rgba(51, 255, 102, 0.3f)), userCorners = Corners(8),
        assistantFill = rgba(8, 30, 16, 0.65f), assistantText = c(0xd8ffe4),
        assistantStroke = BubbleStroke(rgba(51, 255, 102, 0.2f)), assistantCorners = Corners(8),
        assistantGlyph = "❯", glyphColor = c(0x33FF66),
        accent = c(0x33FF66), primaryText = c(0xd8ffe4), secondaryText = rgba(120, 255, 160, 0.6f),
        inputFill = rgba(51, 255, 102, 0.05f), inputStroke = rgba(51, 255, 102, 0.3f), inputRadius = 4,
        placeholderColor = rgba(120, 255, 160, 0.5f), placeholder = "$ type your message",
        placeholderCaret = true,
        divider = BubbleStroke(rgba(51, 255, 102, 0.18f), width = 1f),
        composerButtonRadius = 4,
        sendFill = listOf(c(0x33FF66)), sendGlyph = c(0x042010), sendGlow = rgba(51, 255, 102, 0.5f),
        micFill = rgba(51, 255, 102, 0.1f), micGlyphColor = c(0x7dffa5), micDashed = false,
        timestampColor = rgba(120, 255, 160, 0.5f), timestampStyle = TimestampStyle.SECONDS,
        monospace = true,
        codeFill = rgba(51, 255, 102, 0.08f), codeText = c(0x7dffa5),
        bulletGlyph = "❯",
    )
    private val terminalLight = ChatPalette(
        themeID = ChatThemeID.TERMINAL,
        backgroundColors = listOf(c(0xe4efe6), c(0xcfe2d3), c(0xa8c9b0)),
        panelTint = rgba(244, 252, 246, 0.5f),
        pattern = ThemePattern.SCANLINES, patternColor = rgba(10, 120, 50, 0.04f),
        userFill = listOf(rgba(90, 210, 130, 0.4f)), userText = c(0x08240f),
        userStroke = BubbleStroke(rgba(10, 120, 50, 0.3f)), userCorners = Corners(8),
        assistantFill = rgba(255, 255, 255, 0.65f), assistantText = c(0x08240f),
        assistantStroke = BubbleStroke(rgba(10, 120, 50, 0.22f)), assistantCorners = Corners(8),
        assistantGlyph = "❯", glyphColor = c(0x0B8A3A),
        accent = c(0x0B8A3A), primaryText = c(0x08240f), secondaryText = rgba(10, 90, 40, 0.7f),
        inputFill = rgba(255, 255, 255, 0.55f), inputStroke = rgba(10, 120, 50, 0.35f), inputRadius = 4,
        placeholderColor = rgba(10, 90, 40, 0.5f), placeholder = "$ type your message",
        placeholderCaret = true,
        divider = BubbleStroke(rgba(10, 120, 50, 0.25f), width = 1f),
        composerButtonRadius = 4,
        sendFill = listOf(c(0x0B8A3A)), sendGlyph = Color.White,
        micFill = rgba(255, 255, 255, 0.55f), micGlyphColor = c(0x0B8A3A), micDashed = false,
        timestampColor = rgba(10, 90, 40, 0.55f), timestampStyle = TimestampStyle.SECONDS,
        monospace = true,
        codeFill = rgba(10, 120, 50, 0.1f), codeText = c(0x0B8A3A),
        bulletGlyph = "❯",
    )

    // MARK: Synthwave
    private val synthwaveDark = ChatPalette(
        themeID = ChatThemeID.SYNTHWAVE,
        backgroundColors = listOf(c(0x1b1035), c(0x2a1048), c(0x3d0f4e)), radialBackground = false,
        panelTint = rgba(24, 10, 44, 0.42f),
        userFill = listOf(rgba(255, 46, 151, 0.5f), rgba(140, 60, 255, 0.5f)), userText = c(0xffeaf6),
        userCorners = Corners(16), userGlow = rgba(255, 46, 151, 0.3f),
        assistantFill = rgba(30, 12, 55, 0.65f), assistantText = c(0xffeaf6),
        assistantStroke = BubbleStroke(rgba(0, 229, 255, 0.25f)), assistantCorners = Corners(16),
        assistantGlyph = "▲", glyphColor = c(0xFF2E97),
        accent = c(0xFF2E97), primaryText = c(0xffeaf6), secondaryText = rgba(255, 180, 220, 0.75f),
        inputFill = rgba(255, 46, 151, 0.07f), inputStroke = rgba(0, 229, 255, 0.3f), inputRadius = 8,
        placeholderColor = rgba(255, 180, 220, 0.45f),
        divider = BubbleStroke(rgba(255, 46, 151, 0.25f), width = 1f),
        sendFill = listOf(c(0xFF2E97), c(0x7C4DFF), c(0x00E5FF)),
        sendGlyph = Color.White, sendGlow = rgba(255, 46, 151, 0.55f),
        micFill = rgba(0, 229, 255, 0.12f), micGlyphColor = c(0x8de9ff), micDashed = false,
        timestampColor = rgba(0, 229, 255, 0.6f), timestampStyle = TimestampStyle.UPPER_MERIDIEM,
        codeFill = rgba(255, 46, 151, 0.12f), codeText = c(0xff9ecf),
        dictationColors = listOf(c(0xFF2E97), c(0x00E5FF)),
    )
    private val synthwaveLight = ChatPalette(
        themeID = ChatThemeID.SYNTHWAVE,
        backgroundColors = listOf(c(0xffe3ef), c(0xe8d6ff), c(0xcfeffb)), radialBackground = false,
        panelTint = rgba(255, 248, 253, 0.5f),
        userFill = listOf(rgba(255, 120, 190, 0.5f), rgba(170, 120, 255, 0.5f)), userText = c(0x3a0a26),
        userCorners = Corners(16),
        assistantFill = rgba(255, 255, 255, 0.68f), assistantText = c(0x3a0a26),
        assistantStroke = BubbleStroke(rgba(0, 172, 193, 0.3f)), assistantCorners = Corners(16),
        assistantGlyph = "▲", glyphColor = c(0xE91E8C),
        accent = c(0xE91E8C), primaryText = c(0x3a0a26), secondaryText = rgba(190, 30, 110, 0.7f),
        inputFill = rgba(255, 255, 255, 0.55f), inputStroke = rgba(0, 172, 193, 0.35f), inputRadius = 8,
        placeholderColor = rgba(190, 30, 110, 0.4f),
        divider = BubbleStroke(rgba(233, 30, 140, 0.25f), width = 1f),
        sendFill = listOf(c(0xE91E8C), c(0x7C4DFF), c(0x00ACC1)),
        sendGlyph = Color.White, sendGlow = rgba(233, 30, 140, 0.35f),
        micFill = rgba(0, 172, 193, 0.12f), micGlyphColor = c(0x00838F), micDashed = false,
        timestampColor = rgba(0, 150, 170, 0.7f), timestampStyle = TimestampStyle.UPPER_MERIDIEM,
        codeFill = rgba(233, 30, 140, 0.1f), codeText = c(0xad1465),
        dictationColors = listOf(c(0xE91E8C), c(0x00ACC1)),
    )

    // MARK: Sakura
    private val sakuraDark = ChatPalette(
        themeID = ChatThemeID.SAKURA,
        backgroundColors = listOf(c(0x3a2233), c(0x2a1626), c(0x170b13)),
        panelTint = rgba(40, 20, 34, 0.42f),
        userFill = listOf(rgba(230, 90, 140, 0.45f)), userText = c(0xffeef5),
        userCorners = Corners(20, 20, 6, 20),
        assistantFill = rgba(60, 28, 48, 0.6f), assistantText = c(0xffeef5),
        assistantCorners = Corners(20, 20, 20, 6),
        assistantGlyph = "❀", glyphColor = c(0xF48FB1),
        accent = c(0xF06292), primaryText = c(0xffeef5), secondaryText = rgba(255, 190, 215, 0.75f),
        inputFill = rgba(255, 170, 205, 0.08f), inputStroke = rgba(255, 170, 205, 0.3f), inputRadius = 15,
        placeholderColor = rgba(255, 190, 215, 0.45f), placeholder = "Напиши что-нибудь милое…",
        divider = BubbleStroke(rgba(255, 170, 205, 0.2f), width = 1f),
        sendFill = listOf(c(0xF06292)), sendGlyph = Color.White, sendGlow = rgba(240, 98, 146, 0.45f),
        micFill = rgba(255, 170, 205, 0.12f), micGlyphColor = c(0xffc3d8), micDashed = false,
        timestampColor = rgba(255, 190, 215, 0.55f), timestampStyle = TimestampStyle.FLOWER,
        codeFill = rgba(255, 170, 205, 0.12f), codeText = c(0xffb7cf),
        dictationColors = listOf(c(0xF48FB1)), bulletGlyph = "❀",
        decoration = ThemeDecoration.SAKURA,
    )
    private val sakuraLight = ChatPalette(
        themeID = ChatThemeID.SAKURA,
        backgroundColors = listOf(c(0xffe9f1), c(0xfdd9e6), c(0xf2b9cf)),
        panelTint = rgba(255, 250, 252, 0.5f),
        userFill = listOf(rgba(245, 140, 175, 0.5f)), userText = c(0x42101f),
        userCorners = Corners(20, 20, 6, 20),
        assistantFill = rgba(255, 255, 255, 0.68f), assistantText = c(0x42101f),
        assistantCorners = Corners(20, 20, 20, 6),
        assistantGlyph = "❀", glyphColor = c(0xEC5F8F),
        accent = c(0xEC5F8F), primaryText = c(0x42101f), secondaryText = rgba(190, 70, 115, 0.75f),
        inputFill = rgba(255, 255, 255, 0.6f), inputStroke = rgba(230, 100, 150, 0.3f), inputRadius = 15,
        placeholderColor = rgba(190, 70, 115, 0.45f), placeholder = "Напиши что-нибудь милое…",
        divider = BubbleStroke(rgba(230, 100, 150, 0.25f), width = 1f),
        sendFill = listOf(c(0xEC5F8F)), sendGlyph = Color.White, sendGlow = rgba(236, 95, 143, 0.4f),
        micFill = rgba(255, 255, 255, 0.6f), micGlyphColor = c(0xD8447A), micDashed = false,
        timestampColor = rgba(190, 70, 115, 0.6f), timestampStyle = TimestampStyle.FLOWER,
        codeFill = rgba(230, 100, 150, 0.1f), codeText = c(0xa33361),
        dictationColors = listOf(c(0xEC5F8F)), bulletGlyph = "❀",
        decoration = ThemeDecoration.SAKURA,
    )

    // MARK: Pastel
    private val pastelDark = ChatPalette(
        themeID = ChatThemeID.PASTEL,
        backgroundColors = listOf(c(0x2e2840), c(0x231d33), c(0x141020)),
        panelTint = rgba(35, 28, 50, 0.42f),
        userFill = listOf(rgba(179, 157, 219, 0.5f), rgba(255, 171, 145, 0.45f)), userText = c(0xf7f0ff),
        userCorners = Corners(22),
        assistantFill = rgba(50, 40, 70, 0.6f), assistantText = c(0xf7f0ff),
        assistantCorners = Corners(22),
        assistantGlyph = "♡", glyphColor = c(0xCDB6F5),
        accent = c(0xB39DDB), primaryText = c(0xf7f0ff), secondaryText = rgba(215, 195, 255, 0.6f),
        inputFill = rgba(200, 175, 255, 0.08f), inputStroke = rgba(200, 175, 255, 0.3f), inputRadius = 18,
        placeholderColor = rgba(215, 195, 255, 0.5f),
        divider = BubbleStroke(rgba(200, 175, 255, 0.2f), width = 1f),
        sendFill = listOf(c(0xB39DDB), c(0xF48FB1)),
        sendGlyph = Color.White, sendGlow = rgba(179, 157, 219, 0.45f),
        micFill = rgba(200, 175, 255, 0.14f), micGlyphColor = c(0xe2d4ff), micDashed = false,
        timestampColor = rgba(215, 195, 255, 0.55f), timestampStyle = TimestampStyle.PLAIN,
        codeFill = rgba(200, 175, 255, 0.14f), codeText = c(0xd5c3ff),
        dictationColors = listOf(c(0xB39DDB), c(0xF48FB1), c(0xFFAB91)), bulletGlyph = "✦",
        decoration = ThemeDecoration.PASTEL,
    )
    private val pastelLight = ChatPalette(
        themeID = ChatThemeID.PASTEL,
        backgroundColors = listOf(c(0xf3ecff), c(0xecdcf5), c(0xdcc4ea)),
        panelTint = rgba(255, 252, 255, 0.5f),
        userFill = listOf(rgba(179, 157, 219, 0.55f), rgba(255, 171, 145, 0.5f)), userText = c(0x2d1846),
        userCorners = Corners(22),
        assistantFill = rgba(255, 255, 255, 0.7f), assistantText = c(0x2d1846),
        assistantCorners = Corners(22),
        assistantGlyph = "♡", glyphColor = c(0x9575CD),
        accent = c(0x9575CD), primaryText = c(0x2d1846), secondaryText = rgba(120, 85, 180, 0.65f),
        inputFill = rgba(255, 255, 255, 0.6f), inputStroke = rgba(150, 110, 210, 0.3f), inputRadius = 18,
        placeholderColor = rgba(120, 85, 180, 0.5f),
        divider = BubbleStroke(rgba(150, 110, 210, 0.22f), width = 1f),
        sendFill = listOf(c(0x9575CD), c(0xF06292)),
        sendGlyph = Color.White, sendGlow = rgba(149, 117, 205, 0.4f),
        micFill = rgba(255, 255, 255, 0.6f), micGlyphColor = c(0x7E57C2), micDashed = false,
        timestampColor = rgba(120, 85, 180, 0.6f), timestampStyle = TimestampStyle.PLAIN,
        codeFill = rgba(150, 110, 210, 0.1f), codeText = c(0x6a44a8),
        dictationColors = listOf(c(0x9575CD), c(0xF06292), c(0xFF8A65)), bulletGlyph = "✦",
        decoration = ThemeDecoration.PASTEL,
    )

    // MARK: Halloween
    private val halloweenDark = ChatPalette(
        themeID = ChatThemeID.HALLOWEEN,
        backgroundColors = listOf(c(0x2b1d3e), c(0x1c1130), c(0x0d0618)),
        panelTint = rgba(30, 16, 48, 0.45f), glassSurface = true,
        userFill = listOf(rgba(230, 110, 20, 0.45f)), userText = c(0xfff2e4),
        userCorners = Corners(16),
        assistantFill = rgba(45, 24, 66, 0.65f), assistantText = c(0xfff2e4),
        assistantStroke = BubbleStroke(rgba(255, 140, 60, 0.2f)), assistantCorners = Corners(16),
        assistantGlyph = "🎃", glyphColor = c(0xFF9E4F),
        accent = c(0xFF7A1A), primaryText = c(0xfff2e4), secondaryText = rgba(255, 190, 130, 0.8f),
        accentInk = c(0xFF9E4F),
        inputFill = rgba(255, 140, 60, 0.07f), inputStroke = rgba(255, 140, 60, 0.3f), inputRadius = 6,
        placeholderColor = rgba(255, 190, 130, 0.45f), placeholder = "Whisper something spooky…",
        divider = BubbleStroke(rgba(255, 140, 60, 0.22f), width = 1f),
        sendFill = listOf(c(0xFF7A1A)), sendGlyph = c(0xFFE082), sendGlow = rgba(255, 150, 40, 0.7f),
        micStroke = rgba(186, 104, 200, 0.55f), micFill = rgba(171, 71, 188, 0.18f),
        micGlyphColor = c(0xE1BEE7), micDashed = false,
        timestampColor = rgba(255, 190, 130, 0.6f), timestampStyle = TimestampStyle.LOWER_MERIDIEM,
        codeFill = rgba(255, 190, 130, 0.12f), codeText = c(0xFFD9B8),
        inlineCodeFill = rgba(255, 190, 130, 0.14f), inlineCodeText = c(0xFFB27A),
        bulletColor = c(0xfff2e4), quoteColor = rgba(255, 122, 26, 0.6f),
        dictationColors = listOf(c(0xFF9E4F)), recordingAccent = c(0xFF7A1A),
        decoration = ThemeDecoration.HALLOWEEN,
    )
    private val halloweenLight = ChatPalette(
        themeID = ChatThemeID.HALLOWEEN,
        backgroundColors = listOf(c(0xffe9d2), c(0xf7d4b0), c(0xe0ab84)),
        panelTint = rgba(255, 249, 242, 0.5f), glassSurface = true,
        userFill = listOf(rgba(255, 150, 60, 0.5f)), userText = c(0x3c1a02),
        userCorners = Corners(16),
        assistantFill = rgba(255, 255, 255, 0.68f), assistantText = c(0x3c1a02),
        assistantStroke = BubbleStroke(rgba(150, 70, 20, 0.18f)), assistantCorners = Corners(16),
        assistantGlyph = "🎃", glyphColor = c(0xB4560E),
        accent = c(0xE8650F), primaryText = c(0x3c1a02), secondaryText = rgba(150, 70, 20, 0.8f),
        accentInk = c(0xB4560E),
        inputFill = rgba(255, 255, 255, 0.55f), inputStroke = rgba(200, 100, 30, 0.35f), inputRadius = 6,
        placeholderColor = rgba(150, 70, 20, 0.5f), placeholder = "Whisper something spooky…",
        divider = BubbleStroke(rgba(200, 100, 30, 0.3f), width = 1f),
        sendFill = listOf(c(0xE8650F)), sendGlyph = Color.White, sendGlow = rgba(232, 101, 15, 0.5f),
        micStroke = rgba(123, 31, 162, 0.45f), micFill = rgba(255, 255, 255, 0.55f),
        micGlyphColor = c(0x7B1FA2), micDashed = false,
        timestampColor = rgba(150, 70, 20, 0.65f), timestampStyle = TimestampStyle.LOWER_MERIDIEM,
        codeFill = rgba(200, 100, 30, 0.1f), codeText = c(0x7a3a05),
        inlineCodeFill = rgba(200, 100, 30, 0.12f), inlineCodeText = c(0x9c4a08),
        bulletColor = c(0x3c1a02), quoteColor = rgba(232, 101, 15, 0.6f),
        dictationColors = listOf(c(0xB4560E)), recordingAccent = c(0xE8650F),
        decoration = ThemeDecoration.HALLOWEEN,
    )

    // MARK: Día de Muertos
    private val diaDark = ChatPalette(
        themeID = ChatThemeID.DIA_DE_MUERTOS,
        backgroundColors = listOf(c(0x33163a), c(0x25102e), c(0x120718)),
        panelTint = rgba(38, 16, 44, 0.45f), glassSurface = true,
        userFill = listOf(rgba(216, 40, 100, 0.48f)), userText = c(0xfff0e0),
        userStroke = BubbleStroke(rgba(255, 179, 0, 0.6f), width = 2f, dash = listOf(1f, 3f), bottomOnly = true),
        userCorners = Corners(16),
        assistantFill = rgba(50, 22, 58, 0.68f), assistantText = c(0xfff0e0),
        assistantStroke = BubbleStroke(rgba(38, 166, 154, 0.6f), width = 2f, dash = listOf(1f, 3f), bottomOnly = true),
        assistantCorners = Corners(16),
        assistantGlyph = "💀", glyphColor = c(0xFFB300),
        accent = c(0xFFB300), primaryText = c(0xfff0e0), secondaryText = rgba(255, 210, 120, 0.8f),
        accentInk = c(0xFFB300),
        inputFill = rgba(255, 179, 0, 0.07f), inputStroke = rgba(255, 179, 0, 0.3f), inputRadius = 6,
        placeholderColor = rgba(255, 210, 120, 0.45f), placeholder = "Escribe algo, mi alma…",
        divider = BubbleStroke(rgba(255, 179, 0, 0.35f), width = 2f, dash = listOf(1f, 3f)),
        sendFill = listOf(c(0xFFB300)), sendGlyph = c(0x4A1030), sendGlow = rgba(255, 179, 0, 0.5f),
        micColor = c(0x7fd8cf), micStroke = c(0x26A69A),
        timestampColor = rgba(255, 210, 120, 0.6f), timestampStyle = TimestampStyle.PLAIN,
        codeFill = rgba(255, 210, 120, 0.12f), codeText = c(0xFFE3AE),
        inlineCodeFill = rgba(255, 210, 120, 0.14f), inlineCodeText = c(0xFFCE7A),
        bulletGlyph = "✿", quoteColor = rgba(236, 64, 122, 0.7f),
        dictationColors = listOf(c(0xFFB300), c(0xEC407A), c(0x26A69A)),
        recordingAccent = c(0xEC407A), voiceProgress = c(0xFFD54F),
        decoration = ThemeDecoration.DIA,
    )
    private val diaLight = ChatPalette(
        themeID = ChatThemeID.DIA_DE_MUERTOS,
        backgroundColors = listOf(c(0xffe9c4), c(0xffd9a8), c(0xf0ae74)),
        panelTint = rgba(255, 250, 240, 0.5f), glassSurface = true,
        userFill = listOf(rgba(240, 110, 160, 0.5f)), userText = c(0x3d0d20),
        userStroke = BubbleStroke(rgba(200, 110, 0, 0.6f), width = 2f, dash = listOf(1f, 3f), bottomOnly = true),
        userCorners = Corners(16),
        assistantFill = rgba(255, 255, 255, 0.7f), assistantText = c(0x3d0d20),
        assistantStroke = BubbleStroke(rgba(0, 137, 123, 0.55f), width = 2f, dash = listOf(1f, 3f), bottomOnly = true),
        assistantCorners = Corners(16),
        assistantGlyph = "💀", glyphColor = c(0xF59E00),
        accent = c(0xF59E00), primaryText = c(0x3d0d20), secondaryText = rgba(170, 80, 10, 0.85f),
        accentInk = c(0xC77800),
        inputFill = rgba(255, 255, 255, 0.55f), inputStroke = rgba(200, 110, 0, 0.35f), inputRadius = 6,
        placeholderColor = rgba(170, 80, 10, 0.5f), placeholder = "Escribe algo, mi alma…",
        divider = BubbleStroke(rgba(200, 110, 0, 0.4f), width = 2f, dash = listOf(1f, 3f)),
        sendFill = listOf(c(0xF59E00)), sendGlyph = Color.White, sendGlow = rgba(216, 27, 96, 0.4f),
        micColor = c(0x00897B), micStroke = c(0x00897B),
        timestampColor = rgba(170, 80, 10, 0.65f), timestampStyle = TimestampStyle.PLAIN,
        codeFill = rgba(200, 110, 0, 0.1f), codeText = c(0x7a4a00),
        inlineCodeFill = rgba(200, 110, 0, 0.12f), inlineCodeText = c(0x9a5c00),
        bulletGlyph = "✿", quoteColor = rgba(216, 27, 96, 0.6f),
        dictationColors = listOf(c(0xF59E00), c(0xD81B60), c(0x00897B)),
        recordingAccent = c(0xD81B60),
        decoration = ThemeDecoration.DIA,
    )
}
