import Foundation

/// Best-effort deletion of provider-side document copies. Every place that
/// lets an attachment go (message deleted, new chat, preset deleted, the
/// 15-day prune) enqueues the remote ids here; the queue is persisted so an
/// offline deletion is retried on the next launch. Server-side expiry
/// (`expires_after` at upload) is the backstop when this never succeeds.
nonisolated enum RemoteFileJanitor {
    struct Entry: Codable, Equatable {
        let provider: String
        let fileID: String
    }

    private static let defaultsKey = "files.janitor.queue"
    /// Bounded: a runaway caller can't grow the defaults without limit.
    private static let maxEntries = 200
    private static let queue = DispatchQueue(label: "Cuate.RemoteFileJanitor", qos: .utility)
    private static var draining = false

    /// Adds ids to the queue (deduplicated) and kicks a drain.
    static func enqueue(provider: ProviderID, fileIDs: [String]) {
        let fresh = fileIDs.filter { !$0.isEmpty }
        guard !fresh.isEmpty else { return }
        queue.async {
            var entries = load()
            for id in fresh {
                let entry = Entry(provider: provider.rawValue, fileID: id)
                if !entries.contains(entry) { entries.append(entry) }
            }
            if entries.count > maxEntries {
                entries.removeFirst(entries.count - maxEntries)
            }
            save(entries)
            Diagnostics.log("files", "janitor enqueue count=\(fresh.count) queued=\(entries.count)")
        }
        drainSoon()
    }

    /// Runs the queue in the background; safe to call often (one drain at a time).
    static func drainSoon() {
        queue.async {
            guard !draining, !load().isEmpty else { return }
            draining = true
            Task.detached(priority: .utility) {
                await drain()
                queue.async { draining = false }
            }
        }
    }

    private static func drain() async {
        await APIKeyStore.warmIfNeeded()
        let entries = queue.sync { load() }
        var remaining: [Entry] = []
        for entry in entries {
            guard let provider = ProviderID(rawValue: entry.provider), provider == .openai else {
                continue // unknown provider: nothing to call, drop the entry
            }
            guard let apiKey = APIKeyStore.key(for: provider) else {
                remaining.append(entry) // no key right now — keep for later
                continue
            }
            do {
                try await OpenAIFilesService.delete(fileID: entry.fileID, apiKey: apiKey)
                Diagnostics.log("files", "delete id=\(entry.fileID) status=ok")
            } catch ProviderError.http(let status, let message) where (400..<500).contains(status) {
                // Client errors won't heal on retry (bad id, revoked key).
                Diagnostics.log("files", "delete id=\(entry.fileID) status=\(status) dropped (\(message.prefix(80)))")
            } catch {
                Diagnostics.log("files", "delete id=\(entry.fileID) failed — kept (\(error.localizedDescription.prefix(80)))")
                remaining.append(entry)
            }
        }
        queue.sync {
            // Entries added while draining stay; only the processed ones go.
            let current = load()
            let processed = Set(entries.map { $0.fileID }).subtracting(remaining.map { $0.fileID })
            save(current.filter { !processed.contains($0.fileID) })
        }
    }

    // MARK: - Storage (call on `queue` only)

    private static func load() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }

    private static func save(_ entries: [Entry]) {
        if entries.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
