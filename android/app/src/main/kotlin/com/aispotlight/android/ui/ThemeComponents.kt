package com.aispotlight.android.ui

import android.graphics.BlurMaskFilter
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.drawOutline
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/**
 * Shared themed building blocks — ports of the small signature components in
 * `AppTheme.swift` (glows, themed strokes, Blueprint corner marks, Terminal's
 * blinking caret, the themed composer divider, Día's tapered dotted edge).
 */

// MARK: - Glow

/**
 * Soft colored halo behind the content (the mac `.shadow(color:radius:)` neon
 * glow — Synthwave send button, Terminal green bloom, Día marigold). Draws a
 * blurred rounded rect through the framework Paint, so it works on every API
 * level and in any color.
 */
fun Modifier.themedGlow(color: Color?, radius: Dp, cornerRadius: Dp? = null, yOffset: Dp = 0.dp): Modifier {
    if (color == null || color.alpha == 0f) return this
    return drawBehind {
        val blurPx = radius.toPx()
        val frameworkPaint = Paint().asFrameworkPaint().apply {
            this.color = color.toArgb()
            maskFilter = BlurMaskFilter(blurPx, BlurMaskFilter.Blur.NORMAL)
        }
        val r = cornerRadius?.toPx() ?: (min(size.width, size.height) / 2f)
        drawContext.canvas.nativeCanvas.drawRoundRect(
            0f, yOffset.toPx(), size.width, size.height + yOffset.toPx(), r, r, frameworkPaint,
        )
    }
}

// MARK: - Bubble stroke

/**
 * Bubble border in the theme's own stroke: full dashed/solid outline
 * (Blueprint [4,3], Terminal solid) or the Día `bottomOnly` variant — a
 * dotted underline hugging the bubble's bottom edge whose dots TAPER along
 * the corner curls (CSS border-bottom on a rounded rect).
 */
fun Modifier.bubbleStroke(shape: Shape, stroke: BubbleStroke?, cornerRadius: Dp): Modifier {
    if (stroke == null) return this
    return drawBehind {
        if (stroke.bottomOnly) {
            drawTaperedDottedBottomEdge(stroke, cornerRadius.toPx())
        } else {
            val outline = shape.createOutline(size, layoutDirection, this)
            drawOutline(
                outline,
                color = stroke.color,
                style = Stroke(
                    width = stroke.width.dp.toPx(),
                    pathEffect = if (stroke.dash.isNotEmpty()) {
                        PathEffect.dashPathEffect(stroke.dash.map { it.dp.toPx() }.toFloatArray())
                    } else null,
                ),
            )
        }
    }
}

/**
 * Port of the mac `TaperedDottedBottomEdge` Canvas: the straight bottom run
 * plus the two rounded bottom corners, sampled as a polyline with a per-point
 * taper factor so the dots shrink toward the corner tips.
 */
private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawTaperedDottedBottomEdge(
    stroke: BubbleStroke,
    inset: Float,
) {
    val width = stroke.width * density   // dot diameter on the straight run (dp→px)
    val lift = width / 2f                // half the stroke, dots sit inside
    // Cap the corner curl so a narrow bubble's underline stays mostly flat.
    val r = max(0f, minOf(inset, size.height / 2f, size.width * 0.32f))
    val y = size.height - lift
    val minScale = 0.3f                  // dot size at the very tips

    fun quad(a: Offset, c: Offset, b: Offset, t: Float): Offset {
        val u = 1 - t
        return Offset(
            u * u * a.x + 2 * u * t * c.x + t * t * b.x,
            u * u * a.y + 2 * u * t * c.y + t * t * b.y,
        )
    }

    // Left curl (taper up) → straight run (full) → right curl (down).
    val samples = mutableListOf<Pair<Offset, Float>>()
    val n = 10
    val lp0 = Offset(lift, y - r); val lc = Offset(lift, y); val lp1 = Offset(r, y)
    for (i in 0..n) {
        val t = i / n.toFloat()
        samples.add(quad(lp0, lc, lp1, t) to (minScale + (1 - minScale) * t))
    }
    samples.add(Offset(size.width - r, y) to 1f)
    val rp0 = Offset(size.width - r, y)
    val rc = Offset(size.width - lift, y)
    val rp1 = Offset(size.width - lift, y - r)
    for (i in 1..n) {
        val t = i / n.toFloat()
        samples.add(quad(rp0, rc, rp1, t) to (1f - (1 - minScale) * t))
    }

    // Cumulative arc length, then walk it dropping a dot every period.
    val cum = mutableListOf(0f)
    for (i in 1 until samples.size) {
        cum.add(cum[i - 1] + hypot(
            samples[i].first.x - samples[i - 1].first.x,
            samples[i].first.y - samples[i - 1].first.y,
        ))
    }
    val total = cum.last()
    if (total <= 0f) return

    val spacing = width * 2f   // ≈ CSS `dotted` period (2px dot / 2px gap)
    var d = spacing / 2f
    var seg = 1
    while (d < total) {
        while (seg < samples.size - 1 && cum[seg] < d) seg++
        val t = (d - cum[seg - 1]) / max(cum[seg] - cum[seg - 1], 0.001f)
        val p = Offset(
            samples[seg - 1].first.x + (samples[seg].first.x - samples[seg - 1].first.x) * t,
            samples[seg - 1].first.y + (samples[seg].first.y - samples[seg - 1].first.y) * t,
        )
        val dia = width * (samples[seg - 1].second + (samples[seg].second - samples[seg - 1].second) * t)
        drawCircle(stroke.color, radius = dia / 2f, center = p)
        d += spacing
    }
}

