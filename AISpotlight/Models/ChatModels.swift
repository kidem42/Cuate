import Foundation
import SwiftUI
import Combine

// MARK: - ChatAttachment Model
struct ChatAttachment: Identifiable, Codable {
    let id: UUID
    let filename: String
    let mimeType: String
    let base64: String

    init(filename: String, mimeType: String, base64: String, id: UUID = UUID()) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.base64 = base64
    }

    var data: Data? {
        Data(base64Encoded: base64)
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

    private struct PersistedChat: Codable {
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

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let persisted = try? JSONDecoder().decode(PersistedChat.self, from: data) else { return }
        // Drop dangling voice-file references (recordings are session-scoped).
        messages = persisted.messages.map { message in
            var message = message
            if let url = message.audioURL, !FileManager.default.fileExists(atPath: url.path) {
                message.audioURL = nil
            }
            return message
        }
        conversationSummary = persisted.conversationSummary
        summaryCoversCount = min(persisted.summaryCoversCount, messages.count)
    }

    /// Debounced write of the conversation to Application Support.
    func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let persisted = PersistedChat(
                messages: self.messages,
                conversationSummary: self.conversationSummary,
                summaryCoversCount: self.summaryCoversCount
            )
            if let data = try? JSONEncoder().encode(persisted) {
                try? data.write(to: Self.storeURL, options: .atomic)
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
            // Delete voice recordings referenced by the cleared conversation
            // so they don't pile up as orphans in Application Support.
            for message in self.messages {
                if let url = message.audioURL {
                    try? FileManager.default.removeItem(at: url)
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
