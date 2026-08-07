package com.aispotlight.android.core

import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONObject
import java.io.IOException
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

// MARK: - Provider identifiers

enum class ProviderID(val id: String) {
    ANTHROPIC("anthropic"),
    OPENAI("openai"),
    GEMINI("gemini"),
    MISTRAL("mistral"),
    DEEPSEEK("deepseek"),
    OPENROUTER("openrouter"),
    KIMI("kimi");

    val displayName: String
        get() = when (this) {
            ANTHROPIC -> "Anthropic (Claude)"
            OPENAI -> "OpenAI"
            GEMINI -> "Google Gemini"
            MISTRAL -> "Mistral"
            DEEPSEEK -> "DeepSeek"
            OPENROUTER -> "OpenRouter"
            KIMI -> "Kimi (Moonshot)"
        }

    /** Whether the user types a model slug freely (OpenRouter) instead of picking from a fetched dropdown. */
    val usesManualModelEntry: Boolean get() = this == OPENROUTER

    /** Coarse per-provider vision default; OpenRouter decides per-model from its catalog. */
    val supportsVision: Boolean get() = this != DEEPSEEK

    /** Short badge label used for the provider icon. */
    val badgeLetter: String
        get() = when (this) {
            ANTHROPIC -> "C"; OPENAI -> "AI"; GEMINI -> "G"; MISTRAL -> "M"
            DEEPSEEK -> "DS"; OPENROUTER -> "OR"; KIMI -> "K"
        }

    /** Brand-ish accent behind the badge letter (ARGB). */
    val brandColor: Long
        get() = when (this) {
            ANTHROPIC -> 0xFFD4A27F; OPENAI -> 0xFF10A37F; GEMINI -> 0xFF4285F4
            MISTRAL -> 0xFFFA520F; DEEPSEEK -> 0xFF4D6BFE; OPENROUTER -> 0xFF6467F2
            KIMI -> 0xFF16191E
        }

    /** Page where the user can create an API key for this provider. */
    val apiKeyURL: String
        get() = when (this) {
            ANTHROPIC -> "https://console.anthropic.com/settings/keys"
            OPENAI -> "https://platform.openai.com/api-keys"
            GEMINI -> "https://aistudio.google.com/apikey"
            MISTRAL -> "https://console.mistral.ai/api-keys"
            DEEPSEEK -> "https://platform.deepseek.com/api_keys"
            OPENROUTER -> "https://openrouter.ai/keys"
            KIMI -> "https://platform.moonshot.ai/console/api-keys"
        }

    /**
     * Preferred default chat models per provider, best first. When a key is
     * saved the live model list is fetched and the first of these the provider
     * actually serves is auto-selected (exact match, or the prefix of a dated
     * snapshot id).
     */
    val preferredDefaultModels: List<String>
        get() = when (this) {
            OPENAI -> listOf("chat-latest")
            ANTHROPIC -> listOf("claude-sonnet-5", "claude-opus-4-8", "claude-sonnet-4-5", "claude-haiku-4-5")
            GEMINI -> listOf("gemini-flash-latest", "gemini-2.0-flash", "gemini-2.5-flash", "gemini-1.5-flash")
            MISTRAL -> listOf("mistral-large-latest", "mistral-medium-latest", "mistral-small-latest")
            DEEPSEEK -> listOf("deepseek-chat", "deepseek-reasoner")
            OPENROUTER -> emptyList()
            KIMI -> listOf("kimi-k3", "kimi-k2.6", "kimi-k2.7-code")
        }

    companion object {
        fun fromId(id: String?): ProviderID? = entries.firstOrNull { it.id == id }
    }
}

// MARK: - Model catalog metadata

/** Per-model capabilities from a provider's catalog (OpenRouter). */
data class ModelInfo(
    val id: String,
    val supportsVision: Boolean,
    val supportsTools: Boolean,
    val supportsReasoning: Boolean,
    val supportedParameters: List<String> = emptyList(),
    /**
     * USD per ONE token (OpenRouter reports prices in that unit), captured
     * from the catalog so aggregator models get exact per-model pricing.
     * null for catalogs that don't carry prices (or older cached entries).
     */
    val promptPricePerToken: Double? = null,
    val completionPricePerToken: Double? = null,
)

// MARK: - Messages

