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
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.rememberTextMeasurer
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
            ThemeDecoration.YULE -> YuleDecorations(dark)
            ThemeDecoration.AURORA -> AuroraDecorations(dark)
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

// MARK: - Yule (garland bulbs hugging the top edge + falling snow)

/**
 * Wall-clock milliseconds ticking every frame — the Compose analog of the
 * mac's `TimelineView(.animation)`. The particle loops (snow, shooting
 * stars) are pure functions of this clock, phase-shifted per particle, so
 * they never drift or restart the way state-toggled repeatForever loops do.
 */
@Composable
private fun rememberFrameClockMillis(): androidx.compose.runtime.State<Long> =
    androidx.compose.runtime.produceState(0L) {
        while (true) {
            androidx.compose.runtime.withFrameMillis { value = it }
        }
    }

/** Mock's snowflakes: (x fraction, fall duration s, phase offset s). */
private val yuleFlakes = listOf(
    Triple(0.08f, 11f, 0f), Triple(0.24f, 14f, 3f), Triple(0.43f, 9f, 6f),
    Triple(0.58f, 13f, 1.5f), Triple(0.72f, 10f, 4.5f), Triple(0.88f, 12f, 7.5f),
    Triple(0.33f, 15f, 9f), Triple(0.80f, 12f, 10f), Triple(0.50f, 12f, 2.2f),
    Triple(0.16f, 10f, 7f),
)

@Composable
private fun BoxScope.YuleDecorations(dark: Boolean) {
    androidx.compose.foundation.layout.BoxWithConstraints(Modifier.fillMaxSize()) {
        val width = maxWidth
        // Bulb palette from the mock: red / gold / green / ice blue, one bulb
        // per 10% of width at the mock's hand-tuned drops from the top.
        val bulbColors = listOf(dhex(0xE5484D), dhex(0xF2C14E), dhex(0x58B368), dhex(0x6FB7E8))
        val bulbTops = listOf(10, 17, 21, 18, 11, 16, 22, 17, 10, 15)
        bulbTops.forEachIndexed { i, top ->
            TwinklingBulb(
                color = bulbColors[i % 4],
                glowAlpha = if (dark) 0.8f else 0.47f,
                periodMs = 2000 + (i % 3) * 500,
                phaseMs = i * 350,
                modifier = Modifier.offset(x = width * (0.05f + i * 0.10f), y = top.dp),
            )
        }
        // Snow rides one shared clock: each flake's y is a phase-shifted loop
        // over the panel height, x sways around its lane (mac Canvas port).
        val clock by rememberFrameClockMillis()
        val measurer = rememberTextMeasurer()
        val flakeColor = if (dark) drgba(255, 255, 255, 0.85f) else drgba(120, 150, 170, 0.8f)
        // Measured ONCE and drawn as a ready layout: per-frame drawText(text)
        // derives its constraints from "canvas minus topLeft", and a flake
        // BELOW the bottom edge (travel overshoots by design) made that
        // negative — an IllegalArgumentException in the draw phase took the
        // whole app down (device crash log 2026-08-07 18:00).
        val flakeLayout = remember(measurer, flakeColor) {
            measurer.measure(
                androidx.compose.ui.text.AnnotatedString("❄"),
                TextStyle(fontSize = 7.sp, color = flakeColor),
            )
        }
        Canvas(Modifier.fillMaxSize()) {
            val t = clock / 1000f
            val travel = size.height + 40.dp.toPx()
            for ((x, duration, phase) in yuleFlakes) {
                val progress = ((t + phase) / duration).mod(1f)
                val sway = kotlin.math.sin((t + phase) / (duration / 3.2f) * 2f * Math.PI.toFloat()) * 4.5.dp.toPx()
                // Centered on the point, like the mac's ctx.draw(at:).
                drawText(
                    textLayoutResult = flakeLayout,
                    topLeft = Offset(
                        size.width * x + sway - flakeLayout.size.width / 2f,
                        progress * travel - 24.dp.toPx() - flakeLayout.size.height / 2f,
                    ),
                )
            }
        }
    }
}

