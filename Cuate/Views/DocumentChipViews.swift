import SwiftUI

/// Document attachment chip: icon by extension, file name, pages and size.
/// Shared by the composer's pending card and the transcript bubble.
struct DocumentChipView: View {
    let attachment: ChatAttachment

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: DocumentPreflight.iconName(forFilename: attachment.filename))
                .font(.system(size: 16))
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                let detail = Self.detail(for: attachment)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if (attachment.pageCount ?? 0) >= DocumentPreflight.largePDFPages {
                    Text(L("panel.docLarge"))
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
        }
    }

    /// "12 pages · 1.2 MB" — whichever parts are known.
    static func detail(for attachment: ChatAttachment) -> String {
        var parts: [String] = []
        if let pages = attachment.pageCount {
            parts.append(String(format: L("panel.docPages"), pages))
        }
        if let url = attachment.fileURL,
           let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int {
            parts.append(DocumentPreflight.formattedSize(size))
        } else if !attachment.base64.isEmpty {
            parts.append(DocumentPreflight.formattedSize(attachment.base64.count * 3 / 4))
        }
        return parts.joined(separator: " · ")
    }
}

extension DocumentChipView {
    /// Days until the document leaves the chat: the server expiry when the
    /// copy has one, else the local retention window from the attach date.
    static func daysLeft(for attachment: ChatAttachment, attachedAt: Date) -> Int {
        let expiry = attachment.remoteExpiresAt
            ?? attachedAt.addingTimeInterval(Double(Config.mediaRetentionDays) * 86_400)
        return max(0, Int(ceil(expiry.timeIntervalSinceNow / 86_400)))
    }

    /// "12 pages · 21 KB · 15 d" — the chat-files popover subtitle.
    static func retentionSubtitle(for attachment: ChatAttachment, attachedAt: Date) -> String {
        var parts: [String] = []
        let base = detail(for: attachment)
        if !base.isEmpty { parts.append(base) }
        parts.append(String(format: L("panel.memoryDocDays"), daysLeft(for: attachment, attachedAt: attachedAt)))
        return parts.joined(separator: " · ")
    }
}
