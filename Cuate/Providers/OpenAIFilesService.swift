import Foundation

/// OpenAI Files API (`/v1/files`) for document attachments: upload once with
/// `purpose=user_data`, reference by `file_id` in Responses requests, delete
/// when the chat lets the attachment go. Bound to api.openai.com — never used
/// for the OpenAI-compatible providers that share the chat builder.
nonisolated enum OpenAIFilesService {
    struct Uploaded {
        let id: String
        let expiresAt: Date?
    }

    private static let filesURL = URL(string: "https://api.openai.com/v1/files")!

    /// Own session: `HTTPClient.session` allows 120 s per request, which a
    /// 50 MB upload on a slow link can exceed.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 1200
        return URLSession(configuration: config)
    }()

    /// Uploads a document. `expiresInSeconds` asks the server to delete the
    /// file itself (`expires_after` anchored on creation); when the API
    /// rejects the value the upload is retried without it and the app-side
    /// deletion (`RemoteFileJanitor`) remains the only guard.
    static func upload(
        data: Data,
        filename: String,
        mimeType: String,
        expiresInSeconds: Int?,
        apiKey: String
    ) async throws -> Uploaded {
        do {
            return try await send(data: data, filename: filename, mimeType: mimeType,
                                  expiresInSeconds: expiresInSeconds, apiKey: apiKey)
        } catch ProviderError.http(let status, let message)
            where status == 400 && expiresInSeconds != nil && message.lowercased().contains("expires") {
            Diagnostics.log("files", "upload expires_after rejected (\(message.prefix(120))) — retrying without expiry")
            return try await send(data: data, filename: filename, mimeType: mimeType,
                                  expiresInSeconds: nil, apiKey: apiKey)
        }
    }

    /// Deletes a file; a 404 counts as done (already expired or deleted).
    static func delete(fileID: String, apiKey: String) async throws {
        var request = URLRequest(url: filesURL.appendingPathComponent(fileID))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.badResponse }
        if http.statusCode == 404 { return }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.fromHTTP(status: http.statusCode, body: data)
        }
    }

    // MARK: - Request

    private static func send(
        data: Data,
        filename: String,
        mimeType: String,
        expiresInSeconds: Int?,
        apiKey: String
    ) async throws -> Uploaded {
        let boundary = "cuate-\(UUID().uuidString)"
        var request = URLRequest(url: filesURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        appendField(name: "purpose", value: "user_data")
        if let expiresInSeconds {
            appendField(name: "expires_after[anchor]", value: "created_at")
            appendField(name: "expires_after[seconds]", value: String(expiresInSeconds))
        }
        // Quotes and CR/LF in a filename would break the part header.
        let safeName = filename
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (responseData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.fromHTTP(status: http.statusCode, body: responseData)
        }
        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let id = json["id"] as? String, !id.isEmpty else {
            throw ProviderError.decoding("no `id` in file upload response")
        }
        let expiresAt = (json["expires_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return Uploaded(id: id, expiresAt: expiresAt)
    }
}
