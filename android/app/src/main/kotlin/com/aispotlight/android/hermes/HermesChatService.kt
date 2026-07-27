package com.aispotlight.android.hermes

import android.content.Context
import com.aispotlight.android.core.Diagnostics
import com.aispotlight.android.data.ChatAttachment
import com.aispotlight.android.data.ChatDao
import com.aispotlight.android.data.ChatMessage
import com.aispotlight.android.data.ConversationEntity
import com.aispotlight.android.data.ImageStore
import com.aispotlight.android.data.MessageEntity
import com.aispotlight.android.settings.ApiKeyStore
import com.aispotlight.android.settings.AppSettings
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import java.io.File

/**
 * Orchestrates one Hermes agent turn and the session mirror — the Android
 * port of the desktop `AgentChatService` + `HermesAgentSession` +
 * `HermesMirrorSync` trio, folded into one object because on mobile the
 * sessions ARE conversations (Room rows with `hermesSessionId`).
 */
object HermesChatService {

    /** Events surfaced to the ViewModel while an agent turn runs. */
    sealed class AgentEvent {
        data class Text(val chunk: String) : AgentEvent()
        /**
         * Authoritative text of the CURRENT assistant segment — replaces
         * whatever streamed for it (deltas differ in whitespace, or never
         * came at all: fixtures allow completed-without-deltas).
         */
        data class SegmentCompleted(val content: String) : AgentEvent()
        data class Status(val text: String?) : AgentEvent()
        /** The run id, as soon as known — the stop button targets it. */
        data class Run(val runID: String) : AgentEvent()
        /** Rolling step-journal summary (persisted on the reply message). */
        data class Steps(val summary: String) : AgentEvent()
        /** A system line to persist in the chat (courier warnings). */
        data class SystemLine(val text: String) : AgentEvent()
    }

    /** One step of the collapsible journal (desktop `AgentStep`). */
    private data class Step(
        val toolName: String,
        var status: String, // running | ok
        val startedAt: Long = System.currentTimeMillis(),
        var finishedAt: Long? = null,
        val preview: String?,
    )

    /**
     * Port of the desktop `AgentStepJournal`: collects the tool steps of one
     * turn, serializes the compact summary persisted on the reply. The full
     * event stream is deliberately not stored — one turn can emit hundreds
     * of tool events; details are fetched lazily from the transcript.
     */
    private class StepJournal {
        val steps = mutableListOf<Step>()

        fun started(tool: String, preview: String?) {
            steps.add(Step(toolName = tool, status = "running", preview = preview))
        }

        /**
         * Completion updates the last running entry with the same tool name —
         * Hermes completion frames carry no args to match on, and tools run
         * sequentially within a turn.
         */
        fun completed(tool: String) {
            steps.lastOrNull { it.toolName == tool && it.status == "running" }?.let {
                it.status = "ok"
                it.finishedAt = System.currentTimeMillis()
            }
        }

        /**
         * One line per step: "toolName · status · 1.2s (· preview)". Parsed
         * back by [parseSteps] for rendering, so the format is a contract
         * (same as the desktop summary()).
         */
        fun summary(): String? {
            if (steps.isEmpty()) return null
            return steps.joinToString("\n") { step ->
                val parts = mutableListOf(step.toolName, step.status)
                step.finishedAt?.let { end ->
                    parts.add(String.format(java.util.Locale.US, "%.1fs", (end - step.startedAt) / 1000.0))
                }
                step.preview?.takeIf { it.isNotEmpty() }?.let {
                    parts.add(it.replace("\n", " ").take(120))
                }
                parts.joinToString(" · ")
            }
        }
    }

    /** Parses a persisted summary back into displayable rows. */
    fun parseSteps(summary: String): List<Triple<String, String, String?>> =
        summary.split("\n").filter { it.isNotEmpty() }.map { line ->
            val parts = line.split(" · ")
            Triple(
                parts.getOrElse(0) { line },
                parts.getOrElse(1) { "" },
                if (parts.size > 2) parts.drop(2).joinToString(" · ") else null,
            )
        }

