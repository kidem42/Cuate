package com.aispotlight.android.ui

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.cos

/**
 * Theme decoration overlays — a faithful port of the macOS ornaments
 * (`HalloweenDecorations`, `DiaDecorations`, `SakuraDecorations`,
 * `PastelDecorations`): fixed spec positions with gentle bob/sway/flicker
 * loops, not falling particles. Purely decorative: drawn above the panel
 * gradient and under the chat content, ignoring touches.
 */
@Composable
fun ThemeDecorationsOverlay(decoration: ThemeDecoration, dark: Boolean, modifier: Modifier = Modifier) {
    if (decoration == ThemeDecoration.NONE) return
    Box(modifier.fillMaxSize().graphicsLayer(alpha = 0.99f)) {
        when (decoration) {
            ThemeDecoration.SAKURA -> SakuraDecorations(dark)
            ThemeDecoration.PASTEL -> PastelDecorations(dark)
            ThemeDecoration.HALLOWEEN -> HalloweenDecorations(dark)
            ThemeDecoration.DIA -> DiaDecorations(dark)
            ThemeDecoration.NONE -> Unit
        }
    }
}

private fun drgba(r: Int, g: Int, b: Int, a: Float) =
    Color(red = r / 255f, green = g / 255f, blue = b / 255f, alpha = a)

private fun dhex(v: Long) = Color(0xFF000000 or v)

/** The design's `floaty` loop: gentle bob −6dp and back over [duration]. */
@Composable
private fun bobOffset(durationMs: Int, label: String): Dp {
    val transition = rememberInfiniteTransition(label = label)
    val y by transition.animateFloat(
        initialValue = 0f, targetValue = -6f,
        animationSpec = infiniteRepeatable(tween(durationMs / 2), RepeatMode.Reverse),
        label = label,
    )
    return y.dp
}

// MARK: - Sakura (floating cherry-blossom petals at the spec's positions)

@Composable
private fun BoxScope.SakuraDecorations(dark: Boolean) {
    fun petal(opacity: Float) =
        if (dark) drgba(255, 150, 195, opacity) else drgba(230, 100, 150, opacity)

    Text("❀", fontSize = 14.sp, color = petal(if (dark) 0.35f else 0.40f),
        modifier = Modifier.align(Alignment.TopEnd).padding(end = 22.dp, top = 34.dp)
            .offset(y = bobOffset(5000, "sakura1")))
    Text("❀", fontSize = 10.sp, color = petal(if (dark) 0.22f else 0.28f),
        modifier = Modifier.align(Alignment.TopStart).padding(start = 30.dp, top = 90.dp)
            .offset(y = bobOffset(7000, "sakura2")))
    Text("✿", fontSize = 12.sp, color = petal(if (dark) 0.18f else 0.22f),
        modifier = Modifier.align(Alignment.TopEnd).padding(end = 60.dp, top = 150.dp)
            .offset(y = bobOffset(6000, "sakura3")))
}

// MARK: - Pastel (floating sparkles — lavender + peach)

@Composable
private fun BoxScope.PastelDecorations(dark: Boolean) {
    Text("✦", fontSize = 12.sp,
        color = if (dark) drgba(200, 175, 255, 0.40f) else drgba(150, 110, 210, 0.45f),
        modifier = Modifier.align(Alignment.TopEnd).padding(end = 26.dp, top = 40.dp)
            .offset(y = bobOffset(5000, "pastel1")))
    Text("✦", fontSize = 9.sp,
        color = if (dark) drgba(255, 171, 145, 0.35f) else drgba(255, 140, 110, 0.40f),
        modifier = Modifier.align(Alignment.TopStart).padding(start = 34.dp, top = 110.dp)
            .offset(y = bobOffset(7000, "pastel2")))
}

// MARK: - Halloween (webs, dangling spider, bats, ghost)

