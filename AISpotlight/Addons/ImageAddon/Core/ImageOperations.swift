import Foundation
import SwiftUI
import AppKit

extension Notification.Name {
    /// The addon asks the host to make an attachment pending (retry after an
    /// error, «Продолжить редактирование»). ChatWindow observes.
    static let imageAddonAttachRequest = Notification.Name("imageAddonAttachRequest")
}

/// Weak handle to the live chat store, registered by ChatWindow on appear
/// (host mount: one line). Lets addon views that live deep in the message
/// list (result bar) run operations without threading the store through
/// every host view.
@MainActor
enum ChatWindowBridge {
    static weak var chatStore: ChatStore?
}

/// Session-scoped memory of what produced each result attachment — powers
/// «Повторить с другой моделью» and «Продолжить редактирование» (ТЗ §4.3).
/// Deliberately not persisted: after a relaunch the buttons just don't show.
@MainActor
final class ImageResultRegistry {
    struct Record {
        let source: ChatAttachment
        let function: ImageFunction
        let modelID: String
        var factor: Int?
        var faceEnhance: Bool
        var maskPNG: Data?
        var prompt: String?
    }

    static let shared = ImageResultRegistry()
    private var records: [UUID: Record] = [:]
    private init() {}

    func remember(_ record: Record, for attachmentID: UUID) {
        records[attachmentID] = record
    }

    func record(for attachmentID: UUID) -> Record? {
        records[attachmentID]
    }
}

/// The addon's operation pipeline, shared by the actions bar, slash
/// commands, and the result bar: post the source into the chat, normalize
/// the input (GIF/лимиты — с плашками, прозрачность — флэттен на белый),
/// run, restore/sanitize the alpha channel, convert the output format,
/// offload large results to disk, append the result, remember it in the
/// registry, auto-copy if enabled. On failure the source attachment is
/// restored so the user can retry with one click.
@MainActor
enum ImageOperations {

