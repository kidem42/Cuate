import CryptoKit
import Foundation

/// Delivers attached FILES to the agent (Hermes has no upload on the API
/// server — proved in source; files travel as PATHS its file tools read):
///
/// - **local gateway** (the common setup): the file already lives on the
///   agent's host — the note simply lists the paths;
/// - **remote gateway**: the file is first uploaded through the Hermes
///   DASHBOARD server's files API (`/api/files/upload-stream`, multipart,
///   `Authorization: Bearer <session token>`) into `~/cuate-uploads/` on
///   the agent's machine, and the note lists the REMOTE paths. Requires the
///   dashboard URL + token in the addon settings; without them the send
///   falls back to local paths and an honest warning.
@MainActor
enum HermesFileCourier {

    /// Uploads (when remote) and formats the note appended to the outgoing
    /// message. `warning` is non-nil when remote delivery was impossible —
    /// the caller surfaces it as a system line.
    static func deliver(paths: [String]) async -> (note: String, warning: String?) {
        let settings = HermesSettings.shared
        guard settings.isRemoteGateway else {
            return (note(for: paths), nil)
        }
        guard let dashboard = settings.dashboardBaseURL,
              let token = APIKeyStore.key(aux: .hermesDashboard), !token.isEmpty else {
            // Remote agent, no courier configured: send local paths anyway
            // (the agent will say it cannot see them) + tell the user why.
            return (note(for: paths), HL("hermes.dash.missing"))
        }

        var remotePaths: [String] = []
        var failures: [String] = []
        for path in paths {
            do {
                let remote = try await upload(localPath: path, dashboard: dashboard, token: token)
                remotePaths.append(remote)
            } catch {
                failures.append((path as NSString).lastPathComponent)
                Diagnostics.log("hermes", "courier.fail \(path): \(String(error.localizedDescription.prefix(120)))")
            }
        }
        let noteText = note(for: remotePaths.isEmpty ? paths : remotePaths)
        let warning = failures.isEmpty
            ? nil
            : String(format: HL("hermes.dash.uploadFailed"), failures.joined(separator: ", "))
        return (noteText, warning)
    }