    // MARK: - Transport factory

    fun transport(settings: AppSettings): HermesTransport = HermesTransport(
        baseURL = settings.hermesEndpoint.value,
        apiKey = ApiKeyStore.auxKey(ApiKeyStore.AuxKey.HERMES) ?: "",
    )

    // MARK: - Session lifecycle

    /**
     * Creates a gateway session and locks its model (⚠️ MANDATORY — a fresh
     * session inherits the literal "hermes-agent" and every turn 404s until
     * locked; fixtures). The lock pair is the settings choice, or the
     * agent's own current pair.
     */
    suspend fun createSession(settings: AppSettings, title: String): HermesSessionInfo {
        val transport = transport(settings)
        val session = transport.createSession(title)
        val choice = settings.hermesModelLock.value.split("|")
        val pair: Pair<String, String>? = if (choice.size == 2 && choice[0].isNotEmpty()) {
            choice[0] to choice[1]
        } else {
            transport.modelOptions().current
        }
        if (pair != null) {
            try {
                transport.lockModel(session.id, provider = pair.first, model = pair.second)
            } catch (e: Exception) {
                Diagnostics.log("hermes", "model.lock failed: ${e.message?.take(120)}")
            }
        } else {
            Diagnostics.log("hermes", "model.lock skipped — no pair available")
        }
        return session
    }

    // MARK: - Turn streaming

    /**
     * Streams one agent turn into [AgentEvent]s. `text` is what the user
     * typed; image attachments ride inline as OpenAI parts; other files go
     * through the dashboard courier and arrive as a paths note.
     */
    fun streamTurn(
        context: Context,
        sessionID: String,
        text: String,
        attachments: List<ChatAttachment>,
    ): Flow<AgentEvent> = flow {
        val settings = AppSettings.current
        val transport = transport(settings)

        // Images travel inline (probed live: OpenAI parts work) …
        val imageAttachments = attachments.filter { it.mimeType.startsWith("image") }
        val images = imageAttachments.mapNotNull { attachment ->
            val base64 = ImageStore.contentBase64(context, attachment)
            if (base64.isEmpty()) null else attachment.mimeType to base64
        }
        // … and ALSO through the courier, together with the other files:
        // the gateway keeps no pixels (its transcript says "[screenshot]"),
        // so a photo sent from here would reach the desktop as a bare
        // placeholder unless a real file lands on the agent's host.
        var input = text
        val courierFiles = attachments.filter {
            !it.mimeType.startsWith("image") || settings.hermesDashboardUrl.value.isNotEmpty()
        }
        if (courierFiles.isNotEmpty()) {
            val (note, warning) = deliverFiles(context, settings, transport, courierFiles)
            input = if (input.isEmpty()) note else "$input\n\n$note"
            // Images still ride inline for the model, so a courier failure
            // there is not worth a system line of its own.
            if (courierFiles.any { !it.mimeType.startsWith("image") }) {
                warning?.let { emit(AgentEvent.SystemLine(it)) }
            }
        }

        // Per-session reasoning effort (the composer control, desktop 1:1);
        // "" = don't send, the agent's own default rules.
        val effort = settings.hermesSessionEfforts.value[sessionID] ?: ""
        val modelOptions = if (effort.isEmpty()) null
            else org.json.JSONObject().put("reasoning_effort", effort)

        val journal = StepJournal()
        var segmentStarted = false
        transport.chatStream(sessionID, transport.inputPayload(input, images), modelOptions).collect { event ->
            when (event) {
                is HermesStreamEvent.RunStarted -> emit(AgentEvent.Run(event.runID))
                is HermesStreamEvent.MessageStarted -> segmentStarted = true
                is HermesStreamEvent.ToolStarted -> {
                    if (event.tool != "_thinking") {
                        journal.started(event.tool, event.preview)
                        journal.summary()?.let { emit(AgentEvent.Steps(it)) }
                        val label = event.preview?.take(60)?.let { "${event.tool}: $it" } ?: event.tool
                        emit(AgentEvent.Status(label))
                    }
                }
                is HermesStreamEvent.ToolProgress -> {
                    // "_thinking" is the model's reasoning stream, not a tool
                    // (fixtures) — surface as the thinking status, don't log.
                    if (event.tool == "_thinking") emit(AgentEvent.Status("Thinking…"))
                }
                is HermesStreamEvent.ToolCompleted -> {
                    if (event.tool != "_thinking") {
                        journal.completed(event.tool)
                        journal.summary()?.let { emit(AgentEvent.Steps(it)) }
                        emit(AgentEvent.Status("Thinking…"))
                    }
                }
                is HermesStreamEvent.AssistantDelta -> {
                    emit(AgentEvent.Status(null))
                    emit(AgentEvent.Text(event.delta))
                }
                is HermesStreamEvent.AssistantCompleted -> {
                    // Definitive segment text (may arrive without any deltas;
                    // a gateway-side turn error ALSO arrives here as text).
                    emit(AgentEvent.Status(null))
                    emit(AgentEvent.SegmentCompleted(event.content))
                    segmentStarted = false
                }
                is HermesStreamEvent.RunCompleted -> { /* usage is the agent's own billing */ }
                is HermesStreamEvent.Done -> { }
                is HermesStreamEvent.Unknown -> {
                    Diagnostics.log("hermes", "sse.unknown ${event.event}")
                }
            }
        }
        journal.summary()?.let { emit(AgentEvent.Steps(it)) }
    }