    static func run(
        function: ImageFunction,
        model: ImageModelInfo,
        source: ChatAttachment,
        chatStore: ChatStore,
        factor: Int? = nil,
        faceEnhance: Bool = false,
        maskPNG: Data? = nil,
        prompt: String? = nil,
        postSourceMessage: Bool = true
    ) {
        guard let sourceData = source.data else { return }
        let settings = ImageAddonSettings.shared

        // The conversation this operation belongs to. Image ops take seconds;
        // if the user switches to another preset chat meanwhile, results and
        // notes are delivered back HERE (deliver routes them to the dormant
        // store) instead of landing in whatever chat happens to be open —
        // same origin discipline as the text-streaming path.
        let origin = chatStore.conversation
        func isLive() -> Bool { chatStore.conversation == origin }

        // Restored attachments are already visible in the chat — reposting
        // the source would only duplicate the image (and trip the store's
        // unique-id index into an empty bubble).
        if postSourceMessage, !isRestoredFromChat(source) {
            chatStore.appendNow(ChatMessage(text: "", isUser: true, attachments: [source]))
        }
        // Synchronous set (NOT setLoading's async dispatch): the thinking
        // pill must appear in the SAME SwiftUI update as the source message,
        // so the chat auto-scroll lands on the pill, not one frame short.
        chatStore.isLoading = true
        chatStore.statusText = String(format: IAL(statusKey(for: function)), model.name)

        Task { @MainActor in
            do {
                // Input rules: GIF → первый кадр, большой вход → даунскейл.
                // Off the main actor — re-encoding a multi-MB image inline
                // froze the panel right when the progress UI should show.
                let sourceMime = source.mimeType
                let maxMP = settings.maxInputMegapixels
                let normalized = try await Task.detached(priority: .userInitiated) {
                    () -> (data: Data, mime: String, notes: [ImageInputPreparer.InputNote], mask: Data?, alphaMask: Data?) in
                    let prepared = try ImageInputPreparer.normalizeForOperation(
                        data: sourceData,
                        mime: sourceMime,
                        maxMegapixels: maxMP,
                        maxBytes: ImageAddonSettings.maxInputBytes
                    )
                    // The mask was painted at the ORIGINAL resolution; after a
                    // downscale it must be re-rendered to the exact pixel size
                    // of the normalized image (mask APIs require identical
                    // dimensions, and an oversized mask trips the same input
                    // limits the downscale exists to avoid).
                    var mask = maskPNG
                    if let maskData = mask,
                       let imageSize = ImageInputPreparer.pixelSize(of: prepared.data),
                       let maskSize = ImageInputPreparer.pixelSize(of: maskData),
                       maskSize != imageSize {
                        mask = ImageInputPreparer.resizeImage(maskData, to: imageSize) ?? maskData
                    }
                    // Прозрачный вход флэттенится на белый: fal-модели альфу
                    // игнорируют и работают с RGB — у вырезок там лежит
                    // исходный фон (см. Alpha handling в ImageInputPreparer).
                    // Альфа-маску запоминаем: после апскейла она вернётся на
                    // результат.
                    var sendData = prepared.data
                    var sendMime = prepared.mime
                    var alphaMask: Data?
                    if let flat = ImageInputPreparer.flattenIfTransparent(sendData) {
                        sendData = flat.flattened
                        sendMime = "image/png"
                        alphaMask = flat.alphaMask
                    }
                    return (sendData, sendMime, prepared.notes, mask, alphaMask)
                }.value
                for note in normalized.notes {
                    chatStore.deliver(
                        ChatMessage(text: noteText(note), isUser: false, messageType: .system),
                        to: origin
                    )
                }

                var params: [String: Any] = [:]
                if let factor { params[ImageParam.factor] = factor }
                if faceEnhance { params[ImageParam.faceEnhance] = true }

                let request = ImageRequest(
                    function: function,
                    model: model.id,
                    inputImage: normalized.data,
                    inputMime: normalized.mime,
                    maskImage: normalized.mask,
                    prompt: prompt,
                    params: params
                )
                let result = try await ImageTaskRunner.shared.perform(request)

                var outData = result.image
                var outMime = result.mimeType

                // Результат удаления фона несёт нетронутый оригинал в RGB под
                // прозрачностью — затираем (иначе фон утекает в сохранённый
                // файл и «воскресает» в альфа-слепых обработчиках).
                if function == .removeBackground {
                    let payload = outData
                    if let sanitized = await Task.detached(priority: .userInitiated, operation: {
                        ImageInputPreparer.sanitizedTransparency(payload)
                    }).value {
                        outData = sanitized
                        outMime = "image/png"
                    }
                }

                // Апскейл вырезки: модели возвращают непрозрачный RGB —
                // восстанавливаем прозрачность масштабированием исходной
                // альфа-маски (локально, бесплатно).
                var restoredAlpha = false
                if function == .upscale, let mask = normalized.alphaMask {
                    let payload = outData
                    if let masked = await Task.detached(priority: .userInitiated, operation: {
                        ImageInputPreparer.applyingAlphaMask(mask, to: payload)
                    }).value {
                        outData = masked
                        outMime = "image/png"
                        restoredAlpha = true
                    }
                }

                // Output format: user's choice, кроме фона и восстановленной
                // прозрачности — там всегда PNG (альфа-канал), ТЗ §4.4b.
                if function != .removeBackground, !restoredAlpha {
                    (outData, outMime) = ImageInputPreparer.convert(outData, from: outMime, to: settings.outputFormat)
                }

                let filename = ImageResultNaming.filename(
                    source: source.filename,
                    suffix: suffix(for: function),
                    mime: outMime
                )
                // Large payloads live as files, not base64 in chat.json (ТЗ §6).
                let attachment = ImageResultStore.makeAttachment(data: outData, mime: outMime, filename: filename)

                ImageResultRegistry.shared.remember(
                    .init(source: source, function: function, modelID: model.id,
                          factor: factor, faceEnhance: faceEnhance,
                          maskPNG: maskPNG, prompt: prompt),
                    for: attachment.id
                )

                var caption = String(format: IAL(resultKey(for: function)), model.name)
                if function == .upscale, let factor { caption += " ×\(factor)" }
                chatStore.deliver(ChatMessage(text: caption, isUser: false, attachments: [attachment]), to: origin)

                if settings.autoCopyResult, let image = NSImage(data: outData) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                }
            } catch is CancellationError {
                chatStore.deliver(
                    ChatMessage(text: IAL("ia.status.cancelledMsg"), isUser: false, messageType: .system),
                    to: origin
                )
                restoreAttachment(source)
            } catch {
                chatStore.deliver(
                    ChatMessage(text: error.localizedDescription, isUser: false, messageType: .system),
                    to: origin
                )
                // «Повторить»: источник возвращается в композер — повторный
                // запуск в один клик (плюс авто-ретрай уже внутри раннера).
                restoreAttachment(source)
            }
            // The pill belongs to the origin chat; after a switch the store's
            // status/loading were already reset by switchConversation.
            if isLive() {
                chatStore.statusText = nil
                chatStore.setLoading(false)
            }
        }
    }

    /// Re-runs the operation recorded for a result with another model.
    static func rerun(record: ImageResultRegistry.Record, with model: ImageModelInfo, chatStore: ChatStore) {
        run(
            function: record.function,
            model: model,
            source: record.source,
            chatStore: chatStore,
            factor: record.factor.map { min($0, model.maxUpscaleFactor ?? $0) },
            faceEnhance: record.faceEnhance && model.supportsFaceEnhance,
            maskPNG: record.maskPNG,
            prompt: record.prompt,
            postSourceMessage: false
        )
    }

    /// Attachments put back into the composer from an already-shown chat
    /// message («Продолжить редактирование», ретрай после ошибки/отмены).
    /// Их бабл-источник повторно НЕ постится: картинка уже видна в чате, а
    /// уникальный индекс вложений в сторе всё равно оставил бы второе
    /// сообщение без вложения (пустой бабл после перезагрузки). Session-
    /// scoped — после перезапуска карандаш просто снова пометит id.
    private static var restoredIDs: Set<UUID> = []

    static func isRestoredFromChat(_ attachment: ChatAttachment) -> Bool {
        restoredIDs.contains(attachment.id)
    }

    /// Fresh identity (new id + own file) for the rare path that DOES post a
    /// restored attachment as a new chat row (обычная отправка сообщения в
    /// LLM с таким вложением) — иначе коллизия по уникальному индексу.
    static func freshCopyForPosting(_ attachment: ChatAttachment) -> ChatAttachment {
        guard let data = attachment.data else { return attachment }
        return ChatAttachment.fileBacked(data: data, mimeType: attachment.mimeType, filename: attachment.filename)
    }

    /// Puts an attachment (back) into the composer — «Продолжить
    /// редактирование» и восстановление после ошибки/отмены. No copy is
    /// made: the bytes go to the provider from memory, and the source
    /// bubble is skipped for restored attachments (see `restoredIDs`).
    static func restoreAttachment(_ attachment: ChatAttachment) {
        restoredIDs.insert(attachment.id)
        NotificationCenter.default.post(name: .imageAddonAttachRequest, object: attachment)
    }

    // MARK: - Strings

    private static func statusKey(for function: ImageFunction) -> String {
        switch function {
        case .upscale: return "ia.status.upscaling"
        case .removeBackground: return "ia.status.removingBg"
        case .objectCleanup: return "ia.status.cleaning"
        case .generate: return "ia.status.upscaling"
        }
    }

    private static func resultKey(for function: ImageFunction) -> String {
        switch function {
        case .upscale: return "ia.result.upscaled"
        case .removeBackground: return "ia.result.nobg"
        case .objectCleanup: return "ia.result.cleaned"
        case .generate: return "ia.result.upscaled"
        }
    }

    private static func suffix(for function: ImageFunction) -> String {
        switch function {
        case .upscale: return "upscaled"
        case .removeBackground: return "nobg"
        case .objectCleanup: return "cleaned"
        case .generate: return "generated"
        }
    }

    private static func noteText(_ note: ImageInputPreparer.InputNote) -> String {
        switch note {
        case .gifFirstFrame:
            return IAL("ia.note.gif")
        case .downscaled(let from, let to):
            return String(format: IAL("ia.note.downscaled"), from, to)
        }
    }
}

