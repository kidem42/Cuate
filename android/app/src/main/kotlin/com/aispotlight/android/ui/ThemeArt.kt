package com.aispotlight.android.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate

/**
 * Canvas art for the holiday themes — ported verbatim from the design tool's
 * inline SVG via `HalloweenTheme.swift` / `DiaDeMuertosTheme.swift` (viewBox
 * coords and hex colors are 1:1). No vector assets: everything draws natively.
 */

private fun hx(v: Long) = Color(0xFF000000 or v)
private fun hrgba(r: Int, g: Int, b: Int, a: Float) =
    Color(red = r / 255f, green = g / 255f, blue = b / 255f, alpha = a)

// MARK: - Spiderweb (corner web with radial threads + arc rings)

/** Builds the 90×90-space web path scaled into [size]; `rings` ≤ 3. */
fun spiderWebPath(size: Size, rings: Int = 3): Path {
    val sx = size.width / 90f
    val sy = size.height / 90f
    val path = Path()

    // Radial threads
    for ((ex, ey) in listOf(88f to 8f, 74f to 46f, 64f to 64f, 46f to 74f, 8f to 88f)) {
        path.moveTo(0f, 0f)
        path.lineTo(ex * sx, ey * sy)
    }

    // Arc rings (quad-curve chains, verbatim from the SVG)
    val ringPaths = listOf(
        listOf(
            floatArrayOf(27.9f, 2.4f, 27.9f, 2.4f), floatArrayOf(26.5f, 9f, 23.7f, 14.8f),
            floatArrayOf(22f, 17.5f, 19.8f, 19.8f), floatArrayOf(17.5f, 22f, 14.8f, 23.7f),
            floatArrayOf(9f, 26.5f, 2.4f, 27.9f),
        ),
        listOf(
            floatArrayOf(51.8f, 4.5f, 51.8f, 4.5f), floatArrayOf(49f, 17f, 44f, 27.5f),
            floatArrayOf(40.8f, 33f, 36.8f, 36.8f), floatArrayOf(33f, 40.8f, 27.5f, 44f),
            floatArrayOf(17f, 49f, 4.5f, 51.8f),
        ),
        listOf(
            floatArrayOf(75.7f, 6.6f, 75.7f, 6.6f), floatArrayOf(72f, 25f, 64.4f, 40.3f),
            floatArrayOf(59.5f, 48.5f, 53.7f, 53.7f), floatArrayOf(48.5f, 59.5f, 40.3f, 64.4f),
            floatArrayOf(25f, 72f, 6.6f, 75.7f),
        ),
    )
    for (ring in ringPaths.take(rings)) {
        val first = ring.first()
        path.moveTo(first[2] * sx, first[3] * sy)
        for (seg in ring.drop(1)) {
            path.quadraticTo(seg[0] * sx, seg[1] * sy, seg[2] * sx, seg[3] * sy)
        }
    }
    return path
}

// MARK: - Bat (32×16 space: scalloped wings, round head)

fun batPath(size: Size): Path {
    val sx = size.width / 32f
    val sy = size.height / 16f
    fun px(x: Float) = x * sx
    fun py(y: Float) = y * sy
    return Path().apply {
        moveTo(px(2f), py(9f))
        quadraticTo(px(6f), py(2f), px(12f), py(6f))       // left wing top
        quadraticTo(px(13.5f), py(3f), px(16f), py(3f))    // head left
        quadraticTo(px(18.5f), py(3f), px(20f), py(6f))    // head right
        quadraticTo(px(26f), py(2f), px(30f), py(9f))      // right wing top
        quadraticTo(px(25f), py(8f), px(22.5f), py(11f))   // right wing scallop
        lineTo(px(20.5f), py(9f)); lineTo(px(18.5f), py(12f))
        lineTo(px(16f), py(9.5f)); lineTo(px(13.5f), py(12f))
        lineTo(px(11.5f), py(9f)); lineTo(px(9.5f), py(11f))
        quadraticTo(px(7f), py(8f), px(2f), py(9f))        // left wing scallop
        close()
    }
}

@Composable
fun BatArt(dark: Boolean, stroked: Boolean = false, modifier: Modifier = Modifier) {
    val fill = if (dark) hx(0x3b2154) else hx(0x4A2B6B)
    Canvas(modifier) {
        val path = batPath(size)
        drawPath(path, fill)
        if (stroked && dark) {
            drawPath(path, hrgba(255, 170, 90, 0.35f), style = Stroke(width = 0.6f * size.width / 32f * 2f))
        }
    }
}

