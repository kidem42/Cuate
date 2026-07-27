package com.aispotlight.android.hermes

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import com.aispotlight.android.core.Diagnostics
import com.aispotlight.android.settings.ApiKeyStore
import com.aispotlight.android.settings.AppSettings
import java.io.File
import java.security.MessageDigest

/**
 * The REVERSE file courier — port of the desktop 4.4 mechanics: pulls a
 * file the agent created on ITS host down to this phone through the Hermes
 * dashboard files API. Copies land in the app cache (silent auto-fetches
 * must not litter the user's Downloads); an explicit "save" exports to the
 * device's Downloads.
 */
object HermesFileCourier {

    /**
     * remotePath → local copy fetched this run, stamped with the freshness
     * it represents (the mentioning message's timestamp). A NEWER mention
     * of the same path refreshes the copy — the agent edited the file and
     * said so — instead of serving the stale one. Existence re-checked.
     */
    private val fetchedCopies = mutableMapOf<String, Pair<File, Long>>()
    /** remotePath → freshness whose silent fetch failed (newer mention retries). */
    private val autoFetchFailed = mutableMapOf<String, Long>()
    private val inFlight = mutableSetOf<String>()

    /** Auto-fetch serves previews, not archives. */
    private const val AUTO_FETCH_BYTE_LIMIT = 8 * 1024 * 1024

    /** Extensions the artifact viewer renders — the auto-fetch set. */
    val artifactExtensions = setOf("html", "htm", "md", "markdown")

    fun canFetchRemote(settings: AppSettings): Boolean =
        settings.hermesDashboardUrl.value.isNotEmpty() &&
            !ApiKeyStore.auxKey(ApiKeyStore.AuxKey.HERMES_DASHBOARD).isNullOrEmpty()

    fun fetchedCopy(path: String): File? =
        fetchedCopies[path]?.first?.takeIf { it.exists() }

    /** Whether the cached copy already satisfies this freshness — the
     *  auto-fetch loop's termination condition (no fetch, no re-render). */
    fun hasFreshCopy(path: String, asOf: Long): Boolean =
        fetchedCopies[path]?.let { (file, fetchedAsOf) ->
            file.exists() && fetchedAsOf >= asOf
        } ?: false

    private fun cacheDir(context: Context): File =
        File(context.cacheDir, "agent-files").apply { mkdirs() }

    /**
     * Downloads the remote path into the app cache and registers the copy.
     * Stable per-path name: a later fetch refreshes in place. Returns null
     * on any failure — callers fall back to copying the path.
     */
    suspend fun fetchRemote(
        context: Context,
        settings: AppSettings,
        path: String,
        /** Freshness the copy represents — a manual fetch is always newest. */
        asOf: Long = System.currentTimeMillis(),
    ): File? {
        val dashboard = settings.hermesDashboardUrl.value
        val token = ApiKeyStore.auxKey(ApiKeyStore.AuxKey.HERMES_DASHBOARD) ?: ""
        if (dashboard.isEmpty() || token.isEmpty()) return null
        return try {
            val bytes = HermesChatService.transport(settings)
                .downloadFromDashboard(dashboard, token, path)
            if (bytes.isEmpty()) return null
            val hash = MessageDigest.getInstance("SHA-256")
                .digest(path.toByteArray())
                .take(8).joinToString("") { "%02x".format(it) }
            val name = path.substringAfterLast("/").ifEmpty { "file" }
            val target = File(cacheDir(context), "$hash-$name")
            target.writeBytes(bytes)
            fetchedCopies[path] = target to asOf
            Diagnostics.log("hermes", "courier.fetch ok bytes=${bytes.size}")
            target
        } catch (e: Exception) {
            Diagnostics.log("hermes", "courier.fetch.fail ${e.message?.take(120)}")
            null
        }
    }

    /**
     * Silent fetch that materializes HTML/Markdown preview cards. Skips
     * quietly when the courier can't run, the path already failed, or a
     * fetch is in flight; oversized copies are dropped after the fact.
     */
    suspend fun autoFetchArtifact(
        context: Context,
        settings: AppSettings,
        path: String,
        /** The mentioning message's timestamp: an older cached copy is refreshed. */
        asOf: Long,
    ): File? {
        fetchedCopies[path]?.let { (file, fetchedAsOf) ->
            if (file.exists() && fetchedAsOf >= asOf) return file
        }
        if (!canFetchRemote(settings)) return null
        autoFetchFailed[path]?.let { failedAsOf -> if (failedAsOf >= asOf) return null }
        synchronized(inFlight) { if (!inFlight.add(path)) return null }
        try {
            val fetched = fetchRemote(context, settings, path, asOf)
            if (fetched == null) {
                autoFetchFailed[path] = asOf
                return null
            }
            if (fetched.length() > AUTO_FETCH_BYTE_LIMIT) {
                Diagnostics.log("hermes", "courier.fetch.skip cache-too-big bytes=${fetched.length()}")
                fetched.delete()
                fetchedCopies.remove(path)
                autoFetchFailed[path] = asOf
                return null
            }
            return fetched
        } finally {
            synchronized(inFlight) { inFlight.remove(path) }
        }
    }

    /**
     * Exports a cache copy into the device's Downloads — the explicit
     * "give me the file" moment. MediaStore on 29+, the app-scoped
     * Downloads dir on older API levels (no permission either way).
     * Returns a user-readable destination, or null on failure.
     */
    fun exportToDownloads(context: Context, file: File, displayName: String): String? {
        return try {
            if (Build.VERSION.SDK_INT >= 29) {
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, displayName)
                    put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                }
                val resolver = context.contentResolver
                val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                    ?: return null
                resolver.openOutputStream(uri)?.use { out ->
                    file.inputStream().use { it.copyTo(out) }
                } ?: return null
                "Downloads/$displayName"
            } else {
                val dir = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
                    ?: return null
                val target = File(dir, displayName)
                file.copyTo(target, overwrite = true)
                target.absolutePath
            }
        } catch (e: Exception) {
            Diagnostics.log("hermes", "courier.export.fail ${e.message?.take(120)}")
            null
        }
    }

}