/// Stores image results as files under Application Support so the chat store
/// stays lean. Routes through the shared `ChatAttachment.fileBacked` factory —
/// the same path used for pasted images, file attachments and screenshots — so
/// every attachment in the app is file-backed. (Previously results under 8 MB
/// were inlined as base64, which bloated the store and was inconsistent with
/// the rest of the app.)
enum ImageResultStore {
    static func makeAttachment(data: Data, mime: String, filename: String) -> ChatAttachment {
        let attachment = ChatAttachment.fileBacked(data: data, mimeType: mime, filename: filename)
        Diagnostics.log("imageaddon", "result bytes=\(data.count) fileBacked=\(attachment.fileURLString != nil)")
        return attachment
    }
}

/// «×» button in the thinking pill while an image operation runs (host
/// mount: one line in ChatWindow's indicator). Self-gated: renders nothing
/// when no operation is in flight.
struct ImageOperationCancelButton: View {
    @ObservedObject private var runner = ImageTaskRunner.shared

    var body: some View {
        if runner.isRunning {
            Button {
                runner.cancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .help(IAL("ia.cancel.help"))
        }
    }
}

/// Slash commands `/upscale [2|4|8]`, `/bg`, `/cleanup <что удалить>` —
/// alternative to the buttons, acting on the current attachment (ТЗ §4.2).
/// Host mount: one call at the top of ChatWindow.sendMessage.
@MainActor
enum ImageSlashCommands {
    /// Returns true when the input was consumed as a command.
    static func handle(
        input: String,
        attachment: ChatAttachment?,
        chatStore: ChatStore,
        clearAttachment: () -> Void
    ) -> Bool {
        let settings = ImageAddonSettings.shared
        guard settings.enabled else { return false }

        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return false }
        let parts = trimmed.split(separator: " ", maxSplits: 1)
        let command = parts[0].lowercased()
        let argument = parts.count > 1 ? String(parts[1]) : ""

