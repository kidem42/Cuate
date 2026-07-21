package com.aispotlight.android.chat

import android.app.Application
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.aispotlight.android.data.AppDatabase
import com.aispotlight.android.data.ChatAttachment
import com.aispotlight.android.data.ChatMessage
import com.aispotlight.android.data.Conversation
import com.aispotlight.android.data.ImageStore
import com.aispotlight.android.data.MessageEntity
import com.aispotlight.android.data.toDomain
import com.aispotlight.android.data.toEntity
import com.aispotlight.android.providers.TranscriptionService
import com.aispotlight.android.settings.AppSettings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Holds the conversation list, the active conversation's message window, and
 * the streaming state — the Android analog of ChatStore + the send pipeline
 * in ChatWindow.swift.
 */
class ChatViewModel(application: Application) : AndroidViewModel(application) {
    private val dao = AppDatabase.get(application).chatDao()
    private val settings = AppSettings.shared(application)

    /** Initial window size; older pages load on demand (same as macOS: 120/page). */
    private val windowSize = 120

    // MARK: - Conversation list

    val conversations: StateFlow<List<Conversation>> =
        dao.conversations()
            .map { list -> list.map { it.toDomain() } }
            .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    private val _activeConversationId = MutableStateFlow<String?>(null)
    val activeConversationId: StateFlow<String?> = _activeConversationId

    // MARK: - Active conversation state

    private val _messages = MutableStateFlow<List<ChatMessage>>(emptyList())
    val messages: StateFlow<List<ChatMessage>> = _messages

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading

    /** Live status shown in the "thinking" indicator (e.g. "Searching: …"). */
    private val _statusText = MutableStateFlow<String?>(null)
    val statusText: StateFlow<String?> = _statusText

    private val _errorText = MutableStateFlow<String?>(null)
    val errorText: StateFlow<String?> = _errorText

    /** Whether older messages exist in the store beyond the loaded window. */
    private val _hasOlderMessages = MutableStateFlow(false)
    val hasOlderMessages: StateFlow<Boolean> = _hasOlderMessages

    /** Images picked/captured but not yet sent — shown as chips above the input bar. */
    private val _pendingAttachments = MutableStateFlow<List<ChatAttachment>>(emptyList())
    val pendingAttachments: StateFlow<List<ChatAttachment>> = _pendingAttachments

    /** Voice input state: recording → transcribing → text lands in the input. */
    private val _isRecording = MutableStateFlow(false)
    val isRecording: StateFlow<Boolean> = _isRecording

    private val _isTranscribing = MutableStateFlow(false)
    val isTranscribing: StateFlow<Boolean> = _isTranscribing

    /** Transcribed text handed to the input field (consumed by the UI). */
    private val _transcriptionResult = MutableStateFlow<String?>(null)
    val transcriptionResult: StateFlow<String?> = _transcriptionResult

    private val recorder = AudioRecorderService(application)

    private var activeConversation: Conversation? = null
    private var totalMessageCount = 0

    /**
     * Streams keep running when the user switches conversations (the macOS
     * ChatStore.deliver semantics): each conversation owns its job, partials
     * are flushed to the store, and the UI is only touched while its
     * conversation is on screen.
     */
    private val streamJobs = mutableMapOf<String, Job>()
    private val streamingIds = MutableStateFlow<Set<String>>(emptySet())

    /** isLoading == the ACTIVE conversation has a running stream. */
    private fun refreshLoading() {
        _isLoading.value = _activeConversationId.value in streamingIds.value
        if (!_isLoading.value) _statusText.value = null
    }

    private fun markStreaming(conversationId: String, streaming: Boolean) {
        streamingIds.value =
            if (streaming) streamingIds.value + conversationId
            else streamingIds.value - conversationId
        if (!streaming) streamJobs.remove(conversationId)
        refreshLoading()
    }

    /**
     * Serializes conversation lookup-or-create: two rapid switches to the same
     * preset (double-tap, recomposition) must not race `isolatedConversationId`
     * read-then-create — the loser would create a SECOND conversation and
     * overwrite the stored id, orphaning the history the user just wrote.
     */
    private val switchMutex = Mutex()