/**
 * One garland bulb, 1:1 with the mock's `box-shadow` + `twinkle`: a soft
 * radial-gradient halo behind the drop (the CSS blur+spread), swelling and
 * fading in step with the bulb's own brightness.
 */
@Composable
private fun TwinklingBulb(
    color: Color,
    glowAlpha: Float,
    periodMs: Int,
    phaseMs: Int,
    modifier: Modifier = Modifier,
) {
    val transition = rememberInfiniteTransition(label = "bulb$phaseMs")
    // 0 = bright, 1 = dimmed (the mac's `dim` toggle, made continuous).
    val dim by transition.animateFloat(
        initialValue = 0f, targetValue = 1f,
        animationSpec = infiniteRepeatable(
            tween(periodMs / 2),
            RepeatMode.Reverse,
            initialStartOffset = androidx.compose.animation.core.StartOffset(phaseMs),
        ),
        label = "dim$phaseMs",
    )
    Box(modifier.size(16.dp, 18.dp), contentAlignment = Alignment.Center) {
        Canvas(
            Modifier.fillMaxSize()
                .scale(1.3f - 0.55f * dim)
                .alpha(glowAlpha * (1f - 0.65f * dim))
        ) {
            drawOval(
                androidx.compose.ui.graphics.Brush.radialGradient(
                    listOf(color, color.copy(alpha = 0f)),
                )
            )
        }
        Box(
            Modifier.size(6.dp, 8.dp)
                .alpha(1f - 0.5f * dim)
                .background(
                    color,
                    androidx.compose.foundation.shape.RoundedCornerShape(
                        topStart = 2.7.dp, topEnd = 2.7.dp,
                        bottomEnd = 3.dp, bottomStart = 3.dp,
                    ),
                ),
        )
    }
}

// MARK: - Aurora (breathing ribbons, twinkling stars, shooting stars)

/** Mock's star field: (x fraction, y dp, diameter dp). */
private val auroraStars = listOf(
    Triple(0.12f, 34, 2f), Triple(0.30f, 16, 1.5f), Triple(0.52f, 28, 2f),
    Triple(0.76f, 20, 1.5f), Triple(0.88f, 48, 2f), Triple(0.22f, 66, 1.5f),
    Triple(0.64f, 58, 1.5f), Triple(0.41f, 46, 1.5f), Triple(0.83f, 84, 1.5f),
    Triple(0.08f, 96, 1.5f),
)

@Composable
private fun BoxScope.AuroraDecorations(dark: Boolean) {
    androidx.compose.foundation.layout.BoxWithConstraints(Modifier.fillMaxSize()) {
        val w = maxWidth
        val h = maxHeight
        if (dark) {
            AuroraRibbon(drgba(61, 232, 176, 0.40f), periodMs = 11_000, phaseMs = 0,
                Modifier.offset(x = -w * 0.18f, y = -h * 0.10f).size(w * 0.85f, h * 0.48f))
            AuroraRibbon(drgba(125, 108, 255, 0.34f), periodMs = 14_000, phaseMs = 2_500,
                Modifier.offset(x = w * 0.32f, y = -h * 0.06f).size(w * 0.90f, h * 0.54f))
            AuroraRibbon(drgba(111, 227, 255, 0.22f), periodMs = 9_000, phaseMs = 5_000,
                Modifier.offset(x = w * 0.16f, y = -h * 0.04f).size(w * 0.70f, h * 0.36f))
            auroraStars.forEachIndexed { i, (x, y, d) ->
                TwinklingStar(
                    diameter = d.dp,
                    periodMs = 2000 + (i % 4) * 700,
                    phaseMs = i * 500,
                    modifier = Modifier.offset(x = w * x, y = y.dp),
                )
            }
            // Two shooting stars on offset cycles: each flares at a RANDOM
            // point anywhere in the window (chat-only on the mac too).
            ShootingStars(Modifier.fillMaxSize())
        } else {
            AuroraRibbon(drgba(64, 196, 160, 0.26f), periodMs = 12_000, phaseMs = 0,
                Modifier.offset(x = -w * 0.14f, y = -h * 0.08f).size(w * 0.80f, h * 0.42f))
            AuroraRibbon(drgba(150, 130, 255, 0.24f), periodMs = 15_000, phaseMs = 3_000,
                Modifier.offset(x = w * 0.33f, y = -h * 0.02f).size(w * 0.85f, h * 0.48f))
        }
    }
}

