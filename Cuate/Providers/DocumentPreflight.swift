import Foundation

/// Document attachments in ordinary chats: the file-type allowlist, the
/// per-message limits and the pre-flight that runs BEFORE any upload or
/// extraction. Pure Foundation on purpose — `scripts/DocumentContractTest.swift`
/// compiles it standalone together with `DocumentTextQuery`.
nonisolated enum DocumentPreflight {
    /// Documents per message (ours). Together with images the row still
    /// stays under `ChatWindow.maxPendingAttachments`.
    static let maxDocumentsPerMessage = 3
    /// OpenAI file inputs: 50 MB per file and 50 MB combined per request.
    /// Enforced for every provider — the local text path has no reason to
    /// take more, and one rule is easier to explain than two.
    static let maxBytesPerFile = 50 * 1024 * 1024
    static let maxBytesPerMessage = 50 * 1024 * 1024
    /// From this page count the chip warns about the token cost; sending is
    /// still allowed.
    static let largePDFPages = 100
    /// A PDF above this rides as extracted text even where the provider takes
    /// files inline (OpenRouter has no storage: the bytes go base64 in the
    /// request, and a 50 MB body on a phone is not worth the page images).
    static let maxInlineFileBytes = 20 * 1024 * 1024
    /// Inline text cap per document on the attach turn (non-native providers
    /// and the OpenAI fallback). The read_document tool serves the rest.
    static let inlineTextCharacterCap = 60_000
    /// …and across all documents of one message: ~60k tokens of Cyrillic at
    /// the app's 2.5 chars/token estimate, under half of a 128k window. The
    /// third document is what gets cut when three large ones arrive at once.
    static let inlineTextCharacterCapPerMessage = 150_000

    /// Extension → MIME for everything the chat accepts as a document. Images
    /// are deliberately absent: they keep their own path.
    static let mimeByExtension: [String: String] = [
        "pdf": "application/pdf",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "doc": "application/msword",
        "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "xls": "application/vnd.ms-excel",
        "txt": "text/plain",
        "md": "text/markdown",
        "markdown": "text/markdown",
        "csv": "text/csv",
        "json": "application/json",
        "rtf": "application/rtf",
    ]

    /// MIME types the Mac can turn into text itself (PDFKit, AppKit, plain
    /// text). Spreadsheets and slide decks reach a model only natively.
    static let locallyReadableMimes: Set<String> = [
        "application/pdf",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/msword",
        "application/rtf",
        "text/plain",
        "text/markdown",
        "text/csv",
        "application/json",
    ]

    static func mimeType(forExtension ext: String) -> String? {
        mimeByExtension[ext.lowercased()]
    }

    /// Whether a MIME type is one of the chat's document types.
    static func isDocumentMime(_ mime: String) -> Bool {
        mimeByExtension.values.contains(mime.lowercased())
    }

    static func isPDF(mime: String) -> Bool {
        mime.lowercased() == "application/pdf"
    }

    static func isLocallyReadable(mime: String) -> Bool {
        locallyReadableMimes.contains(mime.lowercased())
    }

    enum Verdict: Equatable {
        case accepted
        case tooManyDocuments(limit: Int)
        case fileTooLarge(limitBytes: Int)
        case messageTooLarge(limitBytes: Int)
        case unsupportedType(ext: String)
        case emptyFile
        case encrypted
    }

    /// Checks ONE more document joining the documents already staged for the
    /// message. `isEncrypted` is the caller's PDFKit answer (false for
    /// non-PDF files). Order matters: the cheapest, most actionable refusal
    /// wins (type before size, size before count).
    static func check(
        ext: String,
        bytes: Int,
        isEncrypted: Bool,
        pendingDocumentCount: Int,
        pendingDocumentBytes: Int
    ) -> Verdict {
        guard mimeType(forExtension: ext) != nil else {
            return .unsupportedType(ext: ext.lowercased())
        }
        if bytes <= 0 { return .emptyFile }
        if isEncrypted { return .encrypted }
        if bytes > maxBytesPerFile { return .fileTooLarge(limitBytes: maxBytesPerFile) }
        if pendingDocumentBytes + bytes > maxBytesPerMessage {
            return .messageTooLarge(limitBytes: maxBytesPerMessage)
        }
        if pendingDocumentCount >= maxDocumentsPerMessage {
            return .tooManyDocuments(limit: maxDocumentsPerMessage)
        }
        return .accepted
    }

    /// SF Symbol for a chip, by extension.
    static func iconName(forFilename filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "docx", "doc", "rtf": return "doc.text"
        case "pptx": return "rectangle.on.rectangle"
        case "xlsx", "xls", "csv": return "tablecells"
        case "json": return "curlybraces"
        case "md", "markdown", "txt": return "doc.plaintext"
        default: return "doc"
        }
    }

    /// "1.2 MB" — for chips and refusal notes.
    static func formattedSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB]
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
