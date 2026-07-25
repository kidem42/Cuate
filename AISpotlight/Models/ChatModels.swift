import Foundation
import SwiftUI
import AppKit
import Combine
import CryptoKit
import UniformTypeIdentifiers

// MARK: - ChatAttachment Model
nonisolated struct ChatAttachment: Identifiable, Codable {
    let id: UUID
    let filename: String
    let mimeType: String
    /// Inline payload. Empty when the attachment lives as a file on disk
    /// (`fileURLString`) — large results would bloat chat.json otherwise.
    let base64: String
    /// Path of a file-backed payload. New rows store it RELATIVE to the
    /// Application Support base directory (survives a container move/rename);
    /// legacy rows hold absolute paths — `resolveURL` accepts both. The
    /// optional decodes as nil for chats saved by older versions.
    var fileURLString: String?
    /// Cached OCR extraction of an image payload, filled the first time the
    /// content is needed as text (non-vision provider, or the message aged out
    /// of the "attach pixels" window). Persisting it means retries and later
    /// turns never re-pay the OCR call, and older turns keep their image
    /// content as grounding instead of a content-free "[attached earlier]" note.
    var ocrText: String?

    init(filename: String, mimeType: String, base64: String, id: UUID = UUID(), fileURLString: String? = nil, ocrText: String? = nil) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.base64 = base64
        self.fileURLString = fileURLString
        self.ocrText = ocrText
    }

    /// Resolves a stored payload path: absolute (legacy rows) is used as-is,
    /// relative (the norm now) resolves against Application Support.
    static func resolveURL(_ path: String) -> URL {
        path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : ChatStore.baseDirectory.appendingPathComponent(path)
    }

    var fileURL: URL? {
        fileURLString.map { Self.resolveURL($0) }
    }

    var data: Data? {
        if !base64.isEmpty { return Data(base64Encoded: base64) }
        if let fileURL { return try? Data(contentsOf: fileURL) }
        return nil
    }

    /// Base64 of the payload regardless of where it lives (for API calls).
    var contentBase64: String {
        if !base64.isEmpty { return base64 }
        return data?.base64EncodedString() ?? ""
    }

    /// Persists the payload as a FILE under Application Support (`images/`) and
    /// returns a file-backed attachment (`base64` empty). Keeping image bytes
    /// out of the chat store is what stops it bloating — every UI entry point
    /// (paste, file dialog, screenshot capture) must route through here. Falls
    /// back to inline base64 only if the write fails, so an attachment is never
    /// silently dropped.
    static func fileBacked(data: Data, mimeType: String, filename: String) -> ChatAttachment {
        let id = UUID()
        let ext = fileExtension(mimeType: mimeType, filename: filename)
        // Stored relative to Application Support (see fileURLString docs).
        let relativePath = "images/\(id.uuidString).\(ext)"
        let fileURL = ChatStore.baseDirectory.appendingPathComponent(relativePath)
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            return ChatAttachment(filename: filename, mimeType: mimeType, base64: "", id: id, fileURLString: relativePath)
        } catch {
            return ChatAttachment(filename: filename, mimeType: mimeType, base64: data.base64EncodedString(), id: id)
        }
    }

    /// Extension for a written attachment: the source filename's extension,
    /// else one derived from the MIME type, else "bin". (Also used by the
    /// inline-media externalization migration in ChatPersistence.)
    static func fileExtension(mimeType: String, filename: String) -> String {
        let nameExt = (filename as NSString).pathExtension
        if !nameExt.isEmpty { return nameExt.lowercased() }
        if let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension { return ext }
        return "bin"
    }
}

