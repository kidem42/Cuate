package com.aispotlight.android.chat

import android.app.Application
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.aispotlight.android.data.AppDatabase
import com.aispotlight.android.data.ChatAttachment
import com.aispotlight.android.data.ChatMessage
import com.aispotlight.android.R
import com.aispotlight.android.data.Conversation
import com.aispotlight.android.data.ImageAlpha
import com.aispotlight.android.data.ImageStore
import com.aispotlight.android.data.MessageEntity
import com.aispotlight.android.data.toDomain
import com.aispotlight.android.data.toEntity
import com.aispotlight.android.hermes.HermesChatService
import com.aispotlight.android.hermes.HermesTransport
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

    /**
     * Guards the one-shot "return to where the user left off" branch: only
     * the FIRST emission of the preset collector (the cold start) restores
     * the stored conversation — every later preset change is a deliberate
     * switch and must be obeyed.
     */
    private var restoredLastConversation = false

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
                        // COLD START ONLY: the conversation the user left wins
                        // over the derived rule. An agent thread is not
                        // derivable from a preset at all, so without this a
                        // relaunch always dumped the user back into the preset
                        // chat, whatever they were doing in Hermes.
                        val restoreId = if (restoredLastConversation) null else {
                            settings.lastConversationId()
                                ?.let { dao.conversation(it) }
                                // A thread whose gateway is gone (endpoint
                                // cleared in Settings) would restore into a
                                // dead agent chat — fall back to the preset.
                                ?.takeIf { it.hermesSessionId == null || settings.hermesConfigured }
                                ?.id
                        }
                        restoredLastConversation = true
                        if (isIsolated) {
                            if (restoreId != null) openConversation(restoreId)
                            else openIsolated(active)
                        } else {
                            val generalId = ensureGeneralConversation()
                            // The general chat carries the active preset's
                            // system prompt (mac semantics: regular presets
                            // share one conversation, swapping prompts). Synced
                            // even when restoring elsewhere — a later switch
                            // back to this preset must speak with its prompt.
                            dao.conversation(generalId)?.let { entity ->
                                if (entity.presetName != active) {
                                    dao.upsertConversation(entity.copy(presetName = active))
                                }
                            }
                            val target = restoreId ?: generalId
                            if (_activeConversationId.value == target) {
                                if (target == generalId) {
                                    activeConversation = activeConversation?.copy(presetName = active)
                                }
                            } else {
                                openConversation(target)
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
            purgeMediaFiles(id)
            dao.deleteMessages(id)
            dao.deleteConversation(id)
            settings.clearIsolatedConversationId(presetName)
        }
    }

    /**
     * Deletes a conversation's media FILES (attachments + voice recordings)
     * from disk — every path that deletes messages must call this first, or
     * the payloads leak until the retention sweep ages them out.
     */
    private suspend fun purgeMediaFiles(conversationId: String) {
        for (path in dao.attachmentPaths(conversationId)) {
            ImageStore.delete(getApplication(), path)
        }
        for (path in dao.audioPaths(conversationId)) {
            java.io.File(getApplication<Application>().filesDir, path).delete()
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
        // Every switch — preset chat or agent thread — is where a cold start
        // will come back to.
        settings.setLastConversationId(id)
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
                _isHermesActive.value = entity.hermesSessionId != null
                _hermesUnread.value = _hermesUnread.value - id
                refreshPins(id)
                // Agent threads: refresh the mirror in the background —
                // activity from Telegram/CLI lands without a manual refresh.
                if (entity.hermesSessionId != null) {
                    launch(Dispatchers.IO) {
                        try {
                            if (HermesChatService.syncTranscript(dao, entity) > 0) {
                                reloadActiveWindow()
                            }
                        } catch (_: Exception) { }
                    }
                    loadHermesSkills()
                }
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
            purgeMediaFiles(id)
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

    /**
     * Imports an arbitrary file (agent chats: SAF document picker) into the
     * pending set — the courier uploads it to the agent's host on send.
     */
    fun attachFile(uri: Uri) {
        viewModelScope.launch(Dispatchers.IO) {
            val attachment = ImageStore.importFile(getApplication(), uri)
            if (attachment == null) {
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
        // A pill in the chat while transcribing: a long voice message with no
        // indicator looks like a lost message (port of the Mac fix; the
        // composer placeholder duplicates it, but is not always visible).
        _statusText.value = getApplication<Application>().getString(R.string.chat_transcribing)
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
                // dispatch() owns the status from here on (streaming reply);
                // only clear a still-standing transcription pill.
                if (_statusText.value == getApplication<Application>().getString(R.string.chat_transcribing)) {
                    _statusText.value = null
                }
            }
        }
    }

    /**
     * Audio shared from another app (WhatsApp/Telegram voice notes, files):
     * transcribes it and drops the text into the INPUT FIELD — the user
     * decides what to do with it (send as is, add instructions, edit).
     */
    fun importSharedAudio(uri: Uri, mimeType: String?) {
        if (_isTranscribing.value) return
        _isTranscribing.value = true
        _statusText.value = getApplication<Application>().getString(R.string.chat_transcribing)
        viewModelScope.launch {
            try {
                val text = withContext(Dispatchers.IO) {
                    val app = getApplication<Application>()
                    // Extension drives the STT content type — take it from the
                    // announced mime, falling back to the Uri's own name.
                    val ext = when (mimeType?.lowercase()?.substringBefore(";")?.trim()) {
                        "audio/ogg", "audio/opus" -> "ogg"
                        "audio/mpeg", "audio/mp3" -> "mp3"
                        "audio/wav", "audio/x-wav" -> "wav"
                        "audio/webm" -> "webm"
                        "audio/flac" -> "flac"
                        "audio/aac" -> "aac"
                        "audio/mp4", "audio/m4a", "audio/x-m4a" -> "m4a"
                        else -> uri.lastPathSegment?.substringAfterLast('.', "")
                            ?.takeIf { it.length in 2..4 } ?: "m4a"
                    }
                    val file = java.io.File(app.cacheDir, "shared-${System.currentTimeMillis()}.$ext")
                    app.contentResolver.openInputStream(uri)?.use { input ->
                        file.outputStream().use { input.copyTo(it) }
                    } ?: throw IllegalStateException(app.getString(R.string.attach_failed))
                    try {
                        TranscriptionService.transcribe(file)
                    } finally {
                        file.delete()
                    }
                }
                if (text.isNotEmpty()) _transcriptionResult.value = text
            } catch (e: Exception) {
                _errorText.value = e.message
            } finally {
                _isTranscribing.value = false
                if (_statusText.value == getApplication<Application>().getString(R.string.chat_transcribing)) {
                    _statusText.value = null
                }
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
        // Leaving an agent thread for the ALREADY-active preset: the derived
        // (preset → conversation) collector won't fire (nothing changed), so
        // walk back to the preset's conversation explicitly.
        if (_isHermesActive.value && name == settings.activePresetName.value) {
            viewModelScope.launch {
                switchMutex.withLock {
                    if (name in settings.isolatedPresets.value) {
                        openIsolated(name)
                    } else {
                        openConversation(ensureGeneralConversation())
                    }
                }
            }
            return
        }
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
                // Alpha mask of a transparent input (kept to restore the
                // cutout's transparency after an upscale — see ImageAlpha).
                var alphaMask: android.graphics.Bitmap? = null
                val result = withContext(Dispatchers.IO) {
                    val context = getApplication<Application>()
                    // A transparent input is flattened onto white: fal models
                    // ignore alpha and see the RGB under the mask — for cutouts
                    // that holds the original background (ImageAlpha, port of
                    // the Mac fix).
                    val flattened = ImageStore.file(context, attachment)
                        .takeIf { it.exists() }?.readBytes()
                        ?.let { ImageAlpha.flattenIfTransparent(it) }
                    // Some endpoints require PNG input (Recraft); others take the image as-is.
                    val (base64, mime) = when {
                        flattened != null -> {
                            alphaMask = flattened.second
                            android.util.Base64.encodeToString(flattened.first, android.util.Base64.NO_WRAP) to "image/png"
                        }
                        model?.requiresPNGInput == true ->
                            ImageStore.pngBase64(context, attachment) to "image/png"
                        else ->
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
                    var outBytes = result.image
                    var outMime = result.mimeType
                    // A background-removal result carries the untouched original
                    // in the RGB under the transparency — wipe it (a leak, plus
                    // the background "resurrects" in alpha-blind processors).
                    if (function == com.aispotlight.android.providers.FalImageProvider.Function.REMOVE_BACKGROUND) {
                        ImageAlpha.sanitizedTransparency(outBytes)?.let {
                            outBytes = it
                            outMime = "image/png"
                        }
                    }
                    // Upscaling a cutout: models return opaque RGB — restore the
                    // transparency from the original alpha mask.
                    if (function == com.aispotlight.android.providers.FalImageProvider.Function.UPSCALE) {
                        alphaMask?.let { mask ->
                            ImageAlpha.applyAlphaMask(mask, outBytes)?.let {
                                outBytes = it
                                outMime = "image/png"
                            }
                        }
                    }
                    ImageStore.importBytes(
                        getApplication(), outBytes, outMime,
                        filename = attachment.filename.substringBeforeLast('.') + "-$suffix." +
                            if (outMime == "image/png") "png" else "jpg",
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

    /** Runs the send pipeline for a prebuilt user message (text or voice). */
    private fun dispatch(userMessage: ChatMessage) {
        val conversationId = _activeConversationId.value ?: return
        val conversation = activeConversation ?: return
        // Mid-switch guard: _activeConversationId flips synchronously but
        // activeConversation loads async — a send in that gap would pair the
        // new conversation's id with the OLD conversation's preset/summary.
        if (conversation.id != conversationId) return
        // Agent threads speak to the gateway, not a provider.
        if (conversation.isHermes) {
            hermesDispatch(userMessage)
            return
        }
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
                // Auto-continuation (desktop 3.20): the model may end a round
                // with a trailing `<continue/>` marker (taught in the
                // mandatory prompt rules) — "I need another working round".
                // The marker is stripped, a hidden "Continue." user turn is
                // appended to the REQUEST (never to the chat or the DB), and
                // the next round streams into the SAME bubble with a fresh
                // tool budget. Bounded so a marker-happy model can't loop.
                var requestHistory = history
                var round = 0
                while (true) {
                val roundStart = replyText.length
                ChatService.streamReply(
                    context = getApplication(),
                    history = requestHistory,
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
                            // Coalesce chunks to ~30 Hz (the desktop 3.20
                            // cadence) — cheap now that the markdown renderer
                            // re-parses only the live tail per flush…
                            if (t - lastUiFlush > 33) {
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
                        is ChatService.ChatEvent.ToolContext -> {
                            // Rounds accumulate; the suffix cap keeps the
                            // freshest grounding.
                            toolContext = listOfNotNull(toolContext, event.digest)
                                .joinToString("\n\n").takeLast(6000)
                        }
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
                    // Round over: a trailing marker requests another one.
                    val roundRaw = replyText.substring(roundStart)
                    val (roundStripped, wantsContinuation) = ChatService.stripContinueMarker(roundRaw)
                    if (!wantsContinuation || round >= ChatService.MAX_AUTO_CONTINUES) {
                        if (wantsContinuation) {
                            // Out of rounds — the marker itself must not render.
                            replyText.setLength(roundStart)
                            replyText.append(roundStripped)
                        }
                        break
                    }
                    round += 1
                    replyText.setLength(roundStart)
                    replyText.append(roundStripped).append("\n\n")
                    pushReply()
                    if (isActive()) _statusText.value = "Thinking…"
                    // Hidden request-only turns: this round's text and the
                    // continuation nudge. Never shown, never persisted.
                    requestHistory = requestHistory +
                        ChatMessage(text = roundStripped, isUser = false) +
                        ChatMessage(text = "Continue.", isUser = true)
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
        // Agent runs are stopped on the GATEWAY too — cancelling only the
        // local collect would leave the agent working (and billing) blind.
        hermesRunIds.remove(conversationId)?.let { runID ->
            viewModelScope.launch(Dispatchers.IO) {
                try {
                    HermesChatService.transport(settings).stopRun(runID)
                } catch (e: Exception) {
                    com.aispotlight.android.core.Diagnostics.log("hermes", "stop.fail ${e.message?.take(120)}")
                }
            }
        }
        streamJobs[conversationId]?.cancel()
        markStreaming(conversationId, false)
        // Reflect the persisted partial in the on-screen list.
        val last = _messages.value.lastOrNull()
        if (last != null && !last.isUser) {
            viewModelScope.launch { dao.upsertMessage(last.toEntity(conversationId)) }
        }
    }

    // MARK: - Hermes agent (sessions are conversations)

    /** Hermes conversations with activity the user hasn't seen (badge source). */
    private val _hermesUnread = MutableStateFlow<Set<String>>(emptySet())
    val hermesUnread: StateFlow<Set<String>> = _hermesUnread

    /** Agent skills for the `/` autocomplete (fetched once per app run). */
    private val _hermesSkills = MutableStateFlow<List<com.aispotlight.android.hermes.HermesSkill>>(emptyList())
    val hermesSkills: StateFlow<List<com.aispotlight.android.hermes.HermesSkill>> = _hermesSkills
    private var hermesSkillsLoaded = false

    /** Pinned messages of the active conversation, oldest first (pin bar). */
    private val _pinnedMessages = MutableStateFlow<List<ChatMessage>>(emptyList())
    val pinnedMessages: StateFlow<List<ChatMessage>> = _pinnedMessages

    /** Whether the ACTIVE conversation is a Hermes agent thread. */
    private val _isHermesActive = MutableStateFlow(false)
    val isHermesActive: StateFlow<Boolean> = _isHermesActive

    /** Live run id per conversation — the stop button's gateway target. */
    private val hermesRunIds = mutableMapOf<String, String>()

    /** Files of the chat (agent-side paths + attachments the user sent). */
    data class ChatFiles(val agentPaths: List<String>, val sentByYou: List<String>)
    private val _chatFiles = MutableStateFlow<ChatFiles?>(null)
    val chatFiles: StateFlow<ChatFiles?> = _chatFiles

    /**
     * True while a gateway session create is in flight. Guards against
     * repeat taps — creation takes 2 slow round-trips to a remote gateway,
     * and every extra tap used to make one more identical session (the
     * switchMutex only SERIALIZED them, live bug 2026-07-31). The UI shows
     * it as a spinner on the new-session controls.
     */
    private val _hermesCreating = MutableStateFlow(false)
    val hermesCreating: StateFlow<Boolean> = _hermesCreating

    /**
     * The Hermes role tapped in the switcher: opens the most recent agent
     * thread (creating the first session when there is none), then refreshes
     * the session mirror and the skills cache in the background.
     */
    fun openHermes() {
        viewModelScope.launch {
            switchMutex.withLock {
                val existing = dao.hermesConversations().maxByOrNull { it.updatedAt }
                if (existing != null) {
                    openConversation(existing.id)
                } else if (_hermesCreating.compareAndSet(expect = false, update = true)) {
                    try {
                        createHermesConversation()?.let { openConversation(it) }
                    } finally {
                        _hermesCreating.value = false
                    }
                }
            }
            syncHermesSessions()
            loadHermesSkills()
        }
    }

    /** Opens a specific agent thread from the sessions menu. */
    fun openHermesConversation(conversationId: String) {
        openConversation(conversationId)
        _hermesUnread.value = _hermesUnread.value - conversationId
    }

    /** "New session" — a fresh gateway session as a fresh thread. */
    fun newHermesSession() {
        // The flag flips BEFORE the coroutine queues on the mutex — a tap
        // during any phase (mutex wait, network) is dropped, not deferred.
        if (!_hermesCreating.compareAndSet(expect = false, update = true)) return
        viewModelScope.launch {
            try {
                switchMutex.withLock {
                    createHermesConversation()?.let { openConversation(it) }
                }
            } finally {
                _hermesCreating.value = false
            }
        }
    }

    /** Deletes an agent thread on the gateway and locally (default: active). */
    fun deleteHermesConversation(conversationId: String? = null) {
        viewModelScope.launch {
            val id = conversationId ?: _activeConversationId.value ?: return@launch
            val entity = dao.conversation(id) ?: return@launch
            val sessionId = entity.hermesSessionId ?: return@launch
            streamJobs[id]?.cancel()
            markStreaming(id, false)
            try {
                HermesChatService.transport(settings).deleteSession(sessionId)
            } catch (e: Exception) {
                com.aispotlight.android.core.Diagnostics.log("hermes", "delete.fail ${e.message?.take(120)}")
            }
            purgeMediaFiles(id)
            dao.deleteMessages(id)
            dao.deleteConversation(id)
            _hermesUnread.value = _hermesUnread.value - id
            if (_activeConversationId.value == id) {
                switchMutex.withLock {
                    val next = dao.hermesConversations().maxByOrNull { it.updatedAt }
                    if (next != null) openConversation(next.id) else openConversation(ensureGeneralConversation())
                }
            }
        }
    }

    /** Renames an agent thread locally and on the gateway (sidebar action). */
    fun renameHermesConversation(conversationId: String, title: String) {
        val trimmed = title.trim().take(80)
        if (trimmed.isEmpty()) return
        viewModelScope.launch {
            val entity = dao.conversation(conversationId) ?: return@launch
            dao.setTitle(conversationId, trimmed, entity.updatedAt)
            entity.hermesSessionId?.let { sessionId ->
                launch(Dispatchers.IO) {
                    try {
                        HermesChatService.transport(settings).renameSession(sessionId, trimmed)
                    } catch (e: Exception) {
                        com.aispotlight.android.core.Diagnostics.log("hermes", "rename.fail ${e.message?.take(120)}")
                    }
                }
            }
        }
    }

    /** Model/provider options for the composer switcher (fetched with skills). */
    private val _hermesModelOptions =
        MutableStateFlow<com.aispotlight.android.hermes.HermesModelOptions?>(null)
    val hermesModelOptions: StateFlow<com.aispotlight.android.hermes.HermesModelOptions?> = _hermesModelOptions

    /**
     * Re-locks the ACTIVE session's model (the composer control, desktop
     * 4.0): takes effect from the next turn.
     */
    fun setActiveSessionModel(provider: String, model: String) {
        val sessionId = activeConversation?.hermesSessionId ?: return
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val (lockedProvider, lockedModel) =
                    HermesChatService.transport(settings).lockModel(sessionId, provider, model)
                // 0.20: a config model_routes alias can silently reroute the
                // lock to another provider — record and surface the TRUTH,
                // not the request (desktop parity, live find 2026-08-13).
                settings.setHermesSessionModel(sessionId, "$lockedProvider|$lockedModel")
                if (lockedProvider != provider) {
                    _errorText.value = getApplication<android.app.Application>().getString(
                        R.string.hermes_lock_rerouted, provider, lockedModel, lockedProvider)
                    com.aispotlight.android.core.Diagnostics.log(
                        "hermes", "lock.rerouted requested=$provider/$model locked=$lockedProvider/$lockedModel")
                }
            } catch (e: Exception) {
                _errorText.value = "Hermes: ${e.message?.take(160)}"
            }
        }
    }

    fun setActiveSessionEffort(effort: String) {
        val sessionId = activeConversation?.hermesSessionId ?: return
        settings.setHermesSessionEffort(sessionId, effort)
    }

    /** Session id of the active agent thread (composer state reads). */
    val activeHermesSessionId: String?
        get() = activeConversation?.hermesSessionId

    /** Creates gateway session + mirror conversation; null (with banner) on failure. */
    private suspend fun createHermesConversation(): String? {
        return try {
            val stamp = java.text.SimpleDateFormat("MMM d HH:mm", java.util.Locale.US)
                .format(java.util.Date())
            val session = HermesChatService.createSession(
                settings, "Cuate $stamp",
                cachedCurrent = _hermesModelOptions.value?.current,
            )
            val conversation = Conversation(
                title = session.title ?: "Agent",
                presetName = null,
                hermesSessionId = session.id,
            )
            dao.upsertConversation(conversation.toEntity())
            conversation.id
        } catch (e: Exception) {
            _errorText.value = "Hermes: ${e.message?.take(160)}"
            null
        }
    }

    /**
     * Mirrors the gateway session list into conversations — external
     * sessions (created from Telegram/CLI) appear as threads; external
     * activity in known sessions refreshes their transcript and raises an
     * unread badge (the desktop HermesMirrorSync role).
     */
    fun syncHermesSessions() {
        if (!settings.hermesConfigured) return
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val transport = HermesChatService.transport(settings)
                val remote = transport.sessions(limit = 50)
                // Context window of the agent's model, resolved by Hermes
                // itself — the gauge's authoritative source. The route lives
                // on the DASHBOARD server only (public path — the courier
                // token is passed but optional). Once per process: the value
                // moves when the agent's model changes, not per sync.
                if (!hermesModelInfoFetched &&
                    settings.hermesDashboardUrl.value.isNotEmpty()) {
                    hermesModelInfoFetched = true
                    try {
                        val token = com.aispotlight.android.settings.ApiKeyStore
                            .auxKey(com.aispotlight.android.settings.ApiKeyStore.AuxKey.HERMES_DASHBOARD) ?: ""
                        val (model, length) = HermesTransport(
                            settings.hermesDashboardUrl.value, token).modelInfo()
                        settings.recordHermesAgentContext(model, length)
                    } catch (e: Exception) {
                        com.aispotlight.android.core.Diagnostics.log(
                            "hermes", "modelinfo.fail ${e.message?.take(80)}")
                    }
                }
                for (info in remote) {
                    // The session row knows the agent's ACTUAL model — keep
                    // the label map current for sessions locked elsewhere
                    // (creation default, desktop, CLI). The pre-lock literal
                    // is noise. A stored pair with the same model wins: it
                    // also knows the provider.
                    info.model?.takeIf { it != "hermes-agent" }?.let { model ->
                        val stored = settings.hermesSessionModels.value[info.id]
                        if (stored == null || stored.substringAfter("|") != model) {
                            settings.setHermesSessionModel(info.id, "|$model")
                        }
                    }
                    val existing = dao.conversationForHermesSession(info.id)
                    if (existing == null) {
                        val conversation = Conversation(
                            title = info.title ?: info.preview?.take(60) ?: "Agent",
                            presetName = null,
                            createdAt = info.startedAt ?: System.currentTimeMillis(),
                            updatedAt = info.lastActive ?: System.currentTimeMillis(),
                            hermesSessionId = info.id,
                        )
                        dao.upsertConversation(conversation.toEntity())
                        dao.conversation(conversation.id)?.let {
                            HermesChatService.syncTranscript(dao, it)
                        }
                    } else {
                        // Transcript fetch only when the gateway saw activity
                        // we haven't (lastActive vs our updatedAt, 5s slack) —
                        // a resume must not refetch 50 quiet sessions.
                        // NEVER while this conversation's own turn streams:
                        // the gateway already holds the turn's interim rows
                        // and they'd import as duplicates next to the live
                        // bubble (desktop 4.6.1 activeTurnKeys gate; the
                        // turn's end bumps the watermark before releasing
                        // the mark).
                        val streamingNow = existing.id in streamingIds.value
                        val stale = !streamingNow &&
                            (info.lastActive ?: 0) > existing.updatedAt + 5_000
                        val added = if (stale) HermesChatService.syncTranscript(dao, existing) else 0
                        if (added > 0) {
                            dao.touch(existing.id, info.lastActive ?: System.currentTimeMillis())
                            if (_activeConversationId.value == existing.id) {
                                reloadActiveWindow()
                            } else {
                                _hermesUnread.value = _hermesUnread.value + existing.id
                            }
                        }
                        // Titles renamed externally follow the gateway.
                        val title = info.title
                        if (!title.isNullOrEmpty() && title != existing.title) {
                            dao.setTitle(existing.id, title, existing.updatedAt)
                        }
                    }
                }
                // Server-side pins (Hermes 0.20; rows then carry `pinned`).
                // First contact with a pin-capable gateway pushes the LOCAL
                // pins up — the pins made before the upgrade must survive it,
                // not be wiped by an empty server state. From then on the
                // server owns the truth (pins made on the desktop land here).
                if (remote.any { it.pinned != null }) {
                    val serverPinned = remote.filter { it.pinned == true }.map { it.id }.toSet()
                    val known = remote.map { it.id }.toSet()
                    if (!settings.hermesPinsPushed) {
                        settings.hermesPinsPushed = true
                        val toPush = settings.hermesPinnedSessions.value
                            .filter { it in known && it !in serverPinned }
                        for (id in toPush) {
                            try { transport.setSessionPinned(id, true) } catch (_: Exception) { }
                        }
                        if (toPush.isNotEmpty()) {
                            com.aispotlight.android.core.Diagnostics.log(
                                "hermes", "pins.migrated count=${toPush.size}")
                        }
                    } else {
                        val preserved = settings.hermesPinnedSessions.value.filter { it !in known }
                        settings.replaceHermesSessionPins(serverPinned + preserved)
                    }
                }
                // The gateway owns the list: sessions deleted on ANOTHER
                // surface (desktop, CLI) disappear here too (e2e 2026-07-27
                // — the phone kept showing threads deleted from the mac).
                // Only when the page was complete: a truncated 50-row page
                // must not "delete" the sessions beyond it.
                if (remote.size < 50) {
                    val remoteIds = remote.map { it.id }.toSet()
                    val orphans = dao.hermesConversations().filter {
                        it.hermesSessionId != null && it.hermesSessionId !in remoteIds
                    }
                    for (orphan in orphans) {
                        streamJobs[orphan.id]?.cancel()
                        markStreaming(orphan.id, false)
                        purgeMediaFiles(orphan.id)
                        dao.deleteMessages(orphan.id)
                        dao.deleteConversation(orphan.id)
                        _hermesUnread.value = _hermesUnread.value - orphan.id
                    }
                    if (orphans.any { it.id == _activeConversationId.value }) {
                        switchMutex.withLock {
                            val next = dao.hermesConversations().maxByOrNull { it.updatedAt }
                            if (next != null) openConversation(next.id)
                            else openConversation(ensureGeneralConversation())
                        }
                    }
                }
            } catch (e: Exception) {
                com.aispotlight.android.core.Diagnostics.log("hermes", "sync.fail ${e.message?.take(120)}")
            }
        }
    }

    /**
     * Re-reads the model catalog when the picker opens (the gateway's list
     * is live and mutable — fixtures 2026-07-29); `force` maps to the
     * gateway's `?refresh=true` cache drop.
     */
    fun refreshHermesModelOptions(force: Boolean = false) {
        if (!settings.hermesConfigured) return
        viewModelScope.launch(Dispatchers.IO) {
            try {
                _hermesModelOptions.value =
                    HermesChatService.transport(settings).modelOptions(refresh = force)
            } catch (e: Exception) {
                com.aispotlight.android.core.Diagnostics.log("hermes", "models.fail ${e.message?.take(120)}")
            }
        }
    }

    private fun loadHermesSkills() {
        if (hermesSkillsLoaded) return
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val transport = HermesChatService.transport(settings)
                _hermesSkills.value = transport.skills()
                _hermesModelOptions.value = try { transport.modelOptions() } catch (_: Exception) { null }
                hermesSkillsLoaded = true
            } catch (e: Exception) {
                com.aispotlight.android.core.Diagnostics.log("hermes", "skills.fail ${e.message?.take(120)}")
            }
        }
    }

    // MARK: Pins (Telegram-style, any conversation)

    fun togglePin(message: ChatMessage) {
        val conversationId = _activeConversationId.value ?: return
        viewModelScope.launch {
            val pinning = !message.pinned
            val stamp = if (pinning) System.currentTimeMillis() else 0L
            dao.setPinned(message.id, pinning, stamp)
            _messages.value = _messages.value.map {
                if (it.id == message.id) it.copy(pinned = pinning, pinnedAt = stamp) else it
            }
            refreshPins(conversationId)
        }
    }

    private suspend fun refreshPins(conversationId: String) {
        val pins = withAttachments(dao.pinnedMessages(conversationId))
        if (_activeConversationId.value == conversationId) _pinnedMessages.value = pins
    }

    /**
     * Scroll target for a pinned message OUTSIDE the loaded window: pages
     * older messages in until the pin is present, then returns its id.
     */
    private suspend fun ensurePinLoaded(messageId: String): Boolean {
        val id = _activeConversationId.value ?: return false
        var guard = 0
        while (_messages.value.none { it.id == messageId } && guard < 40) {
            val oldest = _messages.value.firstOrNull() ?: return false
            val older = withAttachments(dao.olderMessages(id, oldest.timestamp, windowSize).reversed())
            if (older.isEmpty()) return false
            _messages.value = older + _messages.value
            _hasOlderMessages.value = totalMessageCount > _messages.value.size
            guard++
        }
        return _messages.value.any { it.id == messageId }
    }

    /** Pages the pin into the window and returns its index in the list (-1 = gone). */
    suspend fun locatePin(messageId: String): Int {
        if (!ensurePinLoaded(messageId)) return -1
        return _messages.value.indexOfFirst { it.id == messageId }
    }

    // MARK: Files of the chat

    fun loadChatFiles() {
        val id = _activeConversationId.value ?: return
        viewModelScope.launch {
            val rows = dao.allMessages(id)
            val agent = LinkedHashSet<String>()
            for (row in rows) {
                if (!row.isUser) {
                    com.aispotlight.android.hermes.HermesFilePaths.extract(row.text)
                        .filter { com.aispotlight.android.hermes.HermesFilePaths.isListableFile(it) }
                        .forEach { agent.add(it) }
                }
            }
            val userMessageIds = rows.filter { it.isUser }.map { it.id }
            val sent = if (userMessageIds.isEmpty()) emptyList()
                else dao.attachments(userMessageIds).map { it.filename }.distinct()
            _chatFiles.value = ChatFiles(agent.toList(), sent)
        }
    }

    fun dismissChatFiles() { _chatFiles.value = null }

    /** Lazy second-level detail for a journal row (command/output/exit code). */
    suspend fun hermesStepDetails(messageId: String): List<HermesChatService.StepDetail> {
        val sessionId = activeConversation?.hermesSessionId ?: return emptyList()
        return HermesChatService.stepDetails(sessionId, messageId)
    }

    /** Re-fetches the active conversation's window (mirror sync added rows). */
    private suspend fun reloadActiveWindow() {
        val id = _activeConversationId.value ?: return
        val recent = withAttachments(dao.recentMessages(id, windowSize).reversed())
        val count = dao.messageCount(id)
        if (_activeConversationId.value == id) {
            totalMessageCount = count
            _messages.value = recent
            _hasOlderMessages.value = count > recent.size
        }
    }

    /**
     * Pin toggle used by the sidebar: local flip immediately (works against
     * any gateway), server write best-effort (0.19 400s — the local pin
     * still stands, exactly the pre-0.20 behavior).
     */
    fun toggleHermesSessionPin(sessionId: String) {
        settings.toggleHermesSessionPin(sessionId)
        val pinned = sessionId in settings.hermesPinnedSessions.value
        viewModelScope.launch(Dispatchers.IO) {
            try {
                HermesChatService.transport(settings).setSessionPinned(sessionId, pinned)
            } catch (e: Exception) {
                com.aispotlight.android.core.Diagnostics.log(
                    "hermes", "pins.server write failed (kept local): ${e.message?.take(80)}")
            }
        }
    }

    /**
     * Follow-ups typed while a turn streams, awaiting delivery per
     * conversation. Steer-first: the text rides into the RUNNING turn via
     * `POST /v1/runs/{id}/steer` (upstream Hermes v2026.8.13+), or the
     * patched `/api/sessions/{id}/steer` on older gateways. When neither
     * can steer (no route, 409 race, transport error) the message waits
     * here and goes out as an ordinary turn the moment the stream ends —
     * before the patch such a send was silently DROPPED by the streaming
     * guard (composer cleared, message gone).
     */
    private val pendingHermesFollowUps = mutableMapOf<String, MutableList<ChatMessage>>()

    /** `model/info` fetched this process (it moves on model change, not per sync). */
    private var hermesModelInfoFetched = false

    /** Steer the in-flight turn, or queue for delivery right after it. */
    private fun hermesSteerOrQueue(
        userMessage: ChatMessage, conversationId: String, sessionId: String
    ) {
        viewModelScope.launch {
            val runId = hermesRunIds[conversationId]
            val queued = try {
                withContext(Dispatchers.IO) {
                    val transport = HermesChatService.transport(settings)
                    // Upstream route first — it needs no gateway patch
                    // (v2026.8.13+). A gateway that predates it 404s the
                    // path, so retry the patched session route before
                    // giving up; that one also covers turns started
                    // elsewhere, where no run id ever reached us.
                    if (runId != null) {
                        try {
                            transport.steerRun(runId, userMessage.text)
                        } catch (_: Exception) {
                            transport.steer(sessionId, userMessage.text)
                        }
                    } else {
                        transport.steer(sessionId, userMessage.text)
                    }
                }
            } catch (e: Exception) {
                com.aispotlight.android.core.Diagnostics.log(
                    "hermes", "steer.fallback ${e.message?.take(120)}")
                false
            }
            if (queued) {
                // The agent sees the text inside the running turn — the
                // bubble lands in the chat now, exactly like a normal send.
                if (_activeConversationId.value == conversationId) {
                    _messages.value = _messages.value + userMessage
                    totalMessageCount += 1
                }
                dao.upsertMessage(userMessage.toEntity(conversationId))
                dao.touch(conversationId, System.currentTimeMillis())
            } else {
                // Not steerable: hold it; the stream-end hook re-dispatches
                // (the bubble appears then, in its true delivery order).
                pendingHermesFollowUps.getOrPut(conversationId) { mutableListOf() }
                    .add(userMessage)
            }
        }
    }

    /** Stream ended for [conversationId] — deliver any held follow-ups. */
    private fun deliverPendingHermesFollowUps(conversationId: String) {
        val held = pendingHermesFollowUps.remove(conversationId) ?: return
        if (_activeConversationId.value != conversationId) {
            // Conversation switched away mid-hold: requeue for its return.
            pendingHermesFollowUps[conversationId] = held
            return
        }
        held.firstOrNull()?.let { first ->
            if (held.size > 1) {
                // Coalesce: one turn carrying all held texts, in order.
                val joined = held.joinToString("\n\n") { it.text }
                hermesDispatch(first.copy(text = joined))
            } else {
                hermesDispatch(first)
            }
        }
    }

    /** Runs the agent send pipeline (the Hermes analog of [dispatch]). */
    private fun hermesDispatch(userMessage: ChatMessage) {
        val conversationId = _activeConversationId.value ?: return
        val conversation = activeConversation ?: return
        val sessionId = conversation.hermesSessionId ?: return
        if (conversation.id != conversationId) return
        if (conversationId in streamingIds.value) {
            // Turn in flight: steer it (text-only — attachments keep the
            // pre-steer behavior of waiting for the turn).
            if (userMessage.attachments.isEmpty()) {
                hermesSteerOrQueue(userMessage, conversationId, sessionId)
            }
            return
        }

        _errorText.value = null
        _messages.value = _messages.value + userMessage
        totalMessageCount += 1
        markStreaming(conversationId, true)
        _statusText.value = "Thinking…"
        val isFirst = _messages.value.count { it.isUser } == 1

        fun isActive() = _activeConversationId.value == conversationId

        val job = viewModelScope.launch {
            dao.upsertMessage(userMessage.toEntity(conversationId))
            for (attachment in userMessage.attachments) {
                dao.upsertAttachment(attachment.toEntity(userMessage.id))
            }
            val now = System.currentTimeMillis()
            if (isFirst) {
                // Session titles come from the first message (desktop 4.2) —
                // locally at once, on the gateway best-effort.
                val title = userMessage.text.ifEmpty { "Files" }.take(60)
                dao.setTitle(conversationId, title, now)
                launch(Dispatchers.IO) {
                    try {
                        HermesChatService.transport(settings).renameSession(sessionId, title)
                    } catch (_: Exception) { }
                }
            } else {
                dao.touch(conversationId, now)
            }

            val reply = ChatMessage(text = "", isUser = false)
            val replyText = StringBuilder()
            var segmentStart = 0
            var agentSteps: String? = null
            var lastUiFlush = 0L
            var persisted = false

            fun pushReply(error: Boolean = false) {
                if (!isActive()) return
                val updated = reply.copy(
                    text = replyText.toString().trimEnd('\n'),
                    agentSteps = agentSteps, isError = error,
                )
                val list = _messages.value
                val index = list.indexOfFirst { it.id == reply.id }
                _messages.value = if (index >= 0) {
                    list.toMutableList().also { it[index] = updated }
                } else {
                    list + updated
                }
            }

            suspend fun persistReply(error: Boolean = false) {
                val updated = reply.copy(
                    text = replyText.toString().trimEnd('\n'),
                    agentSteps = agentSteps, isError = error,
                )
                try {
                    dao.upsertMessage(updated.toEntity(conversationId))
                    persisted = true
                } catch (_: android.database.sqlite.SQLiteException) { }
            }

            // Foreground service for the whole turn: without it Android cuts
            // the SSE socket as soon as the app leaves the screen.
            com.aispotlight.android.hermes.HermesRunService.begin(getApplication())
            try {
                HermesChatService.streamTurn(
                    getApplication(), sessionId, userMessage.text, userMessage.attachments,
                ).collect { event ->
                    when (event) {
                        is HermesChatService.AgentEvent.Run ->
                            hermesRunIds[conversationId] = event.runID
                        is HermesChatService.AgentEvent.Text -> {
                            replyText.append(event.chunk)
                            if (isActive()) _statusText.value = null
                            val t = System.currentTimeMillis()
                            if (t - lastUiFlush > 33) {
                                lastUiFlush = t
                                pushReply()
                            }
                        }
                        is HermesChatService.AgentEvent.SegmentCompleted -> {
                            // Authoritative segment text replaces its deltas;
                            // interim messages glue through a blank line
                            // (fixtures: replacing with the last one lost text).
                            replyText.setLength(segmentStart)
                            replyText.append(event.content).append("\n\n")
                            segmentStart = replyText.length
                            pushReply()
                            persistReply()
                        }
                        is HermesChatService.AgentEvent.Status ->
                            if (isActive()) _statusText.value = event.text
                        is HermesChatService.AgentEvent.Steps -> {
                            agentSteps = event.summary
                            pushReply()
                        }
                        is HermesChatService.AgentEvent.SystemLine -> {
                            val line = ChatMessage(
                                text = event.text, isUser = false,
                                messageType = ChatMessage.Type.SYSTEM,
                            )
                            if (isActive()) _messages.value = _messages.value + line
                            totalMessageCount += 1
                            dao.upsertMessage(line.toEntity(conversationId))
                        }
                    }
                }
                if (replyText.isNotEmpty() || agentSteps != null) {
                    pushReply()
                    persistReply()
                    dao.touch(conversationId, System.currentTimeMillis())
                    if (isActive()) totalMessageCount = dao.messageCount(conversationId)
                }
                // Our turn is now the gateway transcript's tail — bump the
                // mirror watermark BEFORE releasing the streaming mark: an
                // async bump raced the onResume mirror sync, which slipped in
                // first and re-imported the fresh turn as duplicate bubbles
                // (live bug 2026-07-31).
                kotlinx.coroutines.withContext(Dispatchers.IO) {
                    HermesChatService.advanceWatermark(dao, conversationId, sessionId)
                }
                hermesRunIds.remove(conversationId)
                markStreaming(conversationId, false)
                // A reply that landed out of sight: unread badge + banner.
                if (!isActive()) {
                    _hermesUnread.value = _hermesUnread.value + conversationId
                }
                if (!isActive() || !com.aispotlight.android.NotificationService.appVisible) {
                    com.aispotlight.android.NotificationService.notifyAgentDone(
                        getApplication(), conversation.title, replyText.toString().trim().take(160),
                    )
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                if (replyText.isNotEmpty() && !persisted) {
                    kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable) { persistReply() }
                }
                hermesRunIds.remove(conversationId)
                markStreaming(conversationId, false)
                throw e
            } catch (e: Exception) {
                // A dropped socket is NOT a failed turn: the gateway usually
                // keeps executing the run (mobile networks flap, Doze cuts
                // sockets). Rebuild the reply from the session transcript
                // before admitting defeat.
                var recovered: HermesChatService.RecoveredTurn? = null
                if (e is java.io.IOException) {
                    if (isActive()) {
                        _statusText.value = getApplication<android.app.Application>()
                            .getString(com.aispotlight.android.R.string.hermes_reconnecting)
                    }
                    recovered = try {
                        HermesChatService.recoverTurn(
                            dao, conversationId, sessionId, userMessage.text,
                        ) { partial ->
                            replyText.setLength(0)
                            replyText.append(partial.text)
                            partial.steps?.let { agentSteps = it }
                            pushReply()
                        }
                    } catch (c: kotlinx.coroutines.CancellationException) {
                        if (replyText.isNotEmpty()) {
                            kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable) { persistReply() }
                        }
                        hermesRunIds.remove(conversationId)
                        markStreaming(conversationId, false)
                        throw c
                    } catch (_: Exception) {
                        null
                    }
                }
                if (recovered != null && recovered.text.isNotEmpty()) {
                    // The transcript is authoritative — it replaces whatever
                    // was streamed before the drop.
                    replyText.setLength(0)
                    replyText.append(recovered.text)
                    recovered.steps?.let { agentSteps = it }
                    if (isActive()) _statusText.value = null
                    pushReply()
                    persistReply()
                    dao.touch(conversationId, System.currentTimeMillis())
                    if (isActive()) totalMessageCount = dao.messageCount(conversationId)
                    hermesRunIds.remove(conversationId)
                    markStreaming(conversationId, false)
                    if (!isActive()) {
                        _hermesUnread.value = _hermesUnread.value + conversationId
                    }
                    if (!isActive() || !com.aispotlight.android.NotificationService.appVisible) {
                        com.aispotlight.android.NotificationService.notifyAgentDone(
                            getApplication(), conversation.title, replyText.toString().trim().take(160),
                        )
                    }
                } else {
                    if (isActive()) _statusText.value = null
                    val message = e.message ?: "Agent request failed."
                    if (replyText.isEmpty()) {
                        replyText.append(message)
                    } else {
                        replyText.append("\n\n⚠️ $message")
                    }
                    pushReply(error = true)
                    persistReply(error = true)
                    if (isActive()) totalMessageCount = dao.messageCount(conversationId)
                    hermesRunIds.remove(conversationId)
                    markStreaming(conversationId, false)
                }
            } finally {
                com.aispotlight.android.hermes.HermesRunService.end(getApplication())
                // Follow-ups the steer path had to hold (gateway without the
                // patch, 409 race) go out as an ordinary turn now.
                deliverPendingHermesFollowUps(conversationId)
            }
        }
        streamJobs[conversationId] = job
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
