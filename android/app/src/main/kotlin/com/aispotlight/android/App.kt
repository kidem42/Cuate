package com.aispotlight.android

import android.app.Application
import com.aispotlight.android.settings.ApiKeyStore
import com.aispotlight.android.settings.AppSettings
import java.io.File

class App : Application() {
    override fun onCreate() {
        super.onCreate()
        ApiKeyStore.init(this)
        val settings = AppSettings.shared(this)
        settings.reconcileHolidayTheme()
        com.aispotlight.android.core.Diagnostics.init(this, settings.diagnosticsEnabled.value)
        com.aispotlight.android.providers.PricingCatalog.init(this)
        com.aispotlight.android.data.SpendTracker.init(this)
        sweepExpiredMedia()
    }

    /**
     * Media retention (port of Config.mediaRetentionDays): image and voice
     * files older than 15 days are deleted at launch; rows survive and render
     * gracefully without their payload.
     */
    private fun sweepExpiredMedia() {
        Thread {
            val cutoff = System.currentTimeMillis() - 15L * 24 * 60 * 60 * 1000
            for (dir in listOf(File(filesDir, "images"), File(filesDir, "recordings"))) {
                dir.listFiles()?.forEach { file ->
                    if (file.lastModified() < cutoff) file.delete()
                }
            }
        }.apply { isDaemon = true }.start()
    }
}
