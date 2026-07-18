import Foundation
import SwiftUI
import Combine
import CryptoKit

// MARK: - ChatAttachment Model
struct ChatAttachment: Identifiable, Codable {
    let id: UUID
    let filename: String
    let mimeType: String
    /// Inline payload. Empty when the attachment lives as a file on disk
    /// (`fileURLString`) — large results would bloat chat.json otherwise.
    let base64: String
    /// Absolute path of a file-backed payload (Application Support). The
    /// optional decodes as nil for chats saved by older versions.
    var fileURLString: String?

    init(filename: String, mimeType: String, base64: String, id: UUID = UUID(), fileURLString: String? = nil) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.base64 = base64
        self.fileURLString = fileURLString
    }

    var fileURL: URL? {
        fileURLString.map { URL(fileURLWithPath: $0) }
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
}

// MARK: - ChatMessage Model
struct ChatMessage: Identifiable, Codable {
    let id: UUID
    var text: String
    let isUser: Bool
    let timestamp: Date
    let messageType: MessageType
    var audioURL: URL? // For voice messages
    var attachments: [ChatAttachment]
    
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
    }
    
    // Custom coding keys to handle URL encoding
    enum CodingKeys: String, CodingKey {
        case id, text, isUser, timestamp, messageType, audioURLString, attachments
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        isUser = try container.decode(Bool.self, forKey: .isUser)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        messageType = try container.decode(MessageType.self, forKey: .messageType)
        attachments = (try? container.decode([ChatAttachment].self, forKey: .attachments)) ?? []
        
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
        
        if let audioURL = audioURL {
            try container.encode(audioURL.absoluteString, forKey: .audioURLString)
        }
    }
}

// MARK: - ChatStore ObservableObject
class ChatStore: ObservableObject {

    /// Identifies which persisted conversation the store is showing: the
    /// shared chat, or a preset's own isolated chat (Settings → Prompts).
    enum ConversationID: Equatable {
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
    /// Invalidates async load completions that finish after a later switch.
    private var loadGeneration = 0
    /// Replies delivered to the current conversation while its load is still
    /// in flight — applied (and persisted) when the load completes.
    private var pendingDeliveries: [(message: ChatMessage, target: ConversationID)] = []

    private var saveWorkItem: DispatchWorkItem?

    /// Serial queue for ALL chat-file disk I/O. Ordering matters: a switch
    /// flushes conversation A and then loads conversation B; a preset delete
    /// must run after the flush that may have just recreated the file.
    private static let diskQueue = DispatchQueue(label: "AISpotlight.ChatStore.disk", qos: .utility)

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
        loadConversation(conversation)
        Self.startupMediaSweep()
    }

    // MARK: Context window accessors

    /// Messages that should be sent verbatim (the summarized prefix is skipped).
    var activeContextMessages: [ChatMessage] {
        let start = min(summaryCoversCount, messages.count)
        return Array(messages[start...])
    }

    func setSummary(_ summary: String, coversCount: Int) {
        DispatchQueue.main.async {
            self.conversationSummary = summary
            self.summaryCoversCount = min(coversCount, self.messages.count)
            self.scheduleSave()
        }
    }

    // MARK: Persistence

    nonisolated private struct PersistedChat: Codable {
        var messages: [ChatMessage]
        var conversationSummary: String?
        var summaryCoversCount: Int
    }