    init {
        // The macOS conversation model: ONE shared general chat, plus a
        // dedicated chat per isolated preset. The active conversation is a
        // DERIVED value — it always follows (activePresetName, isolatedPresets),
        // exactly like ChatWindow's `.onChange(...) { syncConversation() }`.
        // A single collector means EVERY mutation path resynchronizes: the
        // in-chat switcher, the preset chips on the Settings screen, and the
        // isolation toggle itself. (Before, only setConversationPreset switched
        // the conversation — changing the preset or the toggle from Settings
        // left the screen on the old conversation, so messages typed "under"
        // an isolated preset leaked into the general chat and the dedicated
        // chat later opened empty.)
        viewModelScope.launch {
            combine(
                settings.activePresetName,
                settings.isolatedPresets,
            ) { active, isolated -> active to (active in isolated) }
                .distinctUntilChanged()
                .collect { (active, isIsolated) ->
                    switchMutex.withLock {
                        if (isIsolated) {
                            openIsolated(active)
                        } else {
                            val generalId = ensureGeneralConversation()
                            // The general chat carries the active preset's
                            // system prompt (mac semantics: regular presets
                            // share one conversation, swapping prompts).
                            dao.conversation(generalId)?.let { entity ->
                                if (entity.presetName != active) {
                                    dao.upsertConversation(entity.copy(presetName = active))
                                }
                            }
                            if (_activeConversationId.value == generalId) {
                                activeConversation = activeConversation?.copy(presetName = active)
                            } else {
                                openConversation(generalId)
                            }
                        }
                    }
                }
        }
        // Deleting a preset drops its isolated chat's data — the macOS
        // `.presetDeleted` notification semantics.
        viewModelScope.launch {
            settings.presetDeleted.collect { name -> deleteIsolatedConversation(name) }
        }
    }

    /**
     * Removes a deleted preset's dedicated conversation: messages, media,
     * summary, the conversation row and the stored id. The sync collector has
     * already moved the screen off it (deletePreset un-isolates the name and,
     * if it was active, activates a built-in preset).
     */
    private suspend fun deleteIsolatedConversation(presetName: String) {
        val id = settings.isolatedConversationId(presetName) ?: return
        switchMutex.withLock {
            streamJobs[id]?.cancel()
            markStreaming(id, false)
            for (path in dao.attachmentPaths(id)) {
                ImageStore.delete(getApplication(), path)
            }
            for (path in dao.audioPaths(id)) {
                java.io.File(getApplication<Application>().filesDir, path).delete()
            }
            dao.deleteMessages(id)
            dao.deleteConversation(id)
            settings.clearIsolatedConversationId(presetName)
        }
    }

    /** Returns (creating on first run) the shared general conversation. */
    private suspend fun ensureGeneralConversation(): String {
        settings.generalConversationId()?.let { id ->
            if (dao.conversation(id) != null) return id
        }
        val conversation = Conversation(
            title = "Chat",
            presetName = settings.activePresetName.value,
        )
        dao.upsertConversation(conversation.toEntity())
        settings.setGeneralConversationId(conversation.id)
        return conversation.id
    }

    /** Opens (creating if needed) an isolated preset's dedicated chat. */
    private suspend fun openIsolated(presetName: String) {
        val existing = settings.isolatedConversationId(presetName)?.let { dao.conversation(it) }
        if (existing != null) {
            openConversation(existing.id)
        } else {
            val conversation = Conversation(title = presetName, presetName = presetName)
            dao.upsertConversation(conversation.toEntity())
            settings.setIsolatedConversationId(presetName, conversation.id)
            openConversation(conversation.id)
        }
    }

    // MARK: - Conversation management

    fun openConversation(id: String) {
        if (id == _activeConversationId.value) return
        // An in-flight reply is NOT interrupted: it keeps streaming in the
        // background and lands in its home conversation's store.
        _statusText.value = null
        _errorText.value = null
        _activeConversationId.value = id
        _messages.value = emptyList()
        refreshLoading()
        viewModelScope.launch {
            val entity = dao.conversation(id) ?: return@launch
            val recent = withAttachments(dao.recentMessages(id, windowSize).reversed())
            val count = dao.messageCount(id)
            // Only apply if the user hasn't switched again mid-load — a stale
            // slow load must not overwrite the newer conversation's state.
            if (_activeConversationId.value == id) {
                activeConversation = entity.toDomain()
                totalMessageCount = count
                _messages.value = recent
                _hasOlderMessages.value = count > recent.size
            }
        }
    }

