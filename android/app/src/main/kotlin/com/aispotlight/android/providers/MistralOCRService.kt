package com.aispotlight.android.providers

import com.aispotlight.android.core.HttpClient
import com.aispotlight.android.core.ProviderException
import com.aispotlight.android.core.ProviderID
import com.aispotlight.android.data.SpendKind
import com.aispotlight.android.data.SpendTracker
import com.aispotlight.android.settings.ApiKeyStore
import okhttp3.Request
import org.json.JSONObject

/**
 * Mistral OCR — extracts structured markdown from images. Used as the OCR
 * backend on Android (ML Kit has no Cyrillic support, so the cloud model is
 * the default here) and as the fallback that lets non-vision chat providers
 * (DeepSeek) receive image content as text. Port of `MistralOCRService.swift`.
 */
object MistralOCRService {
    private const val ENDPOINT = "https://api.mistral.ai/v1/ocr"
    private const val MODEL = "mistral-ocr-latest"

    val isAvailable: Boolean
        get() = ApiKeyStore.hasKey(ProviderID.MISTRAL)

    /** Runs OCR on a base64-encoded image and returns the extracted markdown. */
    suspend fun extractText(imageBase64: String, mimeType: String): String {
        val apiKey = ApiKeyStore.key(ProviderID.MISTRAL)
            ?: throw ProviderException.missingAPIKey(ProviderID.MISTRAL)

        val body = JSONObject().apply {
            put("model", MODEL)
            put("document", JSONObject().apply {
                put("type", "image_url")
                put("image_url", "data:$mimeType;base64,$imageBase64")
            })
        }
        val request = Request.Builder()
            .url(ENDPOINT)
            .header("Content-Type", "application/json")
            .header("Authorization", "Bearer $apiKey")
            .post(HttpClient.jsonBody(body))
            .build()

        val data = HttpClient.json(request)
        val pages = try {
            JSONObject(data).getJSONArray("pages")
        } catch (_: Exception) {
            throw ProviderException.decoding("no `pages` in OCR response")
        }

        // Billed per page — record the actual page count.
        val pageCount = maxOf(1, pages.length()).toDouble()
        SpendTracker.record(
            kind = SpendKind.OCR, provider = ProviderID.MISTRAL.id, model = MODEL,
            units = pageCount,
            costUSD = PricingCatalog.ocrPerPage[ProviderID.MISTRAL.id]?.times(pageCount),
        )

        val markdown = (0 until pages.length())
            .mapNotNull { pages.optJSONObject(it)?.optString("markdown")?.takeIf { s -> s.isNotEmpty() } }
            .joinToString("\n\n")

        val cleaned = stripImageReferences(markdown).trim()
        if (cleaned.isEmpty()) throw ProviderException.decoding("OCR returned no text")
        return cleaned
    }

    /**
     * OCR output embeds image placeholders like `![img-0.jpeg](img-0.jpeg)` —
     * meaningless outside the OCR container, so remove them.
     */
    private fun stripImageReferences(markdown: String): String {
        var result = markdown.replace(Regex("""!\[[^\]]*\]\([^)]*\)"""), "")
        while (result.contains("\n\n\n")) {
            result = result.replace("\n\n\n", "\n\n")
        }
        return result
    }
}
