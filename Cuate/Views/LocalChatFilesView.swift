import SwiftUI
import AppKit

/// Header folder popover for ORDINARY (non-agent) chats — the same idea as
/// the Hermes agent's CHAT FILES: everything exchanged with the model in
/// this conversation, without scrolling the transcript. Three groups:
/// files the user attached, documents the model produced (HTML/Markdown
/// artifact fences), and Plaud recordings the model touched.
struct LocalChatFilesView: View {
    struct AttachmentRow: Identifiable {
        let id: UUID
        let attachment: ChatAttachment
        /// The message's timestamp — the retention clock of the attachment.
        let attachedAt: Date
    }
    struct ArtifactRow: Identifiable {
        let id: String
        let kind: ArtifactKind
        let title: String
        let content: String
    }
    struct PlaudRow: Identifiable {
        let id: String // recording fileID
        let title: String
    }

    let userFiles: [AttachmentRow]
    let artifacts: [ArtifactRow]
    let plaudNotes: [PlaudRow]
    /// Documents only: puts the file back into the next message (the host
    /// reuses the provider-side copy, so nothing is uploaded twice).
    var onAttachAgain: ((ChatAttachment) -> Void)? = nil

    func attachAgain(_ handler: @escaping (ChatAttachment) -> Void) -> LocalChatFilesView {
        var copy = self
        copy.onAttachAgain = handler
        return copy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("chatfiles.title"))
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            if userFiles.isEmpty && artifacts.isEmpty && plaudNotes.isEmpty {
                Text(L("chatfiles.empty"))
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !artifacts.isEmpty {
                            section(L("chatfiles.model")) {
                                ForEach(artifacts) { row in
                                    fileRow(icon: row.kind.icon, title: row.title,
                                            subtitle: row.kind.typeLabel,
                                            action: {
                                                ArtifactPreview.show(kind: row.kind, content: row.content, title: row.title)
                                            },
                                            trailing: [
                                                // Same glyphs as the agent's CHAT FILES rows:
                                                // open, and reveal the file on disk.
                                                (icon: "arrow.up.forward.app", help: L("chatfiles.open"), run: {
                                                    ArtifactPreview.show(kind: row.kind, content: row.content, title: row.title)
                                                }),
                                                (icon: "folder", help: L("chatfiles.reveal"), run: {
                                                    revealOnDisk(row)
                                                }),
                                            ])
                                }
                            }
                        }
                        if !plaudNotes.isEmpty {
                            section("Plaud") {
                                ForEach(plaudNotes) { row in
                                    plaudRow(row)
                                }
                            }
                        }
                        if !userFiles.isEmpty {
                            section(L("chatfiles.user")) {
                                ForEach(userFiles) { row in
                                    fileRow(icon: rowIcon(for: row.attachment),
                                            title: row.attachment.filename,
                                            subtitle: rowSubtitle(for: row),
                                            action: { AttachmentOpener.open(row.attachment) },
                                            trailing: userActions(for: row))
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)
            content()
        }
    }

    typealias RowAction = (icon: String, help: String, run: () -> Void)

    private func fileRow(icon: String, title: String, subtitle: String,
                         action: @escaping () -> Void,
                         trailing: [RowAction] = []) -> some View {
        HStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            ForEach(Array(trailing.enumerated()), id: \.offset) { _, item in
                Button(action: item.run) {
                    Image(systemName: item.icon)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .help(item.help)
            }
        }
    }

    private func plaudRow(_ row: PlaudRow) -> some View {
        HStack(spacing: 8) {
            Button {
                PlaudNotePreview.show(fileID: row.id, fallbackTitle: row.title)
            } label: {
                HStack(spacing: 8) {
                    PlaudBadge(size: 18)
                    Text(row.title)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            Button {
                PlaudNotePreview.show(fileID: row.id, fallbackTitle: row.title)
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .help(L("chatfiles.open"))
            Button {
                PlaudAddon.openRecording(row.id)
            } label: {
                Image(systemName: "safari")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .help(PLL("plaud.chip.openInPlaud"))
        }
    }

    private func rowIcon(for attachment: ChatAttachment) -> String {
        if attachment.isDocument { return DocumentPreflight.iconName(forFilename: attachment.filename) }
        return attachment.mimeType.hasPrefix("image") ? "photo" : "doc"
    }

    /// Documents show what matters for them — pages, size and how long the
    /// chat still holds the file; everything else keeps the MIME type.
    private func rowSubtitle(for row: AttachmentRow) -> String {
        guard row.attachment.isDocument else { return row.attachment.mimeType }
        return DocumentChipView.retentionSubtitle(for: row.attachment, attachedAt: row.attachedAt)
    }

    /// Open + reveal, plus "attach again" for documents whose file is still
    /// on disk (the retention prune removes it after 15 days).
    private func userActions(for row: AttachmentRow) -> [RowAction] {
        var actions = revealActions(for: row.attachment)
        if row.attachment.isDocument, let onAttachAgain, row.attachment.fileURL != nil {
            let attachment = row.attachment
            actions.append((icon: "paperclip", help: L("chatfiles.attachAgain"), run: {
                onAttachAgain(attachment)
            }))
        }
        return actions
    }

    /// Open + reveal-in-Finder for a user attachment; reveal only exists
    /// for file-backed payloads (inline base64 has no path to show).
    private func revealActions(for attachment: ChatAttachment) -> [RowAction] {
        var actions: [RowAction] = [
            (icon: "arrow.up.forward.app", help: L("chatfiles.open"), run: {
                AttachmentOpener.open(attachment)
            })
        ]
        if let url = attachment.fileURL, FileManager.default.fileExists(atPath: url.path) {
            actions.append((icon: "folder", help: L("chatfiles.reveal"), run: {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }))
        }
        return actions
    }

    /// Artifacts live inside the chat text — materialize the document as a
    /// real file and select it in Finder, mirroring the agent panel's
    /// reveal button.
    private func revealOnDisk(_ row: ArtifactRow) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CuateArtifacts", isDirectory: true)
        let url = directory.appendingPathComponent(
            ArtifactPreview.fileStem(for: row.title) + "." + row.kind.fileExtension
        )
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try row.content.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSSound.beep()
        }
    }

    // MARK: - Collection

    /// Walks the conversation newest-first and gathers the three groups.
    /// Artifact extraction rides the markdown parse cache — messages already
    /// rendered cost nothing to re-scan.
    @MainActor
    static func collect(from messages: [ChatMessage]) -> LocalChatFilesView {
        var userFiles: [AttachmentRow] = []
        var artifacts: [ArtifactRow] = []
        var plaudNotes: [PlaudRow] = []
        var seenPlaud = Set<String>()
        var seenArtifacts = Set<String>()
        for message in messages.reversed() {
            for attachment in message.attachments {
                if let info = PlaudNoteChipView.chipInfo(for: attachment) {
                    if seenPlaud.insert(info.fileID).inserted {
                        plaudNotes.append(PlaudRow(id: info.fileID, title: attachment.filename))
                    }
                } else if message.isUser {
                    userFiles.append(AttachmentRow(id: attachment.id, attachment: attachment, attachedAt: message.timestamp))
                }
            }
            if !message.isUser {
                for block in MarkdownBlocksView.parse(message.text) {
                    if case .artifact(let kind, let content, let complete) = block, complete {
                        let title = kind.extractTitle(from: content) ?? kind.untitledLabel
                        let key = "\(title)|\(content.count)"
                        if seenArtifacts.insert(key).inserted {
                            artifacts.append(ArtifactRow(
                                id: key, kind: kind, title: title, content: content
                            ))
                        }
                    }
                }
            }
        }
        return LocalChatFilesView(userFiles: userFiles, artifacts: artifacts, plaudNotes: plaudNotes)
    }
}