        let known = ["/upscale", "/bg", "/cleanup"]
        guard known.contains(command) else { return false }

        guard let attachment, attachment.mimeType.hasPrefix("image") else {
            chatStore.addMessage(text: IAL("ia.slash.needAttachment"), isUser: false, messageType: .system)
            return true
        }

        switch command {
        case "/upscale":
            guard let model = settings.upscaleModelInfo else { return true }
            let requested = Int(argument)
            let factor = model.maxUpscaleFactor.map { max in
                min(requested ?? 2, max)
            }
            clearAttachment()
            ImageOperations.run(function: .upscale, model: model, source: attachment,
                                chatStore: chatStore, factor: factor)
        case "/bg":
            guard let model = settings.backgroundModelInfo else { return true }
            clearAttachment()
            ImageOperations.run(function: .removeBackground, model: model, source: attachment,
                                chatStore: chatStore)
        case "/cleanup":
            guard !argument.isEmpty else {
                chatStore.addMessage(text: IAL("ia.slash.cleanupNeedsText"), isUser: false, messageType: .system)
                return true
            }
            guard let model = settings.cleanupTextModelInfo else { return true }
            clearAttachment()
            ImageOperations.run(function: .objectCleanup, model: model, source: attachment,
                                chatStore: chatStore, prompt: argument)
        default:
            return false
        }
        return true
    }
}
