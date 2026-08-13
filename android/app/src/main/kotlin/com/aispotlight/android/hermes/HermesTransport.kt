package com.aispotlight.android.hermes

import com.aispotlight.android.core.HttpClient
import com.aispotlight.android.core.TokenUsage
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * HTTP + SSE client for the Hermes Agent API server — the Kotlin port of
 * `HermesTransport.swift`, written against LIVE fixtures
 * (`Cuate/Addons/HermesAddon/Hermes-API-Fixtures.md`, Hermes 0.19.0) — not
 * the docs prose. Value type: one instance per call site, holding the
 * endpoint and token.
 */

// MARK: - Wire models (shapes from the fixtures)

/** `/v1/capabilities` — feature flags gate whole UI sections. */
data class HermesCapabilities(
    val features: Map<String, Boolean> = emptyMap(),
    val platform: String = "",
) {
    fun supports(feature: String): Boolean = features[feature] ?: false
}

/** One session row from `/api/sessions` or `POST /api/sessions`. */
data class HermesSessionInfo(
    val id: String,
    val title: String?,
    val model: String?,
    val source: String?,
    val startedAt: Long?,
    val lastActive: Long?,
    val messageCount: Int,
    val toolCallCount: Int,
    val inputTokens: Int,
    val outputTokens: Int,
    val preview: String?,
    /**
     * Server-side pin (Hermes 0.20: PATCH persists it, the list backfills
     * pinned sessions past the recency window). null = gateway predates the
     * field — local pins stay the only truth then.
     */
    val pinned: Boolean? = null,
)

/**
 * One transcript row from `GET /api/sessions/{id}/messages`. `id` is the
 * gateway's integer sequence within the session; the stable external
 * identity is `"<sessionID>#<id>"`.
 */
data class HermesTranscriptMessage(
    val id: Int,
    val role: String, // user | assistant | tool
    val content: String,
    val toolName: String?,
    /** tool rows: which call this result answers. */
    val toolCallID: String?,
    /** assistant shells: calls with their raw JSON arguments (drill-down source). */
    val toolCallArguments: List<Pair<String, String>>,
    val timestampMs: Long?,
) {
    fun externalID(sessionID: String): String = "$sessionID#$id"
}

data class HermesSkill(val name: String, val description: String, val category: String)

data class HermesToolset(
    val name: String,
    val label: String, // gateway sends it emoji-prefixed, render as is
    val description: String,
    val enabled: Boolean,
    val tools: List<String>,
)

/** `/api/model/options` — provider rows for the model-lock picker. */
data class HermesProviderOption(
    val slug: String,
    val name: String,
    val isCurrent: Boolean,
    val models: List<String>,
)

data class HermesModelOptions(
    /** The agent's CURRENT (provider, model) pair from the response top level. */
    val current: Pair<String, String>?,
    val providers: List<HermesProviderOption>,
)

/**
 * SSE frames of `POST /api/sessions/{id}/chat/stream` (fixture order:
 * run.started → message.started → tool.* / assistant.delta →
 * assistant.completed → run.completed → done).
 */
sealed class HermesStreamEvent {
    data class RunStarted(val runID: String) : HermesStreamEvent()
    data class MessageStarted(val messageID: String) : HermesStreamEvent()
    data class ToolStarted(val tool: String, val preview: String?) : HermesStreamEvent()
    /** `tool == "_thinking"` is the model's reasoning stream, not a tool. */
    data class ToolProgress(val tool: String, val delta: String) : HermesStreamEvent()
    data class ToolCompleted(val tool: String) : HermesStreamEvent()
    data class AssistantDelta(val delta: String) : HermesStreamEvent()
    /**
     * Definitive full text. NOTE: a turn that failed on the gateway ALSO
     * arrives this way — as error text with HTTP 200 (see fixtures). One run
     * can carry SEVERAL of these (interim assistant messages) — glue, don't
     * replace.
     */
    data class AssistantCompleted(
        val content: String,
        val interrupted: Boolean,
        /** ACTUAL (provider, model) this turn ran on (`runtime`, 0.20) — null on older gateways. */
        val runtimeProvider: String? = null,
        val runtimeModel: String? = null,
    ) : HermesStreamEvent()
    /**
     * `contextTokens` — the prompt size of the run's LAST model call, i.e.
     * the session's actual context fill (Hermes' own status-bar number).
     * Only patched gateways send it (`usage.context_tokens`, the Cuate
     * gateway patch); stock reports run-CUMULATIVE sums in `usage`.
     */
    data class RunCompleted(
        val usage: TokenUsage,
        val contextTokens: Int? = null,
        /** The agent's effective window (`usage.context_window`, OAuth caps included). */
        val windowTokens: Int? = null,
    ) : HermesStreamEvent()
    object Done : HermesStreamEvent()
    /** Approval frames (feature-flagged, dormant in 0.19.0) and future events. */
    data class Unknown(val event: String, val payload: JSONObject) : HermesStreamEvent()
}

