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
