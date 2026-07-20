package com.aispotlight.android.chat

import android.content.Context
import android.media.MediaRecorder
import android.os.Build
import java.io.File

/**
 * Voice recording for STT: AAC in an .m4a container (the same format the
 * macOS app records, so the transcription endpoints get identical input).
 */
class AudioRecorderService(private val context: Context) {
    private var recorder: MediaRecorder? = null
    private var outputFile: File? = null

    val isRecording: Boolean get() = recorder != null

    /** Starts a new recording; returns false when the recorder can't start (e.g. mic busy). */
    fun start(): Boolean {
        stopInternal(deleteFile = true)
        val file = File(context.cacheDir, "recording-${System.currentTimeMillis()}.m4a")
        return try {
            val r = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(context)
            } else {
                @Suppress("DEPRECATION")
                MediaRecorder()
            }
            r.setAudioSource(MediaRecorder.AudioSource.MIC)
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            r.setAudioEncodingBitRate(64_000)
            r.setAudioSamplingRate(44_100)
            r.setOutputFile(file.path)
            r.prepare()
            r.start()
            recorder = r
            outputFile = file
            true
        } catch (_: Exception) {
            stopInternal(deleteFile = true)
            false
        }
    }

    /** Stops the recording and returns the audio file (null if nothing was recorded). */
    fun stop(): File? {
        val file = outputFile
        stopInternal(deleteFile = false)
        return file?.takeIf { it.exists() && it.length() > 0 }
    }

    fun cancel() = stopInternal(deleteFile = true)

    private fun stopInternal(deleteFile: Boolean) {
        try {
            recorder?.stop()
        } catch (_: Exception) {
            // Stopped too early (sub-second recording) — treat as empty.
        }
        recorder?.release()
        recorder = null
        if (deleteFile) {
            outputFile?.delete()
        }
        if (deleteFile) outputFile = null
    }
}
