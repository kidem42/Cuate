package com.aispotlight.android.providers

import com.aispotlight.android.core.ChatRequestOptions
import com.aispotlight.android.core.HttpClient
import com.aispotlight.android.core.LLMMessage
import com.aispotlight.android.core.LLMProvider
import com.aispotlight.android.core.LLMStreamEvent
import com.aispotlight.android.core.ModelCapabilities
import com.aispotlight.android.core.ModelInfo
import com.aispotlight.android.core.ProviderException
import com.aispotlight.android.core.ProviderID
import com.aispotlight.android.core.ReasoningMode
import com.aispotlight.android.core.TokenUsage
import com.aispotlight.android.core.ToolCall
import com.aispotlight.android.core.newCallID
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject

/**
 * Chat provider for OpenAI-compatible APIs: OpenAI, Mistral, DeepSeek,
 * OpenRouter, Kimi (Moonshot).
 * Uses `POST {base}/chat/completions` with SSE streaming, function calling,
 * and `GET {base}/models`. OpenAI itself uses the newer `/v1/responses` API.
 */
class OpenAICompatibleProvider(
    override val providerID: ProviderID,
    private val baseURL: String,
) : LLMProvider {

    companion object {
        val openAI = OpenAICompatibleProvider(ProviderID.OPENAI, "https://api.openai.com/v1")
        val mistral = OpenAICompatibleProvider(ProviderID.MISTRAL, "https://api.mistral.ai/v1")
        val deepSeek = OpenAICompatibleProvider(ProviderID.DEEPSEEK, "https://api.deepseek.com/v1")
        val openRouter = OpenAICompatibleProvider(ProviderID.OPENROUTER, "https://openrouter.ai/api/v1")
        val kimi = OpenAICompatibleProvider(ProviderID.KIMI, "https://api.moonshot.ai/v1")
    }

    /**
     * Builds a request with the Bearer key and any provider-specific headers.
     * OpenRouter gets an `X-Title` attribution header for its app rankings.
     */
    private fun requestBuilder(path: String, apiKey: String): Request.Builder {
        val builder = Request.Builder()
            .url("$baseURL/$path")
            .header("Authorization", "Bearer $apiKey")
        if (providerID == ProviderID.OPENROUTER) {
            builder.header("X-Title", "AISpotlight")
        }
        return builder
    }

    // MARK: - Chat

    override fun streamChat(
        messages: List<LLMMessage>,
        model: String,
        systemPrompt: String?,
        options: ChatRequestOptions,
        apiKey: String,
    ): Flow<LLMStreamEvent> {
        // OpenAI's current primary endpoint is /v1/responses — unlike
        // /v1/chat/completions it supports function tools together with
        // reasoning. Mistral/DeepSeek stay on chat/completions.
        if (providerID == ProviderID.OPENAI) {
            return streamResponsesAPI(messages, model, systemPrompt, options, apiKey)
        }
        return flow {
            val apiMessages = JSONArray()
            if (!systemPrompt.isNullOrEmpty()) {
                apiMessages.put(JSONObject().put("role", "system").put("content", systemPrompt))
            }
            for (message in messages) {
                when {
                    message.role == LLMMessage.Role.TOOL -> {
                        apiMessages.put(JSONObject().apply {
                            put("role", "tool")
                            put("tool_call_id", message.toolCallID ?: "")
                            put("content", message.text)
                        })
                    }
                    message.role == LLMMessage.Role.ASSISTANT && message.toolCalls.isNotEmpty() -> {
                        val entry = JSONObject().apply {
                            put("role", "assistant")
                            put("tool_calls", JSONArray().apply {
                                for (call in message.toolCalls) {
                                    put(JSONObject().apply {
                                        put("id", call.id)
                                        put("type", "function")
                                        put("function", JSONObject()
                                            .put("name", call.name)
                                            .put("arguments", call.argumentsJSON))
                                    })
                                }
                            })
                        }
                        if (message.text.isNotEmpty()) entry.put("content", message.text)
                        apiMessages.put(entry)
                    }
                    else -> {
                        if (message.images.isEmpty()) {
                            apiMessages.put(JSONObject().put("role", message.role.raw).put("content", message.text))
                        } else {
                            val parts = JSONArray()
                            if (message.text.isNotEmpty()) {
                                parts.put(JSONObject().put("type", "text").put("text", message.text))
                            }
                            for (image in message.images) {
                                parts.put(JSONObject().apply {
                                    put("type", "image_url")
                                    put("image_url", JSONObject()
                                        .put("url", "data:${image.mimeType};base64,${image.base64}"))
                                })
                            }
                            apiMessages.put(JSONObject().put("role", message.role.raw).put("content", parts))
                        }
                    }
                }
            }

            val body = JSONObject().apply {
                put("model", model)
                put("messages", apiMessages)
                put("stream", true)
                put("max_tokens", options.maxTokens)
                if (options.tools.isNotEmpty()) {
                    put("tools", JSONArray().apply {
                        for (tool in options.tools) {
                            put(JSONObject().apply {
                                put("type", "function")
                                put("function", JSONObject().apply {
                                    put("name", tool.name)
                                    put("description", tool.description)
                                    put("parameters", tool.parameters)
                                })
                            })
                        }
                    })
                }
                // OpenRouter accepts a reasoning-effort knob directly on
                // chat/completions (Mistral/DeepSeek do not). Only sent for
                // models the catalog says support it.
                if (providerID == ProviderID.OPENROUTER &&
                    options.reasoning != ReasoningMode.AUTO &&
                    options.modelSupportsReasoning
                ) {
                    put("reasoning", JSONObject()
                        .put("effort", if (options.reasoning == ReasoningMode.FAST) "low" else "high"))
                }
                // Ask for the final usage chunk (cost tracking). Sent to
                // providers that document `stream_options`: DeepSeek, OpenRouter,
                // Kimi. Mistral is excluded until verified live — unknown
                // params risk a 422 there.
                if (providerID == ProviderID.DEEPSEEK ||
                    providerID == ProviderID.OPENROUTER ||
                    providerID == ProviderID.KIMI
                ) {
                    put("stream_options", JSONObject().put("include_usage", true))
                }
            }

            val request = requestBuilder("chat/completions", apiKey)
                .header("Content-Type", "application/json")
                .post(HttpClient.jsonBody(body))
                .build()

            // Tool call deltas arrive fragmented — accumulate by index.
            data class Pending(var id: String = "", var name: String = "", val args: StringBuilder = StringBuilder())
            val pendingCalls = sortedMapOf<Int, Pending>()
            var usage = TokenUsage()

            HttpClient.sseStream(request).collect { payload ->
                val json = try { JSONObject(payload) } catch (_: Exception) { return@collect }

                // OpenRouter (and some gateways) can surface a mid-stream error
                // inside a data frame instead of a non-2xx status.
                json.optJSONObject("error")?.let { error ->
                    val message = error.optString("message")
                    if (message.isNotEmpty()) {
                        throw ProviderException.http(error.optInt("code", 200), message)
                    }
                }

                // Usage rides on the final chunk, whose `choices` is empty —
                // must be read BEFORE the choice guard below skips it.
                json.optJSONObject("usage")?.let { usage = parseChatCompletionsUsage(it) }

                val choice = json.optJSONArray("choices")?.optJSONObject(0) ?: return@collect
                val delta = choice.optJSONObject("delta") ?: return@collect
                val content = delta.optString("content")
                if (content.isNotEmpty()) emit(LLMStreamEvent.Text(content))
                delta.optJSONArray("tool_calls")?.let { toolCalls ->
                    for (i in 0 until toolCalls.length()) {
                        val fragment = toolCalls.optJSONObject(i) ?: continue
                        val index = fragment.optInt("index", 0)
                        val entry = pendingCalls.getOrPut(index) { Pending() }
                        fragment.optString("id").takeIf { it.isNotEmpty() }?.let { entry.id = it }
                        fragment.optJSONObject("function")?.let { function ->
                            entry.name += function.optString("name")
                            entry.args.append(function.optString("arguments"))
                        }
                    }
                }
            }
            if (pendingCalls.isNotEmpty()) {
                emit(LLMStreamEvent.ToolCalls(pendingCalls.values.map { entry ->
                    ToolCall(
                        id = entry.id.ifEmpty { newCallID() },
                        name = entry.name,
                        argumentsJSON = entry.args.toString().ifEmpty { "{}" }
                    )
                }))
            }
            if (!usage.isEmpty) emit(LLMStreamEvent.Usage(usage))
        }
    }

    /**
     * Maps a chat/completions `usage` object to normalized counts.
     * DeepSeek splits input by cache outcome (hit ≈ 1/50 of miss price) —
     * its `prompt_cache_hit_tokens`/`prompt_cache_miss_tokens` take priority.
     * Other providers report `prompt_tokens` (total) + optional
     * `prompt_tokens_details.cached_tokens`; the cached share is subtracted so
     * `inputTokens` stays "uncached input" across all providers.
     */
    private fun parseChatCompletionsUsage(u: JSONObject): TokenUsage {
        val prompt = u.optInt("prompt_tokens")
        val completion = u.optInt("completion_tokens")
        val hit = u.optInt("prompt_cache_hit_tokens", -1)
        val miss = u.optInt("prompt_cache_miss_tokens", -1)
        val reasoning = u.optJSONObject("completion_tokens_details")?.optInt("reasoning_tokens") ?: 0
        return if (hit >= 0 && miss >= 0) {
            TokenUsage(inputTokens = miss, outputTokens = completion,
                cacheReadTokens = hit, reasoningTokens = reasoning)
        } else {
            val cached = u.optJSONObject("prompt_tokens_details")?.optInt("cached_tokens") ?: 0
            TokenUsage(inputTokens = (prompt - cached).coerceAtLeast(0), outputTokens = completion,
                cacheReadTokens = cached, reasoningTokens = reasoning)
        }
    }

    // MARK: - OpenAI Responses API

    /**
     * `POST /v1/responses` with SSE streaming. Supports function tools together
     * with reasoning (the chat/completions limitation doesn't apply).
     */
    private fun streamResponsesAPI(
        messages: List<LLMMessage>,
        model: String,
        systemPrompt: String?,
        options: ChatRequestOptions,
        apiKey: String,
    ): Flow<LLMStreamEvent> = flow {
        val input = JSONArray()
        for (message in messages) {
            when {
                message.role == LLMMessage.Role.TOOL -> {
                    input.put(JSONObject().apply {
                        put("type", "function_call_output")
                        put("call_id", message.toolCallID ?: "")
                        put("output", message.text)
                    })
                }
                message.role == LLMMessage.Role.ASSISTANT && message.toolCalls.isNotEmpty() -> {
                    if (message.text.isNotEmpty()) {
                        input.put(JSONObject().apply {
                            put("role", "assistant")
                            put("content", JSONArray().put(JSONObject()
                                .put("type", "output_text").put("text", message.text)))
                        })
                    }
                    for (call in message.toolCalls) {
                        input.put(JSONObject().apply {
                            put("type", "function_call")
                            put("call_id", call.id)
                            put("name", call.name)
                            put("arguments", call.argumentsJSON)
                        })
                    }
                }
                message.role == LLMMessage.Role.ASSISTANT -> {
                    input.put(JSONObject().apply {
                        put("role", "assistant")
                        put("content", JSONArray().put(JSONObject()
                            .put("type", "output_text").put("text", message.text)))
                    })
                }
                else -> {
                    val parts = JSONArray()
                    if (message.text.isNotEmpty()) {
                        parts.put(JSONObject().put("type", "input_text").put("text", message.text))
                    }
                    for (image in message.images) {
                        parts.put(JSONObject().apply {
                            put("type", "input_image")
                            put("image_url", "data:${image.mimeType};base64,${image.base64}")
                        })
                    }
                    input.put(JSONObject().put("role", "user").put("content", parts))
                }
            }
        }

        val body = JSONObject().apply {
            put("model", model)
            put("input", input)
            put("stream", true)
            put("store", false) // don't persist conversations server-side
            put("max_output_tokens", options.maxTokens)
            if (!systemPrompt.isNullOrEmpty()) put("instructions", systemPrompt)
            if (options.tools.isNotEmpty()) {
                // Responses API uses a flat function-tool shape.
                put("tools", JSONArray().apply {
                    for (tool in options.tools) {
                        put(JSONObject().apply {
                            put("type", "function")
                            put("name", tool.name)
                            put("description", tool.description)
                            put("parameters", tool.parameters)
                        })
                    }
                })
            }
            if (options.reasoning != ReasoningMode.AUTO &&
                ModelCapabilities.supportsReasoningControl(ProviderID.OPENAI, model)
            ) {
                put("reasoning", JSONObject()
                    .put("effort", if (options.reasoning == ReasoningMode.FAST) "low" else "high"))
            }
        }

        val request = Request.Builder()
            .url("$baseURL/responses")
            .header("Content-Type", "application/json")
            .header("Authorization", "Bearer $apiKey")
            .post(HttpClient.jsonBody(body))
            .build()

        val pendingCalls = mutableListOf<ToolCall>()
        var usage = TokenUsage()
        HttpClient.sseStream(request).collect { payload ->
            val json = try { JSONObject(payload) } catch (_: Exception) { return@collect }
            when (json.optString("type")) {
                "response.completed" -> {
                    // Whole-response usage arrives on the terminal event.
                    json.optJSONObject("response")?.optJSONObject("usage")?.let { u ->
                        val input = u.optInt("input_tokens")
                        val cached = u.optJSONObject("input_tokens_details")?.optInt("cached_tokens") ?: 0
                        usage = TokenUsage(
                            inputTokens = (input - cached).coerceAtLeast(0),
                            outputTokens = u.optInt("output_tokens"),
                            cacheReadTokens = cached,
                            reasoningTokens = u.optJSONObject("output_tokens_details")?.optInt("reasoning_tokens") ?: 0,
                        )
                    }
                }
                "response.output_text.delta" -> {
                    val delta = json.optString("delta")
                    if (delta.isNotEmpty()) emit(LLMStreamEvent.Text(delta))
                }
                "response.output_item.done" -> {
                    // Complete function call arrives assembled here.
                    val item = json.optJSONObject("item")
                    if (item?.optString("type") == "function_call") {
                        val name = item.optString("name")
                        if (name.isNotEmpty()) {
                            pendingCalls.add(ToolCall(
                                id = item.optString("call_id").ifEmpty { newCallID() },
                                name = name,
                                argumentsJSON = item.optString("arguments").ifEmpty { "{}" }
                            ))
                        }
                    }
                }
                "response.failed", "response.incomplete" -> {
                    val message = json.optJSONObject("response")
                        ?.optJSONObject("error")?.optString("message")
                    if (!message.isNullOrEmpty()) throw ProviderException.http(200, message)
                }
                "error" -> {
                    throw ProviderException.http(200, json.optString("message").ifEmpty { "Unknown streaming error" })
                }
            }
        }
        if (pendingCalls.isNotEmpty()) {
            emit(LLMStreamEvent.ToolCalls(pendingCalls))
        }
        if (!usage.isEmpty) emit(LLMStreamEvent.Usage(usage))
    }

    // MARK: - Models

    override suspend fun fetchModels(apiKey: String): List<String> {
        val request = requestBuilder("models", apiKey).build()
        val data = HttpClient.json(request)
        val items = try {
            JSONObject(data).getJSONArray("data")
        } catch (_: Exception) {
            throw ProviderException.decoding("unexpected /models payload")
        }

        val ids = mutableListOf<String>()
        for (i in 0 until items.length()) {
            val item = items.optJSONObject(i) ?: continue
            val id = item.optString("id").takeIf { it.isNotEmpty() } ?: continue
            // Mistral advertises capabilities — keep chat-capable models only.
            val caps = item.optJSONObject("capabilities")
            if (caps != null && caps.has("completion_chat") && !caps.optBoolean("completion_chat", true)) continue
            if (isLikelyChatModel(id)) ids.add(id)
        }
        return ids.sorted()
    }

    /** Filters out obviously non-chat models (embeddings, audio, images, moderation). */
    private fun isLikelyChatModel(id: String): Boolean {
        val lower = id.lowercase()
        val excluded = listOf(
            "embed", "whisper", "tts", "dall-e", "image", "moderation",
            "transcribe", "audio", "realtime", "ocr", "voxtral", "davinci",
            "babbage", "codestral-embed"
        )
        return excluded.none { lower.contains(it) }
    }

    // MARK: - Model catalog (OpenRouter)

    /**
     * Fetches the full model catalog with per-model capabilities, parsed from
     * OpenRouter's richer `/models` payload. Unfiltered on purpose: the catalog
     * validates whatever slug the user types. The key is optional (public endpoint).
     */
    suspend fun fetchModelCatalog(apiKey: String?): List<ModelInfo> {
        val builder = Request.Builder().url("$baseURL/models")
        if (apiKey != null) builder.header("Authorization", "Bearer $apiKey")
        if (providerID == ProviderID.OPENROUTER) builder.header("X-Title", "AISpotlight")

        val data = HttpClient.json(builder.build())
        val items = try {
            JSONObject(data).getJSONArray("data")
        } catch (_: Exception) {
            throw ProviderException.decoding("unexpected /models payload")
        }

        val catalog = mutableListOf<ModelInfo>()
        for (i in 0 until items.length()) {
            val item = items.optJSONObject(i) ?: continue
            val id = item.optString("id").takeIf { it.isNotEmpty() } ?: continue
            val inputModalities = item.optJSONObject("architecture")
                ?.optJSONArray("input_modalities")?.toStringList() ?: emptyList()
            val params = item.optJSONArray("supported_parameters")?.toStringList() ?: emptyList()
            // OpenRouter reports USD-per-token prices as decimal strings.
            val pricing = item.optJSONObject("pricing")
            catalog.add(ModelInfo(
                id = id,
                supportsVision = inputModalities.contains("image"),
                supportsTools = params.contains("tools"),
                supportsReasoning = params.contains("reasoning"),
                supportedParameters = params,
                promptPricePerToken = pricing?.optString("prompt")?.toDoubleOrNull(),
                completionPricePerToken = pricing?.optString("completion")?.toDoubleOrNull(),
            ))
        }
        return catalog
    }

    // MARK: - Key validation

    /**
     * OpenRouter's `/models` is public, so a key check there would pass even
     * with a bad key; `/api/v1/key` requires a valid key.
     */
    override suspend fun validateKey(apiKey: String) {
        if (providerID == ProviderID.OPENROUTER) {
            HttpClient.json(requestBuilder("key", apiKey).build())
        } else {
            fetchModels(apiKey)
        }
    }
}

private fun JSONArray.toStringList(): List<String> =
    (0 until length()).mapNotNull { optString(it).takeIf { s -> s.isNotEmpty() } }
