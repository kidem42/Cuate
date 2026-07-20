package com.aispotlight.android.providers

import com.aispotlight.android.core.ChatRequestOptions
import com.aispotlight.android.core.HttpClient
import com.aispotlight.android.core.LLMMessage
import com.aispotlight.android.core.LLMProvider
import com.aispotlight.android.core.LLMStreamEvent
import com.aispotlight.android.core.ProviderException
import com.aispotlight.android.core.ProviderID
import com.aispotlight.android.core.ReasoningMode
import com.aispotlight.android.core.TokenUsage
import com.aispotlight.android.core.ToolCall
import com.aispotlight.android.core.newCallID
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject

/**
 * Google Gemini API (`streamGenerateContent` via SSE) with function calling.
 * The API key is sent in the `x-goog-api-key` header — never as a URL query
 * parameter, where it could leak into logs.
 */
class GeminiProvider : LLMProvider {
    override val providerID = ProviderID.GEMINI
    private val baseURL = "https://generativelanguage.googleapis.com/v1beta"

    // MARK: - Chat

    override fun streamChat(
        messages: List<LLMMessage>,
        model: String,
        systemPrompt: String?,
        options: ChatRequestOptions,
        apiKey: String,
    ): Flow<LLMStreamEvent> = flow {
        val contents = JSONArray()
        for (message in messages) {
            when {
                message.role == LLMMessage.Role.TOOL -> {
                    contents.put(JSONObject().apply {
                        put("role", "user")
                        put("parts", JSONArray().put(JSONObject().put("functionResponse", JSONObject().apply {
                            put("name", message.toolName ?: "tool")
                            put("response", JSONObject().put("result", message.text))
                        })))
                    })
                }
                message.role == LLMMessage.Role.ASSISTANT && message.toolCalls.isNotEmpty() -> {
                    val parts = JSONArray()
                    if (message.text.isNotEmpty()) {
                        parts.put(JSONObject().put("text", message.text))
                    }
                    for (call in message.toolCalls) {
                        parts.put(JSONObject().put("functionCall", JSONObject().apply {
                            put("name", call.name)
                            put("args", call.arguments)
                        }))
                    }
                    contents.put(JSONObject().put("role", "model").put("parts", parts))
                }
                else -> {
                    val parts = JSONArray()
                    if (message.text.isNotEmpty()) {
                        parts.put(JSONObject().put("text", message.text))
                    }
                    for (image in message.images) {
                        parts.put(JSONObject().put("inline_data", JSONObject().apply {
                            put("mime_type", image.mimeType)
                            put("data", image.base64)
                        }))
                    }
                    contents.put(JSONObject().apply {
                        put("role", if (message.role == LLMMessage.Role.ASSISTANT) "model" else "user")
                        put("parts", parts)
                    })
                }
            }
        }

        val generationConfig = JSONObject().put("maxOutputTokens", options.maxTokens)
        // Reasoning control differs by generation and MUST NOT be mixed:
        // Gemini 3.x takes thinkingLevel (strings), 2.5 takes thinkingBudget
        // (numbers); sending both is an API error, budget 0 is rejected on Pro.
        if (options.reasoning != ReasoningMode.AUTO) {
            val m = model.lowercase()
            if (m.contains("gemini-3")) {
                generationConfig.put("thinkingConfig", JSONObject()
                    .put("thinkingLevel", if (options.reasoning == ReasoningMode.FAST) "low" else "high"))
            } else if (m.contains("2.5") && options.reasoning == ReasoningMode.FAST && m.contains("flash")) {
                generationConfig.put("thinkingConfig", JSONObject().put("thinkingBudget", 0))
            }
            // 2.5 deep / 2.5-pro fast: dynamic thinking is the default — omit.
        }

        val body = JSONObject().apply {
            put("contents", contents)
            put("generationConfig", generationConfig)
            if (!systemPrompt.isNullOrEmpty()) {
                put("systemInstruction", JSONObject()
                    .put("parts", JSONArray().put(JSONObject().put("text", systemPrompt))))
            }
            if (options.tools.isNotEmpty()) {
                put("tools", JSONArray().put(JSONObject().put("functionDeclarations", JSONArray().apply {
                    for (tool in options.tools) {
                        put(JSONObject().apply {
                            put("name", tool.name)
                            put("description", tool.description)
                            put("parameters", tool.parameters)
                        })
                    }
                })))
            }
        }

        val url = "$baseURL/models/$model:streamGenerateContent".toHttpUrl()
            .newBuilder().addQueryParameter("alt", "sse").build()
        val request = Request.Builder()
            .url(url)
            .header("Content-Type", "application/json")
            .header("x-goog-api-key", apiKey)
            .post(HttpClient.jsonBody(body))
            .build()

        val pendingCalls = mutableListOf<ToolCall>()
        var usage = TokenUsage()
        HttpClient.sseStream(request).collect { payload ->
            val json = try { JSONObject(payload) } catch (_: Exception) { return@collect }
            // usageMetadata is cumulative and rides on stream chunks; the final
            // one can be usage-only (no candidates/parts), so it must be read
            // BEFORE the content guard below skips the frame.
            json.optJSONObject("usageMetadata")?.let { meta ->
                val prompt = meta.optInt("promptTokenCount")
                val cached = meta.optInt("cachedContentTokenCount")
                val thoughts = meta.optInt("thoughtsTokenCount")
                usage = TokenUsage(
                    inputTokens = (prompt - cached).coerceAtLeast(0),
                    // Gemini bills thinking at the output rate but reports it
                    // separately from candidatesTokenCount.
                    outputTokens = meta.optInt("candidatesTokenCount") + thoughts,
                    cacheReadTokens = cached,
                    reasoningTokens = thoughts,
                )
            }
            val parts = json.optJSONArray("candidates")?.optJSONObject(0)
                ?.optJSONObject("content")?.optJSONArray("parts") ?: return@collect
            for (i in 0 until parts.length()) {
                val part = parts.optJSONObject(i) ?: continue
                val text = part.optString("text")
                if (text.isNotEmpty()) emit(LLMStreamEvent.Text(text))
                part.optJSONObject("functionCall")?.let { functionCall ->
                    val name = functionCall.optString("name")
                    if (name.isNotEmpty()) {
                        val args = functionCall.optJSONObject("args") ?: JSONObject()
                        pendingCalls.add(ToolCall(
                            id = newCallID(),
                            name = name,
                            argumentsJSON = args.toString()
                        ))
                    }
                }
            }
        }
        if (pendingCalls.isNotEmpty()) {
            emit(LLMStreamEvent.ToolCalls(pendingCalls))
        }
    }

    // MARK: - Models

    override suspend fun fetchModels(apiKey: String): List<String> {
        val url = "$baseURL/models".toHttpUrl()
            .newBuilder().addQueryParameter("pageSize", "200").build()
        val request = Request.Builder()
            .url(url)
            .header("x-goog-api-key", apiKey)
            .build()

        val data = HttpClient.json(request)
        val items = try {
            JSONObject(data).getJSONArray("models")
        } catch (_: Exception) {
            throw ProviderException.decoding("unexpected /models payload")
        }

        val ids = mutableListOf<String>()
        for (i in 0 until items.length()) {
            val item = items.optJSONObject(i) ?: continue
            val name = item.optString("name").takeIf { it.isNotEmpty() } ?: continue
            // Keep only models that can generate content (chat).
            val methods = item.optJSONArray("supportedGenerationMethods")
            if (methods != null) {
                val list = (0 until methods.length()).map { methods.optString(it) }
                if (!list.contains("generateContent")) continue
            }
            val id = name.removePrefix("models/")
            if (id.lowercase().contains("embedding")) continue
            ids.add(id)
        }
        return ids.sorted()
    }
}
