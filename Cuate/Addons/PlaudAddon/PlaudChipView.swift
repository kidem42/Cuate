import SwiftUI
import AppKit

/// The Plaud brand badge, faithful to the original favicon: black "Λ·"
/// glyph on a white rounded square. One component for every mount point
/// (chips, preview header, files panel, settings) so the mark stays
/// consistent. The hairline border keeps the white square visible on
/// light backgrounds.
struct PlaudBadge: View {
    var size: CGFloat = 24

    var body: some View {
        Image("Provider-plaud")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: size * 0.54, height: size * 0.54)
            .foregroundStyle(.black)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .fill(.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
            )
    }
}

/// The chat-bubble chip for a Plaud attachment (note tab, transcript, or an
/// unprocessed recording) and its full-fidelity preview. Recognized by the
/// payload path (`PlaudNotes/<fileID>__<kind>__<slug>.md`) — the metadata
/// channel `ChatAttachment` doesn't otherwise have.
struct PlaudNoteChipView: View {
    let attachment: ChatAttachment

    struct ChipInfo {
        let fileID: String
        let kind: PlaudToolService.ChipKind
    }

    static func chipInfo(for attachment: ChatAttachment) -> ChipInfo? {
        // Current chips point at "…__<kind>__meta.json"; chips persisted by
        // the first build point at per-tab "…__<kind>__<slug>.md" — both
        // resolve to the same recording preview.
        guard let path = attachment.fileURLString, path.hasPrefix("PlaudNotes/"),
              path.hasSuffix(".md") || path.hasSuffix(".json") else { return nil }
        let stem = (path.dropFirst("PlaudNotes/".count) as NSString).deletingPathExtension
        let parts = stem.components(separatedBy: "__")
        guard parts.count >= 2, let kind = PlaudToolService.ChipKind(rawValue: parts[1]) else {
            return nil
        }
        return ChipInfo(fileID: parts[0], kind: kind)
    }

    /// The dispatch predicate for `AttachmentPreviewBubble`.
    static func matches(_ attachment: ChatAttachment) -> Bool {
        chipInfo(for: attachment) != nil
    }

    private var info: ChipInfo? { Self.chipInfo(for: attachment) }

    var body: some View {
        HStack(spacing: 8) {
            // Plaud's own "Λ·" mark — the chip must read as THEIR content.
            PlaudBadge(size: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(attachment.filename)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    Text(kindLabel)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if info?.kind == .unprocessed {
                        Text(PLL("plaud.chip.unprocessed"))
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                            .foregroundColor(.orange)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .contextMenu {
            Button(PLL("plaud.chip.openInPlaud")) {
                PlaudAddon.openRecording(info?.fileID)
            }
        }
        .help(info?.kind == .unprocessed
            ? PLL("plaud.chip.unprocessed.help")
            : PLL("plaud.chip.help"))
    }

    private var kindLabel: String {
        switch info?.kind {
        case .transcript: return PLL("plaud.chip.kind.transcript")
        default: return PLL("plaud.chip.kind.note")
        }
    }

    private func open() {
        guard let info else { return }
        if info.kind == .unprocessed {
            // Nothing to preview — processing starts in Plaud's own UI.
            PlaudAddon.openRecording(info.fileID)
            return
        }
        // The tabbed preview: every cached tab + transcript + audio, with a
        // live refresh — not just the one payload this chip was born from.
        PlaudNotePreview.show(fileID: info.fileID, fallbackTitle: attachment.filename)
    }
}