    /** Maps message rows to domain values with their attachments joined in. */
    private suspend fun withAttachments(rows: List<MessageEntity>): List<ChatMessage> {
        if (rows.isEmpty()) return emptyList()
        val attachments = dao.attachments(rows.map { it.id })
            .groupBy({ it.messageId }, { it.toDomain() })
        return rows.map { it.toDomain(attachments[it.id] ?: emptyList()) }
    }

    /**
     * "New chat" — the macOS clearMessages: wipes the current conversation's
     * messages, media and rolling summary; the conversation itself (general
     * or an isolated preset's) stays in place.
     */
    fun clearChat() {
        val id = _activeConversationId.value ?: return
        streamJobs[id]?.cancel()
        markStreaming(id, false)
        viewModelScope.launch {
            for (path in dao.attachmentPaths(id)) {
                ImageStore.delete(getApplication(), path)
            }
            for (path in dao.audioPaths(id)) {
                java.io.File(getApplication<Application>().filesDir, path).delete()
            }
            dao.deleteMessages(id)
            dao.setSummary(id, null, 0)
            if (_activeConversationId.value == id) {
                activeConversation = activeConversation?.copy(summary = null, summaryCoversCount = 0)
                totalMessageCount = 0
                _messages.value = emptyList()
                _hasOlderMessages.value = false
                _errorText.value = null
            }
        }
    }

    /** Pages one more chunk of older messages in from the store. */
    fun loadOlderPage() {
        val id = _activeConversationId.value ?: return
        val oldest = _messages.value.firstOrNull() ?: return
        viewModelScope.launch {
            val older = withAttachments(dao.olderMessages(id, oldest.timestamp, windowSize).reversed())
            if (_activeConversationId.value != id) return@launch
            if (older.isEmpty()) {
                _hasOlderMessages.value = false
                return@launch
            }
            _messages.value = older + _messages.value
            _hasOlderMessages.value = totalMessageCount > _messages.value.size
        }
    }

    // MARK: - Sending

    // MARK: - Attachments & voice input

    /** Imports a picked/captured image (downscaled, file-backed) into the pending set. */
    fun attachImage(uri: Uri, filename: String? = null) {
        viewModelScope.launch(Dispatchers.IO) {
            val attachment = ImageStore.importImage(getApplication(), uri, filename)
            if (attachment == null) {
                // An undecodable image (unsupported format, revoked Uri) used
                // to fail into the void — no chip, no message, "the photo
                // just vanished". Say so instead.
                _errorText.value = getApplication<Application>()
                    .getString(com.aispotlight.android.R.string.attach_failed)
                return@launch
            }
            _pendingAttachments.value = _pendingAttachments.value + attachment
        }
    }

    /** Clears the error banner (called when the user dismisses it). */
    fun consumeError() {
        _errorText.value = null
    }

    fun removePendingAttachment(id: String) {
        val attachment = _pendingAttachments.value.firstOrNull { it.id == id } ?: return
        _pendingAttachments.value = _pendingAttachments.value.filter { it.id != id }
        viewModelScope.launch(Dispatchers.IO) {
            ImageStore.delete(getApplication(), attachment.filePath)
        }
    }

    fun startRecording(): Boolean {
        val started = recorder.start()
        _isRecording.value = started
        return started
    }

    fun cancelRecording() {
        recorder.cancel()
        _isRecording.value = false
    }

