import Foundation

/// The translation run: the selection in chunks, each streamed through the
/// resolved provider with the addon's prompt, the replies shaped before they
/// reach the bubble. Reuses the host's provider stack exactly like
/// `DictationService.postProcess`; nothing is recorded in the spend ledger,
/// the same as the dictation pass.
@MainActor
enum TranslatorService {
    enum Event {
        /// The run starts with this many chunks.
        case started(chunks: Int)
        /// Chunk `index` (0-based) starts streaming.
        case chunkBegan(Int)
        /// The whole partial reply of the current chunk so far.
        case partial(String)
        /// The current chunk is complete: its shaped translation.
        case chunkEnded(String)
        case finished
        /// A user-facing message; the run stops.
        case failed(String)
    }

    /// Runs to completion or cancellation, delivering events on the main
    /// actor. Cancel the surrounding task to abort.
    static func run(text: String, settings: TranslatorSettings, handle: @escaping @MainActor (Event) -> Void) async {
        await APIKeyStore.warmIfNeeded() // key lookups below are cache-only
        guard let choice = settings.resolvedModel() else {
            Diagnostics.log("translator", "run.noModel")
            handle(.failed(TRL("tr.bubble.noModel")))
            return
        }
        let provider = ProviderRegistry.provider(for: choice.provider)
        let apiKey = (try? AppSettings.shared.resolvedAPIKey(for: choice.provider)) ?? ""
        let chunks = TranslatorPrompt.chunks(text)
        guard !chunks.isEmpty else {
            handle(.finished)
            return
        }
        let system = TranslatorPrompt.systemPrompt(target: settings.targetLanguage, fallback: settings.fallbackLanguage)
        Diagnostics.log("translator", "run \(choice.provider.rawValue)/\(choice.model) chars=\(text.count) chunks=\(chunks.count)")
        handle(.started(chunks: chunks.count))

        let started = Date()
        for (index, chunk) in chunks.enumerated() {
            if Task.isCancelled { return }
            handle(.chunkBegan(index))
            var reply = ""
            let stream = provider.streamChat(
                messages: [LLMMessage(role: .user, text: TranslatorPrompt.userMessage(chunk))],
                model: choice.model,
                systemPrompt: system,
                options: ChatRequestOptions(maxTokens: 4096, reasoning: .fast, preferNoReasoning: true),
                apiKey: apiKey
            )
            do {
                for try await event in stream {
                    if Task.isCancelled { return }
                    if case .text(let piece) = event {
                        reply += piece
                        handle(.partial(reply))
                    }
                }
            } catch {
                if Task.isCancelled { return }
                Diagnostics.log("translator", "run.failed \(choice.provider.rawValue)/\(choice.model) chunk=\(index) \(String(error.localizedDescription.prefix(120)))")
                handle(.failed(TRL("tr.bubble.failed")))
                return
            }
            handle(.chunkEnded(TranslatorPrompt.shape(reply, fallback: chunk)))
        }
        Diagnostics.log("translator", "run.done ms=\(Int(Date().timeIntervalSince(started) * 1000)) chunks=\(chunks.count)")
        handle(.finished)
    }
}
