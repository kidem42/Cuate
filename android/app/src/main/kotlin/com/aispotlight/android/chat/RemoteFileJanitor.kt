package com.aispotlight.android.chat

import android.content.Context
import com.aispotlight.android.core.Diagnostics
import com.aispotlight.android.core.ProviderException
import com.aispotlight.android.core.ProviderID
import com.aispotlight.android.providers.OpenAIFilesService
import com.aispotlight.android.settings.ApiKeyStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject

/**
 * Best-effort deletion of provider-side document copies. Every place that
 * lets an attachment go enqueues the remote ids here; the queue is persisted
 * so an offline deletion is retried at the next launch. Server-side expiry
 * (`expires_after` at upload) is the backstop. Port of the Mac janitor.
 */
object RemoteFileJanitor {
    private const val PREFS = "files.janitor"
    private const val KEY_QUEUE = "queue"
    private const val MAX_ENTRIES = 200

    private lateinit var appContext: Context
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val drainMutex = Mutex()

    fun init(context: Context) {
        appContext = context.applicationContext
    }

    /** Adds ids (deduplicated) and kicks a drain. */
    fun enqueue(provider: ProviderID, fileIds: Collection<String>) {
        val fresh = fileIds.filter { it.isNotEmpty() }
        if (fresh.isEmpty() || !::appContext.isInitialized) return
        synchronized(this) {
            val entries = load().toMutableList()
            for (id in fresh) {
                val entry = provider.id to id
                if (entry !in entries) entries.add(entry)
            }
            while (entries.size > MAX_ENTRIES) entries.removeAt(0)
            save(entries)
            Diagnostics.log("files", "janitor enqueue count=${fresh.size} queued=${entries.size}")
        }
        drainSoon()
    }

    fun drainSoon() {
        if (!::appContext.isInitialized) return
        scope.launch { drain() }
    }

    private suspend fun drain() = drainMutex.withLock {
        val entries = synchronized(this) { load() }
        if (entries.isEmpty()) return@withLock
        val remaining = mutableListOf<Pair<String, String>>()
        for ((providerId, fileId) in entries) {
            val provider = ProviderID.fromId(providerId)
            if (provider != ProviderID.OPENAI) continue // nothing to call: drop
            val apiKey = ApiKeyStore.key(provider)
            if (apiKey == null) { remaining.add(providerId to fileId); continue }
            try {
                OpenAIFilesService.delete(fileId, apiKey)
                Diagnostics.log("files", "delete id=$fileId status=ok")
            } catch (e: ProviderException) {
                val message = e.message ?: ""
                // Client errors won't heal on retry (bad id, revoked key).
                if (Regex("HTTP 4\\d\\d").containsMatchIn(message)) {
                    Diagnostics.log("files", "delete id=$fileId dropped (${message.take(80)})")
                } else {
                    Diagnostics.log("files", "delete id=$fileId failed — kept (${message.take(80)})")
                    remaining.add(providerId to fileId)
                }
            } catch (e: Exception) {
                Diagnostics.log("files", "delete id=$fileId failed — kept (${e.message?.take(80)})")
                remaining.add(providerId to fileId)
            }
        }
        synchronized(this) {
            // Entries added while draining stay; only the processed ones go.
            val processed = entries.map { it.second }.toSet() - remaining.map { it.second }.toSet()
            save(load().filter { it.second !in processed })
        }
    }

    private fun load(): List<Pair<String, String>> {
        val raw = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_QUEUE, null)
            ?: return emptyList()
        return try {
            val array = JSONArray(raw)
            (0 until array.length()).mapNotNull { index ->
                val item = array.optJSONObject(index) ?: return@mapNotNull null
                item.optString("provider") to item.optString("fileId")
            }.filter { it.second.isNotEmpty() }
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun save(entries: List<Pair<String, String>>) {
        val prefs = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (entries.isEmpty()) {
            prefs.edit().remove(KEY_QUEUE).apply()
            return
        }
        val array = JSONArray()
        for ((provider, fileId) in entries) {
            array.put(JSONObject().put("provider", provider).put("fileId", fileId))
        }
        prefs.edit().putString(KEY_QUEUE, array.toString()).apply()
    }
}
