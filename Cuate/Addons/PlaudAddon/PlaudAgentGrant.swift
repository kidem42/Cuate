import Foundation

/// Hands the Hermes agent its own read-only access to the Plaud library.
///
/// The agent's tools live on ITS host, so they need their own copy of the
/// grant — Cuate's Keychain is unreachable from a VPS. This writes the two
/// tokens into `~/.hermes/plaud.json` on that host, which is exactly where the
/// `cuate-plaud` plugin looks; the plugin refreshes them by itself afterwards.
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

    /// Where the plugin reads the grant, relative to the agent host's home.
    static let remotePath = ".hermes/plaud.json"

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