    /**
     * Stops recording, transcribes, and sends the result as a VOICE message
     * (audio kept for playback, transcript is the message text) — the macOS
     * voice-message flow.
     */
    fun stopRecordingAndTranscribe() {
        val file = recorder.stop()
        _isRecording.value = false
        if (file == null) return
        _isTranscribing.value = true
        viewModelScope.launch {
            try {
                val text = withContext(Dispatchers.IO) { TranscriptionService.transcribe(file) }
                if (text.isEmpty()) return@launch
                val attachments = _pendingAttachments.value
                if (attachments.isNotEmpty()) {
                    // Dictation over staged images: voice here is just an input
                    // method (instead of typing), so the transcript goes out as
                    // a REGULAR text message under the image — no audio kept,
                    // no voice reply. (An empty/failed transcription above
                    // keeps the chips staged.)
                    _pendingAttachments.value = emptyList()
                    withContext(Dispatchers.IO) { file.delete() }
                    dispatch(ChatMessage(text = text, isUser = true, attachments = attachments))
                } else {
                    // Keep the audio: move it into the app's recordings directory.
                    val relativePath = withContext(Dispatchers.IO) {
                        val target = java.io.File(
                            getApplication<Application>().filesDir,
                            "recordings/${file.name}"
                        )
                        target.parentFile?.mkdirs()
                        file.copyTo(target, overwrite = true)
                        file.delete()
                        "recordings/${target.name}"
                    }
                    dispatch(ChatMessage(
                        text = text, isUser = true,
                        messageType = ChatMessage.Type.VOICE,
                        audioPath = relativePath,
                    ))
                }
            } catch (e: Exception) {
                _errorText.value = e.message
                file.delete()
            } finally {
                _isTranscribing.value = false
            }
        }
    }

    fun consumeTranscription() {
        _transcriptionResult.value = null
    }

    // MARK: - Presets

    /**
     * Switches the active preset — the macOS semantics: an ISOLATED preset
     * opens its own dedicated conversation (separate history, context and
     * summary); a regular preset returns to the shared general chat and swaps
     * its system prompt. The actual conversation switch happens in the init
     * sync collector, which observes the settings — so Settings-screen paths
     * (preset chips, isolation toggle) take the exact same route.
     */
    fun setConversationPreset(name: String) {
        settings.activatePreset(name)
    }

    val activeConversationPreset: String?
        get() = activeConversation?.presetName

    // MARK: - Image tools (fal.ai)

    private val _isImageToolRunning = MutableStateFlow(false)
    val isImageToolRunning: StateFlow<Boolean> = _isImageToolRunning

    /**
     * Runs a fal.ai operation on a chat attachment with the model selected in
     * Settings and drops the result into the conversation as a local (non-LLM)
     * message. The cost is added to the session/month counters.
     */
    fun runImageTool(
        attachment: com.aispotlight.android.data.ChatAttachment,
        function: com.aispotlight.android.providers.FalImageProvider.Function,
        prompt: String? = null,
        maskBase64: String? = null,
    ) {
        val conversationId = _activeConversationId.value ?: return
        if (_isImageToolRunning.value) return
        _isImageToolRunning.value = true
        _statusText.value = "Processing image…"
        viewModelScope.launch {
            try {
                val modelId = settings.imageModel(function)
                val model = com.aispotlight.android.providers.FalImageProvider.model(modelId)
                val result = withContext(Dispatchers.IO) {
                    val context = getApplication<Application>()
                    // Some endpoints require PNG input (Recraft); others take the image as-is.
                    val (base64, mime) =
                        if (model?.requiresPNGInput == true) {
                            ImageStore.pngBase64(context, attachment) to "image/png"
                        } else {
                            ImageStore.contentBase64(context, attachment) to attachment.mimeType
                        }
                    com.aispotlight.android.providers.FalImageProvider.run(
                        modelId = modelId,
                        imageBase64 = base64,
                        mimeType = mime,
                        prompt = prompt,
                        maskBase64 = maskBase64,
                        factor = settings.upscaleFactor.value.coerceAtMost(model?.maxUpscaleFactor ?: 8),
                        faceEnhance = settings.faceEnhance.value && model?.supportsFaceEnhance == true,
                    )
                }
                settings.addImageCost(result.costUSD)
                // Mirror into the unified spend ledger so the Costs screen's
                // charts include image operations (the settings counters keep
                // their own UI as before).
                com.aispotlight.android.data.SpendTracker.record(
                    kind = com.aispotlight.android.data.SpendKind.IMAGE,
                    provider = "fal", model = modelId,
                    units = 1.0, costUSD = result.costUSD,
                )
                val suffix = when (function) {
                    com.aispotlight.android.providers.FalImageProvider.Function.UPSCALE -> "upscaled"
                    com.aispotlight.android.providers.FalImageProvider.Function.REMOVE_BACKGROUND -> "nobg"
                    com.aispotlight.android.providers.FalImageProvider.Function.OBJECT_CLEANUP -> "cleaned"
                }
                val resultAttachment = withContext(Dispatchers.IO) {
                    ImageStore.importBytes(
                        getApplication(), result.image, result.mimeType,
                        filename = attachment.filename.substringBeforeLast('.') + "-$suffix." +
                            if (result.mimeType == "image/png") "png" else "jpg",
                    )
                }
                // Local system-style message with the result — not sent to the LLM.
                val message = ChatMessage(
                    text = "", isUser = false,
                    messageType = ChatMessage.Type.SYSTEM,
                    attachments = listOf(resultAttachment),
                )
                _messages.value = _messages.value + message
                totalMessageCount += 1
                dao.upsertMessage(message.toEntity(conversationId))
                dao.upsertAttachment(resultAttachment.toEntity(message.id))
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                _errorText.value = e.message
            } finally {
                _isImageToolRunning.value = false
                _statusText.value = null
            }
        }
    }

