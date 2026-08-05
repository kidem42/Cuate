import Foundation

/// The PlaudAddon's bridge into the agentic tool loop (pattern:
/// `CalendarToolService`): builds the `ToolSpec`s advertised to the model
/// and executes the calls against the Plaud REST API.
///
/// Errors are returned as plain strings (never thrown): the model reads the
/// message and either self-corrects (bad ID, empty filter) or relays it to
/// the user.
@MainActor
enum PlaudToolService {

    // MARK: - Tool names

    static let findToolName = "plaud_find"
    static let noteToolName = "plaud_get_note"
    static let transcriptToolName = "plaud_get_transcript"

    static func canHandle(_ name: String) -> Bool {
        [findToolName, noteToolName, transcriptToolName].contains(name)
    }

    // MARK: - Tool specs

    static func toolSpecs() -> [ToolSpec] {
        guard PlaudAddon.shared.isAvailable else { return [] }
        return [
            ToolSpec(
                name: findToolName,
                description: "List or search the user's Plaud voice-recorder recordings (meetings, calls, memos). Optional filters: query (case-insensitive substring of the recording name), date_from/date_to (inclusive, on the recording date). Returns id, name, date, duration per recording, newest first. Recordings the user has not yet processed in Plaud carry no notes or transcript — they are marked accordingly.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Case-insensitive substring match on the recording name."
                        ],
                        "date_from": [
                            "type": "string",
                            "description": "Start date inclusive, YYYY-MM-DD."
                        ],
                        "date_to": [
                            "type": "string",
                            "description": "End date inclusive, YYYY-MM-DD."
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "Max recordings to return without filters (default 20, max 100)."
                        ]
                    ]
                ]
            ),
            ToolSpec(
                name: noteToolName,
                description: "Fetch the AI-generated notes of a Plaud recording — every summary tab (Summary, Highlights, action items, …) in Markdown. Try this BEFORE \(transcriptToolName): the summary usually already answers the question.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "file_id": [
                            "type": "string",
                            "description": "The recording ID from \(findToolName)."
                        ],
                        "tab": [
                            "type": "string",
                            "description": "Optional: return only the tab whose name matches (e.g. \"Summary\", \"Highlights\")."
                        ]
                    ],
                    "required": ["file_id"]
                ]
            ),
            ToolSpec(
                name: transcriptToolName,
                description: "Fetch the full timestamped transcript of a Plaud recording with speaker labels. Long — an hour of audio is tens of thousands of characters; use from_min/to_min to fetch only a slice when you know roughly where to look.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "file_id": [
                            "type": "string",
                            "description": "The recording ID from \(findToolName)."
                        ],
                        "version": [
                            "type": "string",
                            "enum": ["verbatim", "clean", "outline"],
                            "description": "Which version to read. \"verbatim\" (default) is the raw transcript — use it whenever exact wording matters (\"who said exactly what\", quotes). \"clean\" is Plaud's AI-cleaned transcript: same speakers and timecodes, fillers and stumbles removed, roughly a quarter shorter — better for summaries and for long recordings that would otherwise be truncated. \"outline\" is a short structural overview of the recording. Not every recording has every version; the result says which ones exist."
                        ],
                        "from_min": [
                            "type": "integer",
                            "description": "Optional: skip segments before this minute of the recording."
                        ],
                        "to_min": [
                            "type": "integer",
                            "description": "Optional: skip segments after this minute of the recording."
                        ]
                    ],
                    "required": ["file_id"]
                ]
            ),
        ]
    }

    /// Usage hint appended to the system prompt at request time, only when
    /// `toolSpecs()` is non-empty. CACHE-CRITICAL: stable within a day (same
    /// contract as CalendarToolService.systemPromptHint) — no wall clock.
    static func systemPromptHint() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd (EEEE)"
        return """
You have tools for the user's Plaud voice recorder — their recorded meetings, calls, and memos with AI summaries and transcripts ("Plaud", "плауд"). Today is \(fmt.string(from: Date())). When the user asks about a recorded meeting or their notes, call \(findToolName) first to locate the recording, then \(noteToolName) — the summary tabs usually answer the question. Reach for \(transcriptToolName) only when the summary lacks the needed detail ("who exactly said…", verbatim quotes). Resolve relative dates ("last week") against today's date. Recordings marked "not processed" have no notes or transcript yet — processing them costs the user credits, so never suggest it happened automatically; mention such recordings in a separate line and point the user to the Plaud app (\(PlaudClient.webAppURL)) to process them. When presenting recordings, show name, date, duration, and keep the id available for follow-ups.
"""
    }

    /// Extra hint for a turn the user opened with "/plaud …" — the command
    /// is a promise that the answer lives in the recordings.
    static func invokedPromptHint() -> String {
        "The user's message starts with \"/plaud\" — an explicit command to answer FROM their Plaud recordings. Treat the rest of the message as the query: call \(findToolName) right away and ground the entire answer in the recordings; do not answer from general knowledge. Ignore the \"/plaud\" prefix itself when reading the question."
    }

    /// Status line for the chat panel while a call runs.
    static func statusLine(for call: ToolCall) -> String {
        switch call.name {
        case findToolName:
            let query = call.arguments["query"] as? String
            return query.map { "\(PLL("plaud.status.searching")): \($0)" } ?? PLL("plaud.status.listing")
        case noteToolName: return PLL("plaud.status.readingNote")
        case transcriptToolName: return PLL("plaud.status.readingTranscript")
        default: return PLL("plaud.status.listing")
        }
    }

    // MARK: - Chips (attachments for the reply bubble)

    /// Notes and transcripts the model actually read this turn, materialized
    /// as file-backed attachments so the reply bubble grows clickable chips
    /// with a full-fidelity preview. ChatService drains this after each Plaud
    /// call and forwards the batch as a `.attachments` event.
    ///
    /// Chip metadata rides IN THE FILE PATH (`PlaudNotes/<fileID>__<kind>__
    /// <slug>.md`) — `ChatAttachment`/`SDAttachment` have no metadata field
    /// and a SwiftData schema change is not worth one enum.
    private static var pendingChips: [ChatAttachment] = []

    static func takePendingAttachments() -> [ChatAttachment] {
        defer { pendingChips = [] }
        return pendingChips
    }

    /// Chip kinds encoded in the path. `unprocessed` chips carry no payload —
    /// clicking one deep-links into Plaud where processing can be started.
    /// (`transcript` survives only for chips persisted by earlier builds.)
    enum ChipKind: String {
        case note
        case transcript
        case unprocessed
    }

    /// ONE chip per recording per turn — the preview window offers every
    /// cached tab plus the transcript, so per-tab chips would only clone the
    /// row. The chip's payload path is the recording's meta file; contents
    /// live in the per-tab cache next to it.
    private static func registerChip(fileID: String, title: String, kind: ChipKind) {
        let relative = PlaudNoteCache.metaRelativePath(fileID: fileID, kind: kind.rawValue)
        guard !pendingChips.contains(where: { $0.fileURLString == relative }) else { return }
        pendingChips.append(ChatAttachment(
            filename: title, mimeType: "text/markdown", base64: "", fileURLString: relative
        ))
    }

    // MARK: - Dispatch

    /// The grant died mid-turn (or before it). Retrying is pointless — only
    /// a browser sign-in fixes it — so the result spells out both the stop
    /// and the one thing the user has to do; otherwise the model just burns
    /// tool turns and the user gets an answer that never mentions Plaud.
    private static let sessionExpiredResult = """
    Plaud session expired: the saved sign-in is no longer valid and the account has been disconnected. \
    Do NOT retry this or any other Plaud tool in this conversation. \
    Tell the user, in their language, that the Plaud session expired and that they need to reconnect the account in Settings → Plaud, \
    then answer whatever else you can without Plaud data.
    """

    static func run(_ call: ToolCall) async -> String {
        guard PlaudAddon.shared.isAvailable else {
            if PlaudSettings.shared.needsReauth { return sessionExpiredResult }
            return "Plaud is not connected (addon disabled or account not linked)."
        }
        do {
            switch call.name {
            case findToolName: return try await find(call.arguments)
            case noteToolName: return try await note(call.arguments)
            case transcriptToolName: return try await transcript(call.arguments)
            default: return "Unknown Plaud tool: \(call.name)"
            }
        } catch let error as PlaudClient.PlaudError where error.isSessionExpired {
            return sessionExpiredResult
        } catch {
            return "Plaud request failed: \(error.localizedDescription)"
        }
    }

    // MARK: - plaud_find

    /// Server-side filtering does not exist — when any filter is set we walk
    /// up to 5 pages × 100 and filter client-side (the official MCP does the
    /// same). Without filters one page suffices.
    private static let filterPageLimit = 5
    private static let maxListed = 30

    private static func find(_ args: [String: Any]) async throws -> String {
        let query = (args["query"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let dateFrom = args["date_from"] as? String
        let dateTo = args["date_to"] as? String
        if let from = dateFrom, !isDay(from) { return "Invalid date_from — use YYYY-MM-DD." }
        if let to = dateTo, !isDay(to) { return "Invalid date_to — use YYYY-MM-DD." }
        let hasFilters = !(query ?? "").isEmpty || dateFrom != nil || dateTo != nil

        var files: [[String: Any]] = []
        if hasFilters {
            for page in 1...filterPageLimit {
                let batch = try await PlaudClient.shared.listFiles(page: page, pageSize: 100)
                files += batch
                if batch.count < 100 { break }
            }
        } else {
            let limit = min(max(args["limit"] as? Int ?? 20, 1), 100)
            files = try await PlaudClient.shared.listFiles(page: 1, pageSize: limit)
        }

        var matches = files.filter { file in
            if let query, !query.isEmpty {
                let name = (file["name"] as? String ?? "").lowercased()
                guard name.contains(query) else { return false }
            }
            let day = String((file["created_at"] as? String ?? "").prefix(10))
            if let from = dateFrom, day < from { return false }
            if let to = dateTo, day > to { return false }
            return true
        }
        // Server order is already newest-first; keep it stable regardless.
        matches.sort { (($0["created_at"] as? String) ?? "") > (($1["created_at"] as? String) ?? "") }

        guard !matches.isEmpty else {
            return hasFilters
                ? "No recordings match. Try a shorter query keyword or a wider date range."
                : "No recordings in the Plaud library."
        }

        var lines: [String] = []
        for file in matches.prefix(maxListed) {
            lines.append(formatListLine(file))
            // Every found recording becomes a clickable chip under the
            // reply — the preview window fetches tabs/transcript on open,
            // so no upfront note reads are needed for a browsable list.
            if let id = file["id"] as? String {
                PlaudNoteCache.updateMeta(
                    fileID: id,
                    name: file["name"] as? String ?? "(untitled)",
                    day: String((file["created_at"] as? String ?? "").prefix(10)),
                    duration: durationString(file["duration"])
                )
                registerChip(fileID: id, title: file["name"] as? String ?? "(untitled)", kind: .note)
            }
        }
        var result = "Recordings (\(matches.count)):\n" + lines.joined(separator: "\n")
        if matches.count > maxListed {
            result += "\n[Showing \(maxListed) of \(matches.count) — narrow the query or date range]"
        }
        result += "\n[Each listed recording is attached to your reply as a clickable card — do not paste raw IDs or full contents into the answer; give a short readable list and point to the cards.]"
        return result
    }

    private static func formatListLine(_ file: [String: Any]) -> String {
        let name = file["name"] as? String ?? "(untitled)"
        let day = String((file["created_at"] as? String ?? "").prefix(10))
        let duration = durationString(file["duration"])
        let id = file["id"] as? String ?? "?"
        return "\(day) | \(duration) | \"\(name)\" | id=\(id)"
    }

    // MARK: - plaud_get_note

    /// Whole-note budget: several tabs of Markdown fit comfortably; a
    /// runaway payload must not evict the conversation.
    private static let maxNoteChars = 30_000

    private static func note(_ args: [String: Any]) async throws -> String {
        guard let fileID = args["file_id"] as? String, !fileID.isEmpty else {
            return "Missing \"file_id\" — find it with \(findToolName)."
        }
        let file = try await PlaudClient.shared.getFile(fileID)
        let header = fileHeader(file)
        let recordingName = file["name"] as? String ?? "(untitled)"
        updateCachedMeta(fileID: fileID, file: file)
        let noteList = file["note_list"] as? [[String: Any]] ?? []
        guard !noteList.isEmpty else {
            registerChip(fileID: fileID, title: recordingName, kind: .unprocessed)
            return header + "\nThis recording is NOT processed yet — no notes exist. Processing starts in the Plaud app (\(PlaudClient.webAppURL)) and uses the user's Plaud credits."
        }

        let tabFilter = (args["tab"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var sections: [String] = []
        var availableTabs: [String] = []
        for item in noteList {
            let tabName = item["data_tab_name"] as? String
                ?? item["data_title"] as? String
                ?? item["data_type"] as? String
                ?? "Note"
            availableTabs.append(tabName)
            if let tabFilter, !tabFilter.isEmpty {
                let type = (item["data_type"] as? String ?? "").lowercased()
                guard tabName.lowercased().contains(tabFilter) || type.contains(tabFilter) else {
                    continue
                }
            }
            // data_link is presigned with a ~5-minute TTL — resolving right
            // here, inside the same tool call, is not an optimization but a
            // correctness requirement.
            let content = await PlaudClient.resolveContent(of: item)
                .map(PlaudFormat.noteMarkdown(fromRaw:))
            sections.append("## Tab: \(tabName)\n" + (content?.isEmpty == false
                ? content!
                : "(this tab has no content)"))
            if let content, !content.isEmpty {
                PlaudNoteCache.writeTab(fileID: fileID, tabName: tabName, content: content)
                registerChip(fileID: fileID, title: recordingName, kind: .note)
            }
        }

        if sections.isEmpty {
            return header + "\nNo tab matches \"\(tabFilter ?? "")\". Available tabs: \(availableTabs.joined(separator: ", "))."
        }
        var result = header + "\nTabs: \(availableTabs.joined(separator: ", "))\n\n"
            + sections.joined(separator: "\n\n")
        if result.count > maxNoteChars {
            result = String(result.prefix(maxNoteChars)) + "\n[Truncated — request a single tab via the \"tab\" parameter]"
        }
        return result
    }

    // MARK: - plaud_get_transcript

    /// A generous budget — transcripts are the whole point — but still a
    /// budget: an hour of audio can exceed 80k chars.
    private static let maxTranscriptChars = 60_000

    private static func transcript(_ args: [String: Any]) async throws -> String {
        guard let fileID = args["file_id"] as? String, !fileID.isEmpty else {
            return "Missing \"file_id\" — find it with \(findToolName)."
        }
        let requested = (args["version"] as? String).flatMap(PlaudSourceBlock.from(publicName:))
            ?? .transaction
        let file = try await PlaudClient.shared.getFile(fileID)
        let header = fileHeader(file)
        let recordingName = file["name"] as? String ?? "(untitled)"
        updateCachedMeta(fileID: fileID, file: file)
        let sourceList = file["source_list"] as? [[String: Any]] ?? []
        let available = PlaudSourceBlock.displayOrder.filter { block in
            sourceList.contains { ($0["data_type"] as? String) == block.rawValue }
        }
        guard !available.isEmpty else {
            registerChip(fileID: fileID, title: recordingName, kind: .unprocessed)
            return header + "\nThis recording has no transcript — it is not processed yet. Processing starts in the Plaud app (\(PlaudClient.webAppURL)) and uses the user's Plaud credits."
        }
        guard let block = available.first(where: { $0 == requested }),
              let item = sourceList.first(where: { ($0["data_type"] as? String) == block.rawValue }) else {
            // Plaud fills the versions per recording — say what IS there
            // instead of letting the model conclude the recording is empty.
            return header + "\nThe \"\(requested.publicName)\" version does not exist for this recording. Available: \(available.map(\.publicName).joined(separator: ", ")). Call again with one of those."
        }
        guard let raw = await PlaudClient.resolveContent(of: item) else {
            return header + "\nTranscript content could not be loaded — try again."
        }
        // `outline` (and anything Plaud changes later) may be prose rather
        // than an utterance list — serve it as-is instead of failing.
        guard let segments = PlaudFormat.transcriptSegments(fromRaw: raw) else {
            PlaudNoteCache.writeTab(
                fileID: fileID, tabName: block.title, content: raw, slug: block.slug
            )
            registerChip(fileID: fileID, title: recordingName, kind: .note)
            var result = header + "\n\(block.publicName):\n" + raw
            if result.count > maxTranscriptChars {
                result = String(result.prefix(maxTranscriptChars)) + "\n[Truncated]"
            }
            return result
        }

        let fromMs = (args["from_min"] as? Int).map { Double($0) * 60_000 }
        let toMs = (args["to_min"] as? Int).map { Double($0) * 60_000 }
        var lines: [String] = []
        for row in PlaudFormat.rows(from: segments) {
            if let fromMs, row.startMs < fromMs { continue }
            if let toMs, row.startMs > toMs { break }
            let time = clockString(ms: row.startMs)
            // The outline has no speakers — labelling its topics "Speaker:"
            // told the model a lie about the shape of the data.
            lines.append(row.speaker.map { "[\(time)] \($0): \(row.text)" }
                ?? "[\(time)] \(row.text)")
        }
        guard !lines.isEmpty else {
            return header + "\nNo transcript segments in the requested minute range."
        }
        var result = header + "\nTranscript (\(block.publicName))"
        if fromMs != nil || toMs != nil {
            result += " (minutes \(args["from_min"] as? Int ?? 0)–\((args["to_min"] as? Int).map(String.init) ?? "end"))"
        }
        result += ":\n" + lines.joined(separator: "\n")
        if result.count > maxTranscriptChars {
            result = String(result.prefix(maxTranscriptChars))
                + "\n[Truncated — use from_min/to_min to fetch a narrower slice"
                + (block == .transaction && available.contains(.transactionPolish)
                   ? ", or read version=\"clean\" which is shorter]" : "]")
        }
        // The chip always carries the FULL transcript regardless of the
        // range/budget the model requested — the preview is for the human.
        PlaudNoteCache.writeSegmentTab(
            fileID: fileID,
            slug: block.slug,
            title: block.title,
            markdown: PlaudFormat.transcriptMarkdown(from: segments),
            rawSegments: raw
        )
        registerChip(fileID: fileID, title: recordingName, kind: .note)
        return result
    }

    // MARK: - Formatting helpers

    /// One header block shared by note/transcript results, so the model
    /// always knows WHICH recording it is reading.
    private static func fileHeader(_ file: [String: Any]) -> String {
        let name = file["name"] as? String ?? "(untitled)"
        let day = String((file["created_at"] as? String ?? "").prefix(10))
        let duration = durationString(file["duration"])
        let id = file["id"] as? String ?? "?"
        return "Recording \"\(name)\" | \(day) | \(duration) | id=\(id)"
    }

    /// Keeps the recording's cached meta fresh for the preview window.
    private static func updateCachedMeta(fileID: String, file: [String: Any]) {
        PlaudNoteCache.updateMeta(
            fileID: fileID,
            name: file["name"] as? String ?? "(untitled)",
            day: String((file["created_at"] as? String ?? "").prefix(10)),
            duration: durationString(file["duration"])
        )
    }

    private static func durationString(_ raw: Any?) -> String {
        PlaudFormat.durationString(raw)
    }

    private static func clockString(ms: Double) -> String {
        PlaudFormat.clockString(ms: ms)
    }

    private static func isDay(_ s: String) -> Bool {
        s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }
}
