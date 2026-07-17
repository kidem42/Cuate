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
/// the input (GIF/лимиты — с плашками), run, convert the output format,
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

        if postSourceMessage {
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
                    () -> (data: Data, mime: String, notes: [ImageInputPreparer.InputNote], mask: Data?) in
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
                    return (prepared.data, prepared.mime, prepared.notes, mask)
                }.value
                for note in normalized.notes {
                    chatStore.addMessage(text: noteText(note), isUser: false, messageType: .system)
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

                // Output format: user's choice, кроме фона — там всегда PNG
                // (альфа-канал), ТЗ §4.4b.
                var outData = result.image
                var outMime = result.mimeType
                if function != .removeBackground {
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
                chatStore.appendNow(ChatMessage(text: caption, isUser: false, attachments: [attachment]))

                if settings.autoCopyResult, let image = NSImage(data: outData) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                }
            } catch is CancellationError {
                chatStore.addMessage(text: IAL("ia.status.cancelledMsg"), isUser: false, messageType: .system)
                restoreAttachment(source)
            } catch {
                chatStore.addMessage(text: error.localizedDescription, isUser: false, messageType: .system)
                // «Повторить»: источник возвращается в композер — повторный
                // запуск в один клик (плюс авто-ретрай уже внутри раннера).
                restoreAttachment(source)
            }
            chatStore.statusText = nil
            chatStore.setLoading(false)
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

    static func restoreAttachment(_ attachment: ChatAttachment) {
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

/// Stores oversized results as files under Application Support so chat.json
/// stays lean (ТЗ §6: > 8 MB → файловая ссылка).
enum ImageResultStore {
    static let inlineLimit = 8 * 1024 * 1024

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AISpotlight/images", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func makeAttachment(data: Data, mime: String, filename: String) -> ChatAttachment {
        guard data.count > inlineLimit else {
            return ChatAttachment(filename: filename, mimeType: mime, base64: data.base64EncodedString())
        }
        let id = UUID()
        let url = directory.appendingPathComponent("\(id.uuidString)-\(filename)")
        do {
            try data.write(to: url, options: .atomic)
            Diagnostics.log("imageaddon", "result.file bytes=\(data.count) → \(url.lastPathComponent)")
            return ChatAttachment(filename: filename, mimeType: mime, base64: "", id: id, fileURLString: url.path)
        } catch {
            // Disk write failed — fall back to inline rather than losing the result.
            return ChatAttachment(filename: filename, mimeType: mime, base64: data.base64EncodedString(), id: id)
        }
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
