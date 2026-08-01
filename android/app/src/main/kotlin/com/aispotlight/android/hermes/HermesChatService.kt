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
     * locked; fixtures). The lock pair is the settings choice, the caller's
     * cached catalog pair, or — last resort, one more slow round-trip — a
     * fresh catalog fetch. Creation is 2–3 sequential requests to a remote
     * gateway; the cache keeps it at 2.
     */
    suspend fun createSession(
        settings: AppSettings,
        title: String,
        cachedCurrent: Pair<String, String>? = null,
    ): HermesSessionInfo {
        val transport = transport(settings)
        val session = transport.createSession(title)
        val choice = settings.hermesModelLock.value.split("|")
        val pair: Pair<String, String>? = if (choice.size == 2 && choice[0].isNotEmpty()) {
            choice[0] to choice[1]
        } else {
            cachedCurrent ?: transport.modelOptions().current
        }
        if (pair != null) {
            try {
                transport.lockModel(session.id, provider = pair.first, model = pair.second)
                // Record the pair so the UI can SHOW what this session runs
                // on — before this, fresh sessions had no label until the
                // user re-picked by hand (feedback 2026-07-31).
                settings.setHermesSessionModel(session.id, "${pair.first}|${pair.second}")
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
            if (base64.isEmpty()) null
            else {
                // Downscaled wire copy (desktop 4.4 parity): original-size
                // photos blow through reverse-proxy body limits as opaque
                // 413s, and the gateway's model downscales anyway.
                val wire = com.aispotlight.android.core.LLMImage.forModel(attachment.mimeType, base64)
                wire.mimeType to wire.base64
            }
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
        // Canonical cross-device note (AgentAttachNote is the shared
        // contract) — the desktop recognizes it and renders the paths as
        // inline images / pills instead of raw text (2026-08-01).
        val note = if (remotePaths.isEmpty()) {
            "The user attached files ($names) but the upload to your host failed."
        } else {
            AgentAttachNote.compose(remotePaths)
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
        val existing = dao.allMessages(conversation.id)
        val known = existing.map { it.id }.toSet()
        // Purge compaction summaries older builds already imported as OUR
        // messages (mirror rows only — "<session>#<seq>" ids). Counted into
        // the return value so the open chat reloads its window.
        var purged = 0
        for (message in existing) {
            if (message.isUser && message.id.contains("#") &&
                HermesCompaction.visibleUserText(message.text) == null
            ) {
                dao.deleteMessage(message.id)
                purged++
            }
        }
        // Turns whose watermark bump never ran (a turn that died with the
        // process/connection) leave OUR user line above the watermark under
        // its local UUID id — match it by text so it doesn't come back as a
        // duplicate. Mirror rows carry "<session>#<seq>" ids; local ones
        // don't. Matches are time-boxed so an IDENTICAL text legitimately
        // re-sent later from another device still mirrors in.
        val localEchoTimes = HashMap<String, MutableList<Long>>()
        for (message in existing) {
            if (!message.isUser || message.id.contains("#")) continue
            val text = message.text.trim()
            if (text.isNotEmpty()) localEchoTimes.getOrPut(text) { mutableListOf() }.add(message.timestamp)
        }
        fun isLocalEcho(content: String, rowTs: Long?): Boolean {
            fun near(key: String) = localEchoTimes[key]
                ?.any { rowTs == null || kotlin.math.abs(it - rowTs) < ECHO_WINDOW_MS } == true
            val trimmed = content.trim()
            if (near(trimmed)) return true
            // Attachment sends arrive as "<text>\n\n<courier paths note>",
            // plus the gateway's own "[screenshot]" placeholder for the
            // inline image part — strip the note and placeholders too (the
            // shared contract normalizer, same as the desktop mirror).
            val head = trimmed.substringBefore("\n\n").trim()
            if (head.isNotEmpty() && near(head)) return true
            val display = AgentAttachNote.normalizedForMatching(
                AgentAttachNote.split(trimmed).display)
            return display.isNotEmpty() && display != trimmed && near(display)
        }
        // Same story for assistant rows: a turn streamed into a local bubble
        // (UUID id) whose watermark bump was lost must not come back from
        // the mirror. The bubble glues a turn's segments with blank lines,
        // so a mirror row matches when the bubble CONTAINS its text —
        // time-boxed like the user echo.
        val localAssistantEcho = existing.filter {
            !it.isUser && !it.id.contains("#") && it.text.isNotBlank()
        }
        fun isAssistantEcho(content: String, rowTs: Long?): Boolean {
            val trimmed = content.trim()
            if (trimmed.isEmpty()) return false
            return localAssistantEcho.any { message ->
                (rowTs == null || kotlin.math.abs(message.timestamp - rowTs) < ECHO_WINDOW_MS) &&
                    message.text.contains(trimmed)
            }
        }

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
                    // Compaction summaries ride the transcript as user rows
                    // and mirrored verbatim they render as OUR message
                    // (2026-08-01). Null = fully synthetic — skip WITHOUT
                    // resetting the step trail (the row is no turn boundary);
                    // a merged row imports only its real user part.
                    val visible = HermesCompaction.visibleUserText(row.content)
                    if (visible != null) {
                        pendingSteps = mutableListOf()
                        val id = row.externalID(sessionID)
                        if (id !in known && visible.isNotBlank() && !isLocalEcho(visible, row.timestampMs)) {
                            dao.upsertMessage(MessageEntity(
                                id = id, conversationId = conversation.id,
                                text = visible, isUser = true,
                                timestamp = row.timestampMs ?: System.currentTimeMillis(),
                                messageType = "text", audioPath = null,
                                toolContext = null,
                            ))
                            added++
                        }
                    }
                }
                "assistant" -> {
                    // Blank content = a tool-call shell: its calls feed
                    // argsByCallID; the journal lines come from the tool rows.
                    if (row.content.isNotBlank()) {
                        val id = row.externalID(sessionID)
                        if (id !in known && !isAssistantEcho(row.content, row.timestampMs)) {
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
        return added + purged
    }

    // MARK: - Turn recovery (transcript polling after a dropped stream)

    /** What [recoverTurn] rebuilt from the gateway transcript. */
    data class RecoveredTurn(
        /** Assistant segments after our user row, glued with blank lines. */
        val text: String,
        /** Journal lines rebuilt from the tool rows (summary() format). */
        val steps: String?,
        val tailSeq: Int,
    )

    /**
     * The SSE stream died mid-turn, but the gateway may well still be (or
     * have finished) executing the run — mobile networks drop sockets far
     * more often than the agent fails. Polls the session transcript for
     * rows AFTER our user message and rebuilds the reply from them,
     * feeding partial text through [onPartial] as rows land.
     *
     * Completion is a heuristic (0.19.0 has no fixtured run-status route):
     * once at least one content-bearing assistant row exists and the
     * transcript has been QUIET for [QUIET_MS], the turn is considered
     * done. If a long silent tool makes us finish early, the remainder
     * arrives through the regular mirror sync — the watermark is advanced
     * only past what was imported here.
     *
     * On failure (nothing new for [DEAD_MS]) returns null; when our user
     * row IS in the transcript the watermark advances past it, so a later
     * mirror sync doesn't duplicate the user line (locally it lives under
     * a UUID id the mirror can't recognize).
     */
    suspend fun recoverTurn(
        dao: ChatDao,
        conversationId: String,
        sessionID: String,
        userText: String,
        onPartial: suspend (RecoveredTurn) -> Unit,
    ): RecoveredTurn? {
        val settings = AppSettings.current
        var lastTail = -1
        var lastChangeAt = System.currentTimeMillis()
        val startedAt = lastChangeAt
        var anchorSeq: Int? = null
        var best: RecoveredTurn? = null

        while (true) {
            kotlinx.coroutines.delay(POLL_MS)
            val rows = try {
                transport(settings).messages(sessionID)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                // Still offline — keep trying until the dead-window closes.
                Diagnostics.log("hermes", "recover.poll ${e.message?.take(120)}")
                if (System.currentTimeMillis() - startedAt > DEAD_MS) return null
                continue
            }

            // Anchor: the LAST user row matching what we sent (attachment-only
            // sends match by the courier note prefix, so fall back to the
            // last user row when text is blank or not found).
            if (anchorSeq == null) {
                // Compare against the visible part: a compaction can glue its
                // summary as a PREFIX onto our just-sent row, and a fully
                // synthetic summary row must never anchor the turn.
                anchorSeq = rows.lastOrNull {
                    it.role == "user" && userText.isNotBlank() &&
                        HermesCompaction.visibleUserText(it.content)?.trim()
                            ?.startsWith(userText.trim()) == true
                }?.id ?: rows.lastOrNull {
                    it.role == "user" && HermesCompaction.visibleUserText(it.content) != null
                }?.id
            }
            val anchor = anchorSeq
            if (anchor == null) {
                // The request never reached the gateway — nothing to recover.
                if (System.currentTimeMillis() - startedAt > DEAD_MS) return null
                continue
            }

            val turnRows = rows.filter { it.id > anchor }
            val tail = turnRows.maxOfOrNull { it.id } ?: anchor
            if (tail != lastTail) {
                lastTail = tail
                lastChangeAt = System.currentTimeMillis()
                val rebuilt = rebuildTurn(sessionID, rows, anchor)
                if (rebuilt.text.isNotEmpty() || rebuilt.steps != null) {
                    best = rebuilt
                    onPartial(rebuilt)
                }
            }

            val quietFor = System.currentTimeMillis() - lastChangeAt
            val current = best
            val hasText = current != null && current.text.isNotEmpty()
            if (hasText && quietFor > QUIET_MS) {
                dao.advanceHermesSyncedSeq(conversationId, current!!.tailSeq)
                return current
            }
            if (!hasText && quietFor > DEAD_MS) {
                // No reply text and a long-quiet transcript: the run died with
                // the connection (assistant errors are never persisted —
                // fixtures). Advance past what we saw so the mirror never
                // re-imports the user row (or stray tool rows) as duplicates;
                // an answer that lands later still syncs — it sits above this.
                dao.advanceHermesSyncedSeq(conversationId, maxOf(anchor, lastTail))
                return null
            }
            if (System.currentTimeMillis() - startedAt > MAX_RECOVERY_MS) {
                dao.advanceHermesSyncedSeq(conversationId, maxOf(anchor, lastTail))
                return current?.takeIf { it.text.isNotEmpty() }
            }
        }
    }

    /** How far apart a mirror row and its local echo may sit and still match. */
    private const val ECHO_WINDOW_MS = 15 * 60_000L
    private const val POLL_MS = 4_000L
    /** Reply text present + this much silence = the turn is finished. */
    private const val QUIET_MS = 30_000L
    /**
     * No reply text + this much silence = the run died. Generous on purpose:
     * a live run can sit in ONE silent tool for minutes (the transcript only
     * gains the tool row when the tool completes).
     */
    private const val DEAD_MS = 3 * 60_000L
    private const val MAX_RECOVERY_MS = 30 * 60_000L

    /** Glues the turn's assistant segments + journal from transcript rows. */
    private fun rebuildTurn(
        sessionID: String,
        rows: List<HermesTranscriptMessage>,
        anchorSeq: Int,
    ): RecoveredTurn {
        val argsByCallID = mutableMapOf<String, String>()
        for (row in rows) {
            if (row.role == "assistant") {
                for ((callID, arguments) in row.toolCallArguments) argsByCallID[callID] = arguments
            }
        }
        val segments = mutableListOf<String>()
        val steps = mutableListOf<String>()
        for (row in rows.filter { it.id > anchorSeq }) {
            when (row.role) {
                "tool" -> {
                    val command = row.toolCallID?.let { argsByCallID[it] }?.let { commandText(it) }
                    val parts = mutableListOf(row.toolName ?: "tool", "ok")
                    command?.takeIf { it.isNotEmpty() }?.let { parts.add(it.replace("\n", " ").take(120)) }
                    steps.add(parts.joinToString(" · "))
                }
                "assistant" -> if (row.content.isNotBlank()) segments.add(row.content)
                // A later user row would mean the anchor was wrong — but rows
                // after OUR user message can't contain another user turn while
                // this conversation is blocked on the streaming one.
            }
        }
        return RecoveredTurn(
            text = segments.joinToString("\n\n"),
            steps = steps.takeIf { it.isNotEmpty() }?.joinToString("\n"),
            tailSeq = rows.filter { it.id > anchorSeq }.maxOfOrNull { it.id } ?: anchorSeq,
        )
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
