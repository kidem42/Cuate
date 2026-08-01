package com.aispotlight.android.hermes

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import com.aispotlight.android.R
import java.util.concurrent.atomic.AtomicInteger

/**
 * Foreground service alive WHILE a Hermes agent turn streams — without it
 * Android tears the SSE socket down as soon as the app leaves the screen
 * (Doze / app standby), which surfaced as "aborted connection" and lost
 * replies (live bug 2026-07-30). `dataSync` type: the turn IS a data
 * transfer, and the quiet ongoing notification doubles as an honest
 * "agent is working" indicator.
 *
 * Ref-counted by [begin]/[end]: several parallel sessions may stream at
 * once (each conversation has its own turn job) — the service stops only
 * when the LAST turn finishes.
 */
class HermesRunService : Service() {

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, buildNotification(this))
        // If the process is killed mid-turn there is nothing to resume —
        // the recovery path re-syncs from the gateway transcript instead.
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?) = null

    companion object {
        private const val CHANNEL = "agent_run"
        private const val NOTIFICATION_ID = 7401
        private val active = AtomicInteger(0)

        /** A turn started: first one brings the service up. */
        fun begin(context: Context) {
            if (active.incrementAndGet() == 1) {
                try {
                    androidx.core.content.ContextCompat.startForegroundService(
                        context, Intent(context, HermesRunService::class.java)
                    )
                } catch (_: Exception) {
                    // Background-start restriction — the turn still runs,
                    // just without the keep-alive guarantee.
                    active.decrementAndGet()
                }
            }
        }

        /** A turn finished (any way): last one tears the service down. */
        fun end(context: Context) {
            if (active.updateAndGet { (it - 1).coerceAtLeast(0) } == 0) {
                context.stopService(Intent(context, HermesRunService::class.java))
            }
        }

        private fun buildNotification(context: Context): android.app.Notification {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val manager = context.getSystemService(NotificationManager::class.java)
                manager.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL,
                        context.getString(R.string.hermes_run_channel),
                        NotificationManager.IMPORTANCE_MIN,
                    )
                )
            }
            val open = PendingIntent.getActivity(
                context, 0,
                Intent(context, com.aispotlight.android.ui.MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            return NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_launcher_foreground)
                .setContentTitle(context.getString(R.string.hermes_run_notification))
                .setOngoing(true)
                .setSilent(true)
                .setContentIntent(open)
                .build()
        }
    }
}