data class LLMImage(val mimeType: String, val base64: String) {
    companion object {
        /**
         * Longest side beyond which cloud providers downscale server-side anyway
         * (Anthropic caps at 1568px; OpenAI/Gemini tile below that). Pixels above
         * this never reach the model — they only cost upload bytes and latency.
         */
        private const val MAX_MODEL_DIMENSION = 1568
        /**
         * Payloads at or under this many bytes pass through un-recoded when the
         * pixels already fit — recompression would only lose quality.
         */
        private const val MAX_PASSTHROUGH_BYTES = 4 shl 20

        /**
         * Wire image for cloud providers — port of `LLMImage.forModel` on macOS:
         * downscaled to fit [MAX_MODEL_DIMENSION] and re-encoded (JPEG for opaque
         * images, PNG when alpha is present), EXIF orientation baked in. Small-enough
         * images, non-images, GIFs (animation would be flattened) and anything
         * undecodable pass through unchanged. Hermes inline images go through here
         * too: original-size photos blow through reverse-proxy body limits as opaque
         * 413s, and the gateway's model downscales to the same ceiling anyway.
         */
        fun forModel(mimeType: String, base64: String): LLMImage {
            val original = LLMImage(mimeType, base64)
            if (!mimeType.startsWith("image") || mimeType == "image/gif") return original
            val bytes = try {
                android.util.Base64.decode(base64, android.util.Base64.DEFAULT)
            } catch (_: IllegalArgumentException) {
                return original
            }
            val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
            android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return original

            val fitsPixels = maxOf(bounds.outWidth, bounds.outHeight) <= MAX_MODEL_DIMENSION
            if (fitsPixels && bytes.size <= MAX_PASSTHROUGH_BYTES) return original

            // Power-of-two pre-downsample bounds decode memory; the exact scale
            // below lands on the ceiling (mirrors ImageIO thumbnailing on mac).
            var sample = 1
            while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= MAX_MODEL_DIMENSION) sample *= 2
            val decoded = android.graphics.BitmapFactory.decodeByteArray(
                bytes, 0, bytes.size,
                android.graphics.BitmapFactory.Options().apply { inSampleSize = sample },
            ) ?: return original
            val longest = maxOf(decoded.width, decoded.height)
            val scaled = if (longest <= MAX_MODEL_DIMENSION) decoded else {
                val scale = MAX_MODEL_DIMENSION.toFloat() / longest
                android.graphics.Bitmap.createScaledBitmap(
                    decoded,
                    (decoded.width * scale).toInt().coerceAtLeast(1),
                    (decoded.height * scale).toInt().coerceAtLeast(1),
                    true,
                )
            }
            // Bake EXIF orientation into the pixels — the mac side does this via
            // kCGImageSourceCreateThumbnailWithTransform.
            val orientation = try {
                java.io.ByteArrayInputStream(bytes).use {
                    android.media.ExifInterface(it).getAttributeInt(
                        android.media.ExifInterface.TAG_ORIENTATION,
                        android.media.ExifInterface.ORIENTATION_NORMAL,
                    )
                }
            } catch (_: Exception) {
                android.media.ExifInterface.ORIENTATION_NORMAL
            }
            val upright = bakeExifOrientation(scaled, orientation)

            val hasAlpha = upright.hasAlpha()
            val out = java.io.ByteArrayOutputStream()
            val encoded = if (hasAlpha) {
                upright.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, out)
            } else {
                upright.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, out)
            }
            if (!encoded || out.size() == 0) return original
            // Recode of an already-fitting (but heavy) image must actually shrink
            // it; a downscale is kept regardless — fewer pixels is the point.
            if (fitsPixels && out.size() >= bytes.size) return original
            return LLMImage(
                mimeType = if (hasAlpha) "image/png" else "image/jpeg",
                base64 = android.util.Base64.encodeToString(out.toByteArray(), android.util.Base64.NO_WRAP),
            )
        }
    }
}

/**
 * Applies an EXIF orientation to decoded pixels (BitmapFactory ignores the
 * tag). Returns the input bitmap unchanged for normal/unknown orientations.
 */
internal fun bakeExifOrientation(bitmap: android.graphics.Bitmap, orientation: Int): android.graphics.Bitmap {
    val matrix = android.graphics.Matrix()
    when (orientation) {
        android.media.ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
        android.media.ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
        android.media.ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
        android.media.ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
        android.media.ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
        android.media.ExifInterface.ORIENTATION_TRANSPOSE -> {
            matrix.postRotate(90f); matrix.postScale(-1f, 1f)
        }
        android.media.ExifInterface.ORIENTATION_TRANSVERSE -> {
            matrix.postRotate(270f); matrix.postScale(-1f, 1f)
        }
        else -> return bitmap
    }
    return android.graphics.Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
}

data class LLMMessage(
    val role: Role,
    val text: String,
    val images: List<LLMImage> = emptyList(),
    /** Tool calls the assistant requested (assistant role only). */
    val toolCalls: List<ToolCall> = emptyList(),
    /** For TOOL role: which call this result answers. */
    val toolCallID: String? = null,
    /** For TOOL role: the tool's name (Gemini requires it in the response). */
    val toolName: String? = null,
) {
    enum class Role(val raw: String) { USER("user"), ASSISTANT("assistant"), TOOL("tool") }
}

// MARK: - Tools