/**
 * One curtain of light, drifting and swelling on its own slow period (the
 * mock's `ribbon` keyframe: x ±14, slight swell, opacity breathing). The
 * radial gradient fades to transparent on its own — no platform blur needed,
 * so the effect renders identically on every API level.
 */
@Composable
private fun AuroraRibbon(color: Color, periodMs: Int, phaseMs: Int, modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "ribbon$periodMs")
    val t by transition.animateFloat(
        initialValue = 0f, targetValue = 1f,
        animationSpec = infiniteRepeatable(
            tween(periodMs, easing = LinearEasing),
            RepeatMode.Restart,
            initialStartOffset = androidx.compose.animation.core.StartOffset(phaseMs),
        ),
        label = "t$periodMs",
    )
    val angle = t * 2f * Math.PI.toFloat()
    val drift = kotlin.math.sin(angle) * 14f
    val swell = 1f + kotlin.math.sin(angle + Math.PI.toFloat() / 3f) * 0.10f
    val breath = 0.82f + kotlin.math.sin(angle + Math.PI.toFloat() / 6f) * 0.18f
    Canvas(
        modifier.graphicsLayer(
            translationX = drift,
            scaleY = swell,
            alpha = breath.coerceIn(0f, 1f),
        )
    ) {
        drawOval(
            androidx.compose.ui.graphics.Brush.radialGradient(
                listOf(color, color.copy(alpha = 0f)),
            )
        )
    }
}

/** A pin-prick star pulsing between bright and faint (mock's `starTw`). */
@Composable
private fun TwinklingStar(diameter: Dp, periodMs: Int, phaseMs: Int, modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "star$phaseMs")
    val dim by transition.animateFloat(
        initialValue = 0f, targetValue = 1f,
        animationSpec = infiniteRepeatable(
            tween(periodMs / 2),
            RepeatMode.Reverse,
            initialStartOffset = androidx.compose.animation.core.StartOffset(phaseMs),
        ),
        label = "dim$phaseMs",
    )
    Box(
        modifier.size(diameter)
            .scale(1f - 0.25f * dim)
            .alpha(0.9f - 0.65f * dim)
            .background(Color.White, androidx.compose.foundation.shape.CircleShape),
    )
}

/**
 * Shooting stars: invisible for most of a 12s cycle, then a bright streak
 * slides down-left and fades. Each flight starts at a NEW pseudo-random point
 * (fract-sin hash seeded by the flyby index) — a 1:1 port of the mac
 * `ShootingStar`, both stars drawn from one frame-clock canvas.
 */