    // MARK: - OCR (extract text)

    private val _isExtractingText = MutableStateFlow(false)

    /**
     * User-facing OCR — the mac "Extract text" flow: Mistral OCR returns
     * layout-aware markdown (headings, lists, TABLES), which lands in the chat
     * as an assistant bubble (rendered structure, copyable) and on the
     * clipboard; a system note confirms. The extraction is also cached onto
     * the attachment so the vision-fallback context pipeline never re-pays it.
     */
    fun extractText(attachment: ChatAttachment) {
        val conversationId = _activeConversationId.value ?: return
        if (_isExtractingText.value) return
        _isExtractingText.value = true
        _statusText.value = "Extracting text…"
        viewModelScope.launch {
            try {
                val markdown = withContext(Dispatchers.IO) {
                    com.aispotlight.android.providers.MistralOCRService.extractText(
                        ImageStore.contentBase64(getApplication(), attachment),
                        attachment.mimeType,
                    )
                }
                // Cache on the attachment row + the loaded window copy.
                dao.setAttachmentOCR(attachment.id, markdown)
                _messages.value = _messages.value.map { m ->
                    m.copy(attachments = m.attachments.map { a ->
                        if (a.id == attachment.id) a.copy(ocrText = markdown) else a
                    })
                }
                // Clipboard (mac parity: paste-ready for editors).
                val clipboard = getApplication<Application>()
                    .getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
                clipboard.setPrimaryClip(android.content.ClipData.newPlainText("OCR", markdown))
                // Mac parity: extracting from a STAGED image consumes the chip
                // and posts the source screenshot as a user message first, so
                // the chat reads "picture → its extracted text".
                if (_pendingAttachments.value.any { it.id == attachment.id }) {
                    _pendingAttachments.value = _pendingAttachments.value.filter { it.id != attachment.id }
                    val extracted = attachment.copy(ocrText = markdown)
                    val source = ChatMessage(text = "", isUser = true, attachments = listOf(extracted))
                    _messages.value = _messages.value + source
                    totalMessageCount += 1
                    dao.upsertMessage(source.toEntity(conversationId))
                    dao.upsertAttachment(extracted.toEntity(source.id))
                }
                // Structured result as an assistant bubble (markdown renders
                // headings/lists/tables), then a system confirmation note.
                val result = ChatMessage(text = markdown, isUser = false)
                val note = ChatMessage(
                    text = getApplication<Application>().getString(com.aispotlight.android.R.string.ocr_done),
                    isUser = false,
                    messageType = ChatMessage.Type.SYSTEM,
                )
                _messages.value = _messages.value + result + note
                totalMessageCount += 2
                dao.upsertMessage(result.toEntity(conversationId))
                dao.upsertMessage(note.toEntity(conversationId))
                dao.touch(conversationId, System.currentTimeMillis())
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                _errorText.value = e.message
            } finally {
                _isExtractingText.value = false
                _statusText.value = null
            }
        }
    }

