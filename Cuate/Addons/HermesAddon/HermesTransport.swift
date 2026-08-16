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
    /// Server-side pin (Hermes 0.20: PATCH persists it, the list backfills
    /// pinned sessions past the recency window). nil = gateway predates the
    /// field — local pins stay the only truth then.
    var pinned: Bool?
}

/// One transcript row from `GET /api/sessions/{id}/messages`. `id` is the
/// gateway's integer sequence within the session — our `seq`; the stable
/// external identity is "<sessionID>#<id>".
struct HermesTranscriptMessage {
    let id: Int
    let role: String // user | assistant | tool
    let content: String
    let toolName: String?
    /// tool rows: which call this result answers.
    let toolCallID: String?
    /// assistant shells: the calls with their tool name and raw JSON
    /// arguments — the journal's expanded detail shows the command text from
    /// here, and the name is what labels a call still awaiting its result
    /// (`HermesLiveTurnDetector`; tool ROWS carry `toolName`, shells don't).
    let toolCallArguments: [(id: String, name: String, arguments: String)]
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
    /// `runtime` — the ACTUAL (provider, model) this turn ran on
    /// (`assistant.completed.runtime`, 0.20): the ground truth the label
    /// reconciliation records, whatever was requested or rerouted.
    case assistantCompleted(content: String, interrupted: Bool,
                            runtime: (provider: String, model: String)?)
    /// `contextTokens` — the prompt size of the run's LAST model call, i.e.
    /// the session's actual context fill (what Hermes' own status bar shows).
    /// Only patched gateways send it (`usage.context_tokens`, our carried
    /// commit); stock 0.19.0 reports run-CUMULATIVE sums in `usage` — summed
    /// across every tool-loop call, so a 26-step turn "uses" 2M+ tokens.
    /// `windowTokens` — the window the agent ACTUALLY operates with (OAuth
    /// caps included; `usage.context_window`, the second line of the Cuate
    /// gateway patch). Both gauge numbers ride the same frame.
    case runCompleted(usage: TokenUsage, contextTokens: Int?, windowTokens: Int?)
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

/// `nonisolated` (the target defaults to MainActor): the transport holds
/// only value state and must not drag its work onto the main actor — the
/// full-transcript JSON parse measured 0.5–3.7s per fetch (telemetry
/// 2026-07-31) and, main-isolated, it stalled scrolling on every sync.
nonisolated struct HermesTransport {
    let baseURL: URL
    let apiKey: String

    /// Loopback answers in milliseconds; a dead LAN host should fail the
    /// probe fast, not spin a minute (§ plan: ~1.5s probe timeout).
    var requestTimeout: TimeInterval = 15

    /// How Cuate introduces itself to a gateway. The API server records the
    /// `User-Agent` in its request audit context and stamps it into the
    /// `origin` of jobs created over HTTP (`api_server.py`,
    /// `_request_audit_context` / `_cron_origin_from_request`) — so a named
    /// client shows up in the operator's log instead of an anonymous request.
    /// Every request we make to a Hermes host carries it.
    static let userAgent: String = {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "Cuate/\(short) (macOS \(os.majorVersion).\(os.minorVersion); +https://github.com/kidem42/Cuate)"
    }()

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = requestTimeout
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
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
    ///
    /// `@concurrent` — under approachable concurrency a nonisolated async
    /// func still runs on the CALLER's actor, and every caller here is
    /// MainActor code; this hop is what actually takes the
    /// `JSONSerialization` of megabyte transcripts off the main thread.
    @concurrent
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

    /// `/api/model/info`: the agent's CURRENT model plus the context window
    /// Hermes resolved for it through its own full chain (config override →
    /// probes → OAuth caps → table). ⚠️ The route belongs to the DASHBOARD
    /// server, not the API server (absent from both the 0.19 and 0.20 route
    /// tables — established 2026-08-12; the earlier "newer than the VPS"
    /// reading of the 404 was wrong). Callers reach it via a transport built
    /// on `dashboardBaseURL`; against the API server it 404s, which reads as
    /// "no data", never an error.
    func modelInfo() async throws -> (model: String, contextLength: Int) {
        let object = try await json("GET", "api/model/info")
        let model = object["model"] as? String ?? ""
        let length = object["effective_context_length"] as? Int ?? 0
        return (model, length)
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
            preview: row["preview"] as? String,
            pinned: row["pinned"] as? Bool
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

    @concurrent
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

    /// Persists a pin on the gateway (Hermes 0.20; 0.19 rejected the field
    /// with a 400 — callers treat failure as "server can't, local pin only").
    func setSessionPinned(id: String, pinned: Bool) async throws {
        _ = try await json("PATCH", "api/sessions/\(id)", body: ["pinned": pinned])
    }

    /// `POST /api/sessions/{id}/steer` — the Cuate gateway patch (0.20+,
    /// advertised as `features.session_steer`): injects follow-up text into
    /// the session's RUNNING turn via the agent's own steer primitive — it
    /// rides on the next completed tool batch, no interrupt. Returns true
    /// when queued, false when the agent refused the text. Throws
    /// `.http(409, …)` (`no_active_turn`) when nothing is running — the
    /// caller then falls back to an ordinary send.
    func steer(sessionID: String, text: String) async throws -> Bool {
        let object = try await json("POST", "api/sessions/\(sessionID)/steer",
                                    body: ["text": text])
        return (object["status"] as? String) == "queued"
    }

    /// `POST /v1/runs/{id}/steer` — UPSTREAM Hermes (v2026.8.13+, advertised
    /// as `features.run_steer`): the same primitive, addressed by run id
    /// instead of session id. Preferred over `steer(sessionID:)` — it needs
    /// no gateway patch. Session-chat runs qualify: the stream handler
    /// registers its run in `_active_run_agents` (`active_run_id=run_id`),
    /// which is what the handler looks the agent up in.
    ///
    /// Returns true when the agent took the text. Throws `.http(404,
    /// run_not_found)` for an unknown/finished run and `.http(409, …)` when
    /// the run is no longer accepting steer input — both mean "send it as an
    /// ordinary turn instead".
    func steerRun(runID: String, text: String) async throws -> Bool {
        let object = try await json("POST", "v1/runs/\(runID)/steer", body: ["text": text])
        return (object["accepted"] as? Bool) == true
    }

    /// ⚠️ Required after `createSession`: a fresh session inherits the
    /// literal model "hermes-agent" and every turn 404s until locked
    /// (fixtures). Provider+model pairs come from `modelOptions()`.
    ///
    /// Returns what the gateway ACTUALLY locked. 0.20's handler runs the
    /// body through config `model_routes` first, and an alias route there
    /// silently overrides the explicit provider (found live 2026-08-13:
    /// picked Codex, got Nous Portal — the 200 "success" carried
    /// `runtime.provider: nous` all along). Callers must compare and tell
    /// the user instead of celebrating the 200.
    @discardableResult
    func lockModel(sessionID: String, provider: String, model: String) async throws
        -> (provider: String, model: String, routeSource: String) {
        let object = try await json("POST", "api/sessions/\(sessionID)/model",
                                    body: ["model": model, "provider": provider])
        let runtime = object["runtime"] as? [String: Any] ?? [:]
        return (
            provider: runtime["provider"] as? String ?? provider,
            model: runtime["model"] as? String ?? model,
            routeSource: runtime["route_source"] as? String ?? ""
        )
    }

    /// A transcript row's text. `content` comes back either as a plain
    /// string or as an OpenAI-style parts array — the very shape WE send
    /// whenever a message carries an image (`inputPayload`), and what phone
    /// clients send for media. Read as a string only, those rows arrived
    /// EMPTY and the mirror dropped them as contentless: a long session held
    /// on the phone mirrored onto the desktop as a couple of bubbles
    /// (diagnosed 2026-08-10 from `mirror.catchUp rows=289 merged=2`).
    ///
    /// Image/audio parts become bracketed placeholders on purpose: the
    /// gateway keeps no pixels, and the mirror's matcher strips `[…]` tokens
    /// before comparing with our local copy, which holds the real attachment
    /// (`AgentAttachNote.normalizedForMatching`).
    static func transcriptText(_ raw: Any?) -> String {
        if let text = raw as? String { return text }
        guard let parts = raw as? [[String: Any]] else { return "" }
        return parts.compactMap { part -> String? in
            switch part["type"] as? String {
            case "image_url", "input_image", "image": return "[image]"
            case "input_audio", "audio": return "[audio]"
            case "file", "input_file": return "[file]"
            // Text parts — and any shape we don't know, which still carries
            // its text under the same key on every variant seen so far.
            default: return part["text"] as? String
            }
        }.joined(separator: "\n")
    }

    /// Hermes 0.20 paginated `/messages` (unqualified GET now serves the
    /// LATEST 500, silently beheading long transcripts — the mirror merge
    /// needs the whole thing). Explicit oldest-first pages restore the full
    /// fetch: loop until a short page. A 0.19 gateway ignores the params and
    /// serves everything at once — the first page is then short by the same
    /// rule, so both generations converge on one code path.
    @concurrent
    func messages(sessionID: String) async throws -> [HermesTranscriptMessage] {
        let pageSize = 500 // server cap per page (0.20)
        let maxPages = 40  // 20k rows — far beyond any live session; a bound, not a target
        var rows: [[String: Any]] = []
        var offset = 0
        for page in 0..<maxPages {
            let object = try await json(
                "GET", "api/sessions/\(sessionID)/messages",
                query: [
                    URLQueryItem(name: "order", value: "oldest"),
                    URLQueryItem(name: "limit", value: String(pageSize)),
                    URLQueryItem(name: "offset", value: String(offset)),
                ])
            let data = object["data"] as? [[String: Any]] ?? []
            rows.append(contentsOf: data)
            // 0.19 has no `pagination` block AND ignores the params — looping
            // there would refetch the same full transcript forever.
            if data.count < pageSize || object["pagination"] == nil { break }
            offset += data.count
            if page == maxPages - 1 {
                // Never truncate silently — a session this size deserves a trace.
                Diagnostics.log("hermes", "messages: page cap hit session=\(sessionID) rows=\(rows.count)")
            }
        }
        return Self.parseTranscript(rows)
    }

    private static func parseTranscript(_ data: [[String: Any]]) -> [HermesTranscriptMessage] {
        return data.compactMap { row in
            guard let id = row["id"] as? Int, let role = row["role"] as? String else { return nil }
            var callArguments: [(String, String, String)] = []
            if let calls = row["tool_calls"] as? [[String: Any]] {
                for call in calls {
                    guard let callID = (call["id"] ?? call["call_id"]) as? String else { continue }
                    let function = call["function"] as? [String: Any]
                    callArguments.append((
                        callID,
                        (function?["name"] as? String) ?? (call["name"] as? String) ?? "tool",
                        function?["arguments"] as? String ?? ""
                    ))
                }
            }
            return HermesTranscriptMessage(
                id: id,
                role: role,
                content: Self.transcriptText(row["content"]),
                toolName: row["tool_name"] as? String,
                toolCallID: row["tool_call_id"] as? String,
                toolCallArguments: callArguments,
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

    /// `GET /v1/runs/{id}` → `{"object":"hermes.run","status":…}`, or 404
    /// `run_not_found` once the gateway has forgotten it. Answers the one
    /// question the session API cannot: is THIS turn still going? Without it
    /// a run killed mid-tool (a gateway restart, a crash) leaves an
    /// unfinished transcript tail that our detector must read as "working"
    /// for its full staleness window.
    ///
    /// False on 404, on an unknown status, and on any transport failure — a
    /// run we cannot see is not one to keep waiting on. The route is newer
    /// than some deployments, so a 404 from an older gateway lands on the
    /// same answer and merely restores the old timeout behaviour.
    func runIsRunning(runID: String) async -> Bool {
        guard let object = try? await json("GET", "v1/runs/\(runID)"),
              let status = object["status"] as? String else { return false }
        return status == "running" || status == "queued" || status == "stopping"
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
            // The turn's factual runtime (0.20). Absent/empty on older
            // gateways — nil keeps the stored label untouched.
            var runtime: (provider: String, model: String)?
            if let raw = payload["runtime"] as? [String: Any] {
                let provider = raw["provider"] as? String ?? ""
                let model = raw["model"] as? String ?? ""
                if !provider.isEmpty || !model.isEmpty {
                    runtime = (provider, model)
                }
            }
            return .assistantCompleted(content: payload["content"] as? String ?? "",
                                       interrupted: payload["interrupted"] as? Bool ?? false,
                                       runtime: runtime)
        case "run.completed":
            var usage = TokenUsage()
            var contextTokens: Int?
            var windowTokens: Int?
            if let raw = payload["usage"] as? [String: Any] {
                usage.inputTokens = raw["input_tokens"] as? Int ?? 0
                usage.outputTokens = raw["output_tokens"] as? Int ?? 0
                usage.cacheReadTokens = raw["cache_read_tokens"] as? Int ?? 0
                usage.cacheWriteTokens = raw["cache_write_tokens"] as? Int ?? 0
                usage.reasoningTokens = raw["reasoning_tokens"] as? Int ?? 0
                if let context = raw["context_tokens"] as? Int, context > 0 {
                    contextTokens = context
                }
                if let window = raw["context_window"] as? Int, window > 0 {
                    windowTokens = window
                }
            }
            return .runCompleted(usage: usage, contextTokens: contextTokens, windowTokens: windowTokens)
        case "done":
            return .done
        default:
            return .unknown(event: name, payload: payload)
        }
    }
}
