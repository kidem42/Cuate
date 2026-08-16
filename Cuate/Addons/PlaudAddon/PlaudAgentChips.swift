import Foundation

/// Turns the recordings an AGENT referred to into the app's own chips.
///
/// An agent carrying the Plaud plugin finds recordings on its own host and
/// answers with identifiers (`plaud://<file_id>` — see `AgentPlaudNote`),
/// never with content. This resolves those ids HERE, with the user's own
/// Plaud grant: one `get_file` per recording fills the cached meta the chip
/// and the preview window read, and the result is the same card an ordinary
/// chat produces — every summary tab, the timecoded transcript, inline audio.
///
/// Why not have the agent send the content: its reply is plain text on a
/// gateway that stores no metadata, Plaud's content links expire in five
/// minutes, and a transcript pasted into the turn would burn the agent's
/// context to render worse than what the app already draws.
@MainActor
enum PlaudAgentChips {

    /// Best effort by design: a recording whose lookup fails simply gets no
    /// chip — the agent's words stay in the bubble either way, and a failed
    /// fetch must never cost the user the reply.
    static func attachments(for references: [AgentPlaudNote.Reference]) async -> [ChatAttachment] {
        guard PlaudAddon.shared.isAvailable, !references.isEmpty else { return [] }
        var chips: [ChatAttachment] = []
        for reference in references {
            guard let chip = await attachment(for: reference) else { continue }
            chips.append(chip)
        }
        return chips
    }

    private static func attachment(for reference: AgentPlaudNote.Reference) async -> ChatAttachment? {
        let fileID = reference.fileID
        var title = reference.title
        var kind = PlaudToolService.ChipKind.note

        // The cached meta is enough for a chip; the fetch is what makes the
        // title and the "unprocessed" state true, so it runs when the cache
        // has nothing (a recording this device never opened).
        if let cached = PlaudNoteCache.meta(fileID: fileID), !cached.name.isEmpty {
            title = cached.name
        } else {
            do {
                let file = try await PlaudClient.shared.getFile(fileID)
                let name = file["name"] as? String ?? title
                PlaudNoteCache.updateMeta(
                    fileID: fileID,
                    name: name,
                    day: String((file["created_at"] as? String ?? "").prefix(10)),
                    duration: PlaudFormat.durationString(file["duration"])
                )
                if !name.isEmpty { title = name }
                // Nothing recorded on either side = Plaud has not processed
                // it yet; that chip deep-links into their app instead of
                // opening a preview with nothing in it.
                let noteList = file["note_list"] as? [[String: Any]] ?? []
                let sourceList = file["source_list"] as? [[String: Any]] ?? []
                if noteList.isEmpty && sourceList.isEmpty { kind = .unprocessed }
            } catch {
                Diagnostics.log("plaud", "agent.chip.fail id=\(fileID) \(String(error.localizedDescription.prefix(120)))")
                // An id we cannot resolve at all is not worth a dead chip.
                guard PlaudNoteCache.meta(fileID: fileID) != nil else { return nil }
            }
        }

        return ChatAttachment(
            filename: title.isEmpty ? fileID : title,
            mimeType: "text/markdown",
            base64: "",
            fileURLString: PlaudNoteCache.metaRelativePath(fileID: fileID, kind: kind.rawValue)
        )
    }
}
