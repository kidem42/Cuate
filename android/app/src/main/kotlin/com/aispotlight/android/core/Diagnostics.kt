package com.aispotlight.android.core

import android.content.Context
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Optional local diagnostics log (port of Diagnostics.swift): timestamped
 * category lines appended to a file; capped at ~500 KB with a simple rotate.
 * Off by default; toggled in Settings.
 */
object Diagnostics {
    @Volatile private var file: File? = null
    @Volatile private var enabled = false
    private val format = SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.US)

    fun init(context: Context, isEnabled: Boolean) {
        file = File(context.filesDir, "diagnostics.log")
        enabled = isEnabled
    }

    fun setEnabled(value: Boolean) {
        enabled = value
    }

    fun log(category: String, message: String) {
        if (!enabled) return
        val target = file ?: return
        synchronized(this) {
            try {
                if (target.length() > 500_000) {
                    // Keep the tail: drop the oldest half.
                    val tail = target.readText().let { it.substring(it.length / 2) }
                    target.writeText(tail)
                }
                target.appendText("${format.format(Date())} [$category] $message\n")
            } catch (_: Exception) {
                // Logging must never break the app.
            }
        }
    }

    fun logFile(): File? = file?.takeIf { it.exists() && it.length() > 0 }
}
