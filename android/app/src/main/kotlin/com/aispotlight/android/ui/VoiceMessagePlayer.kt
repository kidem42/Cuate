package com.aispotlight.android.ui

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaPlayer
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PauseCircle
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.io.File
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sqrt

/**
 * Inline voice-message player — a 1:1 port of the mac `VoiceMessagePlayer`:
 * the real audio envelope drawn as a thin-bar waveform (3dp bars, 4→18dp),
 * the played portion filling from the left in the theme's own color (Día
 * dark plays in marigold via `voiceProgress`), play button pinned left and a
 * monospaced duration label bottom-right. On top of the mac look the Android
 * player adds the messenger transport: scrubbing by tap/drag on the waveform,
 * a single active playback per chat and auto-advance down the voice queue.
 */

// MARK: - Waveform analysis (real audio envelope)

/**
 * Extracts the amplitude envelope of an audio file: decodes PCM via
 * MediaCodec, computes per-bucket RMS, normalizes with the mac's perceptual
 * curve (pow 0.6). Results are cached per file so re-renders never re-decode.
 */
private object WaveformAnalyzer {
    private val cache = ConcurrentHashMap<String, FloatArray>()

    suspend fun levels(path: String, buckets: Int = 56): FloatArray? = withContext(Dispatchers.Default) {
        cache[path] ?: compute(path, buckets)?.also { cache[path] = it }
    }

    private fun compute(path: String, buckets: Int): FloatArray? {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(path)
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                if (f.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                    extractor.selectTrack(i)
                    format = f
                    break
                }
            }
            val trackFormat = format ?: return null
            val mime = trackFormat.getString(MediaFormat.KEY_MIME) ?: return null
            val sampleRate = trackFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val durationUs = if (trackFormat.containsKey(MediaFormat.KEY_DURATION)) {
                trackFormat.getLong(MediaFormat.KEY_DURATION)
            } else return null
            val totalFrames = (durationUs * sampleRate / 1_000_000L).coerceAtLeast(1)
            val framesPerBucket = (totalFrames / buckets).coerceAtLeast(1)

            val decoder = MediaCodec.createDecoderByType(mime)
            codec = decoder
            decoder.configure(trackFormat, null, null, 0)
            decoder.start()

            val sumSquares = DoubleArray(buckets)
            val counts = IntArray(buckets)
            var frameOffset = 0L
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            val stride = 4 // sampling every 4th frame is plenty for an envelope

            while (!outputDone) {
                if (!inputDone) {
                    val inIndex = decoder.dequeueInputBuffer(10_000)
                    if (inIndex >= 0) {
                        val buf = decoder.getInputBuffer(inIndex) ?: continue
                        val size = extractor.readSampleData(buf, 0)
                        if (size < 0) {
                            decoder.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            decoder.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val outIndex = decoder.dequeueOutputBuffer(info, 10_000)
                if (outIndex >= 0) {
                    val out = decoder.getOutputBuffer(outIndex)
                    if (out != null && info.size > 0) {
                        val channels = decoder.outputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT).coerceAtLeast(1)
                        val shorts = out.order(ByteOrder.nativeOrder()).asShortBuffer()
                        val frames = shorts.remaining() / channels
                        var i = 0
                        while (i < frames) {
                            val bucket = min(buckets - 1, ((frameOffset + i) / framesPerBucket).toInt())
                            val sample = shorts.get(i * channels) / 32768.0
                            sumSquares[bucket] += sample * sample
                            counts[bucket]++
                            i += stride
                        }
                        frameOffset += frames
                    }
                    decoder.releaseOutputBuffer(outIndex, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                }
            }

            val levels = FloatArray(buckets)
            for (b in 0 until buckets) {
                if (counts[b] > 0) levels[b] = sqrt(sumSquares[b] / counts[b]).toFloat()
            }
            val peak = max(levels.max(), 1e-4f)
            // Normalize and lift quiet parts (perceptual curve) so speech reads well.
            return FloatArray(buckets) { (levels[it] / peak).pow(0.6f) }
        } catch (_: Exception) {
            return null
        } finally {
            try {
                codec?.stop()
                codec?.release()
            } catch (_: Exception) { }
            extractor.release()
        }
    }
}

// MARK: - Shared transport (one active playback + auto-advance)

/**
 * One shared voice transport per chat: only a single message sounds at a time
 * (starting one displaces the previous, resetting it to the start), and when
 * a message finishes, the next NEWER voice message in the list picks up —
 * the Telegram voice-queue behavior. `nowPlaying` is snapshot state, so every
 * player recomposes off the same source of truth.
 */
class VoicePlaybackCoordinator {
    /** audioPath of the message that should be sounding right now (null = silence). */
    var nowPlaying by mutableStateOf<String?>(null)
        private set