    /**
     * Desktop `HermesFileCourier`, remote-only branch: uploads each file
     * through the dashboard files API into `~/cuate-uploads/` and formats
     * the paths note the agent reads. Without a configured dashboard the
     * note lists nothing useful — an honest warning explains why.
     */
    private suspend fun deliverFiles(
        context: Context,
        settings: AppSettings,
        transport: HermesTransport,
        files: List<ChatAttachment>,
    ): Pair<String, String?> {
        val dashboard = settings.hermesDashboardUrl.value
        val token = ApiKeyStore.auxKey(ApiKeyStore.AuxKey.HERMES_DASHBOARD) ?: ""
        val names = files.joinToString(", ") { it.filename }
        if (dashboard.isEmpty() || token.isEmpty()) {
            return "The user attached files ($names) but they could not be delivered to your host." to
                "Files not delivered: set the Hermes dashboard URL and token in Settings to upload files to the agent."
        }
        val remotePaths = mutableListOf<String>()
        val failures = mutableListOf<String>()
        for (attachment in files) {
            val local = File(context.filesDir, attachment.filePath)
            try {
                remotePaths.add(transport.uploadToDashboard(dashboard, token, local))
            } catch (e: Exception) {
                failures.add(attachment.filename)
                Diagnostics.log("hermes", "courier.fail ${attachment.filename}: ${e.message?.take(120)}")
            }
        }
        val header = if (remotePaths.size == 1) "The user attached a file, available at this path on your host:"
            else "The user attached files, available at these paths on your host:"
        val note = if (remotePaths.isEmpty()) {
            "The user attached files ($names) but the upload to your host failed."
        } else {
            header + "\n" + remotePaths.joinToString("\n") { "- $it" }
        }
        val warning = if (failures.isEmpty()) null
            else "Upload failed for: ${failures.joinToString(", ")}"
        return note to warning
    }

    // MARK: - Mirror sync (gateway transcript → Room)

