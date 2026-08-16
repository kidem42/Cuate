import Foundation

/// Hands the Hermes agent its own read-only access to the Plaud library.
///
/// The agent's tools live on ITS host, so they need their own copy of the
/// grant — Cuate's Keychain is unreachable from a VPS. This writes the two
/// tokens into `~/.hermes/plaud.json` on that host, which is exactly where the
/// `plaud` plugin looks; the plugin refreshes them by itself afterwards.
///
/// Two delivery paths, same destination:
/// - a gateway on THIS Mac — a plain file write;
/// - a remote gateway — the dashboard's files API, the same courier that
///   already carries attachments (its `path` field takes any home-relative
///   destination, so nothing has to be moved afterwards).
///
/// This is a real handover of access, not a setting: from here on the agent
/// can read the user's recordings on every surface it has. The UI says so
/// plainly, and revoking is one click in the Plaud app.
@MainActor
enum PlaudAgentGrant {

    enum GrantError: LocalizedError {
        case notConnected
        case noDashboard
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notConnected: return PLL("plaud.grant.err.notconnected")
            case .noDashboard: return PLL("plaud.grant.err.nodashboard")
            case .writeFailed(let detail): return PLL("plaud.grant.err.write") + " " + detail
            }
        }
    }

    /// Where the plugin keeps its grant, relative to the agent host's home.
    /// The dashboard refuses to serve credential basenames — `auth.json` is on
    /// that list — so this check learns only whether the file EXISTS (403), and
    /// that is the right trade: a token file must not be readable through a
    /// files API. The flat legacy path is still probed so a host granted by an
    /// earlier build still reports.
    static let remotePath = ".hermes/plaud/auth.json"
    static let legacyRemotePath = ".hermes/plaud.json"

    /// What the agent host currently holds. Handing over a copy of someone's
    /// grant is only acceptable if it can be looked at and taken back, so the
    /// settings pane asks for this and offers `revoke()`.
    enum Status: Equatable {
        /// No grant file on the agent's host.
        case absent
        /// A grant is there and carries the token this Mac holds now.
        case current
        /// A grant is there, but from an earlier sign-in — the agent may be
        /// working with a token that no longer refreshes.
        case stale
        /// A grant is there; its contents are not readable back (the
        /// dashboard refuses to serve some files). Presence is all we know.
        case present
        /// The host could not be asked at all (offline, no dashboard).
        case unknown(String)
    }

    static func status() async -> Status {
        if HermesLocalGateway.isLocalEndpoint(HermesSettings.shared.endpointURL) {
            let home = FileManager.default.homeDirectoryForCurrentUser
            for path in [remotePath, legacyRemotePath] {
                if let data = try? Data(contentsOf: home.appendingPathComponent(path)) {
                    Diagnostics.log("plaud", "agent.grant status local path=\(path) found")
                    return await compare(data)
                }
            }
            Diagnostics.log("plaud", "agent.grant status local=absent")
            return .absent
        }
        guard let dashboard = HermesSettings.shared.dashboardBaseURL,
              let token = APIKeyStore.key(aux: .hermesDashboard), !token.isEmpty else {
            return .unknown(PLL("plaud.grant.err.nodashboard"))
        }
        // `/api/files/download`, NOT `/api/files/read`: read wraps the file in
        // a JSON envelope with the bytes base64'd into `data_url`, so matching
        // on its text never found the token and every granted agent read as
        // "no access" (live, 2026-08-16). Download returns the file itself.
        var components = URLComponents(
            url: dashboard.appendingPathComponent("api/files/download"), resolvingAgainstBaseURL: false
        )
        var lastCode = 0
        for path in [remotePath, legacyRemotePath] {
            components?.queryItems = [URLQueryItem(name: "path", value: "~/\(path)")]
            guard let url = components?.url else { return .unknown("bad dashboard URL") }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            // A status check must hit the server every time: the default
            // policy served the FIRST successful answer from cache, so the
            // row kept reading "granted" long after the file was deleted
            // (live, 2026-08-16 — revoking looked like it did nothing).
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(HermesTransport.userAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request) else {
                return .unknown(PLL("plaud.grant.status.unreachable"))
            }
            lastCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            Diagnostics.log("plaud", "agent.grant status path=\(path) http=\(lastCode)")
            switch lastCode {
            case 200: return await compare(data)
            case 403: return .present     // there, but the API will not read it back
            case 404: continue            // try the legacy path before giving up
            default: return .unknown("HTTP \(lastCode)")
            }
        }
        Diagnostics.log("plaud", "agent.grant status=absent")
        return lastCode == 404 ? .absent : .unknown("HTTP \(lastCode)")
    }

    /// Same token as this Mac holds → the agent's copy still refreshes.
    /// Parsed as JSON, not matched as text: the file is written by us but
    /// REWRITTEN by the plugin on every refresh, so its formatting is not ours
    /// to assume.
    private static func compare(_ payload: Data) async -> Status {
        guard let theirs = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let theirToken = theirs["access_token"] as? String, !theirToken.isEmpty else {
            return .absent
        }
        guard let mine = await PlaudClient.shared.exportableGrant(),
              let ours = (try? JSONSerialization.jsonObject(with: mine)) as? [String: Any],
              let ourToken = ours["access_token"] as? String, !ourToken.isEmpty else {
            return .present
        }
        // The plugin refreshes on its own, so a DIFFERENT access token is
        // normal — what matters is that both sides came from the same grant,
        // which the refresh token identifies.
        let theirRefresh = theirs["refresh_token"] as? String ?? ""
        let ourRefresh = ours["refresh_token"] as? String ?? ""
        if theirToken == ourToken || (!theirRefresh.isEmpty && theirRefresh == ourRefresh) {
            return .current
        }
        return .stale
    }

    /// Takes the access back: the file is what the plugin reads, so removing
    /// it ends the agent's access at the next call. This does NOT revoke the
    /// grant at Plaud — that is a separate, account-wide action the user makes
    /// in the Plaud app (and it would kill this Mac's access too).
    static func revoke() async throws {
        if HermesLocalGateway.isLocalEndpoint(HermesSettings.shared.endpointURL) {
            let home = FileManager.default.homeDirectoryForCurrentUser
            for path in [remotePath, legacyRemotePath] {
                let url = home.appendingPathComponent(path)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                do { try FileManager.default.removeItem(at: url) }
                catch { throw GrantError.writeFailed(error.localizedDescription) }
            }
            Diagnostics.log("plaud", "agent.grant revoked local=true")
            return
        }
        guard let dashboard = HermesSettings.shared.dashboardBaseURL,
              let token = APIKeyStore.key(aux: .hermesDashboard), !token.isEmpty else {
            throw GrantError.noDashboard
        }
        // Both stores, so revoking never leaves the legacy copy behind.
        var lastStatus = 404
        for path in [remotePath, legacyRemotePath] {
        var request = URLRequest(url: dashboard.appendingPathComponent("api/files"))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(HermesTransport.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["path": "~/\(path)", "recursive": false]
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 404 = already gone, which is the outcome the user asked for.
        guard (200...299).contains(status) || status == 404 else {
            throw GrantError.writeFailed("HTTP \(status): \(String(data: data, encoding: .utf8)?.prefix(160) ?? "")")
        }
        lastStatus = status
        }
        Diagnostics.log("plaud", "agent.grant revoked local=false http=\(lastStatus)")
    }

    static func grant() async throws {
        guard let payload = await PlaudClient.shared.exportableGrant() else {
            throw GrantError.notConnected
        }
        if HermesLocalGateway.isLocalEndpoint(HermesSettings.shared.endpointURL) {
            try writeLocally(payload)
        } else {
            try await upload(payload)
        }
        Diagnostics.log("plaud", "agent.grant delivered local=\(HermesLocalGateway.isLocalEndpoint(HermesSettings.shared.endpointURL))")
    }

    private static func writeLocally(_ payload: Data) throws {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(remotePath)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try payload.write(to: url, options: .atomic)
            // Someone's recordings, not a config knob.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw GrantError.writeFailed(error.localizedDescription)
        }
    }

    private static func upload(_ payload: Data) async throws {
        guard let dashboard = HermesSettings.shared.dashboardBaseURL,
              let token = APIKeyStore.key(aux: .hermesDashboard), !token.isEmpty else {
            throw GrantError.noDashboard
        }
        var request = URLRequest(url: dashboard.appendingPathComponent("api/files/upload-stream"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(HermesTransport.userAgent, forHTTPHeaderField: "User-Agent")
        let boundary = "cuate-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("path", "~/\(remotePath)")
        field("overwrite", "true")
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"plaud.json\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json\r\n\r\n".data(using: .utf8)!)
        body.append(payload)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw GrantError.writeFailed("HTTP \(status): \(String(data: data, encoding: .utf8)?.prefix(160) ?? "")")
        }
    }
}
