import Foundation
import Network
import CryptoKit

/// Plaud REST client + OAuth. Talks to the same endpoints as Plaud's own
/// MCP package (`@plaud-ai/mcp`) — their local "MCP server" is a thin REST
/// client to `platform.plaud.ai`, so we skip the Node layer entirely and
/// speak the REST API natively. Protocol details (client id, PKCE, the
/// localhost callback) mirror that reference implementation exactly: the
/// public client id is registered with `http://localhost:8199/auth/callback`
/// as its redirect URI, so the callback listener must sit on that port.
///
/// Tokens live in the Keychain (`APIKeyStore.AuxKey.plaud`) as one JSON
/// blob — never in UserDefaults, never in ~/.plaud (that file belongs to
/// the official CLI, sharing it would desync refresh rotations).
actor PlaudClient {
    static let shared = PlaudClient()

    // MARK: - Constants (mirrors @plaud-ai/mcp dist/config)

    private static let clientID = "client_9c501dad-8a0d-40b2-a7b0-d1cb8787f674"
    private static let clientSecret = "" // public client — empty secret, Basic "id:"
    private static let redirectURI = "http://localhost:8199/auth/callback"
    private static let callbackPort: UInt16 = 8199
    private static let callbackPath = "/auth/callback"
    private static let authorizationURL = "https://web.plaud.ai/platform/oauth"
    private static let tokenURL = "https://platform.plaud.ai/developer/api/oauth/third-party/access-token"
    private static let refreshURL = "https://platform.plaud.ai/developer/api/oauth/third-party/access-token/refresh"
    private static let apiBase = "https://platform.plaud.ai/developer/api"

    /// Web UI base — deep links ("Open in Plaud") land here.
    nonisolated static let webAppURL = "https://web.plaud.ai/"

    struct PlaudError: LocalizedError {
        /// WHY the call failed. The UI and the tool layer branch on this —
        /// never on the message text: "the grant is dead" (only a fresh
        /// sign-in helps) and "Plaud is down right now" (the tokens are fine,
        /// retry later) demand opposite reactions.
        enum Kind {
            case generic
            case sessionExpired
            case transient
        }

        let message: String
        var kind: Kind = .generic
        var errorDescription: String? { message }

        /// Marker for a user-initiated abort of the OAuth flow — the UI
        /// resets silently instead of showing an error banner.
        static let cancelledMessage = "Cancelled."
        var isCancellation: Bool { message == Self.cancelledMessage }
        var isSessionExpired: Bool { kind == .sessionExpired }
    }

    /// The one error every dead-grant path throws — the tokens are already
    /// gone by the time a caller sees it.
    private static var sessionExpiredError: PlaudError {
        PlaudError(
            message: "Plaud session expired — reconnect the account in Settings → Plaud.",
            kind: .sessionExpired
        )
    }

    // MARK: - Token set

    private struct TokenSet: Codable {
        var accessToken: String
        var refreshToken: String?
        /// Unix seconds; nil when the server sent no expiry.
        var expiresAt: TimeInterval?
    }

    /// In-memory copy of the Keychain blob — loaded lazily, dropped on logout.
    private var cachedTokens: TokenSet?
    private var loadedFromKeychain = false

    /// The callback server of an authorize() currently awaiting the browser —
    /// held so the user can abort the wait ("wrong browser opened").
    private var activeServer: PlaudOAuthCallbackServer?

    /// Aborts a pending `authorize()` — its continuation resumes with a
    /// cancellation error and the port is freed for the next attempt.
    func cancelAuthorization() {
        activeServer?.stop()
        activeServer = nil
    }

    /// Sync connectivity check for UI gating: Keychain presence only, no
    /// network. `nonisolated` so views and ChatService read it directly.
    nonisolated static var hasTokens: Bool {
        APIKeyStore.hasKey(aux: .plaud)
    }

    private func loadTokens() -> TokenSet? {
        if loadedFromKeychain { return cachedTokens }
        loadedFromKeychain = true
        guard let json = APIKeyStore.key(aux: .plaud),
              let data = json.data(using: .utf8),
              let tokens = try? JSONDecoder().decode(TokenSet.self, from: data) else {
            cachedTokens = nil
            return nil
        }
        cachedTokens = tokens
        return tokens
    }

    private func saveTokens(_ tokens: TokenSet) {
        cachedTokens = tokens
        loadedFromKeychain = true
        if let data = try? JSONEncoder().encode(tokens),
           let json = String(data: data, encoding: .utf8) {
            APIKeyStore.set(json, aux: .plaud)
        }
    }

    private func clearTokens() {
        cachedTokens = nil
        loadedFromKeychain = true
        APIKeyStore.remove(aux: .plaud)
    }

    /// The stored grant is dead: drop it AND tell the UI, so the settings
    /// card stops claiming a live account and offers a reconnect instead.
    ///
    /// Before 4.7 a rejected refresh only threw — the blob stayed in the
    /// Keychain, `hasTokens` kept answering "connected", the green checkmark
    /// lied indefinitely and every chat turn re-attached tools that could
    /// only fail (observed 2026-08-05: 8 days idle → refresh 401).
    private func invalidateSession() {
        let hadTokens = cachedTokens != nil || APIKeyStore.hasKey(aux: .plaud)
        clearTokens()
        guard hadTokens else { return }
        Diagnostics.log("plaud", "session.expired tokens dropped")
        Task { @MainActor in PlaudAddon.shared.handleSessionExpired() }
    }

    // MARK: - OAuth: authorization (PKCE)

    /// Runs the whole interactive flow: starts the localhost listener, opens
    /// the browser at the authorization page, waits for the redirect (up to
    /// 2 minutes), exchanges the code. Returns normally on success with
    /// tokens already persisted.
    func authorize(openURL: @Sendable @escaping (URL) -> Void) async throws {
        let verifier = Self.base64URL(Self.randomBytes(32))
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.base64URL(Self.randomBytes(16))

        var components = URLComponents(string: Self.authorizationURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authURL = components.url else {
            throw PlaudError(message: "Failed to build authorization URL.")
        }

        // Listener first, browser second — the redirect must never race a
        // half-started server.
        let server = try PlaudOAuthCallbackServer(port: Self.callbackPort, path: Self.callbackPath)
        activeServer = server
        defer {
            activeServer = nil
            server.stop()
        }
        Diagnostics.log("plaud", "oauth.start")
        openURL(authURL)

        let callback = try await server.waitForCallback(timeout: 120)
        guard callback.state == state else {
            throw PlaudError(message: "OAuth state mismatch — please try connecting again.")
        }
        try await exchangeCode(callback.code, verifier: verifier, state: state)
        Diagnostics.log("plaud", "oauth.success")
    }

    private func exchangeCode(_ code: String, verifier: String, state: String) async throws {
        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let basic = Data("\(Self.clientID):\(Self.clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.httpBody = Self.formEncode([
            "code": code,
            "redirect_uri": Self.redirectURI,
            "code_verifier": verifier,
            "state": state,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            Diagnostics.log("plaud", "oauth.exchange failed status=\(status)")
            throw PlaudError(message: "Token exchange failed (HTTP \(status)).")
        }
        try saveTokenResponse(data, fallbackRefresh: nil)
    }

    // MARK: - OAuth: refresh

    private func refresh(_ refreshToken: String) async throws {
        var request = URLRequest(url: URL(string: Self.refreshURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formEncode(["refresh_token": refreshToken])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // Offline says nothing about the grant — keep the tokens.
            Diagnostics.log("plaud", "oauth.refresh network error")
            throw PlaudError(
                message: "Plaud is unreachable — check the connection and try again.",
                kind: .transient
            )
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            Diagnostics.log("plaud", "oauth.refresh failed status=\(status)")
            // Same split as the reference client (@plaud-ai/mcp): 5xx is
            // THEIR outage and must never log the user out; anything else is
            // invalid_grant — the refresh token is spent, revoked or past its
            // ~week-long TTL, and no retry will ever bring it back.
            if status >= 500 {
                throw PlaudError(
                    message: "Plaud backend error (HTTP \(status)) — the account stays connected, try again later.",
                    kind: .transient
                )
            }
            invalidateSession()
            throw Self.sessionExpiredError
        }
        try saveTokenResponse(data, fallbackRefresh: refreshToken)
        Diagnostics.log("plaud", "oauth.refresh success")
    }

    /// Parses an access-token response (exchange and refresh share the shape).
    private func saveTokenResponse(_ data: Data, fallbackRefresh: String?) throws {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw PlaudError(message: "Malformed token response.")
        }
        let expiresAt = (json["expires_in"] as? Double).map { Date().timeIntervalSince1970 + $0 }
        saveTokens(TokenSet(
            accessToken: access,
            refreshToken: json["refresh_token"] as? String ?? fallbackRefresh,
            expiresAt: expiresAt
        ))
    }

    /// Valid access token, refreshing when within a minute of expiry —
    /// same margin as the reference client.
    private func validAccessToken() async throws -> String {
        guard let tokens = loadTokens() else {
            throw PlaudError(message: "Not connected to Plaud. Connect in Settings → Plaud.")
        }
        if let expires = tokens.expiresAt, Date().timeIntervalSince1970 > expires - 60 {
            guard let refreshToken = tokens.refreshToken else {
                invalidateSession()
                throw Self.sessionExpiredError
            }
            try await refresh(refreshToken)
            guard let refreshed = cachedTokens else {
                invalidateSession()
                throw Self.sessionExpiredError
            }
            return refreshed.accessToken
        }
        return tokens.accessToken
    }

    // MARK: - Session upkeep

    /// Rotates the token pair while the app runs, well before the access
    /// token dies. Plaud's refresh token expires on roughly the same
    /// week-long clock as the access token, so a Mac left alone for a week
    /// comes back to a grant nothing can revive — the only prevention is
    /// touching it earlier. Called at launch and every few hours.
    ///
    /// A no-op while the token still has more than a day to live, so a live
    /// session costs about one refresh per week.
    func keepAliveIfNeeded() async {
        guard let tokens = loadTokens(), let refreshToken = tokens.refreshToken else { return }
        let margin: TimeInterval = 24 * 3600
        if let expires = tokens.expiresAt, Date().timeIntervalSince1970 < expires - margin {
            return
        }
        // The failure is already classified inside refresh(): a dead grant
        // invalidated the session (and told the UI), a transient one left the
        // tokens alone for the next tick.
        try? await refresh(refreshToken)
    }

    // MARK: - Logout

    /// Best-effort revoke on the server, then local cleanup. Local cleanup
    /// happens even when the network call fails — Disconnect must always work.
    func logout() async {
        if let tokens = loadTokens() {
            var request = URLRequest(url: URL(string: Self.apiBase + "/open/third-party/users/current/revoke")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: request)
        }
        clearTokens()
        Diagnostics.log("plaud", "logout")
    }

    // MARK: - REST

    private func request(_ path: String) async throws -> Any {
        let token = try await validAccessToken()
        var request = URLRequest(url: URL(string: Self.apiBase + path)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        var (data, response) = try await URLSession.shared.data(for: request)
        var status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 401 {
            // Stale access token mid-lifetime (revoked or clock skew):
            // one forced refresh, then retry once.
            guard let refreshToken = loadTokens()?.refreshToken else {
                invalidateSession()
                throw Self.sessionExpiredError
            }
            try await refresh(refreshToken)
            let fresh = try await validAccessToken()
            request.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            (data, response) = try await URLSession.shared.data(for: request)
            status = (response as? HTTPURLResponse)?.statusCode ?? -1
        }
        guard status == 200 else {
            Diagnostics.log("plaud", "api.error path=\(path) status=\(status)")
            switch status {
            case 401:
                // A token minted seconds ago is already rejected — the whole
                // grant is gone (access revoked in the Plaud app).
                invalidateSession()
                throw Self.sessionExpiredError
            case 404: throw PlaudError(message: "Recording not found — the ID may be wrong.")
            case 500: throw PlaudError(message: "Plaud backend error (often an invalid ID).")
            default: throw PlaudError(message: "Plaud API error (HTTP \(status)).")
            }
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    func currentUser() async throws -> [String: Any] {
        guard let user = try await request("/open/third-party/users/current") as? [String: Any] else {
            throw PlaudError(message: "Malformed user response.")
        }
        return user
    }

    /// One page of recordings, newest first (server order).
    func listFiles(page: Int = 1, pageSize: Int = 20) async throws -> [[String: Any]] {
        let raw = try await request("/open/third-party/files/?page=\(page)&page_size=\(pageSize)")
        // Response shape: {"type":"list","data":[...]} — tolerate both a
        // wrapped and a bare array so a server-side change degrades softly.
        if let dict = raw as? [String: Any], let list = dict["data"] as? [[String: Any]] {
            return list
        }
        if let list = raw as? [[String: Any]] { return list }
        throw PlaudError(message: "Malformed file list response.")
    }

    func getFile(_ fileID: String) async throws -> [String: Any] {
        // The ID lands in the URL path — reject anything that couldn't be one
        // before it can mangle the request (model-supplied input).
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !fileID.isEmpty, fileID.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw PlaudError(message: "Invalid file ID.")
        }
        guard let file = try await request("/open/third-party/files/\(fileID)") as? [String: Any] else {
            throw PlaudError(message: "Malformed file response.")
        }
        return file
    }

    // MARK: - Content resolution

    /// A `note_list`/`source_list` item carries its payload either inline
    /// (`data_content`) or behind a presigned S3 URL (`data_link`, ~5 min
    /// TTL) — resolve to the actual text, fetching immediately while the
    /// link is still alive. Returns nil when the item has neither.
    nonisolated static func resolveContent(of item: [String: Any]) async -> String? {
        if let inline = item["data_content"] as? String, !inline.isEmpty {
            return inline
        }
        guard let link = item["data_link"] as? String, let url = URL(string: link) else {
            return nil
        }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            Diagnostics.log("plaud", "content.link fetch failed")
            return nil
        }
        return text
    }

    // MARK: - Helpers

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}

// MARK: - OAuth callback listener

/// One-shot HTTP listener for the OAuth redirect. Plaud's public client id
/// is registered with `http://localhost:8199/auth/callback`, so the port is
/// not negotiable. Serves exactly one successful callback, answers stray
/// requests (favicon probes) with 404, and shuts down with the flow.
/// `nonisolated`: NWListener delivers on a background queue; the lock is the
/// synchronization, not an actor.
private nonisolated final class PlaudOAuthCallbackServer: @unchecked Sendable {
    struct Callback {
        let code: String
        let state: String?
    }

    private let listener: NWListener
    private let path: String
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Callback, Error>?
    private var connections: [NWConnection] = []

    init(port: UInt16, path: String) throws {
        self.path = path
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw PlaudClient.PlaudError(message: "Invalid callback port.")
        }
        let params = NWParameters.tcp
        // Loopback only — the callback carries an auth code; nothing on the
        // LAN has any business connecting here.
        params.requiredInterfaceType = .loopback
        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            throw PlaudClient.PlaudError(
                message: "Port \(port) is busy — close the app using it and try again."
            )
        }
    }

    func waitForCallback(timeout: TimeInterval) async throws -> Callback {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            continuation = cont
            lock.unlock()

            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    self?.finish(.failure(PlaudClient.PlaudError(
                        message: "Callback server failed: \(error.localizedDescription)"
                    )))
                }
            }
            listener.start(queue: .global(qos: .userInitiated))

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(PlaudClient.PlaudError(
                    message: "Timed out waiting for the browser sign-in."
                )))
            }
        }
    }

    private func handle(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
        connection.start(queue: .global(qos: .userInitiated))
        // The whole GET request line fits in the first read; 16 KB is plenty.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let head = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            self.respond(to: head, on: connection)
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        // "GET /auth/callback?code=..&state=.. HTTP/1.1"
        guard let requestLine = head.components(separatedBy: "\r\n").first,
              requestLine.hasPrefix("GET ") else {
            send(connection, status: "405 Method Not Allowed", body: "")
            return
        }
        let target = requestLine.dropFirst(4).components(separatedBy: " ").first ?? ""
        guard let components = URLComponents(string: String(target)),
              components.path == path else {
            send(connection, status: "404 Not Found", body: "")
            return
        }
        let query = components.queryItems ?? []
        if let error = query.first(where: { $0.name == "error" })?.value {
            send(connection, status: "200 OK", body: Self.html(title: "Authorization failed", detail: error))
            finish(.failure(PlaudClient.PlaudError(message: "Authorization was denied: \(error)")))
            return
        }
        guard let code = query.first(where: { $0.name == "code" })?.value else {
            send(connection, status: "200 OK", body: Self.html(title: "Authorization failed", detail: "Missing code."))
            finish(.failure(PlaudClient.PlaudError(message: "Callback carried no authorization code.")))
            return
        }
        let state = query.first(where: { $0.name == "state" })?.value
        send(connection, status: "200 OK", body: Self.html(title: "Authorization successful!", detail: "You can close this tab and return to Cuate."))
        finish(.success(Callback(code: code, state: state)))
    }

    private func send(_ connection: NWConnection, status: String, body: String) {
        let payload = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
        connection.send(content: Data(payload.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func html(title: String, detail: String) -> String {
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>Cuate × Plaud</title></head><body style=\"font-family:system-ui;padding:2rem;text-align:center;\"><h1>\(title)</h1><p>\(detail)</p></body></html>"
    }

    private func finish(_ result: Result<Callback, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        guard let cont else { return }
        switch result {
        case .success(let callback): cont.resume(returning: callback)
        case .failure(let error): cont.resume(throwing: error)
        }
    }

    func stop() {
        finish(.failure(PlaudClient.PlaudError(message: PlaudClient.PlaudError.cancelledMessage)))
        listener.cancel()
        lock.lock()
        let open = connections
        connections = []
        lock.unlock()
        // A cancel right after send would race the final response bytes —
        // the per-connection send completion already cancels each one; this
        // sweep only covers connections that never got a response.
        for connection in open where connection.state != .cancelled {
            connection.cancel()
        }
    }
}
