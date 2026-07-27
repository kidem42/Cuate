package com.aispotlight.android

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/**
 * Agent-run completion banners — the mobile analog of the desktop
 * NotificationService subsystem: a long Hermes task finishing while the app
 * is backgrounded (or another thread is on screen) posts a notification that
 * opens the app.
 */
object NotificationService {
    private const val CHANNEL_AGENT = "agent"

    /** Kept current by MainActivity onResume/onPause. */
    @Volatile var appVisible: Boolean = false

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_AGENT, "Agent", NotificationManager.IMPORTANCE_DEFAULT)
        )
    }

    /** True when POST_NOTIFICATIONS is granted (pre-13 always). */
    fun canNotify(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    fun notifyAgentDone(context: Context, title: String, snippet: String) {
        if (!canNotify(context)) return
        ensureChannel(context)
        val open = PendingIntent.getActivity(
            context, 0,
            Intent(context, com.aispotlight.android.ui.MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_AGENT)
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setContentTitle(title)
            .setContentText(snippet.ifEmpty { "Done" })
            .setStyle(NotificationCompat.BigTextStyle().bigText(snippet))
            .setAutoCancel(true)
            .setContentIntent(open)
            .build()
        try {
            NotificationManagerCompat.from(context)
                .notify(title.hashCode(), notification)
        } catch (_: SecurityException) {
            // Permission revoked between check and post — banner skipped.
        }
    }
}