    /** All voice messages of the open chat, oldest → newest; ChatScreen keeps it fresh. */
    var queue: List<String> = emptyList()

    /** Players currently composed (≈ near the viewport) — valid handoff targets. */
    private val mounted = mutableSetOf<String>()

    fun mount(path: String) { mounted += path }

    /** A player left composition: it can no longer sound, so free the transport. */
    fun unmount(path: String) {
        mounted -= path
        if (nowPlaying == path) nowPlaying = null
    }

    fun play(path: String) { nowPlaying = path }

    fun pause(path: String) { if (nowPlaying == path) nowPlaying = null }

    /**
     * Auto-advance: a finished message hands the transport to the next newer
     * one — but only if that player is actually on screen. A dangling handoff
     * to a disposed item would start sounding whenever the user happens to
     * scroll it back in.
     */
    fun completed(path: String) {
        if (nowPlaying != path) return
        val next = queue.indexOf(path) + 1
        nowPlaying = queue.getOrNull(next)?.takeIf { it in mounted }
    }
}

// MARK: - Player

@Composable
fun VoiceMessagePlayer(
    audioPath: String,
    isUser: Boolean = true,
    coordinator: VoicePlaybackCoordinator = remember { VoicePlaybackCoordinator() },
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val file = remember(audioPath) { File(context.filesDir, audioPath) }
    var progress by remember { mutableFloatStateOf(0f) }
    // While the finger is on the waveform, the poll loop must not fight the
    // drag for `progress`; the seek lands on release.
    var scrubbing by remember { mutableStateOf(false) }
    var levels by remember(audioPath) { mutableStateOf<FloatArray?>(null) }
    val player = remember(audioPath) {
        if (file.exists()) {
            try {
                MediaPlayer().apply {
                    setDataSource(file.path)
                    prepare()
                }
            } catch (_: Exception) {
                null
            }
        } else null
    }
    // This message plays iff the shared transport points at it.
    val active = coordinator.nowPlaying == audioPath

    DisposableEffect(player) {
        coordinator.mount(audioPath)
        player?.setOnCompletionListener {
            progress = 0f
            coordinator.completed(audioPath)
        }
        onDispose {
            // Scrolled out of the window mid-play: the MediaPlayer dies with
            // the composable, so free the transport too.
            coordinator.unmount(audioPath)
            player?.release()
        }
    }

    // The transport drives the MediaPlayer: start when it points here, pause
    // when it leaves. A displacement (another message started) also rewinds
    // this one to the beginning; a plain user pause keeps the position.
    LaunchedEffect(active, player) {
        val p = player ?: return@LaunchedEffect
        if (active) {
            try { p.start() } catch (_: Exception) { }
            while (true) {
                if (!scrubbing && p.duration > 0) {
                    progress = p.currentPosition.toFloat() / p.duration
                }
                delay(100)
            }
        } else {
            try {
                if (p.isPlaying) p.pause()
                if (coordinator.nowPlaying != null) {
                    p.seekTo(0)
                    progress = 0f
                }
            } catch (_: Exception) { }
        }
    }

    // Real audio envelope, decoded off the main thread and cached per file.
    LaunchedEffect(audioPath) {
        if (file.exists()) levels = WaveformAnalyzer.levels(file.path)
    }

    if (player == null) return

    // Colors — verbatim from the mac player: the thin-line equalizer pattern
    // is kept across all themes; the palette only overrides the played
    // portion (Día dark: marigold) and the chrome tint.
    val palette = LocalChatPalette.current
    val dark = palette.dark
    val baseTrackColor = voiceTrackColor(isUser, dark)
    val accent = if (palette.isDynamic) MaterialTheme.colorScheme.primary else palette.accent
    val fillWaveColor = when {
        !palette.isDynamic && isUser && palette.voiceProgress != null -> palette.voiceProgress!!
        isUser -> if (dark) Color.White else Color.Black.copy(alpha = 0.8f)
        else -> accent
    }
    val playButtonColor = when {
        !palette.isDynamic -> if (isUser) palette.userText else palette.accent
        isUser -> if (dark) Color.White else MaterialTheme.colorScheme.onSurface
        else -> accent
    }
    val timeLabelColor = when {
        !palette.isDynamic -> if (isUser) palette.userText.copy(alpha = 0.8f) else palette.secondaryText
        isUser && dark -> Color.White.copy(alpha = 0.8f)
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }

    // Width comes from the caller (the bubble's voice floor); default keeps a
    // sensible standalone size.
    Column(modifier.widthIn(min = 220.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            // Play/Pause pinned to the leading edge (mac: 28pt circle glyph).
            IconButton(
                onClick = {
                    if (active) coordinator.pause(audioPath) else coordinator.play(audioPath)
                },
                modifier = Modifier.size(36.dp),
            ) {
                Icon(
                    if (active) Icons.Filled.PauseCircle else Icons.Filled.PlayCircle,
                    contentDescription = null,
                    tint = playButtonColor,
                    modifier = Modifier.size(30.dp),
                )
            }
            Spacer(Modifier.width(8.dp))
            // Scrubbing, the messenger way: tap jumps, a horizontal drag
            // scrubs with live fill and the seek applied on release. The
            // canvas is taller than the bars (centered) purely for the
            // finger's sake.
            WaveformBars(
                progress = progress,
                levels = levels,
                baseColor = baseTrackColor,
                fillColor = fillWaveColor,
                modifier = Modifier
                    .weight(1f)
                    .height(32.dp)
                    .pointerInput(player) {
                        detectTapGestures { offset ->
                            val f = (offset.x / size.width.toFloat()).coerceIn(0f, 1f)
                            progress = f
                            try {
                                if (player.duration > 0) player.seekTo((f * player.duration).toInt())
                            } catch (_: Exception) { }
                        }
                    }
                    .pointerInput(player) {
                        detectHorizontalDragGestures(
                            onDragStart = { offset ->
                                scrubbing = true
                                progress = (offset.x / size.width.toFloat()).coerceIn(0f, 1f)
                            },
                            onDragEnd = {
                                try {
                                    if (player.duration > 0) {
                                        player.seekTo((progress * player.duration).toInt())
                                    }
                                } catch (_: Exception) { }
                                scrubbing = false
                            },
                            onDragCancel = { scrubbing = false },
                        ) { change, _ ->
                            change.consume()
                            progress = (change.position.x / size.width.toFloat()).coerceIn(0f, 1f)
                        }
                    },
            )
        }
        // Bottom row: monospaced digits bottom-right (mac caption2) — the
        // total duration at rest, the live position while playing/scrubbing.
        val durationMs = player.duration
        val seconds = if (active || scrubbing || progress > 0f) {
            (progress.coerceIn(0f, 1f) * durationMs).toInt() / 1000
        } else {
            durationMs / 1000
        }
        Text(
            "%d:%02d".format(seconds / 60, seconds % 60),
            style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
            color = timeLabelColor,
            modifier = Modifier.align(Alignment.End),
        )
    }
}

// MARK: - Pending placeholder (reply is being voiced)

/**
 * The player's silhouette shown while a spoken reply is still streaming or
 * being synthesized: a disabled play glyph and flat quiet bars, pulsing
 * gently. Keeps the bubble in its voice shape so the real player lands
 * without a layout jump.
 */
@Composable
fun PendingVoiceBar(isUser: Boolean, modifier: Modifier = Modifier) {
    val palette = LocalChatPalette.current
    val baseTrackColor = voiceTrackColor(isUser, palette.dark)
    val accent = if (palette.isDynamic) MaterialTheme.colorScheme.primary else palette.accent
    val pulse by rememberInfiniteTransition(label = "voicePending")
        .animateFloat(
            initialValue = 0.45f,
            targetValue = 1f,
            animationSpec = infiniteRepeatable(tween(900), RepeatMode.Reverse),
            label = "alpha",
        )
    Column(modifier.widthIn(min = 220.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(36.dp), contentAlignment = Alignment.Center) {
                Icon(
                    Icons.Filled.PlayCircle,
                    contentDescription = null,
                    tint = accent.copy(alpha = 0.4f),
                    modifier = Modifier.size(30.dp),
                )
            }
            Spacer(Modifier.width(8.dp))
            WaveformBars(
                progress = 0f,
                levels = null,
                baseColor = baseTrackColor,
                fillColor = baseTrackColor,
                modifier = Modifier.weight(1f).height(32.dp).alpha(pulse),
            )
        }
        Text(
            "…",
            style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
            color = if (!palette.isDynamic) palette.secondaryText else MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.align(Alignment.End),
        )
    }
}

