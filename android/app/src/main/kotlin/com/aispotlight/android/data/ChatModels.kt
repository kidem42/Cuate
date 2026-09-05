package com.aispotlight.android.data

import java.util.UUID

/** UI-facing value type for an image attachment (the analog of `ChatAttachment` in Swift). */
data class ChatAttachment(
    val id: String = UUID.randomUUID().toString(),
    val filename: String,
    val mimeType: String,
    /** Path relative to the app's files directory. */
    val filePath: String,
    val ocrText: String? = null,
    /** PDF page count, read at attach time (chips, tool inventory). */
    val pageCount: Int? = null,
    /** Hex SHA-256 of the bytes — a re-attached identical file reuses the copy. */
    val contentHash: String? = null,
    /** Provider-side copy (OpenAI Files): id, holder, server-side expiry. */
    val remoteFileId: String? = null,
    val remoteProvider: String? = null,
    val remoteExpiresAt: Long? = null,
) {
    /** A document (PDF, Word, text, …) as opposed to an image. */
    val isDocument: Boolean
        get() = com.aispotlight.android.core.DocumentPreflight.isDocumentMime(mimeType)

    /** Uploaded and not past the server-side expiry. */
    val hasLiveRemoteFile: Boolean
        get() = !remoteFileId.isNullOrEmpty() &&
            (remoteExpiresAt == null || remoteExpiresAt > System.currentTimeMillis())
}

/** UI-facing value type for a chat message (the analog of `ChatMessage` in Swift). */
data class ChatMessage(
    val id: String = UUID.randomUUID().toString(),
    val text: String,
    val isUser: Boolean,
    val timestamp: Long = System.currentTimeMillis(),
    val messageType: Type = Type.TEXT,
    val toolContext: String? = null,
    val isError: Boolean = false,
    val attachments: List<ChatAttachment> = emptyList(),
    /** Relative path of a voice recording (messageType == VOICE). */
    val audioPath: String? = null,
    /** Agent replies: compact tool-step journal (see MessageEntity.agentSteps). */
    val agentSteps: String? = null,
    /** Pinned by the user (pin bar above the transcript). */
    val pinned: Boolean = false,
    /** When it was pinned — the bar cycles in pin order. */
    val pinnedAt: Long = 0,
) {
    enum class Type(val raw: String) {
        TEXT("text"), VOICE("voice"), SYSTEM("system");

        companion object {
            fun fromRaw(raw: String): Type = entries.firstOrNull { it.raw == raw } ?: TEXT
        }
    }
}

/** UI-facing value type for a conversation row. */
data class Conversation(
    val id: String = UUID.randomUUID().toString(),
    val title: String,
    val presetName: String?,
    val createdAt: Long = System.currentTimeMillis(),
    val updatedAt: Long = System.currentTimeMillis(),
    val summary: String? = null,
    val summaryCoversCount: Int = 0,
    /** Non-null = mirrors a Hermes Agent gateway session with that id. */
    val hermesSessionId: String? = null,
    /** Gateway-transcript watermark (see ConversationEntity.hermesSyncedSeq). */
    val hermesSyncedSeq: Int = 0,
) {
    val isHermes: Boolean get() = hermesSessionId != null
}

fun MessageEntity.toDomain(attachments: List<ChatAttachment> = emptyList()) = ChatMessage(
    id = id,
    text = text,
    isUser = isUser,
    timestamp = timestamp,
    messageType = ChatMessage.Type.fromRaw(messageType),
    toolContext = toolContext,
    isError = isError,
    attachments = attachments,
    audioPath = audioPath,
    agentSteps = agentSteps,
    pinned = pinned,
    pinnedAt = pinnedAt,
)

fun AttachmentEntity.toDomain() = ChatAttachment(
    id = id,
    filename = filename,
    mimeType = mimeType,
    filePath = filePath,
    ocrText = ocrText,
    pageCount = pageCount,
    contentHash = contentHash,
    remoteFileId = remoteFileId,
    remoteProvider = remoteProvider,
    remoteExpiresAt = remoteExpiresAt,
)

fun ChatAttachment.toEntity(messageId: String) = AttachmentEntity(
    id = id,
    messageId = messageId,
    filename = filename,
    mimeType = mimeType,
    filePath = filePath,
    ocrText = ocrText,
    pageCount = pageCount,
    contentHash = contentHash,
    remoteFileId = remoteFileId,
    remoteProvider = remoteProvider,
    remoteExpiresAt = remoteExpiresAt,
)

fun ChatMessage.toEntity(conversationId: String) = MessageEntity(
    id = id,
    conversationId = conversationId,
    text = text,
    isUser = isUser,
    timestamp = timestamp,
    messageType = messageType.raw,
    audioPath = audioPath,
    toolContext = toolContext,
    isError = isError,
    agentSteps = agentSteps,
    pinned = pinned,
    pinnedAt = pinnedAt,
)

fun ConversationEntity.toDomain() = Conversation(
    id = id,
    title = title,
    presetName = presetName,
    createdAt = createdAt,
    updatedAt = updatedAt,
    summary = summary,
    summaryCoversCount = summaryCoversCount,
    hermesSessionId = hermesSessionId,
    hermesSyncedSeq = hermesSyncedSeq,
)

fun Conversation.toEntity() = ConversationEntity(
    id = id,
    title = title,
    presetName = presetName,
    createdAt = createdAt,
    updatedAt = updatedAt,
    summary = summary,
    summaryCoversCount = summaryCoversCount,
    hermesSessionId = hermesSessionId,
    hermesSyncedSeq = hermesSyncedSeq,
)
