import Foundation

/// Native Ollama management client (`/api/*`): installed-model list, per-model
/// capabilities, pull/delete, load/unload, and loaded-model status.
///
/// These routes are Ollama-specific — NOT part of the OpenAI-compatible `/v1`
/// surface the chat provider uses — so callers invoke them only after
/// `detect()` confirms the endpoint is actually Ollama. All methods are cheap
/// value-type async calls reusing the shared ephemeral `HTTPClient.session`.
struct OllamaAdminService {
    /// Host root derived from the chat endpoint URL, e.g. http://localhost:11434
    let host: URL

    init(endpointURL: String) {
        // The chat URL is the OpenAI-compatible base (…/v1); Ollama's native API
        // lives at the host root under /api. Strip a trailing /v1 (+ slashes).
        var trimmed = endpointURL.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasSuffix("/v1") { trimmed.removeLast(3) }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.host = URL(string: trimmed) ?? URL(string: "http://localhost:11434")!
    }

    private func apiURL(_ path: String) -> URL {
        host.appendingPathComponent("api").appendingPathComponent(path)
    }

    private func jsonRequest(_ path: String, method: String, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: apiURL(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Types

    /// An installed model with its on-disk size.
    struct InstalledModel: Identifiable, Equatable {
        let name: String
        let sizeBytes: Int64
        var id: String { name }
    }

    /// A model currently resident in memory, with its footprint.
    struct LoadedModel: Equatable {
        let name: String
        /// Bytes held in (V)RAM — `size_vram`, falling back to `size`. On Apple
        /// Silicon's unified memory this is the model's real RAM footprint.
        let sizeVRAM: Int64
    }

    /// Streaming pull progress (bytes of the current layer).
    struct PullProgress: Equatable {
        let status: String
        let completed: Int64
        let total: Int64
        var fraction: Double { total > 0 ? min(1, Double(completed) / Double(total)) : 0 }
    }

    // MARK: - Detection

    /// True when the endpoint is Ollama (native `/api/version` answers 2xx).
    func detect() async -> Bool {
        var request = URLRequest(url: apiURL("version"))
        request.timeoutInterval = 4
        guard let (_, response) = try? await HTTPClient.session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return false
        }
        return true
    }

    // MARK: - Queries

    /// GET `/api/tags` — installed models with on-disk size.
    func tags() async throws -> [InstalledModel] {
        let data = try await HTTPClient.json(URLRequest(url: apiURL("tags")))
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            throw ProviderError.decoding("unexpected /api/tags payload")
        }
        return models.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            let size = (item["size"] as? NSNumber)?.int64Value ?? 0
            return InstalledModel(name: name, sizeBytes: size)
        }
    }

    /// GET `/api/ps` — models currently loaded in memory, with footprint.
    func ps() async throws -> [LoadedModel] {
        let data = try await HTTPClient.json(URLRequest(url: apiURL("ps")))
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            return []
        }
        return models.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            let vram = (item["size_vram"] as? NSNumber)?.int64Value
                ?? (item["size"] as? NSNumber)?.int64Value ?? 0
            return LoadedModel(name: name, sizeVRAM: vram)
        }
    }

    /// POST `/api/show` — per-model capabilities, mapped onto the shared
    /// `ModelInfo` (vision/tools/reasoning) used by the capability gates.
    func show(model: String) async throws -> ModelInfo {
        let request = try jsonRequest("show", method: "POST", body: ["model": model])
        let data = try await HTTPClient.json(request)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let caps = (json?["capabilities"] as? [String]) ?? []
        return ModelInfo(
            id: model,
            supportsVision: caps.contains("vision"),
            supportsTools: caps.contains("tools"),
            supportsReasoning: caps.contains("thinking") || caps.contains("reasoning"),
            supportedParameters: caps
        )
    }

    // MARK: - Mutations

    /// DELETE `/api/delete` — remove a model from disk.
    func delete(model: String) async throws {
        let request = try jsonRequest("delete", method: "DELETE", body: ["model": model])
        _ = try await HTTPClient.json(request)
    }

    /// "Start" — keep the model resident in memory (`keep_alive: -1`).
    func load(model: String) async throws {
        try await setKeepAlive(model: model, keepAlive: -1)
    }

    /// "Stop" — unload the model from memory immediately (`keep_alive: 0`).
    func unload(model: String) async throws {
        try await setKeepAlive(model: model, keepAlive: 0)
    }

    /// A prompt-less `/api/generate` just loads or unloads the model depending
    /// on `keep_alive`; `stream: false` collapses the reply to a single object.
    private func setKeepAlive(model: String, keepAlive: Int) async throws {
        let request = try jsonRequest("generate", method: "POST", body: [
            "model": model, "keep_alive": keepAlive, "stream": false
        ])
        _ = try await HTTPClient.json(request)
    }

    // MARK: - Pull (streaming progress)

    /// POST `/api/pull` (stream) — yields progress as newline-delimited JSON
    /// arrives. Cancelling the consuming task cancels the download.
    func pull(model: String) -> AsyncThrowingStream<PullProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try jsonRequest("pull", method: "POST", body: ["model": model])
                    let (bytes, response) = try await HTTPClient.session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw ProviderError.badResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = Data()
                        for try await b in bytes { body.append(b) }
                        throw ProviderError.fromHTTP(status: http.statusCode, body: body)
                    }
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
                        if let err = json["error"] as? String {
                            throw ProviderError.http(status: 200, message: err)
                        }
                        continuation.yield(PullProgress(
                            status: json["status"] as? String ?? "",
                            completed: (json["completed"] as? NSNumber)?.int64Value ?? 0,
                            total: (json["total"] as? NSNumber)?.int64Value ?? 0
                        ))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