// MARK: - Ghost (20×24 space: dome top, wavy hem, two eyes)

@Composable
fun GhostArt(dark: Boolean, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val sx = size.width / 20f
        val sy = size.height / 24f
        val body = Path().apply {
            moveTo(2f * sx, 22f * sy)
            lineTo(2f * sx, 10f * sy)
            // Top dome: semicircle over the top (a8 8 0 0 1 16 0)
            arcTo(Rect(Offset(10f * sx - 8f * sx, 10f * sy - 8f * sx), Size(16f * sx, 16f * sx)),
                180f, 180f, false)
            lineTo(18f * sx, 22f * sy)
            // Wavy hem
            lineTo(15.3f * sx, 19.6f * sy); lineTo(12.7f * sx, 22f * sy)
            lineTo(10.0f * sx, 19.6f * sy); lineTo(7.4f * sx, 22f * sy)
            lineTo(4.7f * sx, 19.6f * sy)
            close()
        }
        if (dark) {
            drawPath(body, hrgba(255, 255, 255, 0.16f))
        } else {
            drawPath(body, hrgba(255, 255, 255, 0.85f))
            drawPath(body, hrgba(130, 65, 15, 0.25f), style = Stroke(width = 0.6f * sx))
        }
        val eye = if (dark) hrgba(13, 6, 24, 0.8f) else hx(0x4A2B6B)
        for (cx in listOf(7f, 13f)) {
            drawOval(eye, Offset((cx - 1.3f) * sx, 8.7f * sy), Size(2.6f * sx, 2.6f * sy))
        }
    }
}

// MARK: - Spider (16×34 space: thread, body, six legs, amber eyes)

@Composable
fun SpiderArt(dark: Boolean, modifier: Modifier = Modifier) {
    val bodyColor = if (dark) hx(0x3b2154) else hx(0x4A2B6B)
    val threadColor = if (dark) hrgba(255, 200, 140, 0.5f) else hrgba(130, 65, 15, 0.5f)
    val eyeColor = if (dark) hx(0xFF9E4F) else hx(0xFFB74D)
    Canvas(modifier) {
        val sx = size.width / 16f
        val sy = size.height / 34f
        fun circle(cx: Float, cy: Float, r: Float, color: Color) =
            drawOval(color, Offset((cx - r) * sx, (cy - r) * sy), Size(2 * r * sx, 2 * r * sy))
        // Thread (runs off the top edge; clipped by the panel)
        drawLine(threadColor, Offset(8f * sx, -20f * sy), Offset(8f * sx, 18f * sy), strokeWidth = 0.8f * sx)
        // Body + head
        circle(8f, 22f, 3.6f, bodyColor)
        circle(8f, 17.2f, 2f, bodyColor)
        // Legs (three per side, curved outward)
        val legs = Path()
        val legSegs = listOf(
            Triple(5f to 20f, 2f to 18f, 1f to 15f), Triple(5f to 22.5f, 1.5f to 22.5f, 0.5f to 25.5f),
            Triple(5.5f to 24.5f, 3f to 26.5f, 3f to 29.5f),
            Triple(11f to 20f, 14f to 18f, 15f to 15f), Triple(11f to 22.5f, 14.5f to 22.5f, 15.5f to 25.5f),
            Triple(10.5f to 24.5f, 13f to 26.5f, 13f to 29.5f),
        )
        for ((start, ctrl, end) in legSegs) {
            legs.moveTo(start.first * sx, start.second * sy)
            legs.quadraticTo(ctrl.first * sx, ctrl.second * sy, end.first * sx, end.second * sy)
        }
        drawPath(legs, bodyColor, style = Stroke(width = 1.1f * sx, cap = androidx.compose.ui.graphics.StrokeCap.Round))
        // Eyes
        circle(6.8f, 21.2f, 0.7f, eyeColor)
        circle(9.2f, 21.2f, 0.7f, eyeColor)
    }
}

// MARK: - Pumpkin (assistant bubble icon; 24×24, no face)