/** A function tool the model may call (JSON-schema parameters). */
data class ToolSpec(
    val name: String,
    val description: String,
    val parameters: JSONObject,
)

/** A concrete call the model requested. */
data class ToolCall(
    val id: String,
    val name: String,
    /** Raw JSON string with the call arguments. */
    val argumentsJSON: String,
) {
    val arguments: JSONObject
        get() = try { JSONObject(argumentsJSON) } catch (_: Exception) { JSONObject() }
}

/**
 * Token counts reported by a provider for one model turn (port of the macOS
 * `TokenUsage`). Field semantics are normalized across providers:
 * [inputTokens] is the UNCACHED input; cache traffic is split out because it
 * bills at different rates (Anthropic: write ×1.25, read ×0.1; DeepSeek:
 * hit ≈ 1/50 of miss). [reasoningTokens] are informational — providers that
 * report them (OpenAI, Gemini) already include them in [outputTokens].
 */
data class TokenUsage(
    val inputTokens: Int = 0,
    val outputTokens: Int = 0,
    val cacheReadTokens: Int = 0,
    val cacheWriteTokens: Int = 0,
    val reasoningTokens: Int = 0,
) {
    val isEmpty: Boolean
        get() = inputTokens == 0 && outputTokens == 0 && cacheReadTokens == 0 &&
            cacheWriteTokens == 0 && reasoningTokens == 0

    /** Sums two turns — an agentic loop makes several model calls per user turn. */
    fun merged(other: TokenUsage) = TokenUsage(
        inputTokens = inputTokens + other.inputTokens,
        outputTokens = outputTokens + other.outputTokens,
        cacheReadTokens = cacheReadTokens + other.cacheReadTokens,
        cacheWriteTokens = cacheWriteTokens + other.cacheWriteTokens,
        reasoningTokens = reasoningTokens + other.reasoningTokens,
    )
}

/** Events produced while streaming a single model turn. */
sealed class LLMStreamEvent {
    data class Text(val chunk: String) : LLMStreamEvent()
    /** Emitted once at the end of the turn when the model requested tools. */
    data class ToolCalls(val calls: List<ToolCall>) : LLMStreamEvent()
    /**
     * Emitted once per model call, right before the stream finishes, when the
     * provider reported token usage. Absent on interrupted streams — callers
     * fall back to an estimate.
     */
    data class Usage(val usage: TokenUsage) : LLMStreamEvent()
}

/** Reasoning depth preference, mapped to provider-specific parameters. */
enum class ReasoningMode(val id: String) {
    AUTO("auto"), FAST("fast"), DEEP("deep");

    companion object {
        fun fromId(id: String?): ReasoningMode = entries.firstOrNull { it.id == id } ?: AUTO
    }
}

/** Per-request options resolved from settings. */
data class ChatRequestOptions(
    val maxTokens: Int = 8192,
    val reasoning: ReasoningMode = ReasoningMode.AUTO,
    val tools: List<ToolSpec> = emptyList(),
    /** Whether the selected model honors a reasoning-effort control (resolved by the caller). */
    val modelSupportsReasoning: Boolean = false,
)

// MARK: - Provider interface

interface LLMProvider {
    val providerID: ProviderID

    /** Streams one model turn: text chunks and, possibly, tool call requests. */
    fun streamChat(
        messages: List<LLMMessage>,
        model: String,
        systemPrompt: String?,
        options: ChatRequestOptions,
        apiKey: String,
    ): Flow<LLMStreamEvent>

    /** Fetches the list of available chat model identifiers. */
    suspend fun fetchModels(apiKey: String): List<String>

    /** Verifies an API key with a cheap authenticated call, throwing on failure. */
    suspend fun validateKey(apiKey: String) {
        fetchModels(apiKey)
    }
}

// MARK: - Model capabilities

object ModelCapabilities {
    /**
     * Whether the reasoning selector has any effect for this provider+model.
     * For OpenRouter the answer comes from the fetched catalog, not the slug.
     */
    fun supportsReasoningControl(provider: ProviderID, model: String): Boolean {
        val m = model.lowercase()
        return when (provider) {
            ProviderID.OPENAI ->
                m.startsWith("o1") || m.startsWith("o3") || m.startsWith("o4") || m.contains("gpt-5")
            ProviderID.ANTHROPIC ->
                m.contains("opus-4-6") || m.contains("opus-4-7") || m.contains("opus-4-8") ||
                    m.contains("sonnet-4-6") || m.contains("sonnet-5") ||
                    m.contains("fable") || m.contains("mythos")
            ProviderID.GEMINI -> m.contains("2.5") || m.contains("gemini-3")
            else -> false
        }
    }
}

// MARK: - Errors