    /** Saves an attachment into the system gallery, with a toast on completion. */
    fun saveAttachmentToGallery(attachment: com.aispotlight.android.data.ChatAttachment) {
        viewModelScope.launch {
            val ok = withContext(Dispatchers.IO) { ImageStore.exportToGallery(getApplication(), attachment) }
            val context = getApplication<Application>()
            android.widget.Toast.makeText(
                context,
                context.getString(
                    if (ok) com.aispotlight.android.R.string.image_saved
                    else com.aispotlight.android.R.string.image_save_failed
                ),
                android.widget.Toast.LENGTH_SHORT,
            ).show()
        }
    }

    // MARK: - Sending

    fun send(text: String) {
        val trimmed = text.trim()
        val attachments = _pendingAttachments.value
        if ((trimmed.isEmpty() && attachments.isEmpty()) || _isLoading.value) return
        // Slash commands operate on the newest image instead of the LLM
        // (port of the mac /upscale /bg /cleanup commands).
        if (trimmed.startsWith("/") && handleSlashCommand(trimmed)) return
        _pendingAttachments.value = emptyList()
        dispatch(ChatMessage(text = trimmed, isUser = true, attachments = attachments))
    }

    /** `/upscale`, `/bg`, `/cleanup <object>` → image tool on the newest image. */
    private fun handleSlashCommand(input: String): Boolean {
        val parts = input.split(" ", limit = 2)
        val command = parts[0].lowercase()
        val argument = parts.getOrNull(1)?.trim()
        val target = _pendingAttachments.value.lastOrNull()
            ?: _messages.value.asReversed().firstNotNullOfOrNull { it.attachments.lastOrNull() }
            ?: return false
        return when (command) {
            "/upscale" -> {
                runImageTool(target, com.aispotlight.android.providers.FalImageProvider.Function.UPSCALE)
                true
            }
            "/bg" -> {
                runImageTool(target, com.aispotlight.android.providers.FalImageProvider.Function.REMOVE_BACKGROUND)
                true
            }
            "/cleanup" -> {
                if (argument.isNullOrEmpty()) return false
                runImageTool(
                    target,
                    com.aispotlight.android.providers.FalImageProvider.Function.OBJECT_CLEANUP,
                    prompt = argument,
                )
                true
            }
            else -> false
        }
    }

    /** Builds a shareable markdown transcript of the active conversation. */
    fun exportTranscript(): String {
        val title = conversations.value.firstOrNull { it.id == _activeConversationId.value }?.title ?: "Chat"
        return buildString {
            appendLine("# $title")
            appendLine()
            for (message in _messages.value) {
                if (message.messageType == ChatMessage.Type.SYSTEM) continue
                appendLine(if (message.isUser) "**User:**" else "**Assistant:**")
                appendLine(message.text)
                appendLine()
            }
        }
    }

