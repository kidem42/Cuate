#!/usr/bin/env python3
"""Actual compression/settings/store-accessor contracts with isolated defaults and a fake provider.
No application build, network, real settings or chat storage.
"""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
settings = (root / 'Cuate/Providers/AppSettings.swift').read_text()
properties = settings[settings.index('    @Published var compressionTokenThreshold:'):settings.index('    // MARK: - Web search')].replace('@Published ', '')
initializers = settings[settings.index('        compressionTokenThreshold = ContextCompressionPolicy'):settings.index('        appearanceMode =', settings.index('        compressionTokenThreshold = ContextCompressionPolicy'))]
chat = (root / 'Cuate/Providers/ChatService.swift').read_text()
compression = chat[chat.index('    // MARK: - Context compression'):]
store_source = (root / 'Cuate/Models/ChatModels.swift').read_text()
accessors = store_source[store_source.index('    var totalMessageCount:'):store_source.index('    // MARK: Persistence')]

source = '''import Foundation
@MainActor final class AppSettings {
    static let suiteName = "cuate-compression-test-" + ProcessInfo.processInfo.globallyUniqueString
    static let shared = AppSettings()
    let defaults: UserDefaults
    var chatProvider = "test"
    func resolvedAPIKey(for provider: String) throws -> String { "fake" }
    func selectedModel(for provider: String) -> String? { "test" }
''' + properties + '''
    init() {
        defaults = UserDefaults(suiteName: Self.suiteName)!
''' + initializers + '''
    }
}
struct Attachment { var ocrText: String? = nil; var isDocument = false }
enum MessageType { case system, text }
struct ChatMessage {
    var id = UUID()
    var text: String
    var isUser = true
    var toolContext: String? = nil
    var messageType = MessageType.text
    var attachments: [Attachment] = []
}
@MainActor final class ChatStore {
    struct Conversation: Equatable { let storageKey: String; var isAgent: Bool { storageKey == "agent" } }
    var conversation = Conversation(storageKey: "general")
    typealias ConversationID = Conversation
    var messages: [ChatMessage] = []
    var windowStart = 0
    var conversationSummary: String?
    var summaryCoversCount = 0
    var covers: Int { get { summaryCoversCount } set { summaryCoversCount = newValue } }
    func scheduleSave() {}
''' + accessors + '''
}
@MainActor enum ChatPersistence {
    static var summaries: [String: (String, Int)] = [:]
    static func updateSummary(_ summary: String, coversCount: Int, forKey key: String) {
        summaries[key] = (summary, coversCount)
    }
}

enum APIKeyStore { static func warmIfNeeded() async {} }
enum Diagnostics { static func log(_ category: String, _ event: String) {} }
struct LLMMessage { enum Role { case user }; var role: Role; var text: String }
struct ChatRequestOptions {
    enum Kind { case summary }; enum Reasoning { case fast }
    var reportOutcome: ((String) -> Void)? = nil
    var spendKind: Kind; var maxTokens: Int; var reasoning: Reasoning
}
enum StreamEvent { case text(String) }
@MainActor final class FakeProvider {
    var calls = 0
    var fail = false
    var prompt = ""
    var output = ""
    var outcome = "completed"
    var hold = false
    var pending: [AsyncThrowingStream<StreamEvent, Error>.Continuation] = []
    func streamChat(messages: [LLMMessage], model: String, systemPrompt: String?, options: ChatRequestOptions, apiKey: String) -> AsyncThrowingStream<StreamEvent, Error> {
        calls += 1
        options.reportOutcome?(outcome)
        prompt = messages[0].text
        return AsyncThrowingStream { continuation in
            if hold { pending.append(continuation); return }
            if fail { continuation.finish(throwing: NSError(domain: "test", code: 1)); return }
            continuation.yield(.text(output))
            continuation.finish()
        }
    }
}
@MainActor enum ProviderRegistry {
    static let fake = FakeProvider()
    static func provider(for provider: String) -> FakeProvider { fake }
}
enum ChatService {
    static func documentLabel(_ attachment: Attachment) -> String { "file.pdf" }
''' + compression + '''
@main struct Tests {
    @MainActor static func main() async {
        let settings = AppSettings.shared
        defer { settings.defaults.removePersistentDomain(forName: AppSettings.suiteName) }
        let fake = ProviderRegistry.fake
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            precondition(condition, label)
            checks += 1
        }
        func notes(_ text: String) -> String {
            let object: [String: [String]] = ["facts": [text], "decisions": [], "preferences": [], "openTasks": []]
            return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        }
        func message(_ id: Int) -> ChatMessage {
            ChatMessage(text: "ROW[\(id)] " + String(repeating: "x", count: 3400), isUser: id % 2 == 1)
        }
        func compress(_ store: ChatStore) async { await ChatService.compressHistoryIfNeeded(store: store) }
        check(settings.compressionTokenThreshold == 7000, "default")
        settings.compressionTokenThreshold = 5000
        let reloaded = AppSettings()
        check(reloaded.compressionTokenThreshold == 5000, "persist global threshold")
        settings.defaults.set(["general": 24000], forKey: "chatCompressionThresholds")
        check(AppSettings().compressionTokenThreshold == 5000, "legacy overrides ignored")
        settings.compressionTokenThreshold = 7000
        let chain = ChatStore()
        chain.messages = (1...20).map(message)
        fake.output = notes("S1 valid fact")
        settings.compressionTokenThreshold = 24000
        await compress(chain)
        check(fake.calls == 0, "17k below24k")
        settings.compressionTokenThreshold = 7000
        await compress(chain)
        check(chain.covers == 16 && chain.activeContextMessages.count == 4, "token-sized complete-turn tail")
        check(chain.messages.count == 20 && chain.conversationSummary?.contains("S1 valid fact") == true, "originals and notes")
        check(fake.prompt.contains("ROW[16]") && !fake.prompt.contains("ROW[17]"), "first exact prefix")
        chain.messages += (21...26).map(message)
        fake.output = notes("S2 valid fact")
        await compress(chain)
        check(chain.covers == 22 && chain.activeContextMessages.count == 4, "second boundary")
        check(fake.prompt.contains("S1 valid fact") && fake.prompt.contains("ROW[17]") && !fake.prompt.contains("ROW[1]") && !fake.prompt.contains("ROW[23]"), "second merges only new prefix")
        chain.messages += (27...32).map(message)
        fake.output = notes("S3 valid fact")
        await compress(chain)
        check(chain.covers == 28 && chain.messages.count == 32, "third boundary originals retained")
        check(fake.prompt.contains("S2 valid fact") && !fake.prompt.contains("S1 valid fact"), "one rolling summary")
        let reload = ChatStore()
        reload.messages = Array(chain.messages.dropFirst(10)); reload.windowStart = 10
        reload.summaryCoversCount = chain.summaryCoversCount; reload.conversationSummary = chain.conversationSummary
        check(reload.activeContextMessages.map { $0.id } == chain.activeContextMessages.map { $0.id }, "window offsets")
        let before = fake.calls
        await compress(chain)
        check(fake.calls == before, "no unnecessary summary below threshold")
        let long = ChatStore()
        long.messages = (1...6).map(message)
        long.conversationSummary = String(repeating: "x", count: 40000)
        fake.output = notes("Compact old notes")
        await compress(long)
        check(long.covers > 0, "summary counted and short-history guard removed")
        let bad = ChatStore(); bad.messages = (1...20).map(message)
        for invalid in ["Facts:", "{}", "{", notes(String(repeating: "x", count: 100000)), " "] {
            fake.output = invalid
            await compress(bad)
            check(bad.covers == 0 && bad.conversationSummary == nil, "reject invalid or oversized notes")
        }
        fake.output = notes("Valid fact")
        for outcome in ["incomplete", "failed", "cancelled"] {
            fake.outcome = outcome
            await compress(bad)
            check(bad.covers == 0, "reject unsuccessful provider outcome")
        }
        fake.outcome = "completed"; fake.fail = true
        await compress(bad)
        check(bad.covers == 0, "transport failure retains history")
        fake.fail = false; fake.hold = true
        let racing = ChatStore(); racing.messages = (1...20).map(message)
        let first = Task { await compress(racing) }
        while fake.pending.isEmpty { await Task.yield() }
        let started = fake.calls
        racing.messages += (21...26).map(message)
        await compress(racing)
        check(fake.calls == started && fake.pending.count == 1, "single flight blocks overlap")
        fake.pending[0].yield(.text(notes("First"))); fake.pending[0].finish()
        await first.value
        check(racing.covers == 16 && racing.messages.count == 26, "append-safe commit preserves new rows")
        fake.pending.removeAll()
        let clearing = ChatStore(); clearing.messages = (1...20).map(message)
        let old = Task { await compress(clearing) }
        while fake.pending.isEmpty { await Task.yield() }
        clearing.messages = [message(101), message(102)]
        fake.pending[0].yield(.text(notes("Deleted facts"))); fake.pending[0].finish()
        await old.value
        check(clearing.conversationSummary == nil && clearing.covers == 0 && clearing.activeContextMessages.count == 2, "reset rejects stale summary")
        fake.pending.removeAll()
        let switching = ChatStore(); switching.messages = (1...20).map(message)
        let switched = Task { await compress(switching) }
        while fake.pending.isEmpty { await Task.yield() }
        switching.conversation = ChatStore.Conversation(storageKey: "other")
        fake.pending[0].yield(.text(notes("Old chat"))); fake.pending[0].finish()
        await switched.value
        check(switching.conversationSummary == nil && ChatPersistence.summaries.isEmpty, "switch discards stale result without dormant write")
        fake.pending.removeAll()
        let editing = ChatStore(); editing.messages = (1...20).map(message)
        let edited = Task { await compress(editing) }
        while fake.pending.isEmpty { await Task.yield() }
        editing.messages[0].text = "Changed fact"
        fake.pending[0].yield(.text(notes("Old fact"))); fake.pending[0].finish()
        await edited.value
        check(editing.covers == 0, "edit rejects stale result")
        fake.pending.removeAll()
        let cancelled = Task { await compress(editing) }
        while fake.pending.isEmpty { await Task.yield() }
        cancelled.cancel()
        fake.pending[0].yield(.text(notes("Cancelled fact"))); fake.pending[0].finish()
        await cancelled.value
        check(editing.covers == 0, "cancelled summary cannot commit")
        fake.hold = false
        let agent = ChatStore(); agent.conversation = ChatStore.Conversation(storageKey: "agent")
        agent.messages = (1...20).map(message)
        let agentCalls = fake.calls
        await compress(agent)
        check(fake.calls == agentCalls, "agent bypass")
        let noSavings = ChatStore()
        noSavings.messages = [ChatMessage(text: "Hi"), ChatMessage(text: "OK", isUser: false), message(3), message(4)]
        settings.compressionTokenThreshold = 1000
        fake.output = notes("A valid but longer replacement for Hi and OK")
        await compress(noSavings)
        check(noSavings.covers == 0, "reject expanding summary even within output budget")
        let single = ChatStore(); single.messages = [message(1), message(2)]
        let singleCalls = fake.calls
        await compress(single)
        check(fake.calls == singleCalls, "latest oversized turn never summarized away")
        check(ContextCompressionPolicy.validatedSummary(notes("")) == nil, "empty categories rejected")
        let snapshot = chain.messages
        let priorSummary = chain.conversationSummary
        let priorCovers = chain.covers
        chain.conversationSummary = "Changed concurrently"
        check(!chain.setSummary("Stale", coversCount: priorCovers, for: chain.conversation,
                                expectedMessages: snapshot, expectedWindowStart: 0,
                                previousSummary: priorSummary, previousCoversCount: priorCovers), "summary revision rejects stale commit")
        settings.compressionTokenThreshold = 7000
        let grounding = ChatStore(); grounding.messages = (1...20).map(message)
        grounding.messages[0].toolContext = "Tool fact: budget 12345"
        grounding.messages[0].attachments = [Attachment(ocrText: String(repeating: "x", count: 1200) + " OCR_END")]
        fake.output = notes("Grounded fact")
        await compress(grounding)
        check(fake.prompt.contains("Tool fact: budget 12345") && fake.prompt.contains("OCR_END"), "tool context and full cached image OCR enter summary")
        print("Context compression: \(checks) checks passed")
    }
}

'''
with tempfile.TemporaryDirectory(prefix='cuate-compression-') as temp:
    temp = Path(temp)
    harness = temp / 'Contracts.swift'
    harness.write_text(source)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-default-isolation', 'MainActor',
                    *(['-sdk', os.environ['SDKROOT']] if os.environ.get('SDKROOT') else []),
                    '-module-cache-path', str(temp / 'cache'), '-o', str(temp / 'test'),
                    str(root / 'Cuate/Providers/ContextCompressionPolicy.swift'), str(harness)], check=True)
    subprocess.run([str(temp / 'test')], check=True)