class HermesTransportException(val status: Int, body: String) :
    Exception("Hermes API error (HTTP $status): ${body.take(200)}")

// MARK: - Transport

/**
 * Dedicated client for the chat SSE stream: the shared [HttpClient] enforces
 * readTimeout=120s and callTimeout=600s — an agent turn with one long silent
 * tool (or simply longer than 10 minutes) was killed by our OWN client,
 * surfacing as "aborted connection" (live bug 2026-07-30). Agent turns are
 * unbounded: no read/call timeout, only the connect handshake stays capped.
 */
private val sseClient: okhttp3.OkHttpClient by lazy {
    HttpClient.client.newBuilder()
        .readTimeout(0, java.util.concurrent.TimeUnit.SECONDS)
        .callTimeout(0, java.util.concurrent.TimeUnit.SECONDS)
        .build()
}

class HermesTransport(
    baseURL: String,
    private val apiKey: String,
) {
    private val base: HttpUrl? = baseURL.trim().trimEnd('/').toHttpUrlOrNull()
    private val jsonMedia = "application/json".toMediaType()

    private fun url(path: String, query: Map<String, String> = emptyMap()): HttpUrl {
        val builder = (base ?: throw HermesTransportException(0, "Bad endpoint URL"))
            .newBuilder()
        path.split("/").forEach { builder.addPathSegment(it) }
        query.forEach { (k, v) -> builder.addQueryParameter(k, v) }
        return builder.build()
    }

    private fun request(method: String, path: String, body: JSONObject? = null,
                        query: Map<String, String> = emptyMap()): Request {
        val builder = Request.Builder().url(url(path, query))
        if (apiKey.isNotEmpty()) builder.header("Authorization", "Bearer $apiKey")
        when (method) {
            "GET" -> builder.get()
            "DELETE" -> builder.delete()
            else -> builder.method(method, (body ?: JSONObject()).toString().toRequestBody(jsonMedia))
        }
        return builder.build()
    }

    /** Runs a request and returns the parsed JSON object (non-2xx → exception). */
    private suspend fun json(method: String, path: String, body: JSONObject? = null,
                             query: Map<String, String> = emptyMap()): JSONObject {
        val text = HttpClient.json(request(method, path, body, query))
        return try { JSONObject(text) } catch (_: Exception) {
            throw HermesTransportException(0, "not a JSON object at $path")
        }
    }

    // MARK: Probe & discovery

    /** `GET /health` is unauthenticated: `{"status":"ok","platform":...,"version":...}`. */
    suspend fun health(): String {
        val obj = json("GET", "health")
        return "${obj.optString("platform", "?")} ${obj.optString("version", "?")}"
    }

    suspend fun capabilities(): HermesCapabilities {
        val obj = json("GET", "v1/capabilities")
        val features = mutableMapOf<String, Boolean>()
        obj.optJSONObject("features")?.let { raw ->
            for (key in raw.keys()) {
                (raw.opt(key) as? Boolean)?.let { features[key] = it }
            }
        }
        return HermesCapabilities(features, obj.optString("platform", ""))
    }

    /**
     * `/api/model/options`: provider rows + the agent's CURRENT
     * (provider, model) pair at top level — the reliable model-lock source.
     */
    suspend fun modelOptions(refresh: Boolean = false): HermesModelOptions {
        // `?refresh=true` drops the gateway's ~1h catalog cache (fixtures) —
        // the picker's Refresh button maps to it.
        val obj = json("GET", "api/model/options",
            query = if (refresh) mapOf("refresh" to "true") else emptyMap())
        val providers = mutableListOf<HermesProviderOption>()
        obj.optJSONArray("providers")?.let { rows ->
            for (i in 0 until rows.length()) {
                val row = rows.optJSONObject(i) ?: continue
                val slug = row.optString("slug", "")
                if (slug.isEmpty()) continue
                val models = mutableListOf<String>()
                row.optJSONArray("models")?.let { m ->
                    for (j in 0 until m.length()) models.add(m.optString(j))
                }
                providers.add(HermesProviderOption(
                    slug = slug,
                    name = row.optString("name", slug),
                    isCurrent = row.optBoolean("is_current", false),
                    models = models,
                ))
            }
        }
        val model = obj.optString("model", "")
        val provider = obj.optString("provider", "")
        val current = if (model.isNotEmpty() && provider.isNotEmpty()) provider to model else null
        return HermesModelOptions(current, providers)
    }

    /**
     * `/api/model/info`: the agent's CURRENT model plus the context window
     * Hermes resolved for it (config override → probes → OAuth caps →
     * table). ⚠️ The route belongs to the DASHBOARD server, not the API
     * server — build this transport on the dashboard URL (the route is in
     * the dashboard's public paths, the courier token is optional there).
     * Against the API server it 404s; callers treat that as "no data".
     */
    suspend fun modelInfo(): Pair<String, Int> {
        val obj = json("GET", "api/model/info")
        return obj.optString("model", "") to obj.optInt("effective_context_length", 0)
    }

    // MARK: Sessions

    private fun sessionInfo(row: JSONObject): HermesSessionInfo? {
        val id = row.optString("id", "")
        if (id.isEmpty()) return null
        fun seconds(name: String): Long? =
            if (row.has(name) && !row.isNull(name)) (row.optDouble(name) * 1000).toLong() else null
        return HermesSessionInfo(
            id = id,
            title = row.optString("title", "").ifEmpty { null },
            model = row.optString("model", "").ifEmpty { null },
            source = row.optString("source", "").ifEmpty { null },
            startedAt = seconds("started_at"),
            lastActive = seconds("last_active"),
            messageCount = row.optInt("message_count", 0),
            toolCallCount = row.optInt("tool_call_count", 0),
            inputTokens = row.optInt("input_tokens", 0),
            outputTokens = row.optInt("output_tokens", 0),
            preview = row.optString("preview", "").ifEmpty { null },
            pinned = if (row.has("pinned") && !row.isNull("pinned"))
                row.optBoolean("pinned") else null,
        )
    }

    suspend fun createSession(title: String): HermesSessionInfo {
        val obj = json("POST", "api/sessions", JSONObject().put("title", title))
        return obj.optJSONObject("session")?.let { sessionInfo(it) }
            ?: throw HermesTransportException(0, "session create")
    }

    suspend fun sessions(limit: Int = 50, offset: Int = 0): List<HermesSessionInfo> {
        val obj = json("GET", "api/sessions",
            query = mapOf("limit" to "$limit", "offset" to "$offset"))
        val data = obj.optJSONArray("data") ?: JSONArray()
        return (0 until data.length()).mapNotNull { data.optJSONObject(it)?.let(::sessionInfo) }
    }

    suspend fun deleteSession(id: String) { json("DELETE", "api/sessions/$id") }

    /** Renames a session on the gateway (`PATCH` accepts `title`). */
    suspend fun renameSession(id: String, title: String) {
        json("PATCH", "api/sessions/$id", JSONObject().put("title", title))
    }

    /**
     * Persists a pin on the gateway (Hermes 0.20; 0.19 rejected the field
     * with a 400 — callers treat failure as "server can't, local pin only").
     */
    suspend fun setSessionPinned(id: String, pinned: Boolean) {
        json("PATCH", "api/sessions/$id", JSONObject().put("pinned", pinned))
    }

    /**
     * `POST /api/sessions/{id}/steer` — the Cuate gateway patch (0.20+,
     * advertised as `features.session_steer`): injects follow-up text into
     * the RUNNING turn (rides the next tool-batch boundary, no interrupt).
     * Returns true when queued, false when the agent refused. Throws
     * [HermesTransportException] with status 409 (`no_active_turn`) when
     * nothing is running — callers fall back to an ordinary send.
     */
    suspend fun steer(sessionID: String, text: String): Boolean {
        val obj = json("POST", "api/sessions/$sessionID/steer",
            JSONObject().put("text", text))
        return obj.optString("status") == "queued"
    }

    /**
     * ⚠️ Required after [createSession]: a fresh session inherits the literal
     * model "hermes-agent" and every turn 404s until locked (fixtures).
     * Provider+model pairs come from [modelOptions].
     *
     * Returns what the gateway ACTUALLY locked (provider, model): 0.20 runs
     * the body through config `model_routes` first, and an alias route there
     * silently overrides the explicit provider (found live 2026-08-13 —
     * picked Codex, got Nous Portal; the 200 carried the truth in
     * `runtime`). Callers must compare and surface a reroute.
     */
    suspend fun lockModel(sessionID: String, provider: String, model: String): Pair<String, String> {
        val obj = json("POST", "api/sessions/$sessionID/model",
            JSONObject().put("model", model).put("provider", provider))
        val runtime = obj.optJSONObject("runtime")
        return (runtime?.optString("provider")?.ifEmpty { null } ?: provider) to
            (runtime?.optString("model")?.ifEmpty { null } ?: model)
    }

    /**
     * Full transcript. Hermes 0.20 paginated `/messages` — an unqualified GET
     * there returns only the LATEST 500, silently beheading long sessions —
     * so this walks explicit oldest-first pages until a short one. A 0.19
     * gateway ignores the params (and sends no `pagination` block), so the
     * loop stops after its single full answer either way.
     */
    suspend fun messages(sessionID: String): List<HermesTranscriptMessage> {
        val pageSize = 500 // server cap per page (0.20)
        val maxPages = 40  // 20k rows — a runaway bound, not a target
        val rows = mutableListOf<HermesTranscriptMessage>()
        var offset = 0
        for (page in 0 until maxPages) {
            val obj = json(
                "GET", "api/sessions/$sessionID/messages",
                query = mapOf(
                    "order" to "oldest",
                    "limit" to pageSize.toString(),
                    "offset" to offset.toString(),
                ))
            val data = obj.optJSONArray("data") ?: JSONArray()
            rows += parseTranscript(data)
            if (data.length() < pageSize || !obj.has("pagination")) break
            offset += data.length()
        }
        return rows
    }

    private fun parseTranscript(data: JSONArray): List<HermesTranscriptMessage> {
        return (0 until data.length()).mapNotNull { i ->
            val row = data.optJSONObject(i) ?: return@mapNotNull null
            if (!row.has("id") || row.isNull("id")) return@mapNotNull null
            val calls = mutableListOf<Pair<String, String>>()
            row.optJSONArray("tool_calls")?.let { rawCalls ->
                for (j in 0 until rawCalls.length()) {
                    val call = rawCalls.optJSONObject(j) ?: continue
                    val callID = call.optString("id", call.optString("call_id", ""))
                    if (callID.isEmpty()) continue
                    calls.add(callID to (call.optJSONObject("function")?.optString("arguments") ?: ""))
                }
            }
            HermesTranscriptMessage(
                id = row.optInt("id"),
                role = row.optString("role", ""),
                content = if (row.isNull("content")) "" else row.optString("content", ""),
                toolName = row.optString("tool_name", "").ifEmpty { null },
                toolCallID = row.optString("tool_call_id", "").ifEmpty { null },
                toolCallArguments = calls,
                timestampMs = if (row.has("timestamp") && !row.isNull("timestamp"))
                    (row.optDouble("timestamp") * 1000).toLong() else null,
            )
        }
    }

    // MARK: Skills & toolsets

    suspend fun skills(): List<HermesSkill> {
        val obj = json("GET", "v1/skills")
        val data = obj.optJSONArray("data") ?: JSONArray()
        return (0 until data.length()).mapNotNull { i ->
            val row = data.optJSONObject(i) ?: return@mapNotNull null
            val name = row.optString("name", "")
            if (name.isEmpty()) null
            else HermesSkill(name, row.optString("description", ""), row.optString("category", ""))
        }
    }

    suspend fun toolsets(): List<HermesToolset> {
        val obj = json("GET", "v1/toolsets")
        val data = obj.optJSONArray("data") ?: JSONArray()
        return (0 until data.length()).mapNotNull { i ->
            val row = data.optJSONObject(i) ?: return@mapNotNull null
            val name = row.optString("name", "")
            if (name.isEmpty()) return@mapNotNull null
            val tools = mutableListOf<String>()
            row.optJSONArray("tools")?.let { t ->
                for (j in 0 until t.length()) tools.add(t.optString(j))
            }
            HermesToolset(name, row.optString("label", name),
                row.optString("description", ""), row.optBoolean("enabled", false), tools)
        }
    }

    // MARK: Runs

    suspend fun stopRun(runID: String) { json("POST", "v1/runs/$runID/stop") }

    // MARK: File upload (dashboard server)

    /**
     * Uploads one local file into `~/cuate-uploads/<name>` on the agent's
     * host through the Hermes DASHBOARD server's files API
     * (`/api/files/upload-stream`, multipart, its own bearer token — the
     * desktop `HermesFileCourier` mechanics). Returns the remote path the
     * note should mention. On Android every gateway is remote, so this is
     * the only way a non-image file reaches the agent.
     */
    suspend fun uploadToDashboard(dashboardURL: String, token: String, file: File): String {
        val dash = dashboardURL.trim().trimEnd('/').toHttpUrlOrNull()
            ?: throw HermesTransportException(0, "Bad dashboard URL")
        val remoteRelative = "cuate-uploads/${file.name}"
        val body = MultipartBody.Builder()
            .setType(MultipartBody.FORM)
            .addFormDataPart("path", "~/$remoteRelative")
            .addFormDataPart("overwrite", "true")
            .addFormDataPart("file", file.name,
                // Streamed from disk: readBytes() held the whole payload in
                // memory, and a buffered body cannot be resent — streaming
                // keeps a 60 MB video from doubling the heap on send.
                file.asRequestBody("application/octet-stream".toMediaType()))
            .build()
        val request = Request.Builder()
            .url(dash.newBuilder().addPathSegments("api/files/upload-stream").build())
            .header("Authorization", "Bearer $token")
            .post(body)
            .build()
        val response = HttpClient.json(request)
        // The response carries the display path; fall back to our target.
        val display = try { JSONObject(response).optString("path", "") } catch (_: Exception) { "" }
        return display.ifEmpty { "~/$remoteRelative" }
    }

    /**
     * Downloads a file FROM the agent's host through the dashboard files
     * API (`/api/files/download?path=…`, same bearer token as the upload) —
     * the REVERSE courier: how a file the agent created on its machine
     * reaches this phone (desktop 4.4 mechanics).
     */
    suspend fun downloadFromDashboard(dashboardURL: String, token: String, path: String): ByteArray {
        val dash = dashboardURL.trim().trimEnd('/').toHttpUrlOrNull()
            ?: throw HermesTransportException(0, "Bad dashboard URL")
        val request = Request.Builder()
            .url(dash.newBuilder()
                .addPathSegments("api/files/download")
                .addQueryParameter("path", path)
                .build())
            .header("Authorization", "Bearer $token")
            .get()
            .build()
        return HttpClient.bytes(request)
    }

    // MARK: Chat stream (SSE)

    /**
     * Builds the `input` payload: plain text, or OpenAI-style content parts
     * when images ride along (probed live: the parts array works, a flat
     * `images` field is silently ignored — see fixtures).
     */
    fun inputPayload(text: String, images: List<Pair<String, String>>): Any {
        if (images.isEmpty()) return text
        val parts = JSONArray()
        if (text.isNotEmpty()) {
            parts.put(JSONObject().put("type", "text").put("text", text))
        }
        for ((mimeType, base64) in images) {
            parts.put(JSONObject()
                .put("type", "image_url")
                .put("image_url", JSONObject().put("url", "data:$mimeType;base64,$base64")))
        }
        return parts
    }

    /**
     * Streams one turn. Emits [HermesStreamEvent]s parsed from the SSE
     * frames; finishes after `done` (or throws on transport/HTTP failure —
     * GATEWAY-side turn errors arrive as [HermesStreamEvent.AssistantCompleted]
     * text with HTTP 200, see fixtures).
     */
    fun chatStream(
        sessionID: String,
        input: Any,
        /** Per-request knobs (`reasoning_effort`) — 0.19.0 accepts silently. */
        modelOptions: JSONObject? = null,
    ): Flow<HermesStreamEvent> = callbackFlow {
        val body = JSONObject().put("input", input)
        if (modelOptions != null && modelOptions.length() > 0) {
            body.put("model_options", modelOptions)
        }
        val request = Request.Builder()
            .url(url("api/sessions/$sessionID/chat/stream"))
            .header("Authorization", "Bearer $apiKey")
            .post(body.toString().toRequestBody(jsonMedia))
            .build()
        val call = sseClient.newCall(request)
        val thread = Thread {
            try {
                call.execute().use { response ->
                    if (!response.isSuccessful) {
                        throw HermesTransportException(response.code,
                            response.body?.string()?.take(500) ?: "")
                    }
                    val source = response.body?.source()
                        ?: throw HermesTransportException(0, "empty stream body")
                    // SSE framing: "event: <name>" then "data: <json>".
                    // ⚠️ The frame is dispatched ON the data line, NOT on the
                    // blank separator (the desktop live bug 2026-07-25: a
                    // parser waiting for the blank line never fired a single
                    // frame). Hermes sends one-line JSON payloads, so
                    // per-data dispatch is exact.
                    var eventName = ""
                    while (true) {
                        val line = source.readUtf8Line() ?: break
                        if (line.startsWith("event:")) {
                            eventName = line.removePrefix("event:").trim()
                        } else if (line.startsWith("data:") && eventName.isNotEmpty()) {
                            val payload = line.removePrefix("data:").trim()
                            val event = parseEvent(eventName, payload)
                            if (event != null) {
                                trySend(event)
                                if (event is HermesStreamEvent.Done) break
                            }
                            eventName = ""
                        }
                    }
                }
                close()
            } catch (e: Exception) {
                close(if (call.isCanceled()) null else e)
            }
        }
        thread.isDaemon = true
        thread.start()
        awaitClose { call.cancel() }
    }

    companion object {
        /** Maps one SSE frame onto a stream event (names/fields from fixtures). */
        fun parseEvent(name: String, data: String): HermesStreamEvent? {
            val payload = try { JSONObject(data) } catch (_: Exception) { JSONObject() }
            return when (name) {
                "run.started" -> HermesStreamEvent.RunStarted(payload.optString("run_id", ""))
                "message.started" -> HermesStreamEvent.MessageStarted(
                    payload.optJSONObject("message")?.optString("id") ?: "")
                "tool.started" -> {
                    var preview = payload.optString("preview", "").ifEmpty { null }
                    // Fall back to the args dict when preview is missing.
                    if (preview == null) {
                        payload.optJSONObject("args")?.let { args ->
                            if (args.length() > 0) {
                                preview = args.keys().asSequence()
                                    .map { "$it: ${args.opt(it)}" }.sorted().joinToString(", ")
                            }
                        }
                    }
                    HermesStreamEvent.ToolStarted(payload.optString("tool_name", "?"), preview)
                }
                "tool.progress" -> HermesStreamEvent.ToolProgress(
                    payload.optString("tool_name", "?"), payload.optString("delta", ""))
                "tool.completed" -> HermesStreamEvent.ToolCompleted(payload.optString("tool_name", "?"))
                "assistant.delta" -> HermesStreamEvent.AssistantDelta(payload.optString("delta", ""))
                "assistant.completed" -> {
                    val runtime = payload.optJSONObject("runtime")
                    HermesStreamEvent.AssistantCompleted(
                        content = payload.optString("content", ""),
                        interrupted = payload.optBoolean("interrupted", false),
                        runtimeProvider = runtime?.optString("provider")?.ifEmpty { null },
                        runtimeModel = runtime?.optString("model")?.ifEmpty { null })
                }
                "run.completed" -> {
                    var usage = TokenUsage()
                    payload.optJSONObject("usage")?.let { raw ->
                        usage = TokenUsage(
                            inputTokens = raw.optInt("input_tokens", 0),
                            outputTokens = raw.optInt("output_tokens", 0),
                            cacheReadTokens = raw.optInt("cache_read_tokens", 0),
                            cacheWriteTokens = raw.optInt("cache_write_tokens", 0),
                            reasoningTokens = raw.optInt("reasoning_tokens", 0),
                        )
                    }
                    val contextTokens = payload.optJSONObject("usage")?.let { raw ->
                        if (raw.has("context_tokens")) raw.optInt("context_tokens") else null
                    }
                    val windowTokens = payload.optJSONObject("usage")?.let { raw ->
                        if (raw.has("context_window")) raw.optInt("context_window").takeIf { it > 0 } else null
                    }
                    HermesStreamEvent.RunCompleted(usage, contextTokens, windowTokens)
                }
                "done" -> HermesStreamEvent.Done
                else -> HermesStreamEvent.Unknown(name, payload)
            }
        }
    }
}