    /** Runs the send pipeline for a prebuilt user message (text or voice). */
    private fun dispatch(userMessage: ChatMessage) {
        val conversationId = _activeConversationId.value ?: return
        val conversation = activeConversation ?: return
        // Mid-switch guard: _activeConversationId flips synchronously but
        // activeConversation loads async — a send in that gap would pair the
        // new conversation's id with the OLD conversation's preset/summary.
        if (conversation.id != conversationId) return
        // One stream per conversation; other conversations may stream in parallel.
        if (conversationId in streamingIds.value) return
        val trimmed = userMessage.text
        val attachments = userMessage.attachments

        _errorText.value = null
        _messages.value = _messages.value + userMessage
        totalMessageCount += 1
        markStreaming(conversationId, true)
        _statusText.value = "Thinking…"

        // A first user message names the conversation.
        val isFirst = _messages.value.count { it.isUser } == 1
        // History = loaded window minus the summarized prefix (captured NOW,
        // while this conversation is on screen).
        val summary = conversation.summary
        val coversCount = conversation.summaryCoversCount
        val windowStart = totalMessageCount - _messages.value.size
        val skip = (coversCount - windowStart).coerceIn(0, _messages.value.size)
        val history = _messages.value.drop(skip)

        /** True while this conversation is still the one on screen. */
        fun isActive() = _activeConversationId.value == conversationId

        val job = viewModelScope.launch {
            dao.upsertMessage(userMessage.toEntity(conversationId))
            for (attachment in attachments) {
                dao.upsertAttachment(attachment.toEntity(userMessage.id))
            }
            val now = System.currentTimeMillis()
            if (isFirst) {
                dao.setTitle(conversationId, trimmed.ifEmpty { "Image" }.take(60), now)
            } else {
                dao.touch(conversationId, now)
            }

            // A spoken question with voice replies on WILL be voiced — mark the
            // reply VOICE from the first token so the bubble can keep the text
            // folded during the synthesis lag. If TTS later fails, the message
            // stays VOICE without audio, which renders as plain text.
            val expectVoiceReply = userMessage.messageType == ChatMessage.Type.VOICE &&
                settings.voiceReplies.value &&
                com.aispotlight.android.providers.SpeechService.isAvailable
            val reply = ChatMessage(
                text = "", isUser = false,
                messageType = if (expectVoiceReply) ChatMessage.Type.VOICE else ChatMessage.Type.TEXT,
            )
            var replyText = StringBuilder()
            var toolContext: String? = null
            var lastUiFlush = 0L
            var lastDbFlush = 0L
            var persisted = false

            /** Upserts the reply into the on-screen list (only when its chat is active). */
            fun pushReply(error: Boolean = false) {
                if (!isActive()) return
                val updated = reply.copy(text = replyText.toString(), toolContext = toolContext, isError = error)
                val list = _messages.value
                val index = list.indexOfFirst { it.id == reply.id }
                _messages.value = if (index >= 0) {
                    list.toMutableList().also { it[index] = updated }
                } else {
                    list + updated
                }
            }

            suspend fun persistReply(error: Boolean = false) {
                val updated = reply.copy(text = replyText.toString(), toolContext = toolContext, isError = error)
                try {
                    dao.upsertMessage(updated.toEntity(conversationId))
                    persisted = true
                } catch (_: android.database.sqlite.SQLiteException) {
                    // The conversation was deleted mid-stream — nothing to keep.
                }
            }

            try {
                // The ACTIVE preset speaks through the editable working copy
                // (mac semantics — the user's edits in Settings must apply).
                // Pristine preset text is only for a conversation still
                // streaming under a preset the user has already switched off.
                val presetPrompt = conversation.presetName
                    ?.takeIf { it != settings.activePresetName.value }
                    ?.let { settings.presetText(it) }
                ChatService.streamReply(
                    context = getApplication(),
                    history = history,
                    summary = summary,
                    presetSystemPrompt = presetPrompt,
                    onAttachmentOCR = { messageId, attachmentId, ocrText ->
                        // Persist the lazily computed OCR extraction onto its
                        // attachment (row + loaded window) so it is never re-paid.
                        dao.setAttachmentOCR(attachmentId, ocrText)
                        if (isActive()) {
                            _messages.value = _messages.value.map { m ->
                                if (m.id != messageId) m
                                else m.copy(attachments = m.attachments.map { a ->
                                    if (a.id == attachmentId) a.copy(ocrText = ocrText) else a
                                })
                            }
                        }
                    },
                ).collect { event ->
                    when (event) {
                        is ChatService.ChatEvent.Text -> {
                            replyText.append(event.chunk)
                            if (isActive()) _statusText.value = null
                            val t = System.currentTimeMillis()
                            // Throttle recompositions to ~every 120 ms…
                            if (t - lastUiFlush > 120) {
                                lastUiFlush = t
                                pushReply()
                            }
                            // …and store flushes to ~every second, so a kill or
                            // a conversation switch mid-stream loses nothing.
                            if (t - lastDbFlush > 1000) {
                                lastDbFlush = t
                                persistReply()
                            }
                        }
                        is ChatService.ChatEvent.Status -> if (isActive()) _statusText.value = event.text
                        is ChatService.ChatEvent.ToolContext -> toolContext = event.digest
                        is ChatService.ChatEvent.BudgetWarning -> {
                            // Persisted system line (not sent to the LLM) — the
                            // soft monthly budget crossed a threshold.
                            val warning = ChatMessage(
                                text = event.text, isUser = false,
                                messageType = ChatMessage.Type.SYSTEM,
                            )
                            if (isActive()) _messages.value = _messages.value + warning
                            totalMessageCount += 1
                            dao.upsertMessage(warning.toEntity(conversationId))
                        }
                    }
                }
                if (replyText.isNotEmpty()) {
                    pushReply()
                    persistReply()
                    dao.touch(conversationId, System.currentTimeMillis())
                    // Recount instead of += 1: if the user left and returned
                    // mid-stream, openConversation already counted the
                    // persisted partial — a blind increment double-counts it.
                    if (isActive()) totalMessageCount = dao.messageCount(conversationId)
                    // Voice replies: the user spoke, so the assistant speaks
                    // back — synthesize the reply and attach it as a voice
                    // message; the transcript (the reply text) stays below the
                    // player. TTS failure never degrades the text reply.
                    if (expectVoiceReply) {
                        if (isActive()) _statusText.value = "Voicing…"
                        try {
                            val audio = withContext(Dispatchers.IO) {
                                com.aispotlight.android.providers.SpeechService.synthesize(replyText.toString())
                            }
                            val relativePath = withContext(Dispatchers.IO) {
                                val target = java.io.File(
                                    getApplication<Application>().filesDir,
                                    "recordings/tts-${reply.id}.${audio.fileExtension}"
                                )
                                target.parentFile?.mkdirs()
                                target.writeBytes(audio.bytes)
                                "recordings/${target.name}"
                            }
                            val voiced = reply.copy(
                                text = replyText.toString(),
                                toolContext = toolContext,
                                messageType = ChatMessage.Type.VOICE,
                                audioPath = relativePath,
                            )
                            dao.upsertMessage(voiced.toEntity(conversationId))
                            if (isActive()) {
                                _messages.value = _messages.value.map { if (it.id == reply.id) voiced else it }
                            }
                        } catch (e: kotlinx.coroutines.CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            com.aispotlight.android.core.Diagnostics.log("tts", "synthesize.failed ${e.message}")
                        }
                    }
                }
                markStreaming(conversationId, false)
                if (isActive()) runCompression(conversationId)
            } catch (e: kotlinx.coroutines.CancellationException) {
                // Stop button: keep whatever streamed so far.
                if (replyText.isNotEmpty() && !persisted) {
                    kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable) { persistReply() }
                }
                markStreaming(conversationId, false)
                throw e
            } catch (e: Exception) {
                val message = e.message ?: "Request failed."
                if (replyText.isEmpty()) {
                    replyText = StringBuilder(message)
                } else {
                    replyText.append("\n\n⚠️ $message")
                }
                pushReply(error = true)
                persistReply(error = true)
                if (isActive()) totalMessageCount = dao.messageCount(conversationId)
                markStreaming(conversationId, false)
            }
        }
        streamJobs[conversationId] = job
    }

    fun stopStreaming() {
        val conversationId = _activeConversationId.value ?: return
        streamJobs[conversationId]?.cancel()
        markStreaming(conversationId, false)
        // Reflect the persisted partial in the on-screen list.
        val last = _messages.value.lastOrNull()
        if (last != null && !last.isUser) {
            viewModelScope.launch { dao.upsertMessage(last.toEntity(conversationId)) }
        }
    }

    // MARK: - Compression

    private suspend fun runCompression(conversationId: String) {
        val conversation = activeConversation ?: return
        val coversCount = conversation.summaryCoversCount
        val windowStart = totalMessageCount - _messages.value.size
        val skip = (coversCount - windowStart).coerceIn(0, _messages.value.size)
        val active = _messages.value.drop(skip)
        val result = ChatService.compressHistoryIfNeeded(
            activeMessages = active,
            totalMessageCount = totalMessageCount,
            existingSummary = conversation.summary,
        ) ?: return
        // The user may have switched conversations while the summary call ran —
        // the result still belongs to the conversation it was computed FOR.
        dao.setSummary(conversationId, result.summary, result.coversCount)
        if (_activeConversationId.value == conversationId) {
            activeConversation = conversation.copy(
                summary = result.summary, summaryCoversCount = result.coversCount
            )
        }
    }
}
