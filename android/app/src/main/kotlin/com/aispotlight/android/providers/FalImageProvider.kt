package com.aispotlight.android.providers

import com.aispotlight.android.core.HttpClient
import com.aispotlight.android.core.ProviderException
import com.aispotlight.android.settings.ApiKeyStore
import kotlinx.coroutines.delay
import okhttp3.Request
import org.json.JSONObject

/**
 * fal.ai image tools: REST Queue API (`https://queue.fal.run/{model_id}`,
 * submit → poll → fetch), auth `Authorization: Key <FAL_KEY>`.
 * Images travel as base64 data-URIs. Full port of `FalProvider.swift` with
 * the complete static model catalog (ТЗ §3.1).
 */
object FalImageProvider {

    enum class Function { UPSCALE, REMOVE_BACKGROUND, OBJECT_CLEANUP }

    /** Per-model capabilities and pricing — the mac static catalog verbatim. */
    data class ImageModelInfo(
        val id: String,
        val name: String,
        val function: Function,
        val priceUSD: Double,
        val priceLabel: String,
        val requiresPNGInput: Boolean = false,
        val maxUpscaleFactor: Int? = null,
        val supportsFaceEnhance: Boolean = false,
        /** Cleanup by text prompt (vs a brush mask). */
        val cleanupByText: Boolean = false,
    )

    const val RECRAFT_CRISP = "fal-ai/recraft/upscale/crisp"
    const val TOPAZ = "fal-ai/topaz/upscale/image"
    const val SEEDVR = "fal-ai/seedvr/upscale/image"
    const val ESRGAN = "fal-ai/esrgan"
    const val BRIA_RMBG = "fal-ai/bria/background/remove"
    const val BIREFNET = "fal-ai/birefnet/v2"
    const val BRIA_ERASER = "fal-ai/bria/eraser"
    const val OBJECT_REMOVAL = "fal-ai/object-removal"

    val catalog: List<ImageModelInfo> = listOf(
        // --- Upscale ---
        ImageModelInfo(RECRAFT_CRISP, "Recraft Crisp", Function.UPSCALE, 0.004, "$0.004",
            requiresPNGInput = true),
        ImageModelInfo(TOPAZ, "Topaz Upscale", Function.UPSCALE, 0.08, "~$0.08–0.15",
            maxUpscaleFactor = 4, supportsFaceEnhance = true),
        ImageModelInfo(SEEDVR, "SeedVR2", Function.UPSCALE, 0.03, "~$0.02–0.05",
            maxUpscaleFactor = 4),
        ImageModelInfo(ESRGAN, "Real-ESRGAN", Function.UPSCALE, 0.0025, "~$0.0025",
            maxUpscaleFactor = 8, supportsFaceEnhance = true),
        // --- Background removal ---
        ImageModelInfo(BRIA_RMBG, "Bria RMBG-2.0", Function.REMOVE_BACKGROUND, 0.018, "$0.018"),
        ImageModelInfo(BIREFNET, "BiRefNet v2", Function.REMOVE_BACKGROUND, 0.002, "~$0.002"),
        // --- Object removal ---
        ImageModelInfo(BRIA_ERASER, "Bria Eraser", Function.OBJECT_CLEANUP, 0.04, "~$0.04"),
        ImageModelInfo(OBJECT_REMOVAL, "Object Removal", Function.OBJECT_CLEANUP, 0.024, "~$0.024",
            cleanupByText = true),
    )

    fun models(function: Function): List<ImageModelInfo> = catalog.filter { it.function == function }

    fun model(id: String): ImageModelInfo? = catalog.firstOrNull { it.id == id }

    val isAvailable: Boolean
        get() = ApiKeyStore.hasAuxKey(ApiKeyStore.AuxKey.FAL)

    /**
     * Checks the key WITHOUT spending money: a status request for a
     * nonexistent job answers 401/403 for a bad key and 404/422 for a good one.
     */
    suspend fun validateKey(apiKey: String) {
        val request = Request.Builder()
            .url("https://queue.fal.run/fal-ai/recraft/requests/00000000-0000-0000-0000-000000000000/status")
            .header("Authorization", "Key $apiKey")
            .build()
        try {
            HttpClient.json(request)
        } catch (e: ProviderException) {
            val message = e.message ?: ""
            if (message.contains("HTTP 401") || message.contains("HTTP 403")) throw e
            // 404 / 422 — the key passed authentication.
        }
    }

    data class Result(val image: ByteArray, val mimeType: String, val costUSD: Double)

