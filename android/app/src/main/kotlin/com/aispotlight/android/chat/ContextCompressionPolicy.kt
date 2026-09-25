package com.aispotlight.android.chat

import com.aispotlight.android.data.ChatMessage
import org.json.JSONObject

/** Pure rolling-summary policy; originals never change. */
object ContextCompressionPolicy {
    fun tokens(text: String): Int {
        val ascii = text.count { it.code < 128 }
        return ascii / 4 + (text.length - ascii) * 2 / 5
    }
    fun transcript(message: ChatMessage): String = buildString {
        append(if (message.isUser) "User: " else "Assistant: ")
        append(message.text)
        message.toolContext?.let { append("\nTool context: $it") }
        message.attachments.forEach { attachment ->
            append("\nAttachment: ${attachment.filename}")
            attachment.ocrText?.let { append("\n$it") }
        }
    }
    fun split(messages: List<ChatMessage>, previous: String?, threshold: Int): Int? {
        if (messages.sumOf { tokens(transcript(it)) } + tokens(previous.orEmpty()) <= threshold) return null
        val turns = messages.indices.filter { messages[it].isUser && messages[it].messageType != ChatMessage.Type.SYSTEM }
        if (turns.isEmpty() || turns.last() == 0) return null
        var start = turns.last()
        var retained = messages.drop(start).sumOf { tokens(transcript(it)) }
        for (index in turns.dropLast(1).asReversed()) {
            val cost = messages.subList(index, start).sumOf { tokens(transcript(it)) }
            if (retained + cost > threshold / 2) break
            retained += cost
            start = index
        }
        return start.takeIf { it > 0 }
    }
    fun validatedSummary(raw: String): String? = try {
        val source = org.json.JSONTokener(raw.trim())
        val json = source.nextValue() as? JSONObject ?: error("Object required")
        require(source.nextClean() == '\u0000')
        val keys = listOf("facts", "decisions", "preferences", "openTasks")
        val headings = listOf("Facts", "Decisions", "User preferences", "Open tasks")
        require(json.keys().asSequence().toSet() == keys.toSet())
        keys.mapIndexedNotNull { index, key ->
            val items = json.getJSONArray(key)
            val lines = (0 until items.length()).map {
                val value = items.get(it)
                require(value is String && value.isNotBlank())
                "- $value"
            }
            if (lines.isEmpty()) null else headings[index] + ":\n" + lines.joinToString("\n")
        }.joinToString("\n\n").takeIf { it.isNotBlank() }
    } catch (_: Exception) { null }
}
