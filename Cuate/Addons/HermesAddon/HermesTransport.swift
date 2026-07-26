import Foundation

// MARK: - Hermes API transport
//
// HTTP + SSE client for the Hermes Agent API server, written against LIVE
// fixtures (Hermes-API-Fixtures.md, Hermes 0.19.0) — not the docs prose.
// Value type: one instance per call site, holding the endpoint and token.

// MARK: Wire models (shapes from the fixtures)

/// `/v1/capabilities` — feature flags gate whole UI sections: a false flag
/// hides the section, it never breaks the addon.
struct HermesCapabilities {
    var features: [String: Bool] = [:]
    var platform: String = ""

    func supports(_ feature: String) -> Bool {
        features[feature] ?? false
    }
}

/// One session row from `/api/sessions` (rich enough for the sessions list
/// without extra requests) or `POST /api/sessions`.
struct HermesSessionInfo: Identifiable, Equatable {
    let id: String
    var title: String?
    var model: String?
    var source: String?
    var startedAt: Date?
    var lastActive: Date?
    var messageCount: Int
    var toolCallCount: Int
    var inputTokens: Int
    var outputTokens: Int
    var preview: String?
}

/// One transcript row from `GET /api/sessions/{id}/messages`. `id` is the
/// gateway's integer sequence within the session — our `seq`; the stable
/// external identity is "<sessionID>#<id>".
struct HermesTranscriptMessage {
    let id: Int
    let role: String // user | assistant | tool
    let content: String
    let toolName: String?
    let timestamp: Date?

    func externalID(sessionID: String) -> String {
        "\(sessionID)#\(id)"
    }
}

struct HermesSkill: Identifiable {
    var id: String { name }
    let name: String
    let description: String
    let category: String
}

struct HermesToolset: Identifiable {
    var id: String { name }
    let name: String
    let label: String // gateway sends it emoji-prefixed, render as is
    let description: String
    let enabled: Bool
    let tools: [String]
}

/// `/api/model/options` — provider rows for the model-lock picker.
struct HermesProviderOption: Identifiable {
    var id: String { slug }
    let slug: String
    let name: String
    let isCurrent: Bool
    let models: [String]
}

/// SSE frames of `POST /api/sessions/{id}/chat/stream` (fixture order:
/// run.started → message.started → tool.* / assistant.delta →
/// assistant.completed → run.completed → done). `seq`/`ts` ride on every
/// frame but the consumer doesn't need them — run/message ids do the work.
enum HermesStreamEvent {
    case runStarted(runID: String)
    case messageStarted(messageID: String)
    case toolStarted(tool: String, preview: String?)
    /// `tool_name == "_thinking"` is the model's reasoning stream, not a tool.
    case toolProgress(tool: String, delta: String)
    case toolCompleted(tool: String)
    case assistantDelta(String)
    /// Definitive full text. NOTE: a turn that failed on the gateway ALSO
    /// arrives this way — as error text with HTTP 200 (see fixtures).
    case assistantCompleted(content: String, interrupted: Bool)
    case runCompleted(usage: TokenUsage)
    case done
    /// Approval frames (feature-flagged; exact name pinned down in stage 6
    /// against the live gateway) and anything a future Hermes adds.
    case unknown(event: String, payload: [String: Any])
}

enum HermesTransportError: LocalizedError {
    case http(status: Int, body: String)
    case badPayload(String)

    var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            return "Hermes API error (HTTP \(status)): \(String(body.prefix(200)))"
        case .badPayload(let detail):
            return "Unexpected Hermes response: \(detail)"
        }
    }

    /// Maps onto the shared diagnostics table (§7).
    var probeStatus: GatewayProbe.Status {
        if case .http(let status, _) = self {
            return GatewayProbe.status(forHTTPStatus: status)
        }
        return .failed(localizedDescription)
    }
}

// MARK: - Transport

struct HermesTransport {
    let baseURL: URL
    let apiKey: String