    /**
     * Runs an image operation with a specific catalog model.
     * @param maskBase64 PNG mask for Bria Eraser (white = erase).
     * @param prompt object description for the by-text removal model.
     */
    suspend fun run(
        modelId: String,
        imageBase64: String,
        mimeType: String,
        prompt: String? = null,
        maskBase64: String? = null,
        factor: Int = 2,
        faceEnhance: Boolean = false,
    ): Result {
        val apiKey = ApiKeyStore.auxKey(ApiKeyStore.AuxKey.FAL)
            ?: throw ProviderException(ProviderException.Kind.MISSING_API_KEY, "No fal.ai key. Add one in Settings.")
        val model = model(modelId) ?: throw ProviderException.badResponse()

        val imageURI = "data:$mimeType;base64,$imageBase64"
        // Input schemas verified against the fal API docs per endpoint (mac port).
        val input = JSONObject().apply {
            put("image_url", imageURI)
            when (model.id) {
                RECRAFT_CRISP -> Unit // fixed "crisp" pass, no factor
                TOPAZ -> {
                    put("upscale_factor", factor)
                    put("face_enhancement", faceEnhance)
                }
                SEEDVR -> {
                    put("upscale_mode", "factor")
                    put("upscale_factor", factor)
                }
                ESRGAN -> {
                    put("scale", factor)
                    put("face", faceEnhance)
                    put("output_format", "png")
                }
                BRIA_RMBG -> Unit
                BIREFNET -> {
                    put("output_format", "png")
                    put("refine_foreground", true)
                }
                BRIA_ERASER -> {
                    if (maskBase64.isNullOrEmpty()) {
                        throw ProviderException(ProviderException.Kind.BAD_RESPONSE, "Draw a mask over the object first.")
                    }
                    put("mask_url", "data:image/png;base64,$maskBase64")
                    put("mask_type", "manual")
                }
                OBJECT_REMOVAL -> {
                    if (prompt.isNullOrEmpty()) {
                        throw ProviderException(ProviderException.Kind.BAD_RESPONSE, "Describe the object to remove.")
                    }
                    put("prompt", prompt)
                }
            }
        }

        val submitted = submit(model.id, input, apiKey)
        val response = awaitResult(submitted, apiKey)
        val (bytes, outMime) = downloadOutputImage(response)
        return Result(bytes, outMime, model.priceUSD)
    }

    // MARK: - Queue API

    private data class Submitted(
        val requestId: String,
        val statusUrl: String,
        val responseUrl: String,
        val cancelUrl: String?,
    )

    private fun authorized(url: String, apiKey: String): Request.Builder =
        Request.Builder().url(url).header("Authorization", "Key $apiKey")

    private suspend fun submit(modelID: String, input: JSONObject, apiKey: String): Submitted {
        val request = authorized("https://queue.fal.run/$modelID", apiKey)
            .header("Content-Type", "application/json")
            .post(HttpClient.jsonBody(input))
            .build()
        val json = JSONObject(HttpClient.json(request))
        return Submitted(
            requestId = json.optString("request_id"),
            statusUrl = json.optString("status_url"),
            responseUrl = json.optString("response_url"),
            cancelUrl = json.optString("cancel_url").takeIf { it.isNotEmpty() },
        )
    }

    /** Polls the status URL until COMPLETED, then fetches the result JSON. */
    private suspend fun awaitResult(submitted: Submitted, apiKey: String): JSONObject {
        val deadline = System.currentTimeMillis() + 120_000
        while (true) {
            if (System.currentTimeMillis() > deadline) {
                cancelRemoteJob(submitted, apiKey)
                throw ProviderException(ProviderException.Kind.HTTP, "Image operation timed out.")
            }
            val status = try {
                JSONObject(HttpClient.json(authorized(submitted.statusUrl, apiKey).build()))
                    .optString("status")
            } catch (e: Exception) {
                cancelRemoteJob(submitted, apiKey)
                throw e
            }
            when (status) {
                "COMPLETED" ->
                    return JSONObject(HttpClient.json(authorized(submitted.responseUrl, apiKey).build()))
                "IN_QUEUE", "IN_PROGRESS" -> delay(1000)
                else -> throw ProviderException.badResponse()
            }
        }
    }

    /** Best-effort PUT to the job's cancel URL. */
    private suspend fun cancelRemoteJob(submitted: Submitted, apiKey: String) {
        val url = submitted.cancelUrl ?: return
        try {
            HttpClient.json(authorized(url, apiKey).put(HttpClient.jsonBody(JSONObject())).build())
        } catch (_: Exception) {
            // The job may already be running; nothing to handle either way.
        }
    }

    /** Pulls the first output image: fal models answer `{"image": {...}}` or `{"images": [{...}]}`. */
    private suspend fun downloadOutputImage(json: JSONObject): Pair<ByteArray, String> {
        val file = json.optJSONObject("image")
            ?: json.optJSONArray("images")?.optJSONObject(0)
            ?: throw ProviderException.badResponse()
        val urlString = file.optString("url").takeIf { it.isNotEmpty() }
            ?: throw ProviderException.badResponse()

        // Data-URI result (sync_mode) — decode without the network.
        if (urlString.startsWith("data:")) {
            val comma = urlString.indexOf(',')
            if (comma < 0) throw ProviderException.badResponse()
            val mime = urlString.substring(5, comma).substringBefore(';').ifEmpty { "image/png" }
            val bytes = android.util.Base64.decode(urlString.substring(comma + 1), android.util.Base64.DEFAULT)
            return bytes to mime
        }

        // fal.media — no auth required.
        val request = Request.Builder().url(urlString).build()
        val bytes = kotlinx.coroutines.suspendCancellableCoroutine<ByteArray> { cont ->
            val call = HttpClient.client.newCall(request)
            cont.invokeOnCancellation { call.cancel() }
            call.enqueue(object : okhttp3.Callback {
                override fun onFailure(call: okhttp3.Call, e: java.io.IOException) {
                    if (cont.isActive) cont.resumeWith(kotlin.Result.failure(e))
                }

                override fun onResponse(call: okhttp3.Call, response: okhttp3.Response) {
                    response.use {
                        if (!it.isSuccessful) {
                            if (cont.isActive) cont.resumeWith(kotlin.Result.failure(
                                ProviderException.fromHTTP(it.code, "")
                            ))
                            return
                        }
                        val body = it.body?.bytes() ?: ByteArray(0)
                        if (cont.isActive) cont.resumeWith(kotlin.Result.success(body))
                    }
                }
            })
        }
        return bytes to file.optString("content_type").ifEmpty { "image/png" }
    }
}
