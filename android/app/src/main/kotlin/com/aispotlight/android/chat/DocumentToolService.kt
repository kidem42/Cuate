package com.aispotlight.android.chat

import android.content.Context
import com.aispotlight.android.core.Diagnostics
import com.aispotlight.android.core.DocumentPreflight
import com.aispotlight.android.core.DocumentTextQuery
import com.aispotlight.android.core.ToolCall
import com.aispotlight.android.core.ToolSpec
import com.aispotlight.android.data.ChatAttachment
import com.aispotlight.android.data.ChatMessage
import com.aispotlight.android.data.ImageStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The read_document tool: after the attach turn a document is no longer in
 * the request; the model opens it on demand through this tool, by name, a
 * page range or a query. Client-side like the web tools — free, keyless,
 * every tool-capable provider. Port of the Mac service.
 */
object DocumentToolService {
    const val TOOL_NAME = "read_document"

    /** A document the chat still holds: its attachment plus where it lives. */
    data class LiveDocument(
        val attachment: ChatAttachment,
        val messageId: String,
        val attachedAt: Long,
        val sizeBytes: Long,
    )

    fun canHandle(name: String) = name == TOOL_NAME

    /**
     * Documents of the history whose local file still exists (the 15-day
     * sweep deletes it), newest first, one per file name.
     */
    fun liveDocuments(context: Context, history: List<ChatMessage>): List<LiveDocument> {
        val seen = mutableSetOf<String>()
        val result = mutableListOf<LiveDocument>()
        for (message in history.asReversed()) {
            if (!message.isUser) continue
            for (attachment in message.attachments) {
                if (!attachment.isDocument) continue
                val key = attachment.filename.lowercase()
                if (key in seen) continue
                val file = ImageStore.file(context, attachment)
                if (!file.exists()) continue
                seen.add(key)
                result.add(LiveDocument(attachment, message.id, message.timestamp, file.length()))
            }
        }
        return result
    }

    fun toolSpecs(documents: List<LiveDocument>): List<ToolSpec> {
        if (documents.isEmpty()) return emptyList()
        val inventory = documents.joinToString("\n") { "- ${inventoryLine(it)}" }
        return listOf(ToolSpec(
            name = TOOL_NAME,
            description = "Open a document the user attached earlier in this chat and return its text. " +
                "Documents available:\n$inventory\n" +
                "Prefer a page range or a query over the whole file; results are capped at " +
                "${DocumentTextQuery.MAX_RESULT_CHARACTERS} characters.",
            parameters = JSONObject()
                .put("type", "object")
                .put("properties", JSONObject()
                    .put("name", JSONObject().put("type", "string")
                        .put("description", "File name as listed (case-insensitive; a unique prefix is enough)."))
                    .put("pages", JSONObject().put("type", "string")
                        .put("description", "Page range to return, e.g. \"3-5\" or \"7\" (PDF only)."))
                    .put("query", JSONObject().put("type", "string")
                        .put("description", "Return only paragraphs containing this text, with page numbers.")))
                .put("required", JSONArray().put("name")),
        ))
    }

    fun systemPromptHint(): String =
        "Documents the user attached earlier are listed in the read_document tool. Open one only " +
            "when the question needs its content; ask for a page range or a query rather than the " +
            "whole file when you can. If the user needs charts or images from a document, ask them " +
            "to re-attach it."

    fun statusLine(call: ToolCall): String = "Reading ${call.arguments.optString("name")}…"

    /** Runs the call; the extraction is cached on the attachment via [persistText]. */
    suspend fun run(
        context: Context,
        call: ToolCall,
        documents: List<LiveDocument>,
        persistText: suspend (messageId: String, attachmentId: String, text: String) -> Unit,
    ): String {
        val requested = call.arguments.optString("name").trim()
        val document = match(requested, documents)
            ?: return "No document named \"$requested\". Available:\n" +
                documents.joinToString("\n") { "- ${inventoryLine(it)}" }
        val pages = call.arguments.optString("pages").takeIf { it.isNotBlank() }
        val query = call.arguments.optString("query").takeIf { it.isNotBlank() }
        Diagnostics.log("files", "tool.read_document name=${document.attachment.filename} pages=${pages ?: "-"} query=${query?.take(40) ?: "-"}")
        val text = cachedText(context, document, persistText)
            ?: return if (DocumentPreflight.isLocallyReadable(document.attachment.mimeType)) {
                "${document.attachment.filename}: no readable text in this file."
            } else {
                "${document.attachment.filename}: not readable locally in this version. Ask the user to re-attach it if the provider can read it natively."
            }
        return DocumentTextQuery.render(document.attachment.filename, text, pages, query)
    }

    /** Exact (case-insensitive) first, then prefix, then substring. */
    private fun match(requested: String, documents: List<LiveDocument>): LiveDocument? {
        val needle = requested.lowercase()
        if (needle.isEmpty()) return documents.singleOrNull()
        documents.firstOrNull { it.attachment.filename.lowercase() == needle }?.let { return it }
        documents.firstOrNull { it.attachment.filename.lowercase().startsWith(needle) }?.let { return it }
        return documents.firstOrNull { it.attachment.filename.lowercase().contains(needle) }
    }

    private val dayFormatter = SimpleDateFormat("yyyy-MM-dd", Locale.US)

    private fun inventoryLine(document: LiveDocument): String {
        val parts = mutableListOf(document.attachment.filename)
        document.attachment.pageCount?.let { parts.add("$it page${if (it == 1) "" else "s"}") }
        parts.add(DocumentPreflight.formattedSize(document.sizeBytes))
        parts.add("attached ${dayFormatter.format(Date(document.attachedAt))}")
        return parts.joinToString(", ")
    }

    /** The cached extraction, computed once and persisted on the attachment. */
    suspend fun cachedText(
        context: Context,
        document: LiveDocument,
        persistText: suspend (String, String, String) -> Unit,
    ): String? {
        document.attachment.ocrText?.takeIf { it.isNotEmpty() }?.let { return it }
        val file = ImageStore.file(context, document.attachment)
        val text = withContext(Dispatchers.IO) { DocumentTextService.extract(file, document.attachment.mimeType) }
            ?: return null
        persistText(document.messageId, document.attachment.id, text)
        Diagnostics.log("files", "extract ${document.attachment.filename} chars=${text.length}")
        return text
    }
}
