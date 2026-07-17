import Foundation
import SwiftUI
import Combine

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

    private var saveWorkItem: DispatchWorkItem?

    init() {
        loadFromDisk()
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

    private static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AISpotlight", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("chat.json")
    }

    /// Loads the persisted conversation off the main thread: attachments make
    /// the JSON multi-megabyte (images → base64), and decoding it synchronously
    /// in init stalled the app at launch. Also applies media retention and
    /// sweeps orphaned media files while it's at it.
    private func loadFromDisk() {
        let url = Self.storeURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
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
                Self.sweepOrphanedMedia(referencedBy: persisted.messages)
                let ms = Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6)
                Diagnostics.log("store", "load bytes=\(data.count) messages=\(persisted.messages.count) prunedMedia=\(prunedMedia) ms=\(ms)")
                loaded = persisted
            } else {
                // No (readable) history — every media file is an orphan.
                Self.sweepOrphanedMedia(referencedBy: [])
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let loaded {
                    // Anything sent before the load finished stays after the history.
                    self.messages = loaded.messages + self.messages
                    self.conversationSummary = loaded.conversationSummary
                    self.summaryCoversCount = min(loaded.summaryCoversCount, loaded.messages.count)
                    if prunedMedia {
                        self.scheduleSave() // persist the stripped references
                    }
                }
                self.isHistoryLoaded = true
            }
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

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AISpotlight", isDirectory: true)
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
    /// The snapshot is taken on the main thread (cheap copy-on-write), but
    /// encoding + disk I/O run on a background queue: attachments make the
    /// JSON multi-megabyte (image data → base64), and encoding it on the
    /// main thread froze the UI for noticeable stretches.
    func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let persisted = PersistedChat(
                messages: self.messages,
                conversationSummary: self.conversationSummary,
                summaryCoversCount: self.summaryCoversCount
            )
            DispatchQueue.global(qos: .utility).async {
                let start = DispatchTime.now()
                if let data = try? JSONEncoder().encode(persisted) {
                    try? data.write(to: Self.storeURL, options: .atomic)
                    let ms = Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6)
                    Diagnostics.log("store", "save bytes=\(data.count) messages=\(persisted.messages.count) ms=\(ms)")
                }
            }
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
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