@Composable
fun PumpkinIconArt(dark: Boolean, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val sx = size.width / 24f
        val sy = size.height / 24f
        // Stem: M12 5c0-2 1-3.5 3-3.5 0 2-1 3.5-3 3.5z
        val stem = Path().apply {
            moveTo(12f * sx, 5f * sy)
            cubicTo(12f * sx, 3f * sy, 13f * sx, 1.5f * sy, 15f * sx, 1.5f * sy)
            cubicTo(15f * sx, 3.5f * sy, 14f * sx, 5f * sy, 12f * sx, 5f * sy)
            close()
        }
        drawPath(stem, if (dark) hx(0x7CB342) else hx(0x689F38))
        // Body + ribs
        fun ellipse(rx: Float, ry: Float) =
            Rect(Offset((12f - rx) * sx, (14f - ry) * sy), Size(2 * rx * sx, 2 * ry * sy))
        drawOval(if (dark) hx(0xFF8A2A) else hx(0xF0700F), ellipse(9.5f, 8.5f).topLeft, ellipse(9.5f, 8.5f).size)
        val rib = if (dark) hx(0xE06A0E) else hx(0xC55A08)
        drawOval(rib, ellipse(6.5f, 8.5f).topLeft, ellipse(6.5f, 8.5f).size, style = Stroke(width = 1.2f * sx))
        drawOval(rib, ellipse(2.8f, 8.5f).topLeft, ellipse(2.8f, 8.5f).size, style = Stroke(width = 1.2f * sx))
    }
}

// MARK: - Jack-o'-lantern (send button; 30×28 with carved face)

@Composable
fun JackOLanternArt(dark: Boolean, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val sx = size.width / 30f
        val sy = size.height / 28f
        // Stem
        val stem = Path().apply {
            moveTo(15f * sx, 4.5f * sy)
            cubicTo(15f * sx, 2.1f * sy, 16.2f * sx, 0.5f * sy, 18.6f * sx, 0.5f * sy)
            cubicTo(18.6f * sx, 2.9f * sy, 17.4f * sx, 4.5f * sy, 15f * sx, 4.5f * sy)
            close()
        }
        drawPath(stem, if (dark) hx(0x7CB342) else hx(0x689F38))
        // Body + ribs
        fun ellipse(rx: Float, ry: Float) =
            Rect(Offset((15f - rx) * sx, (16f - ry) * sy), Size(2 * rx * sx, 2 * ry * sy))
        drawOval(if (dark) hx(0xFF7A1A) else hx(0xF0700F), ellipse(13.5f, 11.5f).topLeft, ellipse(13.5f, 11.5f).size)
        val rib = if (dark) hx(0xD8620C) else hx(0xC55A08)
        drawOval(rib, ellipse(9f, 11.5f).topLeft, ellipse(9f, 11.5f).size, style = Stroke(width = 1.3f * sx))
        drawOval(rib, ellipse(4f, 11.5f).topLeft, ellipse(4f, 11.5f).size, style = Stroke(width = 1.3f * sx))
        // Face (triangle eyes + zigzag grin)
        val face = if (dark) hx(0xFFE082) else hx(0xFFF3D6)
        val eyes = Path().apply {
            moveTo(9f * sx, 13f * sy); lineTo(11.6f * sx, 16.6f * sy); lineTo(6.4f * sx, 16.6f * sy); close()
            moveTo(21f * sx, 13f * sy); lineTo(23.6f * sx, 16.6f * sy); lineTo(18.4f * sx, 16.6f * sy); close()
        }
        drawPath(eyes, face)
        val mouth = Path().apply {
            moveTo(7.5f * sx, 20f * sy)
            quadraticTo(15f * sx, 25.5f * sy, 22.5f * sx, 20f * sy)
            lineTo(20.6f * sx, 22.3f * sy); lineTo(18.4f * sx, 21.0f * sy)
            lineTo(15.9f * sx, 22.7f * sy); lineTo(13.4f * sx, 21.0f * sy)
            lineTo(11.2f * sx, 22.3f * sy)
            close()
        }
        drawPath(mouth, face)
    }
}

// MARK: - Sugar skull (Día assistant icon; 24×26)

