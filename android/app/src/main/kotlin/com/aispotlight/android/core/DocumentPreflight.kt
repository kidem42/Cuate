package com.aispotlight.android.core

/**
 * Document attachments in ordinary chats: the file-type allowlist, the
 * per-message limits and the pre-flight that runs BEFORE any upload or
 * extraction. Port of the Mac `DocumentPreflight`; pure Kotlin so the unit
 * test covers it without Android.
 */
object DocumentPreflight {
    /** Documents per message (ours). */
    const val MAX_DOCUMENTS_PER_MESSAGE = 3
    /** OpenAI file inputs: 50 MB per file and 50 MB combined per request. */
    const val MAX_BYTES_PER_FILE = 50L * 1024 * 1024
    const val MAX_BYTES_PER_MESSAGE = 50L * 1024 * 1024
    /** From this page count the chip warns about the token cost. */
    const val LARGE_PDF_PAGES = 100
    /** A PDF above this rides as text even where the provider takes files inline (OpenRouter, base64 in the body). */
    const val MAX_INLINE_FILE_BYTES = 20L * 1024 * 1024
    /** Inline text caps on the attach turn: per document and per message. */
    const val INLINE_TEXT_CHARACTER_CAP = 60_000
    const val INLINE_TEXT_CHARACTER_CAP_PER_MESSAGE = 150_000

    /** Extension → MIME for everything the chat accepts as a document. */
    val mimeByExtension: Map<String, String> = mapOf(
        "pdf" to "application/pdf",
        "docx" to "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "doc" to "application/msword",
        "pptx" to "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "xlsx" to "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "xls" to "application/vnd.ms-excel",
        "txt" to "text/plain",
        "md" to "text/markdown",
        "markdown" to "text/markdown",
        "csv" to "text/csv",
        "json" to "application/json",
        "rtf" to "application/rtf",
    )

    /**
     * MIME types the phone can turn into text itself: PDF text layers
     * (PdfBox), Word 2007+ (the zip's document.xml), plain text. Legacy .doc,
     * RTF, spreadsheets and slide decks reach a model only natively (OpenAI).
     */
    val locallyReadableMimes: Set<String> = setOf(
        "application/pdf",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "text/plain",
        "text/markdown",
        "text/csv",
        "application/json",
    )

    fun mimeType(extension: String): String? = mimeByExtension[extension.lowercase()]

    /** Normalizes a content resolver MIME (may carry parameters or be generic). */
    fun documentMime(filename: String, resolverMime: String?): String? {
        val byExtension = mimeType(filename.substringAfterLast('.', ""))
        if (byExtension != null) return byExtension
        val mime = resolverMime?.substringBefore(';')?.trim()?.lowercase() ?: return null
        return if (isDocumentMime(mime)) mime else null
    }

    fun isDocumentMime(mime: String): Boolean =
        mimeByExtension.values.contains(mime.substringBefore(';').trim().lowercase())

    fun isPDF(mime: String): Boolean = mime.substringBefore(';').trim().lowercase() == "application/pdf"

    fun isLocallyReadable(mime: String): Boolean =
        locallyReadableMimes.contains(mime.substringBefore(';').trim().lowercase())

    sealed class Verdict {
        object Accepted : Verdict()
        data class TooManyDocuments(val limit: Int) : Verdict()
        data class FileTooLarge(val limitBytes: Long) : Verdict()
        data class MessageTooLarge(val limitBytes: Long) : Verdict()
        data class UnsupportedType(val extension: String) : Verdict()
        object EmptyFile : Verdict()
        object Encrypted : Verdict()
    }

    /** Checks ONE more document joining the documents already staged. */
    fun check(
        extension: String,
        bytes: Long,
        isEncrypted: Boolean,
        pendingDocumentCount: Int,
        pendingDocumentBytes: Long,
    ): Verdict {
        if (mimeType(extension) == null) return Verdict.UnsupportedType(extension.lowercase())
        if (bytes <= 0) return Verdict.EmptyFile
        if (isEncrypted) return Verdict.Encrypted
        if (bytes > MAX_BYTES_PER_FILE) return Verdict.FileTooLarge(MAX_BYTES_PER_FILE)
        if (pendingDocumentBytes + bytes > MAX_BYTES_PER_MESSAGE) return Verdict.MessageTooLarge(MAX_BYTES_PER_MESSAGE)
        if (pendingDocumentCount >= MAX_DOCUMENTS_PER_MESSAGE) return Verdict.TooManyDocuments(MAX_DOCUMENTS_PER_MESSAGE)
        return Verdict.Accepted
    }

    /** "1.2 MB" — for chips and refusal notes. */
    fun formattedSize(bytes: Long): String = when {
        bytes >= 1024L * 1024 -> String.format(java.util.Locale.US, "%.1f MB", bytes / (1024.0 * 1024.0))
        bytes >= 1024 -> "${bytes / 1024} KB"
        else -> "$bytes B"
    }
}
