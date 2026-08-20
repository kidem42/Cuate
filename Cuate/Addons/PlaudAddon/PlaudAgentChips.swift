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
        guard !references.isEmpty else { return [] }
        // NOT `PlaudAddon.isAvailable`: that reads `settings.isConnected`, a
        // flag seeded from a CACHE-ONLY Keychain probe at launch. Right after
        // an app update the Keychain ACL re-authorizes for a few seconds, the
        // probe answers "no key", and the flag stays false until something
        // refreshes it — the agent's recordings then silently produced no
        // chips (live, 2026-08-16). The grant itself is the truth here, so
        // wait for the Keychain and ask it.
        guard PlaudSettings.shared.enabled else {
            Diagnostics.log("plaud", "agent.chips skipped=addon-off refs=\(references.count)")
            return []
        }
        await APIKeyStore.warmIfNeeded()
        guard PlaudClient.hasTokens else {
            Diagnostics.log("plaud", "agent.chips skipped=not-connected refs=\(references.count)")
            return []
        }
        var chips: [ChatAttachment] = []
        for reference in references {
            guard let chip = await attachment(for: reference) else { continue }
            chips.append(chip)
        }
        return chips
    }

    /// The same contract applied to a LOCAL turn: the chat's own model cites
    /// the recordings its reply is about with `plaud://` markers after its
    /// Plaud tool calls — one, several, or a whole list, its call entirely.
    /// `held` are the chips the turn's note/transcript reads already produced;
    /// a marker matching one reuses it (its kind — note vs unprocessed — and
    /// fresh title are already right), anything else resolves through the
    /// cache/grant. Markers leave the text only when every one became a card
    /// (same rule as the agent path). Returns nil when there are no markers.
    static func resolvingMarkers(
        in text: String, held: [ChatAttachment]
    ) async -> (display: String, chips: [ChatAttachment])? {
        let (display, references) = AgentPlaudNote.split(text)
        guard !references.isEmpty else { return nil }
        var chips: [ChatAttachment] = []
        for reference in references {
            if let match = held.first(where: {
                $0.fileURLString?.contains(reference.fileID) == true
            }) {
                chips.append(match)
            } else if let chip = await attachments(for: [reference]).first {
                chips.append(chip)
            }
        }
        Diagnostics.log("plaud", "local.chips n=\(chips.count) refs=\(references.count) held=\(held.count)")
        return (chips.count == references.count ? display : text, chips)
    }

    /// The same contract applied to messages that did NOT come through a live
    /// turn: an agent session run from the phone, a messenger or cron reaches
    /// us through mirror sync, which inserts the gateway's text verbatim —
    /// markers and all (live, 2026-08-16: a phone-side turn showed a bare
    /// `plaud://…` where the desktop chat drew a card). Rewrites only the rows
    /// that carry a marker, so re-running over a synced window is a no-op.
    static func decorating(_ messages: [ChatMessage]) async -> [ChatMessage] {
        var out = messages
        for index in out.indices where !out[index].isUser && out[index].text.contains("plaud://") {
            let (display, references) = AgentPlaudNote.split(out[index].text)
            guard !references.isEmpty else { continue }
            let chips = await attachments(for: references)
            guard !chips.isEmpty else { continue }
            let existing = Set(out[index].attachments.compactMap(\.fileURLString))
            out[index].attachments += chips.filter {
                $0.fileURLString.map { !existing.contains($0) } ?? true
            }
            // Only a fully resolved reply loses its markers: dropping an id we
            // could NOT turn into a card would leave the user with neither.
            if chips.count == references.count { out[index].text = display }
        }
        return out
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
