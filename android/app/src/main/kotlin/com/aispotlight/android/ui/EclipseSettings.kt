package com.aispotlight.android.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextFieldColors
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * "Eclipse" settings design system — the claude.ai/design prototype
 * («Редизайн меню настроек Eclipse») ported 1:1: settings get their own
 * look, independent of the chat theme. Glass card stacks with hairline
 * dividers, uppercase accent section headers, and the app icon's eclipse
 * orange as the single accent (switches, chips, primary buttons glow).
 *
 * Two palettes — dark (radial near-black) and light (warm cream); the
 * System/Light/Dark appearance setting picks between them.
 */
class EclipsePalette(
    val dark: Boolean,
    /** Page background, radial from top-center: [center, mid, edge]. */
    val bgColors: List<Color>,
    val text: Color,
    val sub: Color,
    val accent: Color,
    val chevron: Color,
    /** Card stack: subtle vertical gradient + 1dp border + soft glow shadow. */
    val stackTop: Color,
    val stackBottom: Color,
    val stackBorder: Color,
    val divider: Color,
    val iconBg: Color,
    val iconBorder: Color,
    val switchBg: Color,
    val switchBorder: Color,
    val switchKnob: Color,
    val switchOnKnob: Color,
    val chipBg: Color,
    val chipText: Color,
    val chipBorder: Color,
    val chipSelBg: Color,
    val chipSelText: Color,
    val chipSelBorder: Color,
    val fieldBorder: Color,
    val fieldBg: Color,
    val primaryText: Color,
    val ok: Color,
    val delete: Color,
    val deleteBorder: Color,
    val track: Color,
    val thumb: Color,
    val areaBg: Color,
    val areaBorder: Color,
    val areaText: Color,
    val edited: Color,
    /** Eclipse-orange used for glow shadows around lit elements. */
    val glow: Color,
) {
    /** Switch-on / slider fill gradient (burnt → bright orange). */
    val accentGradient = listOf(Color(0xFFB4560F), Color(0xFFF08A2E))

    /** Primary button gradient. */
    val primaryGradient = listOf(Color(0xFFE07B1F), Color(0xFFF5A05A))
}

private val EclipseDark = EclipsePalette(
    dark = true,
    bgColors = listOf(Color(0xFF141018), Color(0xFF08070A), Color(0xFF050506)),
    text = Color(0xFFECEAF0),
    sub = Color(0xFF9C97A6),
    accent = Color(0xFFF0955A),
    chevron = Color(0xFF8A8494),
    stackTop = Color.White.copy(alpha = 0.055f),
    stackBottom = Color.White.copy(alpha = 0.028f),
    stackBorder = Color.White.copy(alpha = 0.09f),
    divider = Color.White.copy(alpha = 0.06f),
    iconBg = Color.White.copy(alpha = 0.06f),
    iconBorder = Color.White.copy(alpha = 0.08f),
    switchBg = Color.White.copy(alpha = 0.09f),
    switchBorder = Color.White.copy(alpha = 0.14f),
    switchKnob = Color(0xFF8A8494),
    switchOnKnob = Color(0xFFFFF4E8),
    chipBg = Color.White.copy(alpha = 0.05f),
    chipText = Color(0xFFC9C4D2),
    chipBorder = Color.White.copy(alpha = 0.10f),
    chipSelBg = Color(0xFFF08A2E).copy(alpha = 0.16f),
    chipSelText = Color(0xFFFFC896),
    chipSelBorder = Color(0xFFF08A2E).copy(alpha = 0.55f),
    fieldBorder = Color.White.copy(alpha = 0.13f),
    fieldBg = Color.Black.copy(alpha = 0.25f),
    primaryText = Color(0xFF1A0F05),
    ok = Color(0xFF59D08A),
    delete = Color(0xFFFF7A70),
    deleteBorder = Color(0xFFFF6E64).copy(alpha = 0.4f),
    track = Color.White.copy(alpha = 0.10f),
    thumb = Color(0xFFF5A05A),
    areaBg = Color.Black.copy(alpha = 0.30f),
    areaBorder = Color.White.copy(alpha = 0.10f),
    areaText = Color(0xFFD8D4E0),
    edited = Color(0xFFF0B27A),
    glow = Color(0xFFFF8C2E),
)