    /**
     * Rebuilds a conversation's messages from the gateway transcript — the
     * mobile `HermesMirrorSync`. Only rows ABOVE the conversation's
     * `hermesSyncedSeq` watermark are considered: our own turns bump the
     * watermark when they finish, so they never come back as duplicates
     * (locally they live under UUID ids, the mirror under "<session>#<row>").
     * Tool rows and empty assistant shells fold into the step journal of the
     * FOLLOWING content-bearing assistant message (the desktop rebuild
     * grouping). Returns the number of NEW rows.
     */
    suspend fun syncTranscript(dao: ChatDao, conversation: ConversationEntity): Int {
        val sessionID = conversation.hermesSessionId ?: return 0
        val settings = AppSettings.current
        val allRows = transport(settings).messages(sessionID)
        val watermark = conversation.hermesSyncedSeq
        val rows = allRows.filter { it.id > watermark }
        val maxSeq = allRows.maxOfOrNull { it.id } ?: watermark
        val known = dao.allMessages(conversation.id).map { it.id }.toSet()

        // Arguments live on the assistant tool-call shells, keyed by call id
        // (the FULL transcript — an imported row may answer an older shell).
        val argsByCallID = mutableMapOf<String, String>()
        for (row in allRows) {
            if (row.role == "assistant") {
                for ((callID, arguments) in row.toolCallArguments) argsByCallID[callID] = arguments
            }
        }

        var added = 0
        var pendingSteps = mutableListOf<String>()
        for (row in rows) {
            when (row.role) {
                "tool" -> {
                    // Rebuild a journal line: tool name + the command text.
                    val command = row.toolCallID?.let { argsByCallID[it] }?.let { commandText(it) }
                    val parts = mutableListOf(row.toolName ?: "tool", "ok")
                    command?.takeIf { it.isNotEmpty() }?.let { parts.add(it.replace("\n", " ").take(120)) }
                    pendingSteps.add(parts.joinToString(" · "))
                }
                "user" -> {
                    pendingSteps = mutableListOf()
                    val id = row.externalID(sessionID)
                    if (id !in known && row.content.isNotBlank()) {
                        dao.upsertMessage(MessageEntity(
                            id = id, conversationId = conversation.id,
                            text = row.content, isUser = true,
                            timestamp = row.timestampMs ?: System.currentTimeMillis(),
                            messageType = "text", audioPath = null,
                            toolContext = null,
                        ))
                        added++
                    }
                }
                "assistant" -> {
                    // Blank content = a tool-call shell: its calls feed
                    // argsByCallID; the journal lines come from the tool rows.
                    if (row.content.isNotBlank()) {
                        val id = row.externalID(sessionID)
                        if (id !in known) {
                            dao.upsertMessage(MessageEntity(
                                id = id, conversationId = conversation.id,
                                text = row.content, isUser = false,
                                timestamp = row.timestampMs ?: System.currentTimeMillis(),
                                messageType = "text", audioPath = null,
                                toolContext = null,
                                agentSteps = pendingSteps.takeIf { it.isNotEmpty() }?.joinToString("\n"),
                            ))
                            added++
                        }
                        pendingSteps = mutableListOf()
                    }
                }
            }
        }
        if (maxSeq > watermark) dao.advanceHermesSyncedSeq(conversation.id, maxSeq)
        return added
    }

    /**
     * Bumps the transcript watermark to the gateway's current tail — called
     * after OUR OWN turn lands, so the mirror never re-imports it.
     */
    suspend fun advanceWatermark(dao: ChatDao, conversationId: String, sessionID: String) {
        try {
            val maxSeq = transport(AppSettings.current).messages(sessionID).maxOfOrNull { it.id } ?: return
            dao.advanceHermesSyncedSeq(conversationId, maxSeq)
        } catch (e: Exception) {
            Diagnostics.log("hermes", "watermark.fail ${e.message?.take(120)}")
        }
    }

    /** The human-facing argument text (desktop `commandText`). */
    fun commandText(rawArguments: String): String {
        return try {
            val json = org.json.JSONObject(rawArguments)
            json.optString("command", "").ifEmpty {
                json.optString("path", "").ifEmpty {
                    json.keys().asSequence().map { "$it: ${json.opt(it)}" }.sorted().joinToString(", ")
                }
            }
        } catch (_: Exception) {
            rawArguments
        }
    }