/** The unplayed-track tint shared by the player and the pending placeholder. */
private fun voiceTrackColor(isUser: Boolean, dark: Boolean): Color = if (isUser) {
    if (dark) Color.White.copy(alpha = 0.35f) else Color.Black.copy(alpha = 0.25f)
} else {
    if (dark) Color.White.copy(alpha = 0.25f) else Color.Black.copy(alpha = 0.20f)
}

// MARK: - Waveform view (3dp bars / 2dp gaps, 4→18dp, filled from the left)

@Composable
private fun WaveformBars(
    progress: Float,
    levels: FloatArray?,
    baseColor: Color,
    fillColor: Color,
    modifier: Modifier = Modifier,
) {
    Canvas(modifier) {
        val barWidth = 3.dp.toPx()
        val spacing = 2.dp.toPx()
        val minHeight = 4.dp.toPx()
        val maxHeight = 18.dp.toPx()
        val count = max(8, ((size.width + spacing) / (barWidth + spacing)).toInt())
        val filledWidth = size.width * progress.coerceIn(0f, 1f)

        fun barHeight(i: Int): Float {
            // Real envelope: resample the analyzed buckets to the bar count.
            if (levels != null && levels.isNotEmpty()) {
                val index = min(levels.size - 1, i * levels.size / max(1, count))
                return minHeight + (maxHeight - minHeight) * levels[index]
            }
            // Placeholder while the file is being analyzed: flat quiet bars.
            return minHeight + 2.dp.toPx()
        }

        for (i in 0 until count) {
            val x = i * (barWidth + spacing)
            val h = barHeight(i)
            val top = (size.height - h) / 2f
            // Base bar, then the filled overlay clipped by played width.
            drawRoundRect(baseColor, Offset(x, top), Size(barWidth, h), CornerRadius(1.dp.toPx()))
            if (x < filledWidth) {
                val visible = min(barWidth, filledWidth - x)
                drawRoundRect(fillColor, Offset(x, top), Size(visible, h), CornerRadius(1.dp.toPx()))
            }
        }
    }
}