class ProviderException(
    val kind: Kind,
    message: String,
) : Exception(message) {
    enum class Kind { MISSING_API_KEY, BAD_RESPONSE, HTTP, DECODING, VISION_UNSUPPORTED }

    companion object {
        fun missingAPIKey(provider: ProviderID) = ProviderException(
            Kind.MISSING_API_KEY, "No API key for ${provider.displayName}. Add one in Settings."
        )

        fun badResponse() = ProviderException(Kind.BAD_RESPONSE, "The server returned an unexpected response.")

        fun decoding(details: String) = ProviderException(Kind.DECODING, "Failed to decode the response: $details")

        fun http(status: Int, message: String) = ProviderException(Kind.HTTP, "API error (HTTP $status): $message")

        fun visionUnsupported(provider: ProviderID) = ProviderException(
            Kind.VISION_UNSUPPORTED,
            "${provider.displayName} does not support images. Configure a Mistral key to enable OCR fallback, or switch the chat provider."
        )

        /**
         * Builds an HTTP error with a sanitized, human-readable message:
         * extracts `error.message`-style fields from a JSON body and truncates,
         * so raw response dumps never reach the UI.
         */
        fun fromHTTP(status: Int, body: String): ProviderException {
            var message = "Request failed."
            try {
                val json = JSONObject(body)
                val error = json.opt("error")
                message = when {
                    error is JSONObject && error.has("message") -> error.getString("message")
                    error is String -> error
                    json.has("message") -> json.getString("message")
                    json.has("detail") -> json.getString("detail")
                    // Deepgram's error shape: {"err_code": ..., "err_msg": ...}
                    json.has("err_msg") -> json.getString("err_msg")
                    else -> message
                }
            } catch (_: Exception) {
                if (body.isNotEmpty()) message = body
            }
            if (message.length > 600) message = message.take(600) + "…"
            return http(status, message)
        }
    }
}

// MARK: - HTTP helpers

object HttpClient {
    /** Shared client; no disk cache so responses are never persisted. */
    val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(120, TimeUnit.SECONDS)
        // OkHttp's default write watchdog is 10 s PER SOCKET WRITE — on a
        // stalling mobile uplink that reliably kills any multi-megabyte
        // upload (the courier's "files over ~10 MB never send on LTE" bug);
        // the overall callTimeout below still bounds a truly dead transfer.
        .writeTimeout(120, TimeUnit.SECONDS)
        .callTimeout(600, TimeUnit.SECONDS)
        .build()

    private val jsonMediaType = "application/json".toMediaType()

    fun jsonBody(json: JSONObject) = json.toString().toRequestBody(jsonMediaType)

    /** Performs a request and returns the body, throwing a sanitized error on non-2xx. */
    suspend fun json(request: Request): String = suspendCancellableCoroutine { cont ->
        val call = client.newCall(request)
        cont.invokeOnCancellation { call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                if (cont.isActive) cont.resumeWithException(e)
            }

            override fun onResponse(call: Call, response: Response) {
                response.use {
                    val body = it.body?.string() ?: ""
                    if (it.isSuccessful) {
                        if (cont.isActive) cont.resume(body)
                    } else {
                        if (cont.isActive) cont.resumeWithException(ProviderException.fromHTTP(it.code, body))
                    }
                }
            }
        })
    }

    /** Performs a request and returns the raw body bytes (binary endpoints, e.g. TTS audio). */
    suspend fun bytes(request: Request): ByteArray = suspendCancellableCoroutine { cont ->
        val call = client.newCall(request)
        cont.invokeOnCancellation { call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                if (cont.isActive) cont.resumeWithException(e)
            }

            override fun onResponse(call: Call, response: Response) {
                response.use {
                    if (it.isSuccessful) {
                        val body = it.body?.bytes() ?: ByteArray(0)
                        if (cont.isActive) cont.resume(body)
                    } else {
                        val body = it.body?.string() ?: ""
                        if (cont.isActive) cont.resumeWithException(ProviderException.fromHTTP(it.code, body))
                    }
                }
            }
        })
    }

    /**
     * Performs a request and emits the `data:` payloads of an SSE stream.
     * Terminates on `[DONE]` or end of stream. On a non-2xx status the body is
     * collected and surfaced as a sanitized error.
     */
    fun sseStream(request: Request): Flow<String> = callbackFlow {
        val call = client.newCall(request)
        val thread = Thread {
            try {
                call.execute().use { response ->
                    if (!response.isSuccessful) {
                        throw ProviderException.fromHTTP(response.code, response.body?.string() ?: "")
                    }
                    val source = response.body?.source() ?: throw ProviderException.badResponse()
                    while (true) {
                        val line = source.readUtf8Line() ?: break
                        if (!line.startsWith("data:")) continue
                        val payload = line.removePrefix("data:").trim()
                        if (payload == "[DONE]") break
                        if (payload.isNotEmpty()) {
                            trySend(payload)
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
}

fun newCallID(): String = UUID.randomUUID().toString()