private val EclipseLight = EclipsePalette(
    dark = false,
    bgColors = listOf(Color(0xFFFFF1E2), Color(0xFFFAF5EF), Color(0xFFF2EDE6)),
    text = Color(0xFF26201B),
    sub = Color(0xFF8B8177),
    accent = Color(0xFFC2610F),
    chevron = Color(0xFFB3A99D),
    stackTop = Color(0xFFFFFFFF),
    stackBottom = Color(0xFFFFFCF7),
    stackBorder = Color(0xFF503214).copy(alpha = 0.10f),
    divider = Color(0xFF503214).copy(alpha = 0.07f),
    iconBg = Color(0xFFF08A2E).copy(alpha = 0.09f),
    iconBorder = Color(0xFFF08A2E).copy(alpha = 0.18f),
    switchBg = Color(0xFFEEE6DB),
    switchBorder = Color(0xFFDFD4C6),
    switchKnob = Color(0xFFA79C8F),
    switchOnKnob = Color(0xFFFFF4E8),
    chipBg = Color(0xFFF7F1E9),
    chipText = Color(0xFF5C5347),
    chipBorder = Color(0xFFE7DCCC),
    chipSelBg = Color(0xFFF08A2E).copy(alpha = 0.13f),
    chipSelText = Color(0xFFA6500A),
    chipSelBorder = Color(0xFFC86E1E).copy(alpha = 0.45f),
    fieldBorder = Color(0xFFE2D7C8),
    fieldBg = Color(0xFFFFFFFF),
    primaryText = Color(0xFF1A0F05),
    ok = Color(0xFF1E9C5A),
    delete = Color(0xFFC2321F),
    deleteBorder = Color(0xFFC2321F).copy(alpha = 0.35f),
    track = Color(0xFFEDE2D3),
    thumb = Color(0xFFE07B1F),
    areaBg = Color(0xFFFBF7F1),
    areaBorder = Color(0xFFE7DCCC),
    areaText = Color(0xFF4C453C),
    edited = Color(0xFFB06010),
    glow = Color(0xFFF08A2E),
)

val LocalEclipsePalette = staticCompositionLocalOf { EclipseDark }

@Composable
fun EclipseSettingsTheme(dark: Boolean, content: @Composable () -> Unit) {
    androidx.compose.runtime.CompositionLocalProvider(
        LocalEclipsePalette provides if (dark) EclipseDark else EclipseLight,
        content = content,
    )
}

/** Page background: radial gradient falling from above the top edge. */
fun Modifier.eclipseBackground(palette: EclipsePalette): Modifier = drawBehind {
    drawRect(
        Brush.radialGradient(
            colors = palette.bgColors,
            center = Offset(size.width / 2f, -size.height * 0.1f),
            radius = maxOf(size.height * 1.2f, size.width),
        )
    )
}

// MARK: - Controls

/** 48×28 eclipse switch: orange gradient + glow when on. */
@Composable
fun EclipseSwitch(checked: Boolean, onCheckedChange: ((Boolean) -> Unit)?) {
    val ecl = LocalEclipsePalette.current
    val knobX by animateDpAsState(if (checked) 21.dp else 2.dp, label = "knob")
    val knobColor by animateColorAsState(
        if (checked) ecl.switchOnKnob else ecl.switchKnob, label = "knobColor",
    )
    Box(
        Modifier
            .size(48.dp, 28.dp)
            .then(if (checked) {
                Modifier.themedGlow(ecl.glow.copy(alpha = 0.55f), 5.dp, cornerRadius = 14.dp)
            } else Modifier)
            .background(
                if (checked) Brush.horizontalGradient(ecl.accentGradient)
                else androidx.compose.ui.graphics.SolidColor(ecl.switchBg),
                RoundedCornerShape(14.dp),
            )
            .border(1.dp, if (checked) Color.Transparent else ecl.switchBorder, RoundedCornerShape(14.dp))
            .then(if (onCheckedChange != null) {
                Modifier.clickable { onCheckedChange(!checked) }
            } else Modifier),
    ) {
        Box(
            Modifier
                .offset(x = knobX)
                .align(Alignment.CenterStart)
                .size(22.dp)
                .background(knobColor, CircleShape),
        )
    }
}

/** Selection chip: translucent glass, orange glow when selected. */
@Composable
fun EclipseChip(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val ecl = LocalEclipsePalette.current
    val shape = RoundedCornerShape(9.dp)
    Box(
        modifier
            .then(if (selected) {
                Modifier.themedGlow(ecl.glow.copy(alpha = 0.45f), 4.dp, cornerRadius = 9.dp)
            } else Modifier)
            .background(if (selected) ecl.chipSelBg else ecl.chipBg, shape)
            .border(1.dp, if (selected) ecl.chipSelBorder else ecl.chipBorder, shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 7.dp),
    ) {
        Text(
            label,
            fontSize = 13.5.sp,
            maxLines = 1,
            fontWeight = if (selected) FontWeight.Medium else FontWeight.Normal,
            color = if (selected) ecl.chipSelText else ecl.chipText,
        )
    }
}

