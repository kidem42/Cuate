package com.aispotlight.android.providers

import com.aispotlight.android.core.Diagnostics
import com.aispotlight.android.core.HttpClient
import com.aispotlight.android.core.ProviderException
import com.aispotlight.android.core.ProviderID
import com.aispotlight.android.settings.ApiKeyStore
import com.aispotlight.android.settings.AppSettings
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject

/**
 * Providers that can synthesize speech (the TTS mirror of `STTProviderID`).
 * Of the integrated providers only OpenAI and Gemini offer TTS models that
 * cover the app's languages (en/es/ru); Deepgram Aura is en/es-only and the
 * rest have no TTS API at all.
 *
 * Capabilities differ: OpenAI has a dedicated `speed` knob (0.25–4.0) on the
 * tts-1 family and free-form style `instructions` on gpt-4o-mini-tts; Gemini
 * only picks a prebuilt voice (pacing is prompt-driven, not parametric).
 */
enum class TTSProviderID(val id: String) {
    OPENAI("openai"),
    GEMINI("gemini");

    val displayName: String
        get() = when (this) {
            OPENAI -> "OpenAI"
            GEMINI -> "Gemini"
        }

    val defaultModel: String
        get() = when (this) {
            OPENAI -> "gpt-4o-mini-tts"
            GEMINI -> "gemini-2.5-flash-preview-tts"
        }

    /**
     * Curated multilingual voices shown in the Settings picker. `marin` and
     * `cedar` are the newest gpt-4o-mini-tts voices, documented as the best
     * quality — hence the default.
     */
    val voices: List<String>
        get() = when (this) {
            OPENAI -> listOf(
                "marin", "cedar", "alloy", "ash", "ballad", "coral", "echo",
                "fable", "nova", "onyx", "sage", "shimmer", "verse",
            )
            GEMINI -> listOf(
                "Kore", "Puck", "Zephyr", "Charon", "Fenrir", "Leda", "Aoede", "Orus",
            )
        }

    val defaultVoice: String
        get() = when (this) {
            OPENAI -> "marin"
            GEMINI -> "Kore"
        }

    /** Whether the provider honors a playback-speed setting. */
    val supportsSpeed: Boolean
        get() = this == OPENAI

    /** Both reuse their chat-provider key. */
    val hasKey: Boolean
        get() = when (this) {
            OPENAI -> ApiKeyStore.hasKey(ProviderID.OPENAI)
            GEMINI -> ApiKeyStore.hasKey(ProviderID.GEMINI)
        }

    val apiKey: String?
        get() = when (this) {
            OPENAI -> ApiKeyStore.key(ProviderID.OPENAI)
            GEMINI -> ApiKeyStore.key(ProviderID.GEMINI)
        }

    companion object {
        fun fromId(id: String?): TTSProviderID = entries.firstOrNull { it.id == id } ?: OPENAI
    }
}

/**
 * Text-to-speech via provider APIs: OpenAI `POST /v1/audio/speech` (Opus in
 * an Ogg container — the Telegram voice-message codec, ~2-3× smaller than mp3
 * at speech quality) and Gemini `generateContent` with the AUDIO response
 * modality (raw 24 kHz PCM — no codec choice on that API — transcoded
 * on-device to AAC/.m4a, the same format the app's own voice recordings use;
 * WAV only as a fallback if the hardware encoder fails).
 */
object SpeechService {

    /** Synthesized audio plus the container its bytes are in. */
    data class Audio(val bytes: ByteArray, val fileExtension: String)

    val isAvailable: Boolean
        get() = TTSProviderID.entries.any { it.hasKey }

    /**
     * Synthesizes speech for a chat reply using the configured TTS provider,
     * falling back to any provider with a key (the STT pattern).
     */
    suspend fun synthesize(replyText: String): Audio {
        val preferred = AppSettings.current.ttsProvider.value
        val candidates = listOf(preferred) + TTSProviderID.entries.filter { it != preferred }
        val provider = candidates.firstOrNull { it.hasKey }
            ?: throw ProviderException(
                ProviderException.Kind.HTTP,
                "No TTS provider configured. Add an OpenAI or Gemini key in Settings."
            )
        val apiKey = provider.apiKey ?: throw ProviderException.missingAPIKey(ProviderID.OPENAI)
        val text = speakableText(replyText)
        if (text.isEmpty()) throw ProviderException.decoding("nothing speakable in the reply")

        val settings = AppSettings.current
        val model = settings.ttsModel(provider)
        val voice = settings.ttsVoice(provider)
        return when (provider) {
            TTSProviderID.OPENAI -> synthesizeOpenAI(apiKey, model, voice, settings.ttsSpeed.value, text)
            TTSProviderID.GEMINI -> synthesizeGemini(apiKey, model, voice, text)
        }
    }

