import Foundation
import SwiftData

// MARK: - SwiftData models
//
// The chat history moved off a monolithic JSON file onto SwiftData (SQLite
// underneath). The UI still speaks `ChatMessage`/`ChatAttachment` value types —
// these `@Model` rows are an internal storage detail that `ChatStore` maps to
// and from. Benefits over the old scheme: incremental per-row writes instead of
// re-encoding the whole conversation on every save, media kept as files (already
// true after the attachment change), and windowed fetches become possible.

@Model
final class SDConversation {
    /// Same identity the old files used: "general", or the 16-hex preset hash.
    @Attribute(.unique) var key: String
    var summary: String?
    var summaryCoversCount: Int
    var updatedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \SDMessage.conversation)
    var messages: [SDMessage]

    init(key: String, summary: String? = nil, summaryCoversCount: Int = 0, updatedAt: Date = Date()) {
        self.key = key
        self.summary = summary
        self.summaryCoversCount = summaryCoversCount
        self.updatedAt = updatedAt
        self.messages = []
    }
}

@Model
final class SDMessage {
    @Attribute(.unique) var id: UUID
    var text: String
    var isUser: Bool
    var timestamp: Date
    var typeRaw: String
    var audioURLString: String?
    /// Explicit order within the conversation — SwiftData relationships are
    /// unordered, and two messages can share a timestamp during fast streaming.
    var sortIndex: Int
    var conversation: SDConversation?
    @Relationship(deleteRule: .cascade, inverse: \SDAttachment.message)
    var attachments: [SDAttachment]

    init(id: UUID, text: String, isUser: Bool, timestamp: Date,
         typeRaw: String, audioURLString: String?, sortIndex: Int) {
        self.id = id
        self.text = text
        self.isUser = isUser
        self.timestamp = timestamp
        self.typeRaw = typeRaw
        self.audioURLString = audioURLString
        self.sortIndex = sortIndex
        self.attachments = []
    }
}

@Model
final class SDAttachment {
    @Attribute(.unique) var id: UUID
    var filename: String
    var mimeType: String
    /// Legacy inline payload — empty for file-backed attachments (the norm now).
    var base64: String
    var fileURLString: String?
    var sortIndex: Int
    var message: SDMessage?

    init(id: UUID, filename: String, mimeType: String, base64: String,
         fileURLString: String?, sortIndex: Int) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.base64 = base64
        self.fileURLString = fileURLString
        self.sortIndex = sortIndex
    }
}

// MARK: - Struct ⇄ model conversion

extension ChatMessage {
    /// Builds a detached `SDMessage` (plus its attachments) from this value.
    /// The caller inserts it into a context and wires `conversation`.
    func toSDMessage(sortIndex: Int) -> SDMessage {
        let row = SDMessage(
            id: id, text: text, isUser: isUser, timestamp: timestamp,
            typeRaw: messageType.rawValue, audioURLString: audioURL?.absoluteString,
            sortIndex: sortIndex
        )
        row.attachments = attachments.enumerated().map { index, attachment in
            SDAttachment(
                id: attachment.id, filename: attachment.filename, mimeType: attachment.mimeType,
                base64: attachment.base64, fileURLString: attachment.fileURLString, sortIndex: index
            )
        }
        return row
    }
}

extension SDMessage {
    func toStruct() -> ChatMessage {
        let atts = attachments
            .sorted { $0.sortIndex < $1.sortIndex }
            .map { ChatAttachment(filename: $0.filename, mimeType: $0.mimeType, base64: $0.base64, id: $0.id, fileURLString: $0.fileURLString) }
        return ChatMessage(
            id: id, text: text, isUser: isUser, timestamp: timestamp,
            messageType: ChatMessage.MessageType(rawValue: typeRaw) ?? .text,
            audioURL: audioURLString.flatMap { URL(string: $0) },
            attachments: atts
        )
    }
}

// MARK: - Persistence layer
//
// Stateless static surface over SwiftData. Every operation runs on one serial
// queue with a freshly created (non-Sendable) `ModelContext` confined to that
// block — this mirrors the old serial `diskQueue` so ordering is preserved
// (a switch flushes conversation A, then loads B), and sidesteps SwiftData's
// non-Sendable context entirely: only value types cross the queue boundary.

