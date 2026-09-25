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
                        "timezone": [
                            "type": "string",
                            "description": "Optional IANA timezone for date filters, e.g. America/Cancun. Defaults to this Mac's timezone."
                        ],
                        "query": [
                            "type": "string",
                            "description": "Case-insensitive substring match on the recording name."
                        ],
                        "date_from": [
                            "type": "string",
                            "description": "Start date inclusive, YYYY-MM-DD, in timezone (default: this Mac)."
                        ],
                        "date_to": [
                            "type": "string",
                            "description": "End date inclusive, YYYY-MM-DD."
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "Max recordings to return (default 20, max 100)."
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
                description: "Read a page of a recording transcript, outline or device marks. Results contain text and next_cursor; repeat with that cursor and the same selection until null to read the whole selection. Pages can split an utterance; concatenate text in order. Use from_min/to_min for a speech excerpt.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "file_id": [
                            "type": "string",
                            "description": "The recording ID from \(findToolName)."
                        ],
                        "version": [
                            "type": "string",
                            "enum": ["verbatim", "clean", "outline", "marks"],
                            "description": "Which version to read. \"verbatim\" (default) is the raw transcript — use it whenever exact wording matters (\"who said exactly what\", quotes). \"clean\" is Plaud's AI-cleaned transcript: same speakers and timecodes, fillers and stumbles removed, roughly a quarter shorter — better for summaries and for long recordings that would otherwise be truncated. \"outline\" is a short structural overview of the recording. \"marks\" contains the moments flagged with the device button, not speech. Read verbatim separately for quotes. Not every recording has every version; the result says which ones exist."
                        ],
                        "cursor": ["type": "string", "description": "next_cursor from the previous page. Keep file_id, version and minute range unchanged."],
                        "page_chars": ["type": "integer", "description": "Maximum text characters per page (default 12000, range 1–60000)."],
                        "from_min": [
                            "type": "number",
                            "description": "Optional: skip segments before this minute of the recording."
                        ],
                        "to_min": [
                            "type": "number",
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
    static func systemPromptHint(includeDate: Bool = true) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd (EEEE)"
        let dateContext = includeDate ? "Today is \(fmt.string(from: Date())). " : ""
        return """
You have tools for the user's Plaud voice recorder — their recorded meetings, calls, and memos with AI summaries and transcripts ("Plaud", "плауд"). \(dateContext)When the user asks about a recorded meeting or their notes, call \(findToolName) first to locate the recording, then \(noteToolName) — the summary tabs usually answer the question. Reach for \(transcriptToolName) only when the summary lacks the needed detail ("who exactly said…", verbatim quotes). Resolve relative dates ("last week") against today's date. Recordings marked "not processed" have no notes or transcript yet — processing them costs the user credits, so never suggest it happened automatically; mention such recordings in a separate line and point the user to the Plaud app (\(PlaudClient.webAppURL)) to process them. To put recordings in front of the user, end your reply with the line "\(AgentPlaudNote.header)" followed by one line per recording: "- plaud://<id> — <name>". The app replaces that block with clickable recording cards carrying the full notes, transcript, and audio. Reference exactly the recordings the reply is about — the one(s) an answer draws on, or every match when the user asked for a list — and never paste raw ids or long note contents into the prose; the cards carry them.
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
            case findToolName: return PlaudReadContract.untrusted(try await find(call.arguments))
            case noteToolName: return PlaudReadContract.untrusted(try await note(call.arguments))
            case transcriptToolName: return PlaudReadContract.untrusted(try await transcript(call.arguments))
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

    private static func find(_ args: [String: Any]) async throws -> String {
        let query = (args["query"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let dateFrom = args["date_from"] as? String
        let dateTo = args["date_to"] as? String
        if let from = dateFrom, !PlaudReadContract.validDay(from) { return "Invalid date_from — use a valid YYYY-MM-DD date." }
        if let to = dateTo, !PlaudReadContract.validDay(to) { return "Invalid date_to — use a valid YYYY-MM-DD date." }
        if let from = dateFrom, let to = dateTo, from > to { return "date_from must not be after date_to." }
        let zone: TimeZone
        if let name = args["timezone"] as? String {
            guard let parsed = TimeZone(identifier: name) else { return "Invalid IANA timezone." }
            zone = parsed
        } else { zone = .current }
        let hasFilters = !(query ?? "").isEmpty || dateFrom != nil || dateTo != nil
        let maxListed = min(max(args["limit"] as? Int ?? 20, 1), 100)
        var files: [[String: Any]] = []
        var exhausted = false
        let pageSize = hasFilters ? 100 : max(20, maxListed)
        for page in 1...(hasFilters ? filterPageLimit : 1) {
            try Task.checkCancellation()
            let batch = try await PlaudClient.shared.listFiles(page: page, pageSize: pageSize)
            files += batch
            if batch.count < pageSize { exhausted = true; break }
        }
        var unknownDates = 0
        var datedMatches = files.map { (file: $0, date: PlaudReadContract.timestamp($0["created_at"])) }.filter { entry in
            let file = entry.file
            if let query, !query.isEmpty,
               !(file["name"] as? String ?? "").lowercased().contains(query) { return false }
            if dateFrom != nil || dateTo != nil {
                guard let date = entry.date else {
                    unknownDates += 1
                    return false
                }
                let day = PlaudReadContract.day(date, zone: zone)
                if let from = dateFrom, day < from { return false }
                if let to = dateTo, day > to { return false }
            }
            return true
        }
        datedMatches.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        let matches = datedMatches.map { $0.file }
        let coverage = PlaudReadContract.coverage(scanned: files.count, exhausted: exhausted,
                                                  unknownDates: unknownDates, zone: zone)
        guard !matches.isEmpty else { return "No matching recordings in the searched portion.\n" + coverage }

        var lines: [String] = []
        for file in matches.prefix(maxListed) {
            lines.append(formatListLine(file, zone: zone))
            // NOT a chip: which recordings deserve a card is the MODEL's
            // call (plaud:// markers in its reply) — chipping every listed
            // recording flooded a "what does the latest note say?" answer
            // with the whole library (live, 2026-08-19). The meta cache is
            // still warmed so a marker resolves without a refetch.
            if let id = file["id"] as? String {
                PlaudNoteCache.updateMeta(
                    fileID: id,
                    name: file["name"] as? String ?? "(untitled)",
                    day: String((file["created_at"] as? String ?? "").prefix(10)),
                    duration: durationString(file["duration"])
                )
            }
        }
        var result = "Recordings (\(matches.count)):\n" + lines.joined(separator: "\n") + "\n" + coverage
        if matches.count > maxListed {
            result += "\n[Showing \(maxListed) of \(matches.count) — narrow the query or date range]"
        }
        result += "\n[Recordings appear to the user as clickable cards ONLY when your final reply references them as plaud://<id> markers — see the marker instructions in the system prompt. Reference exactly the recordings the reply is about: the one(s) an answer draws on, or every match when the user asked to browse. Do not paste raw ids or recording contents into the prose.]"
        return result
    }

    private static func formatListLine(_ file: [String: Any], zone: TimeZone) -> String {
        let name = file["name"] as? String ?? "(untitled)"
        let day = PlaudReadContract.timestamp(file["created_at"]).map { PlaudReadContract.day($0, zone: zone) } ?? "unknown date"
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
            let unprocessed = (file["source_list"] as? [[String: Any]] ?? []).isEmpty
            registerChip(fileID: fileID, title: recordingName, kind: unprocessed ? .unprocessed : .note)
            return header + (unprocessed
                ? "\nNo notes or transcript yet. Processing starts in the Plaud app (\(PlaudClient.webAppURL))."
                : "\nNo summary tabs available. Try plaud_get_transcript.")
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
            // correctness requirement. Same for the note's pictures: their
            // presigned links (the response's link map) die just as fast, so
            // they are downloaded into the cache now and the Markdown points
            // at the local copies from here on (PlaudImages).
            var content = await PlaudClient.resolveContent(of: item)
                .map(PlaudFormat.noteMarkdown(fromRaw:))
            if let resolved = content, resolved.contains("![") {
                content = await PlaudImages.localize(
                    markdown: resolved, fileID: fileID, file: file
                )
            }
            sections.append("## Tab: \(tabName)\n" + (content?.isEmpty == false
                ? content!
                : "(content unavailable or could not be loaded; try this tab again)"))
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

    private static func transcript(_ args: [String: Any]) async throws -> String {
        guard let fileID = args["file_id"] as? String, !fileID.isEmpty else {
            return "Missing \"file_id\" — find it with \(findToolName)."
        }
        guard let requested = PlaudSourceBlock.from(publicName: args["version"] as? String ?? "verbatim") else {
            return "Unknown version. Use verbatim, clean, outline or marks."
        }
        let (from, to) = try PlaudReadContract.minuteRange(args)
        if requested == .marks && (from != nil || to != nil) {
            return "Minute filters apply to speech segments, not device marks. Read marks without a minute range."
        }
        let file = try await PlaudClient.shared.getFile(fileID)
        let header = fileHeader(file)
        let recordingName = file["name"] as? String ?? "(untitled)"
        updateCachedMeta(fileID: fileID, file: file)
        let sourceList = file["source_list"] as? [[String: Any]] ?? []
        let available = PlaudSourceBlock.displayOrder.filter { block in
            sourceList.contains { ($0["data_type"] as? String) == block.rawValue }
        }
        guard !available.isEmpty else {
            let unprocessed = sourceList.isEmpty && (file["note_list"] as? [[String: Any]] ?? []).isEmpty
            registerChip(fileID: fileID, title: recordingName, kind: unprocessed ? .unprocessed : .note)
            return header + (unprocessed ? "\nNot processed yet. Open the Plaud app to process it."
                : "\nNo supported transcript blocks available; try plaud_get_note.")
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
        let text: String
        if requested == .marks {
            text = raw
            let markdown = await PlaudImages.localize(markdown: PlaudReadContract.marksMarkdown(raw),
                fileID: fileID, file: file)
            PlaudNoteCache.writeMarks(fileID: fileID, raw: raw, markdown: markdown)
        } else if let segments = PlaudFormat.transcriptSegments(fromRaw: raw) {
            PlaudNoteCache.writeSegmentTab(fileID: fileID, slug: requested.slug,
                title: requested.title, markdown: PlaudFormat.transcriptMarkdown(from: segments), rawSegments: raw)
            text = PlaudFormat.rows(from: segments).filter { row in
                (from == nil || row.startMs >= from! * 60_000)
                    && (to == nil || row.startMs <= to! * 60_000)
            }.map { row in
                let time = clockString(ms: row.startMs)
                return row.speaker.map { "[\(time)] \($0): \(row.text)" } ?? "[\(time)] \(row.text)"
            }.joined(separator: "\n")
        } else {
            if from != nil || to != nil { return header + "\nThis block has no timestamped segments; omit the minute range." }
            text = raw
            PlaudNoteCache.writeTab(fileID: fileID, tabName: requested.title, content: raw, slug: requested.slug)
        }
        let context = "\(fileID)|\(requested.rawValue)|\(from.map(String.init(describing:)) ?? "")|\(to.map(String.init(describing:)) ?? "")"
        let page = try PlaudReadContract.page(text: text, context: context, args: args)
        registerChip(fileID: fileID, title: recordingName, kind: .note)
        return header + "\nVersion: \(requested.publicName)\n" + page
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

}
