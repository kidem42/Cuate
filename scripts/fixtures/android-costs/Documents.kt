package com.aispotlight.android.chat
import android.content.Context
import com.aispotlight.android.core.*
import com.aispotlight.android.data.*
import java.io.File
object DocumentToolService {
 fun liveDocuments(context: Context, history: List<ChatMessage>) = emptyList<String>()
 fun toolSpecs(documents: List<String>) = emptyList<ToolSpec>()
 fun systemPromptHint() = "documents"
 fun statusLine(call: ToolCall) = "reading"
 fun canHandle(name: String) = false
 suspend fun run(context: Context, call: ToolCall, documents: List<String>, cb: suspend (String,String,String)->Unit) = "document"
}
object DocumentTextService { fun extract(file: File, mime: String): String? = null }