nonisolated enum ChatPersistence {

    /// Snapshot handed back to the store after a load (value types only).
    struct Loaded {
        let messages: [ChatMessage]
        let summary: String?
        let summaryCoversCount: Int
        let existed: Bool
        let prunedMedia: Bool
        /// Absolute index of `messages.first` within the stored conversation —
        /// > 0 when older rows stayed in the store (windowed load).
        let windowStart: Int
    }

    /// How many newest messages the initial load materializes. Everything the
    /// API context needs verbatim (rows past `summaryCoversCount`) is always
    /// included on top of this, so the window can only be wider, never
    /// narrower, than the active context.
    static let initialWindowCount = 120

    /// Legacy on-disk shape, for one-time migration off the JSON files.
    private struct LegacyChat: Codable {
        var messages: [ChatMessage]
        var conversationSummary: String?
        var summaryCoversCount: Int
    }

    static let container: ModelContainer = {
        let schema = Schema([SDConversation.self, SDMessage.self, SDAttachment.self])
        let url = ChatStore.baseDirectory.appendingPathComponent("AISpotlightChats.store")
        let config = ModelConfiguration(schema: schema, url: url)
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            // A corrupt store must not brick launch: move it aside and retry
            // once with a fresh store (the JSON .migrated backups still exist).
            let aside = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: aside)
            if let retried = try? ModelContainer(for: schema, configurations: config) {
                return retried
            }
            // Even the fresh store failed (e.g. the corrupt file could not be
            // moved because something holds it): fall back to an in-memory
            // store — history is unavailable this session, but the app runs.
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: memory)
        }
    }()

    private static let queue = DispatchQueue(label: "AISpotlight.ChatPersistence", qos: .utility)

    // MARK: Fetch helpers (call inside `queue` only)

    private static func fetchConversation(key: String, in ctx: ModelContext) -> SDConversation? {
        var descriptor = FetchDescriptor<SDConversation>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return (try? ctx.fetch(descriptor))?.first
    }

    private static func fetchOrCreateConversation(key: String, in ctx: ModelContext) -> SDConversation {
        if let existing = fetchConversation(key: key, in: ctx) { return existing }
        let created = SDConversation(key: key)
        ctx.insert(created)
        return created
    }

    // MARK: Load

    /// Loads a conversation off the main thread and hands back value types.
    /// Windowed: only the newest `initialWindowCount` rows (plus everything
    /// the summary does not cover — the API context needs those verbatim) are
    /// materialized; older rows stay in the store and are paged in on demand
    /// (`loadOlderMessages`). Media retention runs against the STORE first,
    /// so rows outside the window age out too. `completion` runs on the
    /// persistence queue — the caller hops to main.
    static func load(key: String, mediaExpiredText: String, completion: @escaping (Loaded) -> Void) {
        queue.async {
            let ctx = ModelContext(container)
            guard let convo = fetchConversation(key: key, in: ctx) else {
                completion(Loaded(messages: [], summary: nil, summaryCoversCount: 0,
                                  existed: false, prunedMedia: false, windowStart: 0))
                return
            }
            var pruned = applyStoreRetention(key: key, in: ctx, mediaExpiredText: mediaExpiredText)

            let predicate = #Predicate<SDMessage> { $0.conversation?.key == key }
            let total = (try? ctx.fetchCount(FetchDescriptor(predicate: predicate))) ?? 0
            let coversCount = max(0, min(convo.summaryCoversCount, total))
            let windowStart = min(max(0, total - initialWindowCount), coversCount)

            var descriptor = FetchDescriptor<SDMessage>(
                predicate: predicate,
                sortBy: [SortDescriptor(\.sortIndex, order: .forward)]
            )
            descriptor.fetchOffset = windowStart
            var structs = ((try? ctx.fetch(descriptor)) ?? []).map { $0.toStruct() }

            // Dangling voice references in the window (file gone, e.g. system
            // cleanup): strip and mark pruned so the next save persists it.
            for index in structs.indices {
                if let audioURL = structs[index].audioURL,
                   !FileManager.default.fileExists(atPath: audioURL.path) {
                    structs[index].audioURL = nil
                    pruned = true
                }
            }
            completion(Loaded(
                messages: structs,
                summary: convo.summary,
                summaryCoversCount: coversCount,
                existed: true,
                prunedMedia: pruned,
                windowStart: windowStart
            ))
        }
    }

    /// Fetches the page of `limit` rows immediately preceding `windowStart`
    /// (backfill when the user scrolls to the top of the loaded window).
    /// `completion` runs on the persistence queue.
    static func loadOlderMessages(key: String, before windowStart: Int, limit: Int,
                                  completion: @escaping ([ChatMessage]) -> Void) {
        queue.async {
            let ctx = ModelContext(container)
            let predicate = #Predicate<SDMessage> {
                $0.conversation?.key == key && $0.sortIndex < windowStart
            }
            let olderCount = (try? ctx.fetchCount(FetchDescriptor(predicate: predicate))) ?? 0
            var descriptor = FetchDescriptor<SDMessage>(
                predicate: predicate,
                sortBy: [SortDescriptor(\.sortIndex, order: .forward)]
            )
            descriptor.fetchOffset = max(0, olderCount - limit)
            completion(((try? ctx.fetch(descriptor)) ?? []).map { $0.toStruct() })
        }
    }

    // MARK: Save (debounced full-sync of the current conversation)

    /// Reconciles the store's row set for `key` with `messages` — upsert present,
    /// delete absent. O(n) in message count, but each row is small (media lives
    /// as files), so this replaces the old whole-conversation JSON re-encode.
    /// `windowStart` scopes the reconcile: `messages` is the loaded suffix of
    /// the conversation, so only rows at `sortIndex >= windowStart` are
    /// compared/deleted — rows before the window are untouched (deleting them
    /// was exactly how a windowed save would silently wipe old history).
    static func sync(key: String, messages: [ChatMessage], summary: String?, summaryCoversCount: Int, windowStart: Int) {
        queue.async {
            let ctx = ModelContext(container)
            let convo = fetchOrCreateConversation(key: key, in: ctx)
            convo.summary = summary
            convo.summaryCoversCount = summaryCoversCount
            convo.updatedAt = Date()

            var existing = [UUID: SDMessage]()
            for row in convo.messages where row.sortIndex >= windowStart { existing[row.id] = row }
            let desiredIDs = Set(messages.map { $0.id })

            for (offset, message) in messages.enumerated() {
                let index = windowStart + offset // absolute position in the conversation
                if let row = existing[message.id] {
                    if row.text != message.text { row.text = message.text }
                    if row.sortIndex != index { row.sortIndex = index }
                    // Retention nils out an aged voice message's audio; without
                    // syncing this the row keeps a stale path to a deleted file
                    // and every later load re-detects it as dangling → redundant
                    // re-prune/re-save on every open.
                    let audioString = message.audioURL?.absoluteString
                    if row.audioURLString != audioString { row.audioURLString = audioString }
                    reconcileAttachments(of: row, with: message, in: ctx)
                } else {
                    let row = message.toSDMessage(sortIndex: index)
                    row.conversation = convo
                    ctx.insert(row)
                }
            }
            for (id, row) in existing where !desiredIDs.contains(id) {
                ctx.delete(row)
            }
            try? ctx.save()
        }
    }

    private static func reconcileAttachments(of row: SDMessage, with message: ChatMessage, in ctx: ModelContext) {
        let rowIDs = Set(row.attachments.map { $0.id })
        let msgIDs = Set(message.attachments.map { $0.id })
        guard rowIDs != msgIDs else { return }
        for attachment in row.attachments { ctx.delete(attachment) }
        row.attachments = message.attachments.enumerated().map { index, attachment in
            SDAttachment(
                id: attachment.id, filename: attachment.filename, mimeType: attachment.mimeType,
                base64: attachment.base64, fileURLString: attachment.fileURLString, sortIndex: index
            )
        }
    }

    /// Blocks the calling thread until every operation already enqueued has
    /// completed — the quit-time flush uses this so pending writes reach disk
    /// before the process exits (the queue is .utility; without the barrier
    /// termination could outrun it).
    static func waitUntilDrained() {
        queue.sync {}
    }

    /// Updates only the rolling summary of a conversation that is no longer
    /// on screen (the user switched away while it was being generated).
    static func updateSummary(_ summary: String, coversCount: Int, forKey key: String) {
        queue.async {
            let ctx = ModelContext(container)
            guard let convo = fetchConversation(key: key, in: ctx) else { return }
            convo.summary = summary
            convo.summaryCoversCount = min(coversCount, convo.messages.count)
            try? ctx.save()
        }
    }

    // MARK: Dormant-conversation write (background reply delivery)

    /// Upserts a single message into a conversation that is not on screen —
    /// the SwiftData analogue of the old read-modify-write of a dormant file,
    /// but touching only the one row.
    static func merge(_ message: ChatMessage, intoKey key: String) {
        queue.async {
            let ctx = ModelContext(container)
            let convo = fetchOrCreateConversation(key: key, in: ctx)
            if let row = convo.messages.first(where: { $0.id == message.id }) {
                row.text = message.text
                // Text-only updates were enough for streamed replies, but a
                // delivered message may also carry attachments/audio (image
                // results) — dropping them here would lose them silently.
                let audioString = message.audioURL?.absoluteString
                if row.audioURLString != audioString { row.audioURLString = audioString }
                reconcileAttachments(of: row, with: message, in: ctx)
            } else {
                let nextIndex = (convo.messages.map { $0.sortIndex }.max() ?? -1) + 1
                let row = message.toSDMessage(sortIndex: nextIndex)
                row.conversation = convo
                ctx.insert(row)
            }
            convo.updatedAt = Date()
            try? ctx.save()
        }
    }

    // MARK: Delete a whole conversation (custom preset removed)

    static func deleteConversation(key: String) {
        queue.async {
            let ctx = ModelContext(container)
            guard let convo = fetchConversation(key: key, in: ctx) else { return }
            for row in convo.messages {
                if let s = row.audioURLString, let url = URL(string: s) {
                    try? FileManager.default.removeItem(at: url)
                }
                for attachment in row.attachments {
                    if let path = attachment.fileURLString {
                        try? FileManager.default.removeItem(at: ChatAttachment.resolveURL(path))
                    }
                }
            }
            ctx.delete(convo) // cascades to messages + attachments
            try? ctx.save()
        }
    }

    // MARK: Startup orphan-media sweep (across ALL conversations)

    /// Deletes media files no message references anymore, across every stored
    /// conversation. A 1-hour grace protects files of operations racing this.
    static func sweepOrphanedMedia() {
        queue.async {
            let ctx = ModelContext(container)
            var referenced = Set<String>()
            if let all = try? ctx.fetch(FetchDescriptor<SDMessage>()) {
                for row in all {
                    if let s = row.audioURLString, let url = URL(string: s) { referenced.insert(url.path) }
                    for attachment in row.attachments {
                        // Resolved: stored paths are relative now, and the
                        // sweep compares against absolute directory listings.
                        if let path = attachment.fileURLString {
                            referenced.insert(ChatAttachment.resolveURL(path).path)
                        }
                    }
                }
            }
            let base = ChatStore.baseDirectory
            let grace: TimeInterval = 3600
            var removed = 0
            for subdir in ["Recordings", "images"] {
                let dir = base.appendingPathComponent(subdir, isDirectory: true)
                let files = (try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
                )) ?? []
                for file in files where !referenced.contains(file.path) {
                    let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    if Date().timeIntervalSince(modified) > grace {
                        try? FileManager.default.removeItem(at: file)
                        removed += 1
                    }
                }
            }
            if removed > 0 { Diagnostics.log("store", "sweep removed \(removed) orphaned media file(s)") }
        }
    }

    // MARK: One-time migration off the JSON files

    private static let migrationFlagKey = "didMigrateToSwiftData_v1"

    /// Imports `chat.json` + `chat-<hash>.json` into SwiftData on the first
    /// launch after the storage change, then renames each JSON to `.migrated`
    /// as a backup (never deletes — migration stays reversible). Enqueued on the
    /// persistence queue BEFORE the initial load, so the load sees the result.
    static func migrateFromJSONIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migrationFlagKey) else { return }
        queue.async {
            let ctx = ModelContext(container)
            let base = ChatStore.baseDirectory
            let files = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
            var importedConversations = 0
            for file in files where file.pathExtension == "json"
                && (file.lastPathComponent == "chat.json" || file.lastPathComponent.hasPrefix("chat-")) {

                let key: String
                if file.lastPathComponent == "chat.json" {
                    key = "general"
                } else {
                    // chat-<hash>.json → <hash>, the same key the runtime derives.
                    key = String(file.deletingPathExtension().lastPathComponent.dropFirst("chat-".count))
                }

                guard let data = try? Data(contentsOf: file),
                      let legacy = try? JSONDecoder().decode(LegacyChat.self, from: data) else { continue }

                // Idempotency guard: never double-import onto an existing convo.
                if fetchConversation(key: key, in: ctx) == nil {
                    let convo = SDConversation(
                        key: key,
                        summary: legacy.conversationSummary,
                        summaryCoversCount: legacy.summaryCoversCount
                    )
                    ctx.insert(convo)
                    for (index, message) in legacy.messages.enumerated() {
                        let row = message.toSDMessage(sortIndex: index)
                        row.conversation = convo
                        ctx.insert(row)
                    }
                    importedConversations += 1
                }
                // Back up the JSON so the import is reversible.
                let backup = file.appendingPathExtension("migrated")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.moveItem(at: file, to: backup)
            }
            try? ctx.save()
            UserDefaults.standard.set(true, forKey: migrationFlagKey)
            Diagnostics.log("store", "migrated \(importedConversations) conversation(s) JSON → SwiftData")
        }
    }

    // MARK: Media retention (unchanged policy, applied to the STORE at load)

    /// Attachments and recordings older than the retention window are dropped —
    /// files deleted, references stripped, text kept (image-only messages get a
    /// stub). Runs against the store directly (call inside `queue` only), so
    /// rows outside the loaded window age out too. Returns true when anything
    /// was pruned.
    private static func applyStoreRetention(key: String, in ctx: ModelContext, mediaExpiredText: String) -> Bool {
        let cutoff = Date().addingTimeInterval(-Double(Config.mediaRetentionDays) * 86400)
        let predicate = #Predicate<SDMessage> {
            $0.conversation?.key == key && $0.timestamp < cutoff
        }
        guard let rows = try? ctx.fetch(FetchDescriptor(predicate: predicate)) else { return false }
        var pruned = false
        for row in rows {
            if let urlString = row.audioURLString, let url = URL(string: urlString) {
                try? FileManager.default.removeItem(at: url)
                row.audioURLString = nil
                pruned = true
            }
            if !row.attachments.isEmpty {
                for attachment in row.attachments {
                    if let path = attachment.fileURLString {
                        try? FileManager.default.removeItem(at: ChatAttachment.resolveURL(path))
                    }
                    ctx.delete(attachment)
                }
                row.attachments = []
                pruned = true
                if row.text.isEmpty { row.text = mediaExpiredText }
            }
        }
        if pruned { try? ctx.save() }
        return pruned
    }

    // MARK: Whole-conversation media cleanup ("new chat")

    /// Deletes the media FILES of every stored row of a conversation — rows
    /// themselves are reconciled away by the follow-up sync of the emptied
    /// message list. Needed because clearMessages only sees the loaded
    /// window; media referenced by rows before it would leak as orphans
    /// until the startup sweep.
    static func deleteAllMediaFiles(key: String) {
        queue.async {
            let ctx = ModelContext(container)
            guard let convo = fetchConversation(key: key, in: ctx) else { return }
            for row in convo.messages {
                if let urlString = row.audioURLString, let url = URL(string: urlString) {
                    try? FileManager.default.removeItem(at: url)
                }
                for attachment in row.attachments {
                    if let path = attachment.fileURLString {
                        try? FileManager.default.removeItem(at: ChatAttachment.resolveURL(path))
                    }
                }
            }
        }
    }

    // MARK: Inline-media externalization (migration v2)

    private static let externalizeFlagKey = "didExternalizeInlineMedia_v1"

    /// Conversations imported from the legacy JSON kept their attachments as
    /// inline base64 INSIDE the SQLite rows — a heavy legacy chat still
    /// ballooned every load and sweep. Moves each inline payload out to a
    /// file under `images/` (the directory every new attachment already uses)
    /// and clears the base64 column. Runs once; if any file write fails the
    /// flag stays unset and the remainder is retried next launch.
    static func externalizeInlineMediaIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: externalizeFlagKey) else { return }
        queue.async {
            let ctx = ModelContext(container)
            let rows = (try? ctx.fetch(FetchDescriptor<SDAttachment>())) ?? []
            let dir = ChatStore.baseDirectory.appendingPathComponent("images", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var moved = 0
            var failed = 0
            for row in rows where !row.base64.isEmpty {
                if row.fileURLString != nil {
                    row.base64 = "" // file backing already exists — just drop the copy
                    continue
                }
                guard let data = Data(base64Encoded: row.base64) else {
                    row.base64 = "" // undecodable payload — nothing to preserve
                    continue
                }
                let ext = ChatAttachment.fileExtension(mimeType: row.mimeType, filename: row.filename)
                let relativePath = "images/\(row.id.uuidString).\(ext)"
                do {
                    try data.write(to: dir.appendingPathComponent("\(row.id.uuidString).\(ext)"), options: .atomic)
                    row.fileURLString = relativePath
                    row.base64 = ""
                    moved += 1
                } catch {
                    failed += 1 // keep inline; retried on the next launch
                }
            }
            try? ctx.save()
            if failed == 0 { UserDefaults.standard.set(true, forKey: externalizeFlagKey) }
            if moved > 0 || failed > 0 {
                Diagnostics.log("store", "externalized \(moved) inline attachment(s), \(failed) failed")
            }
        }
    }
}
