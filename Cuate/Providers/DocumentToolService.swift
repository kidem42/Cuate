import Foundation

/// The read_document tool: after the attach turn a document is no longer in
/// the request; the model opens it on demand through this tool, by name, a
/// page range or a query. Client-side like the calendar and Plaud tools —
/// free, keyless, every tool-capable provider.
@MainActor
enum DocumentToolService {
    static let toolName = "read_document"

    static func canHandle(_ name: String) -> Bool {
        name == toolName
    }

    // MARK: - Spec

    /// Empty when the conversation holds no live document — the caller then
    /// adds neither the tool nor the prompt hint.
    static func toolSpecs(store: ChatStore) -> [ToolSpec] {
        let documents = store.liveDocuments
        guard !documents.isEmpty else { return [] }
        let inventory = documents.map { "- \(inventoryLine($0))" }.joined(separator: "\n")
        return [ToolSpec(
            name: toolName,
            description: """
            Open a document the user attached earlier in this chat and return its text. \
            Documents available:
            \(inventory)
            Prefer a page range or a query over the whole file; results are capped at \
            \(DocumentTextQuery.maxResultCharacters) characters.
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "name": [
                        "type": "string",
                        "description": "File name as listed (case-insensitive; a unique prefix is enough)."
                    ],
                    "pages": [
                        "type": "string",
                        "description": "Page range to return, e.g. \"3-5\" or \"7\" (PDF only)."
                    ],
                    "query": [
                        "type": "string",
                        "description": "Return only paragraphs containing this text, with page numbers."
                    ]
                ],
                "required": ["name"]
            ]
        )]
    }

    static func systemPromptHint() -> String {
        """
        Documents the user attached earlier are listed in the read_document tool. Open one only \
        when the question needs its content; ask for a page range or a query rather than the \
        whole file when you can. If the user needs charts or images from a document, ask them \
        to re-attach it.
        """
    }

    static func statusLine(for call: ToolCall) -> String {
        let name = call.arguments["name"] as? String ?? ""
        return String(format: L("panel.readingDoc"), name)
    }

    // MARK: - Run

    static func run(_ call: ToolCall, store: ChatStore) async -> String {
        let documents = store.liveDocuments
        let requested = (call.arguments["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let document = match(requested, in: documents) else {
            let list = documents.map { "- \(inventoryLine($0))" }.joined(separator: "\n")
            return "No document named \"\(requested)\". Available:\n\(list)"
        }
        let pages = call.arguments["pages"] as? String
        let query = call.arguments["query"] as? String
        Diagnostics.log("files", "tool.read_document name=\(document.attachment.filename) pages=\(pages ?? "-") query=\(query.map { String($0.prefix(40)) } ?? "-")")

        guard let text = await cachedText(for: document, store: store) else {
            if DocumentPreflight.isLocallyReadable(mime: document.attachment.mimeType) {
                return "\(document.attachment.filename): no readable text in this file."
            }
            return "\(document.attachment.filename): not readable locally in this version. Ask the user to re-attach it if the provider can read it natively."
        }
        return DocumentTextQuery.render(
            name: document.attachment.filename, text: text, pageRange: pages, query: query
        )
    }

    // MARK: - Helpers

    /// Exact (case-insensitive) first, then prefix, then substring.
    private static func match(_ requested: String, in documents: [ChatStore.LiveDocument]) -> ChatStore.LiveDocument? {
        let needle = requested.lowercased()
        guard !needle.isEmpty else { return documents.count == 1 ? documents.first : nil }
        if let exact = documents.first(where: { $0.attachment.filename.lowercased() == needle }) { return exact }
        if let prefix = documents.first(where: { $0.attachment.filename.lowercased().hasPrefix(needle) }) { return prefix }
        return documents.first(where: { $0.attachment.filename.lowercased().contains(needle) })
    }

    private static func inventoryLine(_ document: ChatStore.LiveDocument) -> String {
        var parts = [document.attachment.filename]
        if let pages = document.attachment.pageCount {
            parts.append("\(pages) page\(pages == 1 ? "" : "s")")
        }
        parts.append(DocumentPreflight.formattedSize(document.sizeBytes))
        parts.append("attached \(Self.dayFormatter.string(from: document.attachedAt))")
        return parts.joined(separator: ", ")
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// The cached extraction, computed once and persisted on the attachment.
    static func cachedText(for document: ChatStore.LiveDocument, store: ChatStore) async -> String? {
        if let cached = document.attachment.ocrText, !cached.isEmpty { return cached }
        guard let data = document.attachment.data else { return nil }
        let languages = DocumentTextService.ocrLanguages()
        guard let text = await DocumentTextService.extract(
            data: data, mimeType: document.attachment.mimeType, ocrLanguages: languages
        ) else { return nil }
        store.updateAttachment(messageID: document.messageID, attachmentID: document.attachment.id) {
            $0.ocrText = text
        }
        return text
    }
}
