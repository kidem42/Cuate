import SwiftUI
import AppKit

/// Save/Copy row under an image the assistant produced (host mount: one
/// line in `MessageRow`). Save is one-click: the file lands in the folder
/// from the addon settings (Downloads by default) — no dialogs.
///
/// Renders nothing when the addon is off or the attachment isn't an image,
/// so the host call site stays unconditional.
struct ImageResultActionsBar: View {
    let attachment: ChatAttachment

    @ObservedObject private var settings = ImageAddonSettings.shared
    @ObservedObject private var runner = ImageTaskRunner.shared
    @Environment(\.themePalette) private var palette
    @State private var savedURL: URL?
    @State private var justCopied = false
    @State private var saveError: String?

    var body: some View {
        if settings.enabled, attachment.mimeType.hasPrefix("image") {
            VStack(alignment: .leading, spacing: 2) {
                // Иконки вместо текста (кроме ретрай-меню): подписи живут в
                // тултипах и accessibility-лейблах.
                HStack(spacing: 12) {
                    iconButton(
                        icon: savedURL == nil ? "square.and.arrow.down" : "checkmark",
                        label: savedURL == nil ? IAL("ia.result.save") : IAL("ia.result.saved"),
                        help: String(format: IAL("ia.help.save"),
                                     (settings.saveFolderURL.path as NSString).abbreviatingWithTildeInPath)
                    ) { save() }

                    if savedURL != nil {
                        iconButton(icon: "folder",
                                   label: IAL("ia.result.reveal"),
                                   help: IAL("ia.help.reveal")) { reveal() }
                    }

                    iconButton(
                        icon: justCopied ? "checkmark" : "doc.on.doc",
                        label: justCopied ? IAL("ia.result.copied") : IAL("ia.result.copy"),
                        help: IAL("ia.help.copy")
                    ) { copy() }

                    // «Продолжить редактирование» — у ЛЮБОГО результата:
                    // картинка возвращается в композер, где доступны все
                    // функции аддона (апскейл/фон/объекты).
                    iconButton(icon: "pencil",
                               label: IAL("ia.result.continueEditing"),
                               help: IAL("ia.help.continueEditing")) {
                        ImageOperations.restoreAttachment(attachment)
                    }

                    // «Повторить с другой моделью» — только пока жива
                    // сессионная запись о том, чем этот результат был
                    // получен (ТЗ §4.3). Текстом — по решению дизайна.
                    if let record = ImageResultRegistry.shared.record(for: attachment.id) {
                        retryMenu(record)
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
                .tint(palette.isGlass ? nil : palette.ink)

                if let saveError {
                    Text(String(format: IAL("ia.error.saveFailed"), saveError))
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
        }
    }

    /// Icon-only action: the text lives in the tooltip; VoiceOver reads the
    /// original label.
    private func iconButton(icon: String, label: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
        }
        .help(help)
        .accessibilityLabel(label)
    }

    /// Other models of the same function → re-run on the remembered source.
    @ViewBuilder
    private func retryMenu(_ record: ImageResultRegistry.Record) -> some View {
        let alternatives = ImageProviderRegistry.models(for: record.function)
            .filter { $0.id != record.modelID }
            .filter { record.function != .objectCleanup || $0.cleanupByText == (record.prompt != nil) }
        if !alternatives.isEmpty, let chatStore = ChatWindowBridge.chatStore {
            Menu(IAL("ia.result.retryOther")) {
                ForEach(alternatives) { model in
                    Button("\(model.name) — \(model.tier.label) · \(model.priceLabel)") {
                        ImageOperations.rerun(record: record, with: model, chatStore: chatStore)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(runner.isRunning)
            .help(IAL("ia.help.retryOther"))
        }
    }

    // MARK: - Actions

    private func save() {
        guard let data = attachment.data else { return }
        let folder = settings.saveFolderURL
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = Self.uniqueURL(in: folder, filename: attachment.filename)
            try data.write(to: url, options: .atomic)
            savedURL = url
            saveError = nil
            Diagnostics.log("imageaddon", "save bytes=\(data.count) → \(url.path)")
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func reveal() {
        guard let savedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([savedURL])
    }

    private func copy() {
        guard let data = attachment.data, let image = NSImage(data: data) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        withAnimation { justCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { justCopied = false }
        }
    }

    /// "photo-upscaled.png" → "photo-upscaled-2.png" when the name is taken.
    private static func uniqueURL(in folder: URL, filename: String) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = folder.appendingPathComponent(filename)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            candidate = folder.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }
}
