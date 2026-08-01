package com.aispotlight.android.ui

import android.graphics.Bitmap
import android.graphics.Canvas as AndroidCanvas
import android.graphics.Paint
import android.util.Base64
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.IconButton
import androidx.compose.material3.Icon
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.aispotlight.android.R
import com.aispotlight.android.data.ChatAttachment
import com.aispotlight.android.data.ImageStore
import java.io.ByteArrayOutputStream

/**
 * Brush mask editor for object removal (port of MaskEditorView.swift):
 * paint over the object, the strokes become a white-on-black PNG mask sent
 * to Bria Eraser.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MaskEditorView(
    attachment: ChatAttachment,
    onRun: (maskBase64: String) -> Unit,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val bitmap = remember(attachment.id) { ImageStore.thumbnail(context, attachment, targetPx = 1600) }
    // Mask APIs require the mask pixel-aligned with the image the model
    // receives — the stored ORIGINAL's dimensions, not the preview's (the
    // editor bitmap is a downsampled copy now that imports keep full size).
    val maskSize = remember(attachment.id) { ImageStore.pixelSize(context, attachment) }
    if (bitmap == null || maskSize == null) {
        onDismiss()
        return
    }

    data class BrushStroke(val points: MutableList<Offset>, val width: Float)

    val strokes = remember { mutableStateListOf<BrushStroke>() }
    var brushSize by remember { mutableFloatStateOf(48f) }
    var canvasSize by remember { mutableStateOf(IntSize.Zero) }

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = { Text(stringResource(R.string.mask_title)) },
                    navigationIcon = {
                        IconButton(onClick = onDismiss) {
                            Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.action_cancel))
                        }
                    },
                    actions = {
                        TextButton(onClick = { strokes.clear() }) {
                            Text(stringResource(R.string.mask_clear))
                        }
                        TextButton(
                            enabled = strokes.isNotEmpty(),
                            onClick = {
                                val mask = renderMask(maskSize.first, maskSize.second, canvasSize, strokes.map { it.points to it.width })
                                onRun(mask)
                            },
                        ) { Text(stringResource(R.string.mask_run)) }
                    },
                )
            },
        ) { padding ->
            Column(Modifier.padding(padding).fillMaxSize()) {
                Box(
                    Modifier
                        .fillMaxWidth()
                        .weight(1f),
                    contentAlignment = Alignment.Center,
                ) {
                    Box(
                        Modifier
                            .aspectRatio(bitmap.width.toFloat() / bitmap.height)
                            .onSizeChanged { canvasSize = it }
                            .pointerInput(Unit) {
                                awaitPointerEventScope {
                                    while (true) {
                                        val down = awaitPointerEvent().changes.firstOrNull() ?: continue
                                        if (!down.pressed) continue
                                        val stroke = BrushStroke(mutableListOf(down.position), brushSize)
                                        strokes.add(stroke)
                                        // Track the drag until release.
                                        while (true) {
                                            val event = awaitPointerEvent()
                                            val change = event.changes.firstOrNull() ?: break
                                            stroke.points.add(change.position)
                                            // Trigger recomposition (list identity change).
                                            strokes[strokes.lastIndex] = stroke
                                            change.consume()
                                            if (!change.pressed) break
                                        }
                                    }
                                }
                            },
                    ) {
                        Image(
                            bitmap.asImageBitmap(),
                            contentDescription = null,
                            contentScale = ContentScale.Fit,
                            modifier = Modifier.fillMaxSize(),
                        )
                        Canvas(Modifier.fillMaxSize()) {
                            for (stroke in strokes) {
                                if (stroke.points.isEmpty()) continue
                                val path = Path().apply {
                                    moveTo(stroke.points.first().x, stroke.points.first().y)
                                    for (point in stroke.points.drop(1)) lineTo(point.x, point.y)
                                }
                                drawPath(
                                    path,
                                    color = Color(0xFFFF2E97).copy(alpha = 0.55f),
                                    style = Stroke(width = stroke.width, cap = StrokeCap.Round, join = StrokeJoin.Round),
                                )
                            }
                        }
                    }
                }
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(stringResource(R.string.mask_brush), style = MaterialTheme.typography.bodySmall)
                    Slider(
                        value = brushSize,
                        onValueChange = { brushSize = it },
                        valueRange = 16f..120f,
                        modifier = Modifier.weight(1f).padding(start = 12.dp),
                    )
                }
            }
        }
    }
}

/** Rasterizes the strokes into a white-on-black PNG mask at the image's own resolution. */
private fun renderMask(
    imageWidth: Int,
    imageHeight: Int,
    canvasSize: IntSize,
    strokes: List<Pair<List<Offset>, Float>>,
): String {
    val mask = Bitmap.createBitmap(imageWidth, imageHeight, Bitmap.Config.ARGB_8888)
    val canvas = AndroidCanvas(mask)
    canvas.drawColor(android.graphics.Color.BLACK)
    val scaleX = imageWidth.toFloat() / canvasSize.width.coerceAtLeast(1)
    val scaleY = imageHeight.toFloat() / canvasSize.height.coerceAtLeast(1)
    val paint = Paint().apply {
        color = android.graphics.Color.WHITE
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
        isAntiAlias = true
    }
    for ((points, width) in strokes) {
        if (points.isEmpty()) continue
        paint.strokeWidth = width * scaleX
        val path = android.graphics.Path().apply {
            moveTo(points.first().x * scaleX, points.first().y * scaleY)
            for (point in points.drop(1)) lineTo(point.x * scaleX, point.y * scaleY)
        }
        canvas.drawPath(path, paint)
    }
    val out = ByteArrayOutputStream()
    mask.compress(Bitmap.CompressFormat.PNG, 100, out)
    mask.recycle()
    return Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
}