// MARK: - Blueprint corner marks

/**
 * Blueprint's engineering reference crosses: a small `+` reper in each of the
 * four panel corners. Insets match the spec (8dp horizontal, 6dp vertical).
 */
@Composable
fun BlueprintCornerMarks(color: Color, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxSize().padding(horizontal = 8.dp, vertical = 6.dp)) {
        for (alignment in listOf(
            Alignment.TopStart, Alignment.TopEnd, Alignment.BottomStart, Alignment.BottomEnd,
        )) {
            Text(
                "+",
                color = color,
                fontSize = 10.sp,
                fontFamily = FontFamily.Monospace,
                modifier = Modifier.align(alignment),
            )
        }
    }
}

// MARK: - Composer divider

/**
 * Composer top divider: themes with `palette.divider` get a themed line —
 * dashed for Blueprint, dotted (round caps) for Día — in their own accent.
 */
@Composable
fun ThemedComposerDivider(palette: ChatPalette, modifier: Modifier = Modifier) {
    val d = palette.divider
    if (d == null || palette.isDynamic) {
        androidx.compose.material3.HorizontalDivider(modifier)
        return
    }
    Canvas(modifier.fillMaxWidth().height(max(1f, d.width).dp)) {
        drawLine(
            d.color,
            Offset(0f, size.height / 2f),
            Offset(size.width, size.height / 2f),
            strokeWidth = d.width.dp.toPx(),
            cap = androidx.compose.ui.graphics.StrokeCap.Round,
            // Round caps make Día's [1,3] dash read as round dots (Blueprint's
            // [4,3] still reads as dashes) — same trick as the mac divider.
            pathEffect = if (d.dash.isNotEmpty()) {
                PathEffect.dashPathEffect(d.dash.map { it.dp.toPx() }.toFloatArray())
            } else null,
        )
    }
}

// MARK: - Blinking caret (Terminal)

/**
 * Terminal's signature blinking block caret, shown after the composer
 * placeholder («$ type your message▮»). A hard on/off blink every 0.55s,
 * matching the design spec's `blink 1.1s step-end`.
 */
@Composable
fun BlinkingCaret(color: Color, width: Dp = 7.dp, height: Dp = 14.dp, modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "caret")
    val t by transition.animateFloat(
        initialValue = 0f, targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(1100, easing = LinearEasing), RepeatMode.Restart),
        label = "blink",
    )
    Box(
        modifier
            .size(width, height)
            .alpha(if (t < 0.5f) 1f else 0f)
            .drawBehind { drawRoundRect(color, cornerRadius = androidx.compose.ui.geometry.CornerRadius(1.dp.toPx())) },
    )
}

// MARK: - Theme thumbnail (Settings picker)

/**
 * One theme's miniature for the Settings grid — port of the mac
 * `ThemeGridPicker` thumbnail: the panel background with a pair of bubble
 * pills and the send accent dot, rendered from the live palette so previews
 * follow light/dark and never drift from the real look.
 */