@Composable
private fun BoxScope.HalloweenDecorations(dark: Boolean) {
    val webColor = if (dark) drgba(255, 200, 140, 0.55f) else drgba(130, 65, 15, 0.5f)

    // Big web, top-left
    Canvas(Modifier.align(Alignment.TopStart).size(90.dp).alpha(if (dark) 0.5f else 0.55f)) {
        drawPath(spiderWebPath(size, rings = 3), webColor, style = Stroke(width = 1.dp.toPx()))
    }
    // Small mirrored web, top-right
    Canvas(
        Modifier.align(Alignment.TopEnd).size(64.dp)
            .alpha(if (dark) 0.4f else 0.45f)
            .graphicsLayer(scaleX = -1f)
    ) {
        drawPath(spiderWebPath(size, rings = 2), webColor, style = Stroke(width = 1.2.dp.toPx()))
    }

    // Spider on a thread (near the small web): the dangle loop drops it 9dp.
    val spiderTransition = rememberInfiniteTransition(label = "spider")
    val drop by spiderTransition.animateFloat(
        initialValue = 0f, targetValue = 9f,
        animationSpec = infiniteRepeatable(tween(2250), RepeatMode.Reverse),
        label = "spiderDrop",
    )
    SpiderArt(dark, Modifier.align(Alignment.TopEnd)
        .padding(end = 34.dp, top = 38.dp).size(16.dp, 34.dp).offset(y = drop.dp))

    // Bats: the big one bobs AND sways ±2°, the small one just bobs.
    val swayTransition = rememberInfiniteTransition(label = "batSway")
    val sway by swayTransition.animateFloat(
        initialValue = -2f, targetValue = 2f,
        animationSpec = infiniteRepeatable(tween(1100), RepeatMode.Reverse),
        label = "sway",
    )
    BatArt(dark, stroked = true, modifier = Modifier.align(Alignment.TopStart)
        .padding(start = 120.dp, top = 52.dp).size(30.dp, 15.dp)
        .offset(y = bobOffset(5000, "bat1")).rotate(sway))
    BatArt(dark, modifier = Modifier.align(Alignment.TopStart)
        .padding(start = 210.dp, top = 96.dp).size(20.dp, 10.dp)
        .offset(y = bobOffset(7000, "bat2")).alpha(if (dark) 0.75f else 0.7f))

    // Ghost
    GhostArt(dark, Modifier.align(Alignment.TopStart)
        .padding(start = 32.dp, top = 150.dp).size(22.dp, 26.dp)
        .offset(y = bobOffset(3250, "ghost")))
}

// MARK: - Día de Muertos (papel picado banner, marigolds, candles)

@Composable
private fun BoxScope.DiaDecorations(dark: Boolean) {
    // Papel picado banner across the top: 8 swaying pennants under a cord.
    val colors = if (dark) {
        listOf(0xEC407AL, 0xFFB300L, 0x26A69AL, 0xAB47BCL, 0xFF7043L, 0xEC407AL, 0xFFB300L, 0x26A69AL)
    } else {
        listOf(0xD81B60L, 0xF59E00L, 0x00897BL, 0x8E24AAL, 0xF4511EL, 0xD81B60L, 0xF59E00L, 0x00897BL)
    }.map(::dhex)

    Box(Modifier.align(Alignment.TopCenter).fillMaxWidth().height(27.dp)) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 10.dp)) {
            colors.forEachIndexed { i, color ->
                SwayingPennant(color, delayMs = i * 500, label = "pennant$i")
                if (i < colors.size - 1) Spacer(Modifier.weight(1f))
            }
        }
        // The cord the pennants hang from.
        Box(
            Modifier.align(Alignment.TopCenter).fillMaxWidth().height(1.5.dp)
                .then(Modifier.padding(0.dp))
        ) {
            Canvas(Modifier.fillMaxSize()) {
                drawRect(if (dark) drgba(255, 235, 190, 0.55f) else drgba(120, 60, 10, 0.45f))
            }
        }
    }

    // Floating marigold (top-right) + smaller one (upper-left)
    Box(Modifier.align(Alignment.TopEnd).padding(end = 24.dp, top = 70.dp)
        .size(18.dp).offset(y = bobOffset(6000, "marigold1"))) {
        MarigoldFlowerArt(dark, withInner = true, centerRadius = 3f,
            centerColor = if (dark) dhex(0xE65100) else dhex(0xBF360C),
            modifier = Modifier.fillMaxSize())
    }
    Box(Modifier.align(Alignment.TopStart).padding(start = 30.dp, top = 130.dp)
        .size(12.dp).offset(y = bobOffset(8000, "marigold2"))
        .alpha(if (dark) 0.8f else 0.85f)) {
        MarigoldFlowerArt(dark, withInner = false, centerRadius = 3f,
            centerColor = if (dark) dhex(0xE65100) else dhex(0xBF360C),
            modifier = Modifier.fillMaxSize())
    }

    // Candles bottom-right, ABOVE the composer divider (the Android composer
    // bar is ~70dp + divider, taller than the mac's — the spec's 66dp bottom
    // inset would sink them onto the input line).
    Row(
        Modifier.align(Alignment.BottomEnd).padding(end = 20.dp, bottom = 92.dp),
        verticalAlignment = Alignment.Bottom,
    ) {
        FlickeringCandle(dark, delayMs = 700, modifier = Modifier.size(10.dp, 18.dp))
        Spacer(Modifier.width(6.dp))
        FlickeringCandle(dark, delayMs = 0, modifier = Modifier.size(12.dp, 22.dp))
    }
}