    /**
     * Reduces a markdown reply to something a voice should actually read:
     * fenced blocks (code, artifacts) are dropped, links keep their label,
     * bare URLs shrink to their host, markdown syntax is stripped. Capped
     * at 4000 chars (the OpenAI input limit is 4096).
     */
    fun speakableText(raw: String): String = raw
        .replace(Regex("(?s)`{3,}.*?(?:`{3,}|$)"), " ")          // fenced blocks incl. unterminated
        .replace(Regex("!\\[[^\\]]*\\]\\([^)]*\\)"), " ")         // images
        .replace(Regex("\\[([^\\]]+)\\]\\([^)]*\\)"), "$1")       // links → label
        .replace(Regex("<?https?://([^/\\s>)]+)[^\\s>)]*>?")) {   // bare URLs → host
            it.groupValues[1].removePrefix("www.")
        }
        .replace(Regex("[*_#>`|]"), "")                            // markdown markers
        .replace(Regex("\\s+"), " ")
        .trim()
        .take(4000)

    // MARK: - OpenAI

    /** Voices that exist only on the gpt-4o-mini-tts model — the tts-1 family
     *  rejects them with a 400, which used to kill voice replies silently. */
    private val newGenVoices = setOf("marin", "cedar")

    private suspend fun synthesizeOpenAI(
        apiKey: String,
        model: String,
        voice: String,
        speed: Float,
        text: String,
    ): Audio {
        // The voice is the user's explicit choice; the model is auto-upgraded
        // to the one generation that actually serves it.
        val effectiveModel =
            if (voice.lowercase() in newGenVoices && !model.startsWith("gpt-4o")) {
                Diagnostics.log("tts", "model.upgrade $model→gpt-4o-mini-tts (voice=$voice)")
                "gpt-4o-mini-tts"
            } else model
        val body = JSONObject().apply {
            put("model", effectiveModel)
            put("input", text)
            put("voice", voice)
            // Opus/Ogg: best speech codec at low bitrates (what Telegram
            // uses); Android decodes Ogg/Opus natively since 5.0.
            put("response_format", "opus")
            // The tts-1 family takes a numeric `speed`; gpt-4o-mini-tts
            // ignores it and is steered through `instructions` instead.
            if (effectiveModel.startsWith("gpt-4o")) {
                if (speed > 1.05f) put("instructions", "Speak at roughly ${"%.2g".format(speed)}x the normal pace.")
                if (speed < 0.95f) put("instructions", "Speak slowly, at roughly ${"%.2g".format(speed)}x the normal pace.")
            } else if (speed != 1f) {
                put("speed", speed)
            }
        }
        val request = Request.Builder()
            .url("https://api.openai.com/v1/audio/speech")
            .header("Authorization", "Bearer $apiKey")
            .post(HttpClient.jsonBody(body))
            .build()
        return Audio(HttpClient.bytes(request), "ogg")
    }

    // MARK: - Gemini

    private suspend fun synthesizeGemini(
        apiKey: String,
        model: String,
        voice: String,
        text: String,
    ): Audio {
        val body = JSONObject().apply {
            put("contents", JSONArray().put(JSONObject().put("parts", JSONArray().put(JSONObject().put("text", text)))))
            put("generationConfig", JSONObject().apply {
                put("responseModalities", JSONArray().put("AUDIO"))
                put("speechConfig", JSONObject().put(
                    "voiceConfig",
                    JSONObject().put("prebuiltVoiceConfig", JSONObject().put("voiceName", voice))
                ))
            })
        }
        val request = Request.Builder()
            .url("https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent")
            .header("x-goog-api-key", apiKey)
            .post(HttpClient.jsonBody(body))
            .build()
        val response = JSONObject(HttpClient.json(request))
        val part = try {
            response.getJSONArray("candidates").getJSONObject(0)
                .getJSONObject("content").getJSONArray("parts").getJSONObject(0)
                .getJSONObject("inlineData")
        } catch (_: Exception) {
            throw ProviderException.decoding("no audio in Gemini TTS response")
        }
        val pcm = android.util.Base64.decode(part.getString("data"), android.util.Base64.DEFAULT)
        // mimeType is e.g. "audio/L16;codec=pcm;rate=24000".
        val rate = Regex("rate=(\\d+)").find(part.optString("mimeType"))
            ?.groupValues?.get(1)?.toIntOrNull() ?: 24_000
        // AAC/.m4a is ~10× smaller than WAV (which stays as the fallback if
        // the device encoder ever fails — WAV always plays).
        return try {
            Audio(pcmToM4a(pcm, sampleRate = rate), "m4a")
        } catch (e: Exception) {
            com.aispotlight.android.core.Diagnostics.log("tts", "aacEncode.failed ${e.message}")
            Audio(pcmToWav(pcm, sampleRate = rate), "wav")
        }
    }