@Composable
private fun ShootingStars(modifier: Modifier = Modifier) {
    val clock by rememberFrameClockMillis()
    val cycle = 12f
    val visibleFrom = 0.92f
    fun hash(v: Float): Float {
        val s = kotlin.math.sin(v.toDouble()) * 43758.5453
        return (s - kotlin.math.floor(s)).toFloat()
    }
    Canvas(modifier) {
        for (seed in listOf(0f, 7f)) {
            val raw = clock / 1000f + seed * cycle / 2f
            val pass = kotlin.math.floor(raw / cycle)
            val t = raw.mod(cycle) / cycle
            val p = ((t - visibleFrom) / (1f - visibleFrom)).coerceAtLeast(0f)
            if (p == 0f) continue
            val opacity = if (p < 0.2f) p * 5f * 0.9f else 0.9f * (1f - (p - 0.2f) / 0.8f)
            val startX = size.width * (0.18f + 0.72f * hash(pass * 12.9898f + seed))
            val startY = size.height * (0.06f + 0.72f * hash(pass * 78.233f + seed * 3f))
            val length = 46.dp.toPx()
            val thickness = 1.5.dp.toPx()
            val flightX = startX - 90.dp.toPx() * p
            val flightY = startY + 54.dp.toPx() * p
            withTransform({
                translate(left = flightX, top = flightY)
                rotate(150f, pivot = Offset(length, thickness / 2f))
            }) {
                drawRoundRect(
                    brush = androidx.compose.ui.graphics.Brush.horizontalGradient(
                        listOf(Color.White.copy(alpha = 0.9f), Color.Transparent),
                        startX = 0f, endX = length,
                    ),
                    size = androidx.compose.ui.geometry.Size(length, thickness),
                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(1.dp.toPx()),
                    alpha = opacity.coerceIn(0f, 1f),
                )
            }
        }
    }
}

// MARK: - Candy-cane spinner (Yule "thinking", port of CandyCaneSpinner)

/**
 * Yule's "thinking" spinner: a candy-cane cylinder lying on its side, its
 * red/cream spiral turning (the barber-pole read). 45° stripes, 6dp
 * perpendicular width, one full period (12·√2 ≈ 16.97dp of horizontal
 * travel) every 0.8s — the loop closes on itself exactly, so the motion
 * never hiccups. Gloss (top highlight, bottom shade) is drawn OVER the
 * stripes so the shine stays put while the spiral moves.
 */
@Composable
fun CandyCaneSpinner(modifier: Modifier = Modifier) {
    val travel = 16.9706f // dp of horizontal travel per turn
    val transition = rememberInfiniteTransition(label = "candyCane")
    val phase by transition.animateFloat(
        initialValue = 0f, targetValue = travel,
        animationSpec = infiniteRepeatable(tween(800, easing = LinearEasing), RepeatMode.Restart),
        label = "phase",
    )
    val red = dhex(0xE5484D)
    val cream = dhex(0xFFF6EC)
    Canvas(modifier.size(44.dp, 11.dp)) {
        val h = size.height
        val capsule = androidx.compose.ui.graphics.Path().apply {
            addRoundRect(
                androidx.compose.ui.geometry.RoundRect(
                    0f, 0f, size.width, h,
                    androidx.compose.ui.geometry.CornerRadius(h / 2f),
                )
            )
        }
        clipPath(capsule) {
            drawRect(cream)
            // Diagonal "/" stripes travelling right with phase; the margin on
            // both sides covers the diagonal overhang.
            val travelPx = travel.dp.toPx()
            var x = -h - travelPx + phase.dp.toPx()
            while (x < size.width + h) {
                val stripe = androidx.compose.ui.graphics.Path().apply {
                    moveTo(x, h)
                    lineTo(x + h, 0f)
                    lineTo(x + h + travelPx / 2f, 0f)
                    lineTo(x + travelPx / 2f, h)
                    close()
                }
                drawPath(stripe, red)
                x += travelPx
            }
            // Cylinder gloss: highlight on top, shadow below — both static.
            drawRect(
                androidx.compose.ui.graphics.Brush.verticalGradient(
                    0f to Color.White.copy(alpha = 0.45f),
                    0.42f to Color.Transparent,
                    0.62f to Color.Transparent,
                    1f to Color.Black.copy(alpha = 0.22f),
                )
            )
        }
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
    if (palette.themeID == ChatThemeID.YULE) {
        // Yule: a candy-cane cylinder — the spiral spins "on its side".
        CandyCaneSpinner(modifier)
        return
    }
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