@Composable
fun SugarSkullArt(dark: Boolean, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val sx = size.width / 24f
        val sy = size.height / 26f
        fun circle(cx: Float, cy: Float, r: Float, color: Color) =
            drawOval(color, Offset((cx - r) * sx, (cy - r) * sy), Size(2 * r * sx, 2 * r * sy))
        // Skull base
        val base = Path().apply {
            moveTo(12f * sx, 1f * sy)
            cubicTo(6.2f * sx, 1f * sy, 2.5f * sx, 5f * sy, 2.5f * sx, 10.3f * sy)
            cubicTo(2.5f * sx, 13.6f * sy, 3.9f * sx, 16.0f * sy, 5.8f * sx, 17.5f * sy)
            lineTo(5.8f * sx, 21f * sy)
            cubicTo(5.8f * sx, 22.3f * sy, 6.9f * sx, 23.4f * sy, 8.2f * sx, 23.4f * sy)
            lineTo(15.8f * sx, 23.4f * sy)
            cubicTo(17.1f * sx, 23.4f * sy, 18.2f * sx, 22.3f * sy, 18.2f * sx, 21f * sy)
            lineTo(18.2f * sx, 17.5f * sy)
            cubicTo(20.1f * sx, 16.0f * sy, 21.5f * sx, 13.6f * sy, 21.5f * sx, 10.3f * sy)
            cubicTo(21.5f * sx, 5f * sy, 17.8f * sx, 1f * sy, 12f * sx, 1f * sy)
        }
        drawPath(base, if (dark) hx(0xFFF4E4) else hx(0xFFFDF8))
        if (!dark) drawPath(base, hrgba(120, 60, 10, 0.3f), style = Stroke(width = 0.6f * sx))

        // Eyes
        circle(8.2f, 10f, 2.1f, if (dark) hx(0xEC407A) else hx(0xD81B60))
        circle(15.8f, 10f, 2.1f, if (dark) hx(0x26A69A) else hx(0x00897B))
        // Marigold dots around eyes
        val dot = if (dark) hx(0xFFB300) else hx(0xF59E00)
        for ((cx, cy) in listOf(8.2f to 6.6f, 4.9f to 10.0f, 8.2f to 13.4f, 15.8f to 6.6f, 19.1f to 10.0f, 15.8f to 13.4f)) {
            circle(cx, cy, 0.7f, dot)
        }
        // Nose
        val nose = Path().apply {
            moveTo(12f * sx, 13.4f * sy); lineTo(10.8f * sx, 15.4f * sy); lineTo(13.2f * sx, 15.4f * sy); close()
        }
        drawPath(nose, hx(0x5C2A47))
        // Mouth + teeth
        val mouth = Path().apply {
            moveTo(8.4f * sx, 19.2f * sy); lineTo(15.6f * sx, 19.2f * sy)
            for (x in listOf(9.8f, 12f, 14.2f)) { moveTo(x * sx, 18f * sy); lineTo(x * sx, 20.4f * sy) }
        }
        drawPath(mouth, hx(0x5C2A47), style = Stroke(width = 0.95f * sx))
        // Forehead flower dot
        circle(12f, 4.4f, 0.9f, if (dark) hx(0xEC407A) else hx(0xD81B60))
    }
}

// MARK: - Marigold flower (Día send button + floating décor; 24×24)

@Composable
fun MarigoldFlowerArt(
    dark: Boolean,
    withInner: Boolean = true,
    withSparkle: Boolean = false,
    centerRadius: Float = 5.2f,
    centerColor: Color? = null,
    modifier: Modifier = Modifier,
) {
    Canvas(modifier) {
        val s = minOf(size.width, size.height) / 24f
        fun petals(color: Color, inner: Boolean, rotated: Boolean) {
            val specs = if (inner) {
                listOf(floatArrayOf(12f, 5.5f, 2.6f, 4f), floatArrayOf(12f, 18.5f, 2.6f, 4f),
                    floatArrayOf(5.5f, 12f, 4f, 2.6f), floatArrayOf(18.5f, 12f, 4f, 2.6f))
            } else {
                listOf(floatArrayOf(12f, 5f, 3f, 4.5f), floatArrayOf(12f, 19f, 3f, 4.5f),
                    floatArrayOf(5f, 12f, 4.5f, 3f), floatArrayOf(19f, 12f, 4.5f, 3f))
            }
            val draw: DrawScope.() -> Unit = {
                for (e in specs) {
                    drawOval(color, Offset((e[0] - e[2]) * s, (e[1] - e[3]) * s), Size(2 * e[2] * s, 2 * e[3] * s))
                }
            }
            if (rotated) rotate(45f, pivot = Offset(12f * s, 12f * s)) { draw() } else draw()
        }
        petals(if (dark) hx(0xFFB300) else hx(0xF59E00), inner = false, rotated = false)
        if (withInner) {
            petals(if (dark) hx(0xFF8F00) else hx(0xE65100), inner = true, rotated = true)
        }
        drawOval(
            centerColor ?: hx(0x4A1030),
            Offset((12f - centerRadius) * s, (12f - centerRadius) * s),
            Size(centerRadius * 2 * s, centerRadius * 2 * s),
        )
        if (withSparkle) {
            val sparkle = Path().apply {
                moveTo(14.85f * s, 9.47f * s)
                lineTo(9.56f * s, 11.66f * s)
                lineTo(11.53f * s, 12.45f * s)
                lineTo(12.33f * s, 14.43f * s)
                close()
            }
            drawPath(sparkle, Color.White)
        }
    }
}

