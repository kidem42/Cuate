package com.aispotlight.android.chat

import com.aispotlight.android.core.DocumentPreflight
import com.aispotlight.android.core.DocumentTextQuery
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.encryption.InvalidPasswordException
import com.tom_roush.pdfbox.text.PDFTextStripper
import org.xmlpull.v1.XmlPullParser
import java.io.File
import java.security.MessageDigest
import java.util.zip.ZipInputStream

/**
 * Local text extraction for document attachments — the data source of the
 * read_document tool and of the attach-turn text for providers without a
 * native document input. Everything runs on the phone: PdfBox for the PDF
 * text layer, the docx zip's document.xml for Word, plain text as is. No
 * cloud OCR for documents, by decision; scanned pages yield nothing here.
 */
object DocumentTextService {
    data class PdfInfo(val pageCount: Int, val isLocked: Boolean)

    /** Page count and password protection; null when PdfBox can't open the file. */
    fun pdfInfo(file: File): PdfInfo? = try {
        PDDocument.load(file).use { PdfInfo(it.numberOfPages, it.isEncrypted) }
    } catch (_: InvalidPasswordException) {
        PdfInfo(pageCount = 0, isLocked = true)
    } catch (_: Exception) {
        null
    }

    /** Hex SHA-256 of the file — the document identity for deduplication. */
    fun sha256Hex(file: File): String? = try {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        digest.digest().joinToString("") { "%02x".format(it) }
    } catch (_: Exception) {
        null
    }

    /**
     * Text with page markers, or null when the type can't be read locally or
     * nothing readable was found. Blocking — call off the main thread.
     */
    fun extract(file: File, mimeType: String): String? {
        val mime = mimeType.substringBefore(';').trim().lowercase()
        if (!DocumentPreflight.isLocallyReadable(mime)) return null
        return when (mime) {
            "application/pdf" -> extractPdf(file)
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document" -> extractDocx(file)
            else -> extractPlainText(file)
        }
    }

    private fun extractPdf(file: File): String? = try {
        PDDocument.load(file).use { document ->
            if (document.isEncrypted || document.numberOfPages == 0) return null
            val stripper = PDFTextStripper()
            var readable = false
            val pages = (1..document.numberOfPages).map { number ->
                stripper.startPage = number
                stripper.endPage = number
                val text = try { stripper.getText(document).trim() } catch (_: Exception) { "" }
                if (text.isNotEmpty()) readable = true
                text
            }
            if (readable) DocumentTextQuery.join(pages) else null
        }
    } catch (_: Exception) {
        null
    }

    /** Word 2007+: paragraphs from word/document.xml, no library needed. */
    private fun extractDocx(file: File): String? = try {
        var xml: ByteArray? = null
        ZipInputStream(file.inputStream().buffered()).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                if (entry.name == "word/document.xml") {
                    xml = zip.readBytes()
                    break
                }
            }
        }
        val bytes = xml ?: return null
        val parser = android.util.Xml.newPullParser()
        parser.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, false)
        parser.setInput(bytes.inputStream(), "UTF-8")
        val out = StringBuilder()
        var event = parser.eventType
        while (event != XmlPullParser.END_DOCUMENT) {
            when (event) {
                XmlPullParser.START_TAG -> when (parser.name) {
                    "w:tab" -> out.append('\t')
                    "w:br", "w:cr" -> out.append('\n')
                }
                XmlPullParser.TEXT -> out.append(parser.text)
                XmlPullParser.END_TAG -> if (parser.name == "w:p") out.append('\n')
            }
            event = parser.next()
        }
        val text = out.toString().trim()
        text.ifEmpty { null }
    } catch (_: Exception) {
        null
    }

    private fun extractPlainText(file: File): String? = try {
        val text = file.readText(Charsets.UTF_8).trim()
        text.ifEmpty { null }
    } catch (_: Exception) {
        null
    }
}