    // MARK: - Step drill-down (lazy details from the transcript)

    /** Full detail of one tool step (desktop `AgentStepDetail`). */
    data class StepDetail(
        val command: String?,
        val output: String?,
        val exitCode: Int?,
        val paths: List<String>,
    )

    /**
     * Details for ALL steps of the assistant message with external id
     * `messageId` ("<session>#<row>"), in step order — the desktop
     * `HermesStepDetails.details` grouping: tool rows since the previous
     * content-bearing row.
     */
    suspend fun stepDetails(sessionID: String, messageId: String): List<StepDetail> {
        val assistantSeq = messageId.substringAfterLast("#").toIntOrNull() ?: return emptyList()
        val rows = try {
            transport(AppSettings.current).messages(sessionID)
        } catch (_: Exception) {
            return emptyList()
        }
        val argsByCallID = mutableMapOf<String, String>()
        for (row in rows) {
            if (row.role == "assistant") {
                for ((callID, arguments) in row.toolCallArguments) argsByCallID[callID] = arguments
            }
        }
        var pending = mutableListOf<StepDetail>()
        for (row in rows) {
            when {
                row.role == "tool" -> {
                    val command = row.toolCallID?.let { argsByCallID[it] }?.let { commandText(it) }
                    var output: String?
                    var exitCode: Int? = null
                    try {
                        val json = org.json.JSONObject(row.content)
                        output = json.optString("output", "").ifEmpty {
                            json.optString("message", "").ifEmpty { row.content.take(4000) }
                        }
                        if (json.has("exit_code") && !json.isNull("exit_code")) {
                            exitCode = json.optInt("exit_code")
                        }
                    } catch (_: Exception) {
                        output = row.content.take(4000)
                    }
                    pending.add(StepDetail(
                        command = command,
                        output = output?.take(4000),
                        exitCode = exitCode,
                        paths = HermesFilePaths.extract((command ?: "") + "\n" + (output ?: "")),
                    ))
                }
                row.role == "assistant" && row.content.isNotBlank() -> {
                    if (row.id == assistantSeq) return pending
                    pending = mutableListOf()
                }
                row.role == "user" -> pending = mutableListOf()
            }
        }
        return emptyList()
    }
}

/**
 * Path extraction from agent replies — port of the desktop `AgentFilePaths`:
 * absolute (or ~-based) paths mentioned in the text become chips. On Android
 * the agent's host is always remote, so a chip copies the path.
 */
object HermesFilePaths {
    // /root, /srv, /mnt: a remote gateway commonly runs as root on a VPS —
    // its files never matched (desktop e2e 2026-07-27).
    private val pattern = Regex(
        """(?:^|[\s`'"(\[])((?:~|/Users|/home|/root|/srv|/mnt|/tmp|/private|/var|/opt|/etc)/[A-Za-z0-9._\-/~]+)"""
    )

    /** Conservative: common root prefixes only, punctuation trimmed, capped at 5. */
    fun extract(text: String): List<String> {
        val seen = LinkedHashSet<String>()
        for (match in pattern.findAll(text)) {
            var path = match.groupValues[1]
            while (path.isNotEmpty() && path.last() in ".,;:!?)") path = path.dropLast(1)
            if (!path.contains("/") || path.split("/").filter { it.isNotEmpty() }.size < 2) continue
            seen.add(path)
            if (seen.size >= 5) break
        }
        return seen.toList()
    }

    /**
     * Whether a mentioned path is a FILE worth listing in the chat-wide
     * files dialog — extension-less prose paths are chatter there (the
     * desktop isListableFile heuristic; no local FS to consult on Android).
     */
    fun isListableFile(path: String): Boolean =
        path.substringAfterLast("/").contains(".")
}