// MARK: - Papel picado pennant (40×27 flag, evenodd cut-outs)

fun papelPicadoPath(size: Size): Path {
    val sx = size.width / 40f
    val sy = size.height / 27f
    fun poly(path: Path, pts: List<Pair<Float, Float>>) {
        val first = pts.first()
        path.moveTo(first.first * sx, first.second * sy)
        for (pt in pts.drop(1)) path.lineTo(pt.first * sx, pt.second * sy)
        path.close()
    }
    return Path().apply {
        fillType = PathFillType.EvenOdd
        // Body: rectangle with 5-tooth sawtooth bottom.
        moveTo(0f, 0f); lineTo(40f * sx, 0f); lineTo(40f * sx, 19f * sy)
        var x = 36f
        while (x >= 4f) {
            val up = (((40f - x) / 4f).toInt()) % 2 == 1   // valleys at 36,28,20,12,4
            lineTo(x * sx, (if (up) 23f else 19f) * sy)
            x -= 4f
        }
        lineTo(0f, 19f * sy); close()

        // Skull head (circle center (20,8) r3.4)
        addOval(Rect(Offset((20f - 3.4f) * sx, (8f - 3.4f) * sy), Size(6.8f * sx, 6.8f * sy)))
        // Skull jaw
        poly(this, listOf(17.9f to 11.6f, 22.1f to 11.6f, 22.1f to 14.0f, 21.1f to 14.9f,
            20.0f to 14.0f, 18.9f to 14.9f, 17.9f to 14.0f))
        // Side diamonds
        poly(this, listOf(8f to 5.6f, 10.3f to 8.7f, 8f to 11.8f, 5.7f to 8.7f))
        poly(this, listOf(32f to 5.6f, 34.3f to 8.7f, 32f to 11.8f, 29.7f to 8.7f))
        // Small diamonds
        poly(this, listOf(5f to 14.8f, 6.5f to 16.3f, 5f to 17.8f, 3.5f to 16.3f))
        poly(this, listOf(35f to 14.8f, 36.5f to 16.3f, 35f to 17.8f, 33.5f to 16.3f))
    }
}

// MARK: - Candle (12×22: white body, marigold flame, bright core)

@Composable
fun CandleArt(dark: Boolean, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val sx = size.width / 12f
        val sy = size.height / 22f
        // Body
        val bodyRect = Rect(Offset(3f * sx, 8f * sy), Size(6f * sx, 13f * sy))
        drawRoundRect(
            if (dark) hrgba(255, 245, 225, 0.85f) else Color.White,
            bodyRect.topLeft, bodyRect.size, CornerRadius(1.5f * sx),
        )
        if (!dark) {
            drawRoundRect(hrgba(120, 60, 10, 0.25f), bodyRect.topLeft, bodyRect.size,
                CornerRadius(1.5f * sx), style = Stroke(width = 0.5f * sx))
        }
        // Flame
        val flame = Path().apply {
            moveTo(6f * sx, 1.2f * sy)
            cubicTo(7.6f * sx, 3f * sy, 8f * sx, 4.4f * sy, 6f * sx, 6.4f * sy)
            cubicTo(4f * sx, 4.4f * sy, 4.4f * sx, 3f * sy, 6f * sx, 1.2f * sy)
        }
        drawPath(flame, if (dark) hx(0xFFB300) else hx(0xF59E00))
        drawOval(hx(0xFFF3C4), Offset(5f * sx, 3.6f * sy), Size(2f * sx, 2f * sy))
    }
}

/** Convenience wrapper so callers can size art via Modifier. */
@Composable
fun ThemedBox(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Box(modifier.fillMaxSize()) { content() }
}
