package com.aispotlight.android.providers

import com.aispotlight.android.core.ChatRequestOptions
import com.aispotlight.android.data.SpendKind
import org.json.JSONArray
import org.json.JSONObject

/** Policy matches the desktop wire format; user prompts remain untouched. */
object PromptCache {
    fun supportsExplicit(model: String) = listOf("gpt-5.6", "gpt-6").any {
        model == it || model.startsWith("$it-")
    }
    fun openAI(body: JSONObject, options: ChatRequestOptions) {
        if (!supportsExplicit(body.getString("model"))) {
            options.cacheKey?.let { body.put("prompt_cache_key", it) }
            return
        }
        var input = body.getJSONArray("input")
        if (options.spendKind == SpendKind.SUMMARY) {
            body.put("prompt_cache_options", JSONObject().put("mode", "explicit"))
            val instructions = body.optString("instructions")
            body.remove("instructions")
            if (instructions.isNotEmpty()) {
                val replaced = JSONArray().put(JSONObject().put("role", "developer").put("content",
                    JSONArray().put(JSONObject().put("type", "input_text").put("text", instructions)
                        .put("prompt_cache_breakpoint", JSONObject().put("mode", "explicit")))))
                for (i in 0 until input.length()) replaced.put(input.get(i))
                input = replaced
            }
        }
        options.requestContext?.takeIf { it.isNotEmpty() }?.let {
            input.put(JSONObject().put("role", "developer").put("content", it))
        }
        body.put("input", input)
    }
    fun anthropic(messages: JSONArray) {
        val indices = (0 until messages.length()).toList()
        val system = indices.firstOrNull { messages.getJSONObject(it).optString("role") == "system" }
        val tail = indices.lastOrNull {
            val content = messages.getJSONObject(it).opt("content")
            (content is String && content.isNotEmpty()) || (content is JSONArray && content.length() > 0)
        }
        for (index in setOfNotNull(system, tail)) {
            val message = messages.getJSONObject(index)
            val content = message.opt("content")
            val blocks = if (content is String) JSONArray().put(JSONObject().put("type", "text").put("text", content))
                else content as? JSONArray ?: continue
            if (blocks.length() == 0) continue
            blocks.getJSONObject(blocks.length() - 1).put("cache_control", JSONObject().put("type", "ephemeral"))
            message.put("content", blocks)
        }
    }
}