@Composable
fun ThemeThumbnailCell(
    theme: ChatThemeID,
    dark: Boolean,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val palette = ChatThemes.palette(theme, dark)
    val shape = androidx.compose.foundation.shape.RoundedCornerShape(8.dp)
    // Material roles hoisted out of drawBehind (composable reads not allowed
    // there). In the Eclipse settings the selection ring and labels come from
    // the eclipse palette so the grid matches the surrounding chrome.
    val scheme = androidx.compose.material3.MaterialTheme.colorScheme
    val ecl = LocalEclipsePalette.current
    val accent = ecl.accent
    val dynSurface = scheme.surfaceVariant
    val dynUser = scheme.primary.copy(alpha = 0.5f)
    val dynAssistant = scheme.onSurface.copy(alpha = 0.25f)

    androidx.compose.foundation.layout.Column(
        modifier
            .clip(androidx.compose.foundation.shape.RoundedCornerShape(10.dp))
            .clickable(onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(64.dp)
                .clip(shape)
                .drawBehind {
                    // Background — mirrors themedPanelSurface's stacking.
                    if (palette.isDynamic) {
                        drawRect(dynSurface)
                    } else if (palette.radialBackground) {
                        drawRect(
                            androidx.compose.ui.graphics.Brush.radialGradient(
                                colors = palette.backgroundColors,
                                center = Offset(size.width * 0.25f, size.height * 0.10f),
                                radius = size.width,
                            )
                        )
                        if (palette.glassSurface) drawRect(palette.panelTint)
                    } else {
                        drawRect(androidx.compose.ui.graphics.Brush.verticalGradient(palette.backgroundColors))
                    }
                }
                .border(
                    width = if (selected) 2.dp else 1.dp,
                    color = if (selected) accent else ecl.stackBorder,
                    shape = shape,
                ),
        ) {
            // Bubble pair
            androidx.compose.foundation.layout.Column(
                Modifier.fillMaxSize().padding(8.dp),
                verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(5.dp),
            ) {
                Box(
                    Modifier
                        .align(Alignment.End)
                        .size(40.dp, 11.dp)
                        .background(
                            if (palette.isDynamic) androidx.compose.ui.graphics.SolidColor(dynUser)
                            else palette.userBrush,
                            androidx.compose.foundation.shape.CircleShape,
                        ),
                )
                Box(
                    Modifier
                        .size(50.dp, 11.dp)
                        .background(
                            if (palette.isDynamic) androidx.compose.ui.graphics.SolidColor(dynAssistant)
                            else androidx.compose.ui.graphics.SolidColor(palette.assistantFill),
                            androidx.compose.foundation.shape.CircleShape,
                        ),
                )
            }
            // Send accent
            Box(
                Modifier
                    .align(Alignment.BottomEnd)
                    .padding(6.dp)
                    .size(9.dp)
                    .background(
                        if (palette.isDynamic) androidx.compose.ui.graphics.SolidColor(accent)
                        else palette.sendBrush,
                        androidx.compose.foundation.shape.CircleShape,
                    ),
            )
        }
        Text(
            theme.displayName,
            fontSize = 11.sp,
            maxLines = 1,
            color = if (selected) ecl.text else ecl.sub,
            modifier = Modifier.padding(top = 4.dp),
        )
    }
}

// MARK: - Themed dropdown menu

/**
 * Dropdown menu in the app's visual language: the M3 Expressive 16dp rounded
 * container instead of the legacy 4dp menu card, colored from the active
 * palette — dynamic themes use the tonal surface container, decorative themes
 * their own bubble surface (Theme.kt maps the Material roles, so item text and
 * icons inherit the palette automatically).
 */
@Composable
fun ThemedDropdownMenu(
    expanded: Boolean,
    onDismissRequest: () -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit,
) {
    val palette = LocalChatPalette.current
    androidx.compose.material3.DropdownMenu(
        expanded = expanded,
        onDismissRequest = onDismissRequest,
        modifier = modifier,
        shape = androidx.compose.foundation.shape.RoundedCornerShape(16.dp),
        containerColor = if (palette.isDynamic) {
            androidx.compose.material3.MaterialTheme.colorScheme.surfaceContainer
        } else {
            // The theme's opaque bubble surface (surface = assistant solid).
            androidx.compose.material3.MaterialTheme.colorScheme.surface
        },
        content = content,
    )
}