    /// Uploads raw bytes (a pasted screenshot has no file on disk) and
    /// returns the remote path. Used for IMAGES, which also ride inline for
    /// the model — the upload is what makes them visible on the OTHER
    /// surfaces later: the gateway keeps no pixels, so a phone-sent photo
    /// would otherwise reach the Mac as a bare "[screenshot]" placeholder.
    static func uploadBytes(_ data: Data, filename: String) async -> String? {
        let settings = HermesSettings.shared
        guard settings.isRemoteGateway,
              let dashboard = settings.dashboardBaseURL,
              let token = APIKeyStore.key(aux: .hermesDashboard), !token.isEmpty
        else { return nil }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cuate-\(UUID().uuidString)-\(filename)")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try data.write(to: temp)
            return try await upload(localPath: temp.path, dashboard: dashboard, token: token)
        } catch {
            Diagnostics.log("hermes", "courier.image.fail \(String(error.localizedDescription.prefix(120)))")
            return nil
        }
    }

    /// Dashboard URL that serves a remote path back as bytes — how a bubble
    /// renders an image that lives on the agent's host.
    static func downloadURL(forRemotePath path: String) -> URL? {
        guard let dashboard = HermesSettings.shared.dashboardBaseURL,
              var comps = URLComponents(
                url: dashboard.appendingPathComponent("api/files/download"),
                resolvingAgainstBaseURL: false)
        else { return nil }
        comps.queryItems = [URLQueryItem(name: "path", value: path)]
        return comps.url
    }

    /// Whether the reverse courier can run: remote gateway with the
    /// dashboard URL + token configured. The chips use it to decide between
    /// "download" and the copy-the-path fallback.
    static var canFetchRemote: Bool {
        HermesSettings.shared.isRemoteGateway
            && HermesSettings.shared.dashboardBaseURL != nil
            && APIKeyStore.key(aux: .hermesDashboard)?.isEmpty == false
    }

    /// remotePath → the local copy `fetchRemoteFile` produced this run,
    /// stamped with the freshness it represents (`asOf` — the timestamp of
    /// the message that triggered the fetch). Lets every surface treat a
    /// downloaded file as local, while a NEWER mention of the same path
    /// (the agent edited the file and said so) refreshes the copy instead
    /// of serving the stale one (e2e 2026-07-27). Existence is re-checked
    /// on read: the user may have deleted the copy.
    private static var fetchedCopies: [String: (url: URL, asOf: Date)] = [:]

    static func fetchedCopy(forRemotePath path: String) -> URL? {
        guard let entry = fetchedCopies[path],
              FileManager.default.fileExists(atPath: entry.url.path) else { return nil }
        return entry.url
    }

    /// Whether the cached copy already satisfies this freshness — the
    /// auto-fetch loop's termination condition (no fetch, no re-render).
    static func hasFreshCopy(forRemotePath path: String, asOf: Date) -> Bool {
        guard let entry = fetchedCopies[path],
              FileManager.default.fileExists(atPath: entry.url.path) else { return false }
        return entry.asOf >= asOf
    }

    /// Where a fetched copy lands. `.downloads` is the EXPLICIT action
    /// (user clicked download); `.cache` is the silent auto-fetch that
    /// materializes HTML/Markdown preview cards — it must not litter the
    /// user's Downloads with files nobody asked for.
    enum FetchDestination { case downloads, cache }

    /// App-owned cache for auto-fetched copies (`.cache` destination).
    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cuate/AgentFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Auto-fetch keeps previews snappy, not archives: anything bigger than
    /// the artifact preview would render is not worth pulling silently.
    private static let autoFetchByteLimit = 8 * 1024 * 1024

    /// Remote paths whose silent fetch failed, stamped with the freshness
    /// that failed — a NEWER mention retries, the same one doesn't loop.
    private static var autoFetchFailed: [String: Date] = [:]
    private static var autoFetchInFlight = Set<String>()

    /// Silent fetch into the cache — the artifact-card materializer.
    /// `asOf` is the mentioning message's timestamp: an up-to-date copy is
    /// returned as is, an OLDER copy is refreshed in place (the agent
    /// edited the file and a new reply mentions it again). Returns nil
    /// quietly when the courier can't run, this freshness already failed,
    /// or a fetch is in flight.
    static func autoFetchArtifact(path: String, asOf: Date) async -> URL? {
        if let entry = fetchedCopies[path],
           FileManager.default.fileExists(atPath: entry.url.path),
           entry.asOf >= asOf {
            return entry.url
        }
        guard canFetchRemote else { return nil }
        if let failedAt = autoFetchFailed[path], failedAt >= asOf { return nil }
        guard autoFetchInFlight.insert(path).inserted else { return nil }
        defer { autoFetchInFlight.remove(path) }
        let fetched = await fetchRemoteFile(path: path, to: .cache, asOf: asOf)
        if fetched == nil { autoFetchFailed[path] = asOf }
        return fetched
    }

    /// True for copies living in the app cache (auto-fetched) — the ones a
    /// "reveal in Finder" must first export somewhere the user owns.
    static func isCacheCopy(_ url: URL) -> Bool {
        url.path.hasPrefix(cacheDirectory.path)
    }

    /// Copies a cache file into ~/Downloads (uniquified) — the explicit
    /// "give me the file" moment for a copy that was auto-fetched silently.
    static func exportToDownloads(_ url: URL) -> URL? {
        // Cache names carry a "<hash>-" prefix; the export sheds it.
        var name = url.lastPathComponent
        if let dash = name.firstIndex(of: "-"), name[..<dash].count == 16 {
            name = String(name[name.index(after: dash)...])
        }
        let target = uniqueDownloadsURL(filename: name)
        do {
            try FileManager.default.copyItem(at: url, to: target)
            return target
        } catch {
            Diagnostics.log("hermes", "courier.export.fail \(String(error.localizedDescription.prefix(120)))")
            return nil
        }
    }

    private static func uniqueDownloadsURL(filename: String) -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var target = downloads.appendingPathComponent(filename)
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path) {
            let numbered = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            target = downloads.appendingPathComponent(numbered)
            counter += 1
        }
        return target
    }

    /// The REVERSE courier: pulls a file the agent created on ITS host down
    /// to this Mac through the dashboard files API — into ~/Downloads
    /// (names uniquified, never overwrites) or the app cache (stable name,
    /// overwrites: re-fetch = refresh). `asOf` stamps the copy's freshness
    /// (defaults to now — a manual fetch is always the newest). nil on any
    /// failure — the caller falls back to copying the path.
    static func fetchRemoteFile(path: String, to destination: FetchDestination = .downloads,
                                asOf: Date = Date()) async -> URL? {
        guard let url = downloadURL(forRemotePath: path),
              let token = APIKeyStore.key(aux: .hermesDashboard), !token.isEmpty
        else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status), !data.isEmpty else {
                Diagnostics.log("hermes", "courier.fetch.fail http=\(status) bytes=\(data.count)")
                return nil
            }
            let name = (path as NSString).lastPathComponent
            let target: URL
            switch destination {
            case .downloads:
                target = uniqueDownloadsURL(filename: name)
            case .cache:
                guard data.count <= autoFetchByteLimit else {
                    Diagnostics.log("hermes", "courier.fetch.skip cache-too-big bytes=\(data.count)")
                    return nil
                }
                // Stable per-path name: a later fetch refreshes in place.
                let hash = SHA256.hash(data: Data(path.utf8))
                    .prefix(8).map { String(format: "%02x", $0) }.joined()
                target = cacheDirectory.appendingPathComponent("\(hash)-\(name)")
            }
            try data.write(to: target, options: .atomic)
            fetchedCopies[path] = (target, asOf)
            Diagnostics.log("hermes", "courier.fetch ok bytes=\(data.count) dest=\(destination)")
            return target
        } catch {
            Diagnostics.log("hermes", "courier.fetch.fail \(String(error.localizedDescription.prefix(120)))")
            return nil
        }
    }

    /// Extensions rendered inline instead of as a file pill.
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic"]

    /// The message block the agent reads: header + one path per line.
    static func note(for paths: [String]) -> String {
        let header = paths.count == 1
            ? AGL("agent.attach.fileNote.header")
            : AGL("agent.attach.filesNote.header")
        return header + "\n" + paths.map { "- \($0)" }.joined(separator: "\n")
    }

    /// One multipart upload into `~/cuate-uploads/<name>` on the agent's
    /// host (the dashboard's managed root is the HOME on a normal install
    /// and paths expanduser — checked in web_server.py source).
    private static func upload(localPath: String, dashboard: URL, token: String) async throws -> String {
        let fileURL = URL(fileURLWithPath: localPath)
        let data = try Data(contentsOf: fileURL)
        let remoteRelative = "cuate-uploads/\(fileURL.lastPathComponent)"

        var request = URLRequest(url: dashboard.appendingPathComponent("api/files/upload-stream"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let boundary = "cuate-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("path", "~/\(remoteRelative)")
        field("overwrite", "true")
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (responseData, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw HermesTransportError.http(status: status,
                                            body: String(data: responseData, encoding: .utf8) ?? "")
        }
        // The response carries the display path; fall back to our target.
        if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let display = json["path"] as? String, !display.isEmpty {
            return display
        }
        return "~/\(remoteRelative)"
    }
}