    /// Loopback answers in milliseconds; a dead LAN host should fail the
    /// probe fast, not spin a minute (§ plan: ~1.5s таймаут пробы).
    var requestTimeout: TimeInterval = 15

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = requestTimeout
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    /// Runs a request and returns the parsed JSON object, mapping non-2xx
    /// onto `HermesTransportError.http`.
    private func json(_ method: String, _ path: String, body: [String: Any]? = nil,
                      query: [URLQueryItem] = []) async throws -> [String: Any] {
        var req = try request(method, path, body: body)
        if !query.isEmpty, let url = req.url,
           var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.queryItems = query
            req.url = comps.url
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw HermesTransportError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HermesTransportError.badPayload("not a JSON object at \(path)")
        }
        return object
    }

    // MARK: Probe & discovery

    /// `GET /health` is unauthenticated: `{"status":"ok","platform":...,"version":...}`.
    func health() async throws -> String {
        let object = try await json("GET", "health")
        let platform = object["platform"] as? String ?? "?"
        let version = object["version"] as? String ?? "?"
        return "\(platform) \(version)"
    }

    func capabilities() async throws -> HermesCapabilities {
        let object = try await json("GET", "v1/capabilities")
        var caps = HermesCapabilities()
        caps.platform = object["platform"] as? String ?? ""
        if let features = object["features"] as? [String: Any] {
            for (key, value) in features {
                if let flag = value as? Bool { caps.features[key] = flag }
            }
        }
        return caps
    }

    /// Model ids from `/v1/models` — the role list (usually one per profile).
    func models() async throws -> [String] {
        let object = try await json("GET", "v1/models")
        let data = object["data"] as? [[String: Any]] ?? []
        return data.compactMap { $0["id"] as? String }
    }

    /// `/api/model/options`: provider rows + the agent's CURRENT
    /// (provider, model) pair at top level — the reliable model-lock source.
    func modelOptions() async throws -> (current: (provider: String, model: String)?, providers: [HermesProviderOption]) {
        let object = try await json("GET", "api/model/options")
        let providers = (object["providers"] as? [[String: Any]] ?? []).compactMap { row -> HermesProviderOption? in
            guard let slug = row["slug"] as? String else { return nil }
            return HermesProviderOption(
                slug: slug,
                name: row["name"] as? String ?? slug,
                isCurrent: row["is_current"] as? Bool ?? false,
                models: row["models"] as? [String] ?? []
            )
        }
        var current: (String, String)?
        if let model = object["model"] as? String, !model.isEmpty,
           let provider = object["provider"] as? String, !provider.isEmpty {
            current = (provider, model)
        }
        return (current, providers)
    }

    // MARK: Sessions

    private static func sessionInfo(_ row: [String: Any]) -> HermesSessionInfo? {
        guard let id = row["id"] as? String else { return nil }
        return HermesSessionInfo(
            id: id,
            title: row["title"] as? String,
            model: row["model"] as? String,
            source: row["source"] as? String,
            startedAt: (row["started_at"] as? Double).map { Date(timeIntervalSince1970: $0) },
            lastActive: (row["last_active"] as? Double).map { Date(timeIntervalSince1970: $0) },
            messageCount: row["message_count"] as? Int ?? 0,
            toolCallCount: row["tool_call_count"] as? Int ?? 0,
            inputTokens: row["input_tokens"] as? Int ?? 0,
            outputTokens: row["output_tokens"] as? Int ?? 0,
            preview: row["preview"] as? String
        )
    }

    func createSession(title: String) async throws -> HermesSessionInfo {
        let object = try await json("POST", "api/sessions", body: ["title": title])
        guard let row = object["session"] as? [String: Any],
              let info = Self.sessionInfo(row) else {
            throw HermesTransportError.badPayload("session create")
        }
        return info
    }

    func sessions(limit: Int = 50, offset: Int = 0) async throws -> [HermesSessionInfo] {
        let object = try await json("GET", "api/sessions", query: [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset))
        ])
        let data = object["data"] as? [[String: Any]] ?? []
        return data.compactMap { Self.sessionInfo($0) }
    }

    func deleteSession(id: String) async throws {
        _ = try await json("DELETE", "api/sessions/\(id)")
    }

    /// Renames a session on the gateway (`PATCH` accepts `title`).
    func renameSession(id: String, title: String) async throws {
        _ = try await json("PATCH", "api/sessions/\(id)", body: ["title": title])
    }

    /// ⚠️ Required after `createSession`: a fresh session inherits the
    /// literal model "hermes-agent" and every turn 404s until locked
    /// (fixtures). Provider+model pairs come from `modelOptions()`.
    func lockModel(sessionID: String, provider: String, model: String) async throws {
        _ = try await json("POST", "api/sessions/\(sessionID)/model",
                           body: ["model": model, "provider": provider])
    }

    func messages(sessionID: String) async throws -> [HermesTranscriptMessage] {
        let object = try await json("GET", "api/sessions/\(sessionID)/messages")
        let data = object["data"] as? [[String: Any]] ?? []
        return data.compactMap { row in
            guard let id = row["id"] as? Int, let role = row["role"] as? String else { return nil }
            return HermesTranscriptMessage(
                id: id,
                role: role,
                content: row["content"] as? String ?? "",
                toolName: row["tool_name"] as? String,
                timestamp: (row["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) }
            )
        }
    }

    // MARK: Skills & toolsets

    func skills() async throws -> [HermesSkill] {
        let object = try await json("GET", "v1/skills")
        let data = object["data"] as? [[String: Any]] ?? []
        return data.compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            return HermesSkill(
                name: name,
                description: row["description"] as? String ?? "",
                category: row["category"] as? String ?? ""
            )
        }
    }

    func toolsets() async throws -> [HermesToolset] {
        let object = try await json("GET", "v1/toolsets")
        let data = object["data"] as? [[String: Any]] ?? []
        return data.compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            return HermesToolset(
                name: name,
                label: row["label"] as? String ?? name,
                description: row["description"] as? String ?? "",
                enabled: row["enabled"] as? Bool ?? false,
                tools: row["tools"] as? [String] ?? []
            )
        }
    }

    // MARK: Runs

    func stopRun(runID: String) async throws {
        _ = try await json("POST", "v1/runs/\(runID)/stop")
    }

    /// Body shape to be pinned against the live gateway in stage 6 (the
    /// endpoint is advertised by capabilities; docs give no schema).
    func resolveApproval(runID: String, approvalID: String, approve: Bool) async throws {
        _ = try await json("POST", "v1/runs/\(runID)/approval",
                           body: ["approval_id": approvalID, "approved": approve])
    }

    // MARK: Chat stream (SSE)

    /// Builds the `input` payload: plain text, or OpenAI-style content parts
    /// when images ride along (probed live: the parts array works, a flat
    /// `images` field is silently ignored — see fixtures).
    static func inputPayload(text: String, images: [(mimeType: String, base64: String)]) -> Any {
        guard !images.isEmpty else { return text }
        var parts: [[String: Any]] = []
        if !text.isEmpty {
            parts.append(["type": "text", "text": text])
        }
        for image in images {
            parts.append([
                "type": "image_url",
                "image_url": ["url": "data:\(image.mimeType);base64,\(image.base64)"]
            ])
        }
        return parts
    }

    /// Streams one turn. Emits `HermesStreamEvent`s parsed from the SSE
    /// frames; finishes after `done` (or throws on transport/HTTP failure —
    /// note that GATEWAY-side turn errors arrive as `assistantCompleted`
    /// text with HTTP 200, see fixtures). `input` is a String or an
    /// OpenAI-parts array (see `inputPayload`).
    func chatStream(sessionID: String, input: Any,
                    modelOptions: [String: Any]? = nil) -> AsyncThrowingStream<HermesStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var body: [String: Any] = ["input": input]
                    // Per-request knobs (reasoning_effort). NOTE: 0.19.0
                    // accepts the field silently and echoes nothing back —
                    // unverifiable server-side, see fixtures.
                    if let modelOptions, !modelOptions.isEmpty {
                        body["model_options"] = modelOptions
                    }
                    var req = try request("POST", "api/sessions/\(sessionID)/chat/stream",
                                          body: body)
                    // A turn with tools can stay silent for a while — the
                    // request timeout must not kill a healthy stream.
                    req.timeoutInterval = 600
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200...299).contains(status) else {
                        // Drain a bounded chunk of the error body for the message.
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 500 { break }
                        }
                        throw HermesTransportError.http(status: status, body: body)
                    }

                    // SSE framing: "event: <name>" then "data: <json>".
                    // ⚠️ The frame is dispatched ON the data line, NOT on the
                    // blank separator: `AsyncBytes.lines` SKIPS empty lines,
                    // so a blank-line-delimited parser never fires a single
                    // frame (live bug 2026-07-25 — every turn ended with
                    // zero events). Hermes sends one-line JSON payloads, so
                    // per-data dispatch is exact.
                    var eventName = ""
                    for try await line in bytes.lines {
                        if line.hasPrefix("event:") {
                            eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:"), !eventName.isEmpty {
                            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            if let event = Self.parseEvent(name: eventName, data: payload) {
                                continuation.yield(event)
                                if case .done = event {
                                    continuation.finish()
                                    return
                                }
                            }
                            eventName = ""
                        }
                        try Task.checkCancellation()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Maps one SSE frame onto a stream event (names/fields from fixtures).
    static func parseEvent(name: String, data: String) -> HermesStreamEvent? {
        let payload = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] ?? [:]
        switch name {
        case "run.started":
            return .runStarted(runID: payload["run_id"] as? String ?? "")
        case "message.started":
            let message = payload["message"] as? [String: Any]
            return .messageStarted(messageID: message?["id"] as? String ?? "")
        case "tool.started":
            var preview = payload["preview"] as? String
            // Fall back to the args dict when preview is missing.
            if preview == nil, let args = payload["args"] as? [String: Any], !args.isEmpty {
                preview = args.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")
            }
            return .toolStarted(tool: payload["tool_name"] as? String ?? "?", preview: preview)
        case "tool.progress":
            return .toolProgress(tool: payload["tool_name"] as? String ?? "?",
                                 delta: payload["delta"] as? String ?? "")
        case "tool.completed":
            return .toolCompleted(tool: payload["tool_name"] as? String ?? "?")
        case "assistant.delta":
            return .assistantDelta(payload["delta"] as? String ?? "")
        case "assistant.completed":
            return .assistantCompleted(content: payload["content"] as? String ?? "",
                                       interrupted: payload["interrupted"] as? Bool ?? false)
        case "run.completed":
            var usage = TokenUsage()
            if let raw = payload["usage"] as? [String: Any] {
                usage.inputTokens = raw["input_tokens"] as? Int ?? 0
                usage.outputTokens = raw["output_tokens"] as? Int ?? 0
                usage.cacheReadTokens = raw["cache_read_tokens"] as? Int ?? 0
                usage.cacheWriteTokens = raw["cache_write_tokens"] as? Int ?? 0
                usage.reasoningTokens = raw["reasoning_tokens"] as? Int ?? 0
            }
            return .runCompleted(usage: usage)
        case "done":
            return .done
        default:
            return .unknown(event: name, payload: payload)
        }
    }
}
