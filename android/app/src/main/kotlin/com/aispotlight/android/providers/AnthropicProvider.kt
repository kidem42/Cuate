package com.aispotlight.android.providers

import com.aispotlight.android.core.ChatRequestOptions
import com.aispotlight.android.core.HttpClient
import com.aispotlight.android.core.LLMMessage
import com.aispotlight.android.core.LLMProvider
import com.aispotlight.android.core.LLMStreamEvent
import com.aispotlight.android.core.ModelCapabilities
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

/** Anthropic Messages API (`POST /v1/messages`) with SSE streaming and tool use. */
class AnthropicProvider : LLMProvider {
    override val providerID = ProviderID.ANTHROPIC
    private val baseURL = "https://api.anthropic.com/v1"
    private val apiVersion = "2023-06-01"

    // MARK: - Chat

    override fun streamChat(
        messages: List<LLMMessage>,
        model: String,
        systemPrompt: String?,
        options: ChatRequestOptions,
        apiKey: String,
    ): Flow<LLMStreamEvent> = flow {
        val apiMessages = JSONArray()
        for (message in messages) {
            when {
                message.role == LLMMessage.Role.TOOL -> {
                    // Tool results are user-role content blocks in the Anthropic API.
                    apiMessages.put(JSONObject().apply {
                        put("role", "user")
                        put("content", JSONArray().put(JSONObject().apply {
                            put("type", "tool_result")
                            put("tool_use_id", message.toolCallID ?: "")
                            put("content", message.text)
                        }))
                    })
                }
                message.role == LLMMessage.Role.ASSISTANT && message.toolCalls.isNotEmpty() -> {
                    val blocks = JSONArray()
                    if (message.text.isNotEmpty()) {
                        blocks.put(JSONObject().put("type", "text").put("text", message.text))
                    }
                    for (call in message.toolCalls) {
                        blocks.put(JSONObject().apply {
                            put("type", "tool_use")
                            put("id", call.id)
                            put("name", call.name)
                            put("input", call.arguments)
                        })
                    }
                    apiMessages.put(JSONObject().put("role", "assistant").put("content", blocks))
                }
                else -> {
                    if (message.images.isEmpty()) {
                        apiMessages.put(JSONObject().put("role", message.role.raw).put("content", message.text))
                    } else {
                        val blocks = JSONArray()
                        for (image in message.images) {
                            blocks.put(JSONObject().apply {
                                put("type", "image")
                                put("source", JSONObject().apply {
                                    put("type", "base64")
                                    put("media_type", image.mimeType)
                                    put("data", image.base64)
                                })
                            })
                        }
                        if (message.text.isNotEmpty()) {
                            blocks.put(JSONObject().put("type", "text").put("text", message.text))
                        }
                        apiMessages.put(JSONObject().put("role", message.role.raw).put("content", blocks))
                    }
                }
            }
        }

        // Anthropic has no implicit prompt cache — without explicit breakpoints
        // every turn re-pays the full input price. Two markers: the system
        // prompt (stable within a day per preset) and the last content block,
        // which caches the entire conversation prefix so the next turn re-reads
        // it at ~10% of the input price.
        if (apiMessages.length() > 0) {
            val last = apiMessages.getJSONObject(apiMessages.length() - 1)
            val content = last.opt("content")
            val blocks: JSONArray = when (content) {
                is String -> JSONArray().put(JSONObject().put("type", "text").put("text", content))
                is JSONArray -> content
                else -> JSONArray()
            }
            if (blocks.length() > 0) {
                blocks.getJSONObject(blocks.length() - 1)
                    .put("cache_control", JSONObject().put("type", "ephemeral"))
                last.put("content", blocks)
            }
        }

        val body = JSONObject().apply {
            put("model", model)
            put("max_tokens", minOf(options.maxTokens, maxTokensCap(model)))
            put("messages", apiMessages)
            put("stream", true)
            if (!systemPrompt.isNullOrEmpty()) {
                put("system", JSONArray().put(JSONObject().apply {
                    put("type", "text")
                    put("text", systemPrompt)
                    put("cache_control", JSONObject().put("type", "ephemeral"))
                }))
            }
            if (options.tools.isNotEmpty()) {
                put("tools", JSONArray().apply {
                    for (tool in options.tools) {
                        put(JSONObject().apply {
                            put("name", tool.name)
                            put("description", tool.description)
                            put("input_schema", tool.parameters)
                        })
                    }
                })
            }
            // Reasoning: adaptive thinking on modern Claude models.
            if (options.reasoning != ReasoningMode.AUTO &&
                ModelCapabilities.supportsReasoningControl(ProviderID.ANTHROPIC, model)
            ) {
                if (options.reasoning == ReasoningMode.DEEP) {
                    put("thinking", JSONObject().put("type", "adaptive"))
                    put("output_config", JSONObject().put("effort", "high"))
                } else {
                    put("output_config", JSONObject().put("effort", "low"))
                }
            }
        }

        val request = Request.Builder()
            .url("$baseURL/messages")
            .header("Content-Type", "application/json")
            .header("x-api-key", apiKey)
            .header("anthropic-version", apiVersion)
            .post(HttpClient.jsonBody(body))
            .build()

        // Tool call deltas arrive fragmented — accumulate by block index.
        val pendingCalls = sortedMapOf<Int, Triple<String, String, StringBuilder>>()
        var usage = TokenUsage()
        HttpClient.sseStream(request).collect { payload ->
            val json = try { JSONObject(payload) } catch (_: Exception) { return@collect }
            when (json.optString("type")) {
                "message_start" -> {
                    // Input-side usage (incl. cache split) rides on the opening
                    // frame; output arrives via message_delta.
                    json.optJSONObject("message")?.optJSONObject("usage")?.let { u ->
                        usage = usage.copy(
                            inputTokens = u.optInt("input_tokens"),
                            cacheWriteTokens = u.optInt("cache_creation_input_tokens"),
                            cacheReadTokens = u.optInt("cache_read_input_tokens"),
                        )
                    }
                }
                "message_delta" -> {
                    // Cumulative output count — keep the latest value.
                    json.optJSONObject("usage")?.let { u ->
                        val output = u.optInt("output_tokens", -1)
                        if (output >= 0) usage = usage.copy(outputTokens = output)
                    }
                }
                "content_block_start" -> {
                    val index = json.optInt("index", -1)
                    val block = json.optJSONObject("content_block")
                    if (index >= 0 && block?.optString("type") == "tool_use") {
                        pendingCalls[index] = Triple(
                            block.optString("id").ifEmpty { newCallID() },
                            block.optString("name"),
                            StringBuilder()
                        )
                    }
                }
                "content_block_delta" -> {
                    val delta = json.optJSONObject("delta") ?: return@collect
                    when (delta.optString("type")) {
                        "text_delta" -> {
                            val text = delta.optString("text")
                            if (text.isNotEmpty()) emit(LLMStreamEvent.Text(text))
                        }
                        "input_json_delta" -> {
                            val index = json.optInt("index", -1)
                            pendingCalls[index]?.third?.append(delta.optString("partial_json"))
                        }
                    }
                }
                "error" -> {
                    val message = json.optJSONObject("error")?.optString("message")
                    if (!message.isNullOrEmpty()) throw ProviderException.http(200, message)
                }
            }
        }
        if (pendingCalls.isNotEmpty()) {
            emit(LLMStreamEvent.ToolCalls(pendingCalls.values.map { (id, name, args) ->
                ToolCall(id = id, name = name, argumentsJSON = args.toString().ifEmpty { "{}" })
            }))
        }
        if (!usage.isEmpty) emit(LLMStreamEvent.Usage(usage))
    }

    /** Output-token ceilings differ per model generation — exceeding them is a 400. */
    private fun maxTokensCap(model: String): Int {
        val m = model.lowercase()
        return when {
            m.contains("claude-3-haiku") -> 4096
            m.contains("claude-3-5") || m.contains("claude-3-7") -> 8192
            m.contains("opus-4-0") || m.contains("opus-4-1") || m.contains("claude-opus-4-2025") -> 32000
            m.contains("haiku-4-5") -> 64000
            else -> 128_000 // modern models (Opus 4.5+, Sonnet 4.5+, Fable/Mythos 5)
        }
    }

    // MARK: - Models

    override suspend fun fetchModels(apiKey: String): List<String> {
        val request = Request.Builder()
            .url("$baseURL/models")
            .header("x-api-key", apiKey)
            .header("anthropic-version", apiVersion)
            .build()

        val data = HttpClient.json(request)
        val items = try {
            JSONObject(data).getJSONArray("data")
        } catch (_: Exception) {
            throw ProviderException.decoding("unexpected /models payload")
        }
        return (0 until items.length()).mapNotNull { i ->
            items.optJSONObject(i)?.optString("id")?.takeIf { it.isNotEmpty() }
        }
    }
}