    static var baseDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AISpotlight", isDirectory: true)
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
        flushPendingSave() // commit the outgoing conversation to its own file
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
        conversationSummary = nil
        summaryCoversCount = 0
        statusText = nil
        isLoading = false
        Diagnostics.log("store", "switch → \(id.fileURL.lastPathComponent)")
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
        let url = target.fileURL
        diskQueue.async {
            var persisted: PersistedChat
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode(PersistedChat.self, from: data) {
                persisted = decoded
            } else {
                persisted = PersistedChat(messages: [], conversationSummary: nil, summaryCoversCount: 0)
            }
            if let index = persisted.messages.firstIndex(where: { $0.id == message.id }) {
                persisted.messages[index] = message
            } else {
                persisted.messages.append(message)
            }
            if let data = try? JSONEncoder().encode(persisted) {
                try? data.write(to: url, options: .atomic)
                Diagnostics.log("store", "merge reply → \(url.lastPathComponent) messages=\(persisted.messages.count)")
            }
        }
    }

    /// Deletes a preset's dormant chat file and its media without loading it
    /// into the UI (used when a custom preset is deleted).
    nonisolated static func deleteConversationData(presetNamed name: String) {
        let url = ConversationID.preset(name).fileURL
        diskQueue.async {
            if let data = try? Data(contentsOf: url),
               let persisted = try? JSONDecoder().decode(PersistedChat.self, from: data) {
                for message in persisted.messages {
                    if let audioURL = message.audioURL {
                        try? FileManager.default.removeItem(at: audioURL)
                    }
                    for attachment in message.attachments {
                        if let fileURL = attachment.fileURL {
                            try? FileManager.default.removeItem(at: fileURL)
                        }
                    }
                }
            }
            try? FileManager.default.removeItem(at: url)
            Diagnostics.log("store", "deleted conversation \(url.lastPathComponent)")
        }
    }

    /// Loads a persisted conversation off the main thread: attachments make
    /// the JSON multi-megabyte (images → base64), and decoding it synchronously
    /// in init stalled the app at launch. Also applies media retention.
    /// Runs on the serial disk queue so it is ordered after the flush of the
    /// previously active conversation (relevant for rapid A→B→A switches).
    private func loadConversation(_ id: ConversationID) {
        let url = id.fileURL
        let generation = loadGeneration
        Self.diskQueue.async { [weak self] in
            let start = DispatchTime.now()
            var loaded: PersistedChat?
            var prunedMedia = false
            if let data = try? Data(contentsOf: url),
               var persisted = try? JSONDecoder().decode(PersistedChat.self, from: data) {
                // Media retention: attachments and recordings older than the
                // window are dropped — files deleted, references stripped,
                // the message text stays (image-only messages get a stub).
                let cutoff = Date().addingTimeInterval(-Double(Config.mediaRetentionDays) * 86400)
                persisted.messages = persisted.messages.map { message in
                    var message = message
                    if message.timestamp < cutoff {
                        if let audioURL = message.audioURL {
                            try? FileManager.default.removeItem(at: audioURL)
                            message.audioURL = nil
                            prunedMedia = true
                        }
                        if !message.attachments.isEmpty {
                            for attachment in message.attachments {
                                if let fileURL = attachment.fileURL {
                                    try? FileManager.default.removeItem(at: fileURL)
                                }
                            }
                            message.attachments = []
                            prunedMedia = true
                            if message.text.isEmpty {
                                message.text = L("chat.mediaExpired")
                            }
                        }
                    }
                    // Drop dangling voice-file references (recordings are session-scoped).
                    if let audioURL = message.audioURL, !FileManager.default.fileExists(atPath: audioURL.path) {
                        message.audioURL = nil
                    }
                    return message
                }
                let ms = Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6)
                Diagnostics.log("store", "load \(url.lastPathComponent) bytes=\(data.count) messages=\(persisted.messages.count) prunedMedia=\(prunedMedia) ms=\(ms)")
                loaded = persisted
            }
            DispatchQueue.main.async {
                guard let self else { return }
                // A later switchConversation invalidated this load — drop it.
                // (Media pruned above is expired in any conversation; harmless.)
                guard self.loadGeneration == generation else { return }
                if let loaded {
                    // Anything sent before the load finished stays after the history.
                    self.messages = loaded.messages + self.messages
                    self.conversationSummary = loaded.conversationSummary
                    self.summaryCoversCount = min(loaded.summaryCoversCount, loaded.messages.count)
                    if prunedMedia {
                        self.scheduleSave() // persist the stripped references
                    }
                }
                // Replies that finished for this conversation while the load
                // was in flight (all queued entries target it by construction
                // — switchConversation drains foreign ones to disk).
                if !self.pendingDeliveries.isEmpty {
                    for delivery in self.pendingDeliveries {
                        self.upsert(delivery.message)
                    }
                    self.pendingDeliveries = []
                    self.scheduleSave()
                }
                self.isHistoryLoaded = true
            }
        }
    }

    /// Startup-only orphan sweep across ALL persisted conversations (the
    /// shared chat plus every isolated preset chat, dormant ones included) —
    /// sweeping against a single conversation's references would delete the
    /// other chats' media. Runs on the serial disk queue, so it is ordered
    /// after the initial load enqueued by init.
    nonisolated private static func startupMediaSweep() {
        diskQueue.async {
            var allMessages: [ChatMessage] = []
            let files = (try? FileManager.default.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json"
                && (file.lastPathComponent == "chat.json" || file.lastPathComponent.hasPrefix("chat-")) {
                if let data = try? Data(contentsOf: file),
                   let persisted = try? JSONDecoder().decode(PersistedChat.self, from: data) {
                    allMessages += persisted.messages
                }
            }
            sweepOrphanedMedia(referencedBy: allMessages)
        }
    }

    /// Deletes media files no message references anymore. Covers crash
    /// windows (a result file written, chat.json's debounced save never
    /// landed) and recordings that never became a message. A 1-hour age
    /// grace protects files of operations racing this startup sweep.
    nonisolated private static func sweepOrphanedMedia(referencedBy messages: [ChatMessage]) {
        var referenced = Set<String>()
        for message in messages {
            if let audioURL = message.audioURL { referenced.insert(audioURL.path) }
            for attachment in message.attachments {
                if let fileURL = attachment.fileURL { referenced.insert(fileURL.path) }
            }
        }

        let base = baseDirectory
        let gracePeriod: TimeInterval = 3600
        var removed = 0
        for subdir in ["Recordings", "images"] {
            let dir = base.appendingPathComponent(subdir, isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            for file in files where !referenced.contains(file.path) {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if Date().timeIntervalSince(modified) > gracePeriod {
                    try? FileManager.default.removeItem(at: file)
                    removed += 1
                }
            }
        }
        if removed > 0 {
            Diagnostics.log("store", "sweep removed \(removed) orphaned media file(s)")
        }
    }

    /// Debounced write of the conversation to Application Support.
    /// The snapshot (cheap copy-on-write) AND its target URL are captured at
    /// schedule time — every mutation re-schedules, so the pending snapshot
    /// is always the latest state, and a conversation switch can never leak
    /// the old chat's messages into the new chat's file. Encoding + disk I/O
    /// run on the background disk queue: attachments make the JSON
    /// multi-megabyte (image data → base64), and encoding it on the main
    /// thread froze the UI for noticeable stretches. Main thread only.
    func scheduleSave() {
        saveWorkItem?.cancel()
        let persisted = PersistedChat(
            messages: messages,
            conversationSummary: conversationSummary,
            summaryCoversCount: summaryCoversCount
        )
        let url = conversation.fileURL
        let item = DispatchWorkItem { [weak self] in
            self?.saveWorkItem = nil
            Self.write(persisted, to: url)
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    /// Commits a pending debounced save immediately (main thread only).
    /// No-op when nothing is pending.
    func flushPendingSave() {
        guard saveWorkItem != nil else { return }
        saveWorkItem?.cancel()
        saveWorkItem = nil
        let persisted = PersistedChat(
            messages: messages,
            conversationSummary: conversationSummary,
            summaryCoversCount: summaryCoversCount
        )
        Self.write(persisted, to: conversation.fileURL)
    }

    nonisolated private static func write(_ persisted: PersistedChat, to url: URL) {
        diskQueue.async {
            let start = DispatchTime.now()
            if let data = try? JSONEncoder().encode(persisted) {
                try? data.write(to: url, options: .atomic)
                let ms = Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6)
                Diagnostics.log("store", "save \(url.lastPathComponent) bytes=\(data.count) messages=\(persisted.messages.count) ms=\(ms)")
            }
        }
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

    /// Appends a streamed chunk to an existing message (used for live assistant replies).
    func appendChunk(_ chunk: String, to messageID: UUID) {
        DispatchQueue.main.async {
            guard let index = self.messages.firstIndex(where: { $0.id == messageID }) else { return }
            self.messages[index].text += chunk
            self.scheduleSave()
        }
    }

    /// Replaces the text of an existing message.
    func setText(_ text: String, for messageID: UUID) {
        DispatchQueue.main.async {
            guard let index = self.messages.firstIndex(where: { $0.id == messageID }) else { return }
            self.messages[index].text = text
            self.scheduleSave()
        }
    }

    /// Removes a message (e.g. an empty streaming placeholder after an error).
    func removeMessage(id messageID: UUID) {
        DispatchQueue.main.async {
            self.messages.removeAll { $0.id == messageID }
            self.summaryCoversCount = min(self.summaryCoversCount, self.messages.count)
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
            self.messages.removeAll()
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
