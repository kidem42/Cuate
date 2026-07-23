package com.aispotlight.android.providers

import com.aispotlight.android.core.HttpClient
import com.aispotlight.android.core.ProviderException
import com.aispotlight.android.core.ProviderID
import com.aispotlight.android.data.SpendKind
import com.aispotlight.android.data.SpendTracker
import com.aispotlight.android.settings.ApiKeyStore
import com.aispotlight.android.settings.AppSettings
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.File

/** Providers that can transcribe audio (port of `STTProviderID`). */
enum class STTProviderID(val id: String) {
    MISTRAL("mistral"),
    OPENAI("openai"),
    DEEPGRAM("deepgram");

    val displayName: String
        get() = when (this) {
            MISTRAL -> "Mistral (Voxtral)"
            OPENAI -> "OpenAI"
            DEEPGRAM -> "Deepgram"
        }

    val defaultModel: String
        get() = when (this) {
            MISTRAL -> "voxtral-mini-latest"
            OPENAI -> "gpt-4o-transcribe"
            DEEPGRAM -> "nova-3"
        }

    /** Mistral/OpenAI reuse their chat-provider key; Deepgram has its own slot. */
    val hasKey: Boolean
        get() = when (this) {
            MISTRAL -> ApiKeyStore.hasKey(ProviderID.MISTRAL)
            OPENAI -> ApiKeyStore.hasKey(ProviderID.OPENAI)
            DEEPGRAM -> ApiKeyStore.hasAuxKey(ApiKeyStore.AuxKey.DEEPGRAM)
        }

    val apiKey: String?
        get() = when (this) {
            MISTRAL -> ApiKeyStore.key(ProviderID.MISTRAL)
            OPENAI -> ApiKeyStore.key(ProviderID.OPENAI)
            DEEPGRAM -> ApiKeyStore.auxKey(ApiKeyStore.AuxKey.DEEPGRAM)
        }

    companion object {
        fun fromId(id: String?): STTProviderID = entries.firstOrNull { it.id == id } ?: MISTRAL
    }
}

/**
 * Speech-to-text via provider APIs. Mistral (Voxtral) and OpenAI share the
 * OpenAI-style `POST /v1/audio/transcriptions` multipart endpoint; Deepgram
 * uses its own `POST /v1/listen` with a raw binary body.
 * Port of `TranscriptionService.swift`.
 */
object TranscriptionService {

    val isAvailable: Boolean
        get() = STTProviderID.entries.any { it.hasKey }

    /**
     * Transcribes the audio file using the configured STT provider.
     * Falls back to any STT provider that has a key if the preferred one doesn't.
     */
    suspend fun transcribe(audioFile: File): String {
        val preferred = AppSettings.current.sttProvider.value
        val candidates = listOf(preferred) + STTProviderID.entries.filter { it != preferred }
        val provider = candidates.firstOrNull { it.hasKey }
            ?: throw ProviderException(
                ProviderException.Kind.HTTP,
                "No transcription provider configured. Add a Mistral or OpenAI key in Settings."
            )
        val apiKey = provider.apiKey ?: throw ProviderException.missingAPIKey(ProviderID.MISTRAL)
        val audioData = audioFile.readBytes()

        val model = AppSettings.current.sttModel(provider)
        val text = when (provider) {
            STTProviderID.MISTRAL, STTProviderID.OPENAI ->
                transcribeOpenAIStyle(provider, apiKey, model, audioData, audioFile.name)
            STTProviderID.DEEPGRAM ->
                transcribeDeepgram(apiKey, model, audioData, audioFile.name)
        }

        // STT bills per audio minute — read the real duration off the file.
        val durationMs = try {
            android.media.MediaMetadataRetriever().use { retriever ->
                retriever.setDataSource(audioFile.absolutePath)
                retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)
                    ?.toLongOrNull() ?: 0L
            }
        } catch (_: Exception) { 0L }
        if (durationMs > 0) {
            val minutes = durationMs / 60000.0
            SpendTracker.record(
                kind = SpendKind.STT, provider = provider.id, model = model,
                units = minutes,
                costUSD = PricingCatalog.sttPerMinute[provider.id]?.times(minutes),
            )
        }
        return text
    }

    /**
     * Content type by filename extension. Own recordings are AAC/.m4a; shared
     * voice notes come as opus/ogg (WhatsApp, Telegram) or anything else the
     * source app produced — providers key off the extension/mime.
     */
    private fun mimeFor(filename: String): String =
        when (filename.substringAfterLast('.', "").lowercase()) {
            "ogg", "oga", "opus" -> "audio/ogg"
            "mp3" -> "audio/mpeg"
            "wav" -> "audio/wav"
            "webm" -> "audio/webm"
            "flac" -> "audio/flac"
            "aac" -> "audio/aac"
            else -> "audio/mp4"
        }

    // MARK: - OpenAI-style multipart (Mistral, OpenAI)

    private suspend fun transcribeOpenAIStyle(
        provider: STTProviderID,
        apiKey: String,
        model: String,
        audioData: ByteArray,
        filename: String,
    ): String {
        val endpoint = when (provider) {
            STTProviderID.MISTRAL -> "https://api.mistral.ai/v1/audio/transcriptions"
            else -> "https://api.openai.com/v1/audio/transcriptions"
        }

        val body = MultipartBody.Builder()
            .setType(MultipartBody.FORM)
            .addFormDataPart("model", model)
            .addFormDataPart("file", filename, audioData.toRequestBody(mimeFor(filename).toMediaType()))
            .build()

        val request = Request.Builder()
            .url(endpoint)
            .header("Authorization", "Bearer $apiKey")
            .post(body)
            .build()

        val data = HttpClient.json(request)
        val text = try {
            JSONObject(data).getString("text")
        } catch (_: Exception) {
            throw ProviderException.decoding("no `text` in transcription response")
        }
        return text.trim()
    }

    // MARK: - Deepgram

    /**
     * `POST /v1/listen` with the audio file as the raw request body.
     * `language=multi` enables nova-3's multilingual mode (covers en, ru, es,
     * de, fr, hi, pt, ja, it, nl — including code-switching mid-speech).
     */
    private suspend fun transcribeDeepgram(apiKey: String, model: String, audioData: ByteArray, filename: String): String {
        val url = "https://api.deepgram.com/v1/listen".toHttpUrl().newBuilder()
            .addQueryParameter("model", model)
            .addQueryParameter("smart_format", "true")
            .addQueryParameter("language", "multi")
            .build()

        val request = Request.Builder()
            .url(url)
            .header("Authorization", "Token $apiKey")
            .post(audioData.toRequestBody(mimeFor(filename).toMediaType()))
            .build()

        val data = HttpClient.json(request)
        val transcript = try {
            JSONObject(data)
                .getJSONObject("results")
                .getJSONArray("channels").getJSONObject(0)
                .getJSONArray("alternatives").getJSONObject(0)
                .getString("transcript")
        } catch (_: Exception) {
            throw ProviderException.decoding("no transcript in Deepgram response")
        }
        return transcript.trim()
    }
}