    /**
     * Transcodes raw 16-bit mono PCM to AAC-LC in an .m4a container with the
     * device MediaCodec — 32 kbps mono, plenty for speech.
     */
    private fun pcmToM4a(pcm: ByteArray, sampleRate: Int): ByteArray {
        val tmp = java.io.File.createTempFile("tts-encode", ".m4a")
        val codec = android.media.MediaCodec.createEncoderByType(android.media.MediaFormat.MIMETYPE_AUDIO_AAC)
        val muxer = android.media.MediaMuxer(tmp.path, android.media.MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        try {
            val format = android.media.MediaFormat.createAudioFormat(
                android.media.MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, 1
            ).apply {
                setInteger(
                    android.media.MediaFormat.KEY_AAC_PROFILE,
                    android.media.MediaCodecInfo.CodecProfileLevel.AACObjectLC
                )
                setInteger(android.media.MediaFormat.KEY_BIT_RATE, 32_000)
            }
            codec.configure(format, null, null, android.media.MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()

            val info = android.media.MediaCodec.BufferInfo()
            val bytesPerSecond = sampleRate * 2L // 16-bit mono
            var track = -1
            var offset = 0
            var inputDone = false
            var outputDone = false
            while (!outputDone) {
                if (!inputDone) {
                    val inIndex = codec.dequeueInputBuffer(10_000)
                    if (inIndex >= 0) {
                        val buffer = codec.getInputBuffer(inIndex)!!
                        buffer.clear()
                        val chunk = minOf(buffer.remaining(), pcm.size - offset)
                        val ptsUs = offset * 1_000_000L / bytesPerSecond
                        if (chunk <= 0) {
                            codec.queueInputBuffer(
                                inIndex, 0, 0, ptsUs,
                                android.media.MediaCodec.BUFFER_FLAG_END_OF_STREAM
                            )
                            inputDone = true
                        } else {
                            buffer.put(pcm, offset, chunk)
                            codec.queueInputBuffer(inIndex, 0, chunk, ptsUs, 0)
                            offset += chunk
                        }
                    }
                }
                val outIndex = codec.dequeueOutputBuffer(info, 10_000)
                when {
                    outIndex == android.media.MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        track = muxer.addTrack(codec.outputFormat)
                        muxer.start()
                    }
                    outIndex >= 0 -> {
                        val isConfig = info.flags and android.media.MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                        if (info.size > 0 && !isConfig && track >= 0) {
                            muxer.writeSampleData(track, codec.getOutputBuffer(outIndex)!!, info)
                        }
                        codec.releaseOutputBuffer(outIndex, false)
                        if (info.flags and android.media.MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            outputDone = true
                        }
                    }
                }
            }
            codec.stop()
            if (track >= 0) muxer.stop()
            return tmp.readBytes()
        } finally {
            codec.release()
            muxer.release()
            tmp.delete()
        }
    }

    /** Wraps raw 16-bit mono PCM in a minimal WAV header. */
    private fun pcmToWav(pcm: ByteArray, sampleRate: Int, channels: Int = 1, bitsPerSample: Int = 16): ByteArray {
        val byteRate = sampleRate * channels * bitsPerSample / 8
        val header = java.nio.ByteBuffer.allocate(44).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        header.put("RIFF".toByteArray(Charsets.US_ASCII))
        header.putInt(36 + pcm.size)
        header.put("WAVE".toByteArray(Charsets.US_ASCII))
        header.put("fmt ".toByteArray(Charsets.US_ASCII))
        header.putInt(16)                                  // PCM chunk size
        header.putShort(1)                                 // PCM format
        header.putShort(channels.toShort())
        header.putInt(sampleRate)
        header.putInt(byteRate)
        header.putShort((channels * bitsPerSample / 8).toShort())
        header.putShort(bitsPerSample.toShort())
        header.put("data".toByteArray(Charsets.US_ASCII))
        header.putInt(pcm.size)
        return header.array() + pcm
    }
}