// MARK: - ChatMessage Model
nonisolated struct ChatMessage: Identifiable, Codable {
    let id: UUID
    var text: String
    let isUser: Bool
    let timestamp: Date
    let messageType: MessageType
    var audioURL: URL? // For voice messages
    var attachments: [ChatAttachment]
    /// Compact digest of the web-search results an assistant reply was based
    /// on. Not rendered in the UI; re-attached to the API context for the most
    /// recent reply that has one, so follow-up questions ("what did the second
    /// source say?") keep their grounding across turns.
    var toolContext: String?

    enum MessageType: String, Codable {
        case text
        case voice
        case system
    }

    init(text: String, isUser: Bool, messageType: MessageType = .text, audioURL: URL? = nil, attachments: [ChatAttachment] = []) {
        self.id = UUID()
        self.text = text
        self.isUser = isUser
        self.timestamp = Date()
        self.messageType = messageType
        self.audioURL = audioURL
        self.attachments = attachments
        self.toolContext = nil
    }

    /// Reconstructs a message with explicit identity and timestamp — used by
    /// persistence (SwiftData rows) and the legacy-JSON migration.
    init(id: UUID, text: String, isUser: Bool, timestamp: Date, messageType: MessageType, audioURL: URL?, attachments: [ChatAttachment], toolContext: String? = nil) {
        self.id = id
        self.text = text
        self.isUser = isUser
        self.timestamp = timestamp
        self.messageType = messageType
        self.audioURL = audioURL
        self.attachments = attachments
        self.toolContext = toolContext
    }

    // Custom coding keys to handle URL encoding
    enum CodingKeys: String, CodingKey {
        case id, text, isUser, timestamp, messageType, audioURLString, attachments, toolContext
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        isUser = try container.decode(Bool.self, forKey: .isUser)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        messageType = try container.decode(MessageType.self, forKey: .messageType)
        attachments = (try? container.decode([ChatAttachment].self, forKey: .attachments)) ?? []
        toolContext = try container.decodeIfPresent(String.self, forKey: .toolContext)

        if let urlString = try container.decodeIfPresent(String.self, forKey: .audioURLString) {
            audioURL = URL(string: urlString)
        } else {
            audioURL = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(isUser, forKey: .isUser)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(messageType, forKey: .messageType)
        if !attachments.isEmpty {
            try container.encode(attachments, forKey: .attachments)
        }
        try container.encodeIfPresent(toolContext, forKey: .toolContext)

        if let audioURL = audioURL {
            try container.encode(audioURL.absoluteString, forKey: .audioURLString)
        }
    }
}

// MARK: - ChatStore ObservableObject
class ChatStore: ObservableObject {

    /// Identifies which persisted conversation the store is showing: the
    /// shared chat, or a preset's own isolated chat (Settings → Prompts).
    nonisolated enum ConversationID: Equatable {
        case general
        case preset(String)

        var fileURL: URL {
            switch self {
            case .general:
                return ChatStore.baseDirectory.appendingPathComponent("chat.json")
            case .preset(let name):
                return ChatStore.baseDirectory.appendingPathComponent("chat-\(Self.fileHash(name)).json")
            }
        }

        /// Stable storage identity — matches the old filename stem, so the
        /// migration maps a file to its conversation without recovering the
        /// preset name from its hash.
        var storageKey: String {
            switch self {
            case .general: return "general"
            case .preset(let name): return Self.fileHash(name)
            }
        }

        /// Stable filesystem-safe file identity for arbitrary preset names
        /// (emoji, slashes, dots are all possible in a name).
        private static func fileHash(_ name: String) -> String {
            let digest = SHA256.hash(data: Data(name.utf8))
            return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
        }
    }

    @Published var messages: [ChatMessage] = []
    @Published var isLoading = false
    /// Live status shown in the "thinking" indicator (e.g. "Searching: …").
    @Published var statusText: String?

    /// Rolling summary of older conversation turns (context compression).
    @Published private(set) var conversationSummary: String?
    /// How many leading messages of `messages` are covered by the summary.
    @Published private(set) var summaryCoversCount: Int = 0
    /// Set once the async history load settles (whether or not a file existed).
    /// Gates the welcome message so it doesn't race the load and duplicate.
    @Published private(set) var isHistoryLoaded = false

    /// Which persisted conversation is currently loaded (main-thread confined).
    private(set) var conversation: ConversationID
    /// Absolute index of `messages.first` within the stored conversation.
    /// `messages` is a contiguous SUFFIX of the conversation — older rows
    /// stay in the store and are paged in by `loadOlderPage`. 0 = everything
    /// is loaded. Main-thread confined.
    private(set) var windowStart = 0
    /// Invalidates async load completions that finish after a later switch.
    private var loadGeneration = 0
    /// Replies delivered to the current conversation while its load is still
    /// in flight — applied (and persisted) when the load completes.
    private var pendingDeliveries: [(message: ChatMessage, target: ConversationID)] = []

    private var saveWorkItem: DispatchWorkItem?

    init() {
        // Resolve the initial conversation straight from UserDefaults: the
        // active preset may be isolated, and AppSettings is @MainActor (this
        // init is nonisolated). ChatWindow re-syncs on appear in case the
        // settings migrations rewrote the active preset after this ran.
        let defaults = UserDefaults.standard
        let active = defaults.string(forKey: "activePresetName")
        let isolated = Set(defaults.stringArray(forKey: "isolatedPresets") ?? [])
        if let active, isolated.contains(active) {
            conversation = .preset(active)
        } else {
            conversation = .general
        }
        // Enqueued in order on ChatPersistence's serial queue: migrate any
        // legacy JSON first, then externalize inline base64 payloads to files,
        // so the initial load sees the imported, slimmed-down data; then
        // sweep orphaned media against the now-populated store.
        ChatPersistence.migrateFromJSONIfNeeded()
        ChatPersistence.externalizeInlineMediaIfNeeded()
        loadConversation(conversation)
        ChatPersistence.sweepOrphanedMedia()
        // Quit-time flush: without it, ⌘Q within the debounce window (or
        // mid-stream, where the max-latency cap still leaves a gap) drops the
        // last mutations. willTerminate is posted on the main thread; queue:
        // nil delivers synchronously there, and the drain blocks termination
        // until the persistence queue has actually written everything out.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.flushPendingSave()
            ChatPersistence.waitUntilDrained()
        }
    }

    // MARK: Context window accessors

    /// Total number of messages in the conversation (loaded window + older
    /// rows still in the store).
    var totalMessageCount: Int { windowStart + messages.count }

    /// Whether older messages exist in the store beyond the loaded window.
    var hasOlderMessages: Bool { windowStart > 0 }

    /// Messages that should be sent verbatim (the summarized prefix is
    /// skipped). `summaryCoversCount` is an ABSOLUTE index; the loaded window
    /// always extends at least back to it (guaranteed by the windowed load),
    /// so the verbatim tail is always in memory.
    var activeContextMessages: [ChatMessage] {
        let start = min(max(0, summaryCoversCount - windowStart), messages.count)
        return Array(messages[start...])
    }

    /// Applies a freshly generated rolling summary — but only to the
    /// conversation it was generated FOR. Summarization is an LLM call that
    /// takes seconds; if the user switched conversations meanwhile, applying
    /// it to the store would stamp chat A's summary onto chat B. In that case
    /// it is written straight to the dormant conversation's rows instead.
    func setSummary(_ summary: String, coversCount: Int, for target: ConversationID) {
        DispatchQueue.main.async {
            guard self.conversation == target else {
                ChatPersistence.updateSummary(summary, coversCount: coversCount, forKey: target.storageKey)
                return
            }
            self.conversationSummary = summary
            self.summaryCoversCount = min(coversCount, self.totalMessageCount)
            self.scheduleSave()
        }
    }

    // MARK: Persistence

    nonisolated static var baseDirectory: URL {
        let base: URL
        if let override = ProcessInfo.processInfo.environment["AISPOTLIGHT_DATA_DIR"], !override.isEmpty {
            // Test hook: e2e harnesses point the whole persistence layer at a
            // sandbox directory (HOME overrides do NOT redirect
            // applicationSupportDirectory — it resolves via the passwd entry).
            base = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AISpotlight", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: Conversation switching

    /// Switches the store to another persisted conversation in place
    /// (same object — SwiftUI observers and ChatWindowBridge stay valid).
    /// An in-flight reply is NOT interrupted: it keeps streaming in the
    /// background and is handed back via `deliver(_:to:)`. Main thread only.
    func switchConversation(to id: ConversationID) {
        guard id != conversation else { return }
        if isHistoryLoaded {
            flushPendingSave() // commit the outgoing conversation to its own file
        } else if !messages.isEmpty {
            // The outgoing conversation's history never finished loading: a
            // full sync would reconcile its store down to these few early
            // messages and wipe the history. Merge them row-by-row instead.
            for message in messages {
                Self.mergeMessage(message, into: conversation)
            }
        }
        // Deliveries the outgoing conversation never got to apply (its load
        // was still in flight) go straight to its file instead.
        for delivery in pendingDeliveries {
            Self.mergeMessage(delivery.message, into: delivery.target)
        }
        pendingDeliveries = []
        conversation = id
        loadGeneration += 1
        // Reset BEFORE clearing messages so the welcome onReceive stays quiet
        // until the new history has actually loaded.
        isHistoryLoaded = false
        messages = []
        windowStart = 0
        conversationSummary = nil
        summaryCoversCount = 0
        statusText = nil
        isLoading = false
        Diagnostics.log("store", "switch → \(id.storageKey)")
        loadConversation(id)
    }

    /// Hands a background-finished (or errored) reply to its home
    /// conversation: applied in-memory when that conversation is on screen,
    /// queued when its load is still in flight, merged straight into its
    /// file on disk otherwise. Main thread only.
    func deliver(_ message: ChatMessage, to target: ConversationID) {
        if conversation == target {
            if isHistoryLoaded {
                upsert(message)
                scheduleSave()
            } else {
                pendingDeliveries.append((message, target))
            }
        } else {
            Self.mergeMessage(message, into: target)
        }
    }

    /// Updates the message with the same id, or appends it (a background
    /// reply may already sit in the history as a partial from an earlier
    /// flush — same UUID, less text).
    private func upsert(_ message: ChatMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
    }

    /// Read-modify-write of a dormant conversation's file: update the
    /// message with the same id, or append it. Runs entirely within one
    /// disk-queue block so no flush/load can interleave.
    nonisolated private static func mergeMessage(_ message: ChatMessage, into target: ConversationID) {
        ChatPersistence.merge(message, intoKey: target.storageKey)
    }

    /// Deletes a preset's dormant chat file and its media without loading it
    /// into the UI (used when a custom preset is deleted).
    nonisolated static func deleteConversationData(presetNamed name: String) {
        ChatPersistence.deleteConversation(key: ConversationID.preset(name).storageKey)
    }

    /// Loads a persisted conversation off the main thread (ChatPersistence maps
    /// SwiftData rows to value types there) and applies media retention.
    /// Ordered on the persistence serial queue after the flush of the
    /// previously active conversation (relevant for rapid A→B→A switches).
    private func loadConversation(_ id: ConversationID) {
        let generation = loadGeneration
        ChatPersistence.load(key: id.storageKey, mediaExpiredText: L("chat.mediaExpired")) { [weak self] loaded in
            DispatchQueue.main.async {
                guard let self else { return }
                // A later switchConversation invalidated this load — drop it.
                guard self.loadGeneration == generation else { return }
                // Messages sent before the load settled: they must be
                // persisted below — their own scheduleSave was suppressed
                // (saving a load-less snapshot would have wiped the history).
                let hadEarlyMessages = !self.messages.isEmpty
                if loaded.existed {
                    // Anything sent before the load finished stays after the history.
                    self.messages = loaded.messages + self.messages
                    self.windowStart = loaded.windowStart
                    self.conversationSummary = loaded.summary
                    self.summaryCoversCount = min(loaded.summaryCoversCount, self.totalMessageCount)
                }
                // Replies that finished for this conversation while the load
                // was in flight (all queued entries target it by construction
                // — switchConversation drains foreign ones to the store).
                let hadDeliveries = !self.pendingDeliveries.isEmpty
                for delivery in self.pendingDeliveries {
                    self.upsert(delivery.message)
                }
                self.pendingDeliveries = []
                // BEFORE scheduling saves — scheduleSave is gated on it.
                self.isHistoryLoaded = true
                if hadEarlyMessages || hadDeliveries || loaded.prunedMedia {
                    self.scheduleSave()
                }
            }
        }
    }

    /// Pages one more chunk of older messages in from the store and prepends
    /// it to the loaded window (main thread only). `completion` receives how
    /// many messages were added (0 when nothing older exists or the
    /// conversation switched while the fetch was in flight).
    func loadOlderPage(_ pageSize: Int, completion: @escaping (Int) -> Void) {
        guard windowStart > 0 else { completion(0); return }
        let generation = loadGeneration
        ChatPersistence.loadOlderMessages(
            key: conversation.storageKey, before: windowStart, limit: pageSize
        ) { [weak self] older in
            DispatchQueue.main.async {
                guard let self, self.loadGeneration == generation else { completion(0); return }
                guard !older.isEmpty else {
                    // The store disagrees about older rows — stop asking.
                    self.windowStart = 0
                    completion(0)
                    return
                }
                self.messages.insert(contentsOf: older, at: 0)
                self.windowStart = max(0, self.windowStart - older.count)
                completion(older.count)
            }
        }
    }

    /// Debounce interval for persists.
    private static let saveDebounce: TimeInterval = 1.0
    /// The debounce coalesces bursts, but a steady mutation stream (streamed
    /// reply flushes every ~120 ms) re-schedules forever — nothing would hit
    /// disk for the whole answer, the user's message included. When a save
    /// has been pending longer than this, it fires even mid-burst.
    private static let saveMaxLatency: TimeInterval = 5.0
    /// When the oldest not-yet-persisted mutation was scheduled.
    private var oldestPendingSave: Date?

    /// Debounced persist of the current conversation. The snapshot (cheap
    /// copy-on-write) AND its conversation key are captured at schedule time —
    /// every mutation re-schedules, so the pending snapshot is always the
    /// latest state, and a conversation switch can never leak the old chat's
    /// messages into the new chat's store. The row reconcile + write run on the
    /// persistence queue (SwiftData), off the main thread. Main thread only.
    func scheduleSave() {
        // Never persist before the history load settles: the snapshot would
        // hold only the post-switch messages, and sync() would reconcile the
        // stored conversation down to it — wiping the history on disk. The
        // load completion re-schedules on behalf of anything suppressed here.
        guard isHistoryLoaded else { return }
        saveWorkItem?.cancel()
        let now = Date()
        let pendingSince = oldestPendingSave ?? now
        oldestPendingSave = pendingSince
        // Shrinks as the pending save ages; hits zero at the latency cap.
        let delay = min(Self.saveDebounce,
                        max(0, Self.saveMaxLatency - now.timeIntervalSince(pendingSince)))
        let messagesSnapshot = messages
        let summarySnapshot = conversationSummary
        let coversSnapshot = summaryCoversCount
        let windowSnapshot = windowStart
        let key = conversation.storageKey
        let item = DispatchWorkItem { [weak self] in
            self?.saveWorkItem = nil
            self?.oldestPendingSave = nil
            ChatPersistence.sync(key: key, messages: messagesSnapshot, summary: summarySnapshot,
                                 summaryCoversCount: coversSnapshot, windowStart: windowSnapshot)
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Commits a pending debounced save immediately (main thread only).
    /// No-op when nothing is pending.
    func flushPendingSave() {
        guard saveWorkItem != nil, isHistoryLoaded else { return }
        saveWorkItem?.cancel()
        saveWorkItem = nil
        oldestPendingSave = nil
        ChatPersistence.sync(key: conversation.storageKey, messages: messages, summary: conversationSummary,
                             summaryCoversCount: summaryCoversCount, windowStart: windowStart)
    }

    @discardableResult
    func addMessage(text: String, isUser: Bool, messageType: ChatMessage.MessageType = .text, audioURL: URL? = nil, attachments: [ChatAttachment] = []) -> UUID {
        let message = ChatMessage(text: text, isUser: isUser, messageType: messageType, audioURL: audioURL, attachments: attachments)
        DispatchQueue.main.async {
            self.messages.append(message)
            self.scheduleSave()
        }
        return message.id
    }

    /// Appends a message synchronously when already on the main thread,
    /// so callers can immediately build a history snapshot that includes it.
    func appendNow(_ message: ChatMessage) {
        if Thread.isMainThread {
            messages.append(message)
            scheduleSave()
        } else {
            DispatchQueue.main.async {
                self.messages.append(message)
                self.scheduleSave()
            }
        }
    }

    /// Replaces the text of an existing message.
    ///
    /// Deliberately ASYNC, even when called from the main thread: the streamed
    /// reply flushes from inside the `for await` loop, and applying the store
    /// mutation inline made that loop wait on a SwiftUI transaction per flush —
    /// chunks were consumed slower and the reply visibly crawled.
    func setText(_ text: String, for messageID: UUID) {
        DispatchQueue.main.async {
            guard let index = self.messages.firstIndex(where: { $0.id == messageID }) else { return }
            self.messages[index].text = text
            self.scheduleSave()
        }
    }

    /// Persists a lazily computed OCR extraction onto its attachment (the
    /// message may have scrolled out of the API context by the time OCR
    /// finishes — matching by IDs keeps the write exact).
    func setAttachmentOCRText(_ text: String, messageID: UUID, attachmentID: UUID) {
        DispatchQueue.main.async {
            guard let messageIndex = self.messages.firstIndex(where: { $0.id == messageID }),
                  let attachmentIndex = self.messages[messageIndex].attachments
                      .firstIndex(where: { $0.id == attachmentID }) else { return }
            self.messages[messageIndex].attachments[attachmentIndex].ocrText = text
            self.scheduleSave()
        }
    }

    /// Removes a message (e.g. an empty streaming placeholder after an error).
    func removeMessage(id messageID: UUID) {
        DispatchQueue.main.async {
            self.messages.removeAll { $0.id == messageID }
            self.summaryCoversCount = min(self.summaryCoversCount, self.totalMessageCount)
            self.scheduleSave()
        }
    }

    func clearMessages() {
        DispatchQueue.main.async {
            // Delete voice recordings and file-backed attachments referenced
            // by the cleared conversation so they don't pile up as orphans
            // in Application Support.
            for message in self.messages {
                if let url = message.audioURL {
                    try? FileManager.default.removeItem(at: url)
                }
                for attachment in message.attachments {
                    if let url = attachment.fileURL {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            }
            // Media referenced by rows BELOW the loaded window never made it
            // into memory — delete their files store-side. The rows themselves
            // are reconciled away by the scheduleSave below (windowStart 0 +
            // empty list = wipe, which is exactly what "new chat" means).
            if self.windowStart > 0 {
                ChatPersistence.deleteAllMediaFiles(key: self.conversation.storageKey)
            }
            self.messages.removeAll()
            self.windowStart = 0
            self.conversationSummary = nil
            self.summaryCoversCount = 0
            self.scheduleSave()
        }
    }
    
    func setLoading(_ loading: Bool) {
        DispatchQueue.main.async {
            self.isLoading = loading
        }
    }
}