/** Gradient pill button (the design's «Проверить» / «Сохранить»). */
@Composable
fun EclipsePrimaryButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    val ecl = LocalEclipsePalette.current
    val shape = RoundedCornerShape(20.dp)
    Box(
        modifier
            .then(if (enabled) {
                Modifier.themedGlow(ecl.glow.copy(alpha = 0.5f), 6.dp, cornerRadius = 20.dp)
            } else Modifier)
            .background(
                Brush.linearGradient(
                    if (enabled) ecl.primaryGradient
                    else ecl.primaryGradient.map { it.copy(alpha = 0.4f) }
                ),
                shape,
            )
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 9.dp),
    ) {
        Text(
            text,
            fontSize = 13.5.sp,
            maxLines = 1,
            fontWeight = FontWeight.SemiBold,
            color = if (enabled) ecl.primaryText else ecl.primaryText.copy(alpha = 0.6f),
        )
    }
}

/** Accent text button (the design's «Обновить список моделей»). */
@Composable
fun EclipseTextButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    val ecl = LocalEclipsePalette.current
    Text(
        text,
        fontSize = 13.5.sp,
        fontWeight = FontWeight.Medium,
        color = if (enabled) ecl.accent else ecl.accent.copy(alpha = 0.4f),
        modifier = modifier
            .clickable(enabled = enabled, onClick = onClick)
            .padding(vertical = 9.dp, horizontal = 4.dp),
    )
}

/** Outline chip-button (the design's «+ Добавить»). */
@Composable
fun EclipseOutlineButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val ecl = LocalEclipsePalette.current
    val shape = RoundedCornerShape(20.dp)
    Box(
        modifier
            .border(1.dp, ecl.chipSelBorder, shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 7.dp),
    ) {
        Text(text, fontSize = 13.sp, fontWeight = FontWeight.Medium, maxLines = 1, color = ecl.accent)
    }
}

/** OutlinedTextField colors mapped onto the eclipse palette. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun eclipseFieldColors(): TextFieldColors {
    val ecl = LocalEclipsePalette.current
    return OutlinedTextFieldDefaults.colors(
        focusedTextColor = ecl.text,
        unfocusedTextColor = ecl.text,
        disabledTextColor = ecl.sub,
        focusedContainerColor = ecl.fieldBg,
        unfocusedContainerColor = ecl.fieldBg,
        disabledContainerColor = ecl.fieldBg,
        cursorColor = ecl.accent,
        focusedBorderColor = ecl.accent,
        unfocusedBorderColor = ecl.fieldBorder,
        disabledBorderColor = ecl.fieldBorder,
        focusedLabelColor = ecl.accent,
        unfocusedLabelColor = ecl.sub,
        disabledLabelColor = ecl.sub,
        focusedTrailingIconColor = ecl.sub,
        unfocusedTrailingIconColor = ecl.sub,
    )
}

/** Slider in eclipse colors (orange fill, glowing thumb). */
@Composable
fun EclipseSlider(
    value: Float,
    onValueChange: (Float) -> Unit,
    valueRange: ClosedFloatingPointRange<Float>,
    steps: Int = 0,
    modifier: Modifier = Modifier,
) {
    val ecl = LocalEclipsePalette.current
    Slider(
        value = value,
        onValueChange = onValueChange,
        valueRange = valueRange,
        steps = steps,
        modifier = modifier,
        colors = SliderDefaults.colors(
            thumbColor = ecl.thumb,
            activeTrackColor = Color(0xFFF08A2E),
            inactiveTrackColor = ecl.track,
            activeTickColor = ecl.primaryText.copy(alpha = 0.4f),
            inactiveTickColor = ecl.sub.copy(alpha = 0.4f),
        ),
    )
}

/** Circular provider brand badge (A / O / G …). */
@Composable
fun EclipseBadge(letter: String, color: Color) {
    Box(
        Modifier.size(26.dp).background(color, CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            letter,
            color = if (color.luminance() > 0.6f) Color(0xFF083D26) else Color.White,
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.Bold,
        )
    }
}

private fun Color.luminance(): Float = 0.299f * red + 0.587f * green + 0.114f * blue