/** One papel picado flag swaying ±2° around its top edge. */
@Composable
private fun SwayingPennant(color: Color, delayMs: Int, label: String) {
    val transition = rememberInfiniteTransition(label = label)
    val sway by transition.animateFloat(
        initialValue = -2f, targetValue = 2f,
        animationSpec = infiniteRepeatable(
            tween(2000, delayMillis = delayMs), RepeatMode.Reverse,
        ),
        label = label,
    )
    Canvas(
        Modifier.size(40.dp, 27.dp).graphicsLayer(
            rotationZ = sway,
            transformOrigin = androidx.compose.ui.graphics.TransformOrigin(0.5f, 0f),
        )
    ) {
        drawPath(papelPicadoPath(size), color)
    }
}

@Composable
private fun FlickeringCandle(dark: Boolean, delayMs: Int, modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "candle$delayMs")
    val flicker by transition.animateFloat(
        initialValue = 1f, targetValue = 0f,
        animationSpec = infiniteRepeatable(
            tween(1200, delayMillis = delayMs), RepeatMode.Reverse,
        ),
        label = "flicker$delayMs",
    )
    Box(
        modifier
            .alpha(0.55f + 0.45f * flicker)
            .scale(0.9f + 0.1f * flicker)
    ) {
        CandleArt(dark, Modifier.fillMaxSize())
    }
}

// MARK: - Thinking equalizer (port of ThinkingIndicator.swift)

/**
 * Themed five-bar equalizer replacing the spinner in the "Thinking…" pill —
 * the same visual language as dictation, so "listening" and "thinking" speak
 * in one style. Deterministic phase-shifted sine per bar (period 1.1s, 0.15s
 * cascade, height 4→15 with opacity dimming on the low end), a 1:1 port of
 * the mac `ThinkingEqualizer`. Colors cycle `dictationColors` when the theme
 * defines them (Synthwave, Sakura, Día, …), otherwise the accent.
 */
@Composable
fun ThinkingEqualizer(palette: ChatPalette, accentFallback: Color, modifier: Modifier = Modifier) {
    val barCount = 5
    val periodMs = 1100
    val cascadeMs = 150
    val minHeight = 4f
    val maxHeight = 15f

    val transition = rememberInfiniteTransition(label = "thinkingEq")
    val t by transition.animateFloat(
        initialValue = 0f, targetValue = periodMs.toFloat(),
        animationSpec = infiniteRepeatable(tween(periodMs, easing = LinearEasing), RepeatMode.Restart),
        label = "phase",
    )

    val colors = palette.dictationColors
    fun barColor(index: Int): Color =
        if (colors.isEmpty()) (if (palette.isDynamic) accentFallback else palette.accent)
        else colors[index % colors.size]

    // Laid out as real boxes (the mac HStack), not canvas drawing — the bars
    // center vertically like the original and can never be clipped.
    Row(
        modifier.height((maxHeight + 1).dp),
        horizontalArrangement = Arrangement.spacedBy(3.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        for (index in 0 until barCount) {
            // 0…1 wave, phase-shifted per bar like the CSS delays.
            val phase = (t - index * cascadeMs) * 2f * Math.PI.toFloat() / periodMs
            val wave = (1f - cos(phase)) / 2f
            Box(
                Modifier
                    .size(width = 3.dp, height = (minHeight + (maxHeight - minHeight) * wave).dp)
                    .alpha(0.5f + 0.5f * wave)
                    .background(barColor(index), androidx.compose.foundation.shape.RoundedCornerShape(1.5.dp)),
            )
        }
    }
}
