import Foundation

/// One-click local onboarding. When the gateway address points at THIS Mac
/// and the probe cannot reach it, a Hermes install is usually present but
/// its gateway process is not running — the API server lives in `hermes
/// gateway run`, which neither the Hermes desktop app nor a closed terminal
/// keeps alive. This type does for the user exactly what the manual setup
/// instructions describe: completes `~/.hermes/.env`, installs the gateway
/// as a launchd service (`hermes gateway install` — idempotent, writes
/// ~/Library/LaunchAgents and bootstraps it), restarts it when the env
/// changed, waits for /health and hands the key back for the Keychain.
enum HermesLocalGateway {

    // MARK: - Detection

    /// The endpoint field points at this Mac — the only case where the app
    /// can fix the gateway itself.
    static func isLocalEndpoint(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var envFile: URL { home.appendingPathComponent(".hermes/.env") }

    /// The `hermes` CLI, wherever the installer put it. The venv binary is
    /// the ground truth; ~/.local/bin is the documented symlink.
    static func cliPath() -> String? {
        let candidates = [
            home.appendingPathComponent(".local/bin/hermes").path,
            home.appendingPathComponent(".hermes/hermes-agent/venv/bin/hermes").path,
            "/usr/local/bin/hermes",
            "/opt/homebrew/bin/hermes"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// A Hermes install exists on this Mac (regardless of gateway state).
    static func isInstalled() -> Bool {
        cliPath() != nil
    }

    // MARK: - Setup

    enum SetupError: LocalizedError {
        case cliNotFound
        case envNotWritable(String)
        case installFailed(String)
        case gatewayNeverCameUp(String)
        case patchFailed(String)

        var errorDescription: String? {
            switch self {
            case .cliNotFound: return HL("hermes.auto.err.cli")
            case .envNotWritable(let detail): return HL("hermes.auto.err.env") + " " + detail
            case .installFailed(let detail): return HL("hermes.auto.err.install") + " " + detail
            case .gatewayNeverCameUp(let detail): return HL("hermes.auto.err.timeout") + (detail.isEmpty ? "" : " " + detail)
            case .patchFailed(let detail): return HL("hermes.patch.err") + " " + detail
            }
        }
    }

    // MARK: - Context-metric patch (usage.context_tokens)
    //
    // Hermes reports run-CUMULATIVE token sums in `run.completed.usage` —
    // useless as a context gauge (a 26-step turn "fills" the window
    // severalfold; seen live: 2188K against a 1050K window). The true fill —
    // the last call's prompt size — lives in `agent.context_compressor.
    // last_prompt_tokens`: Hermes' own status bar shows it, the API omits
    // it. The patch appends it as `usage.context_tokens` after every
    // `"total_tokens"` line of the two usage dicts in gateway/platforms/
    // api_server.py (anchored by code, not line numbers — survives version
    // drift; refuses untouched when the anchor is missing). `hermes update`
    // overwrites the file, so the state is re-checked each time the
    // settings pane looks and the offer simply reappears. The client copes
    // either way: without the field the gauge falls back to the capped sums.

    enum ContextPatchState: Equatable {
        case patched
        case patchable
        /// No install, unreadable file, or a layout the anchor doesn't
        /// match — nothing we can safely offer.
        case unavailable
    }

    private static let contextPatchAnchor =
        "\"total_tokens\": getattr(agent, \"session_total_tokens\", 0) or 0,"
    static let contextPatchLine =
        "\"context_tokens\": max(0, getattr(getattr(agent, \"context_compressor\", None), \"last_prompt_tokens\", 0) or 0),"
    /// Second usage line: the window the agent ACTUALLY operates with
    /// (OAuth caps included) — paired with the fill above, the gauge's both
    /// numbers come from the same `run.completed` frame. Anchored on the
    /// context_tokens line so it also UPGRADES a gateway carrying only the
    /// older one-line patch.
    static let contextWindowLine =
        "\"context_window\": max(0, getattr(getattr(agent, \"context_compressor\", None), \"context_length\", 0) or 0),"

    // MARK: - Steer patch (POST /api/sessions/{id}/steer)
    //
    // Hermes 0.20 grew AIAgent.steer() — mid-turn follow-ups without an
    // interrupt — but wired it only to its own messaging platforms and the
    // TUI RPC, not the REST API this addon speaks. These anchored edits add
    // the route: a per-session live-agent registry next to the shutdown
    // registry (same lifecycle), the handler, and a `session_steer`
    // capabilities flag the client gates its UI on. Anchors exist only in
    // 0.20 (the shutdown registry itself is younger than 0.19), so on an
    // outdated install the whole edit set simply reports non-applicable.
    // Mirrors `HermesSettingsView.gatewayPatchRemoteCommands` — in sync!

    private static let steerMarker = "_handle_session_steer"

    /// Exact-string replacements; each `old` must occur exactly once.
    private static let steerEdits: [(old: String, new: String)] = [
        (
            "        self._shutdown_interruptible_agents: Dict[int, Any] = {}\n",
            "        self._shutdown_interruptible_agents: Dict[int, Any] = {}\n"
            + "        # Cuate patch: live agent per session for mid-turn steering.\n"
            + "        self._active_session_agents: Dict[str, Any] = {}\n"
        ),
        (
            "            (\"POST\", \"/api/sessions/{session_id}/model\", self._handle_session_model_lock),\n",
            "            (\"POST\", \"/api/sessions/{session_id}/model\", self._handle_session_model_lock),\n"
            + "            (\"POST\", \"/api/sessions/{session_id}/steer\", self._handle_session_steer),\n"
        ),
        (
            "                \"session_model_lock\": True,\n",
            "                \"session_model_lock\": True,\n"
            + "                \"session_steer\": True,\n"
        ),
        (
            "                \"session_model_lock\": {\"method\": \"POST\", \"path\": \"/api/sessions/{session_id}/model\"},\n",
            "                \"session_model_lock\": {\"method\": \"POST\", \"path\": \"/api/sessions/{session_id}/model\"},\n"
            + "                \"session_steer\": {\"method\": \"POST\", \"path\": \"/api/sessions/{session_id}/steer\"},\n"
        ),
        (
            "                    self._shutdown_interruptible_agents[id(agent)] = agent\n",
            "                    self._shutdown_interruptible_agents[id(agent)] = agent\n"
            + "                    if session_id:\n"
            + "                        # Cuate patch: expose the live agent for /steer.\n"
            + "                        self._active_session_agents[session_id] = agent\n"
        ),
        (
            "                        self._shutdown_interruptible_agents.pop(id(agent), None)\n",
            "                        self._shutdown_interruptible_agents.pop(id(agent), None)\n"
            + "                        # Cuate patch: drop only this turn's registration.\n"
            + "                        if session_id and self._active_session_agents.get(session_id) is agent:\n"
            + "                            self._active_session_agents.pop(session_id, None)\n"
        ),
        (
            "    @_admit_api_agent_request\n"
            + "    async def _handle_session_chat(self, request: \"web.Request\") -> \"web.Response\":\n",
            steerHandlerSource
            + "    @_admit_api_agent_request\n"
            + "    async def _handle_session_chat(self, request: \"web.Request\") -> \"web.Response\":\n"
        ),
    ]

    /// The handler body inserted before `_handle_session_chat` (the
    /// decorator above it must stay glued to session_chat, hence the anchor
    /// includes it). Raw string: python's `"""` docstring lives inside.
    private static let steerHandlerSource = #"""
        async def _handle_session_steer(self, request: "web.Request") -> "web.Response":
            """POST /api/sessions/{session_id}/steer - Cuate patch.

            Nudges the running turn via AIAgent.steer(): the text rides on the
            next completed tool batch, no interrupt (TUI session.steer semantics).
            200 queued/rejected; 409 no_active_turn -> client sends normally.
            """
            auth_err = self._check_auth(request)
            if auth_err:
                return auth_err
            session_id = request.match_info["session_id"]
            _session, err = await self._get_existing_session_or_404(session_id)
            if err:
                return err
            body, err = await self._read_json_body(request)
            if err:
                return err
            text = str(body.get("text") or "").strip()
            if not text:
                return web.json_response(_openai_error("'text' is required", code="invalid_steer"), status=400)
            agent = self._active_session_agents.get(session_id)
            if agent is None or not hasattr(agent, "steer"):
                return web.json_response(_openai_error("No active turn to steer for this session", code="no_active_turn"), status=409)
            try:
                accepted = bool(agent.steer(text))
            except Exception as exc:
                return web.json_response(_openai_error(f"steer failed: {exc}", code="steer_failed"), status=500)
            return web.json_response({
                "object": "hermes.session.steer",
                "session_id": session_id,
                "status": "queued" if accepted else "rejected",
            })

    """#

    /// The gateway source file, resolved like `cliPath`: the documented
    /// install root first, then the CLI's own `--version` answer ("Install
    /// directory: …") for relocated installs.
    static func apiServerFile() async -> URL? {
        let sub = "gateway/platforms/api_server.py"
        let documented = home.appendingPathComponent(".hermes/hermes-agent/" + sub)
        if FileManager.default.fileExists(atPath: documented.path) { return documented }
        guard let cli = cliPath() else { return nil }
        let version = await run(cli, ["--version"], timeout: 15)
        guard let range = version.tail.range(of: "Install directory: ") else { return nil }
        let root = version.tail[range.upperBound...]
            .split(separator: "\n").first.map(String.init)?
            .components(separatedBy: " · ").first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !root.isEmpty else { return nil }
        let resolved = URL(fileURLWithPath: root).appendingPathComponent(sub)
        return FileManager.default.fileExists(atPath: resolved.path) ? resolved : nil
    }

    /// Steer applies only when every anchor matches exactly once — 0.19
    /// lacks the shutdown registry entirely, so there this is simply false
    /// (not an error: the state row stays quiet until `hermes update`).
    private static func steerApplicable(to src: String) -> Bool {
        steerEdits.allSatisfy { src.components(separatedBy: $0.old).count == 2 }
    }

    static func contextPatchState() async -> ContextPatchState {
        guard let file = await apiServerFile(),
              let src = try? String(contentsOf: file, encoding: .utf8) else { return .unavailable }
        let contextDone = src.contains("\"context_tokens\"")
        let windowDone = src.contains("\"context_window\"")
        let steerDone = src.contains(steerMarker)
        if (contextDone || !src.contains(contextPatchAnchor)),
           (windowDone || !contextDone),  // window rides on the context line
           (steerDone || !steerApplicable(to: src)) {
            // Nothing more we can do here. "Ours is in place" reads as
            // patched; a fully foreign layout as unavailable.
            return (contextDone || steerDone) ? .patched : .unavailable
        }
        return .patchable
    }

    /// Edits api_server.py in place (backup lands next to it as .bak):
    /// `usage.context_tokens` + the /steer route, each skipped when already
    /// present or (steer on pre-0.20) not applicable. One write, after all
    /// edits — a half-patched file can never hit disk. Returns whether
    /// anything changed; the caller owns the restart.
    @discardableResult
    static func applyContextPatchFile() async throws -> Bool {
        guard let file = await apiServerFile(),
              let src = try? String(contentsOf: file, encoding: .utf8) else {
            throw SetupError.patchFailed("api_server.py not found")
        }
        var work = src
        var contextSites = 0
        if !work.contains("\"context_tokens\"") {
            var out: [String] = []
            for line in work.components(separatedBy: "\n") {
                out.append(line)
                if line.trimmingCharacters(in: .whitespaces) == contextPatchAnchor {
                    let indent = line.prefix { $0 == " " || $0 == "\t" }
                    out.append(indent + contextPatchLine)
                    contextSites += 1
                }
            }
            if contextSites > 0 { work = out.joined(separator: "\n") }
        }
        // context_window rides on the context_tokens line — this same pass
        // upgrades a gateway that carried only the older one-line patch.
        var windowSites = 0
        if work.contains("\"context_tokens\""), !work.contains("\"context_window\"") {
            var out: [String] = []
            for line in work.components(separatedBy: "\n") {
                out.append(line)
                if line.trimmingCharacters(in: .whitespaces) == contextPatchLine {
                    let indent = line.prefix { $0 == " " || $0 == "\t" }
                    out.append(indent + contextWindowLine)
                    windowSites += 1
                }
            }
            if windowSites > 0 { work = out.joined(separator: "\n") }
        }
        var steered = false
        if !work.contains(steerMarker), steerApplicable(to: work) {
            for edit in steerEdits {
                work = work.replacingOccurrences(of: edit.old, with: edit.new)
            }
            steered = true
        }
        guard work != src else {
            // Nothing applied. Distinguish "already done" (fine, no-op)
            // from "nothing matched at all" (foreign layout — surface it).
            if src.contains("\"context_tokens\"") || src.contains(steerMarker) { return false }
            throw SetupError.patchFailed("anchor not found")
        }
        try await syntaxCheck(work)
        do {
            try src.write(to: URL(fileURLWithPath: file.path + ".bak"),
                          atomically: true, encoding: .utf8)
            try work.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            throw SetupError.patchFailed(error.localizedDescription)
        }
        Diagnostics.log("hermes", "patch.gateway applied context=\(contextSites) window=\(windowSites) steer=\(steered) file=\(file.path)")
        return true
    }

    /// `ast.parse` gate before the patched source may replace the original —
    /// the same guard the remote paste-block runs. Skipped silently when no
    /// python3 is around (the edits are anchored and deterministic anyway).
    private static func syntaxCheck(_ source: String) async throws {
        let python = ["/usr/bin/python3", "/opt/homebrew/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let python else { return }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cuate-hermes-patch-check.py")
        do { try source.write(to: temp, atomically: true, encoding: .utf8) } catch { return }
        defer { try? FileManager.default.removeItem(at: temp) }
        let result = await run(python, ["-c", "import ast,sys; ast.parse(open(sys.argv[1]).read())", temp.path], timeout: 20)
        guard result.completed else {
            throw SetupError.patchFailed("syntax check failed: " + result.tail)
        }
    }

    /// Settings-button entry point: patch + restart + wait for health.
    static func applyContextPatchAndRestart() async throws {
        let changed = try await applyContextPatchFile()
        guard changed, let cli = cliPath() else { return }
        let restart = await run(cli, ["gateway", "restart"], timeout: 90)
        Diagnostics.log("hermes", "patch.context restart ok=\(restart.completed)")
        let port = Int(readEnv()["API_SERVER_PORT"] ?? "") ?? 8642
        _ = await waitForHealth(port: port, seconds: 20)
    }

    /// Brings the local gateway up and returns the (port, key) to connect
    /// with. Steps: ensure the three API_SERVER_* lines in `.env` (existing
    /// values win — only missing ones are appended, except an explicit
    /// `API_SERVER_ENABLED=false`, which the user's click overrides), then
    /// `hermes gateway install`, attribute the service to this app (Login
    /// Items would otherwise show it as "python"), re-enable it in case the
    /// user flipped its toggle off, and restart until /health answers.
    /// `progress` receives a localized line per step for the UI.
    static func autoSetup(progress: @escaping @Sendable (String) -> Void) async throws -> (port: Int, key: String) {
        guard let cli = cliPath() else { throw SetupError.cliNotFound }

        progress(HL("hermes.auto.step.env"))
        let env = readEnv()
        var lines: [String] = []
        var envChanged = false

        if env["API_SERVER_ENABLED"]?.lowercased() != "true" {
            try rewriteOrAppend(key: "API_SERVER_ENABLED", value: "true")
            envChanged = true
        }
        let port = Int(env["API_SERVER_PORT"] ?? "") ?? 8642
        if env["API_SERVER_PORT"] == nil {
            lines.append("API_SERVER_PORT=\(port)")
        }
        var key = env["API_SERVER_KEY"] ?? ""
        if key.isEmpty {
            key = "cuate-" + randomHex(24)
            lines.append("API_SERVER_KEY=\(key)")
        }
        if !lines.isEmpty {
            try append(lines: lines)
            envChanged = true
        }

        Diagnostics.log("hermes", "auto.setup envChanged=\(envChanged) port=\(port)")

        // Context-metric patch, before the service (re)starts below — the
        // fresh gateway then serves `usage.context_tokens` from the first
        // turn. Best-effort: a refusal (unknown layout) must not block the
        // setup, the client's fallback covers it.
        progress(HL("hermes.auto.step.patch"))
        do {
            try await applyContextPatchFile()
        } catch {
            Diagnostics.log("hermes", "auto.setup patch skipped: \(error.localizedDescription)")
        }

        progress(HL("hermes.auto.step.install"))
        let install = await run(cli, ["gateway", "install"], timeout: 90)
        guard install.completed else {
            throw SetupError.installFailed(install.tail)
        }

        progress(HL("hermes.auto.step.reload"))
        await attributeAndReloadService()

        progress(HL("hermes.auto.step.health"))
        if await waitForHealth(port: port, seconds: 12) { return (port, key) }

        // Installed-but-dead service, or a live one that predates our env
        // changes — re-enable (covers the System Settings toggle switched
        // off) and restart, then give it one more wait.
        progress(HL("hermes.auto.step.reload"))
        _ = await run("/bin/launchctl", ["enable", "gui/\(getuid())/\(launchdLabel)"], timeout: 10)
        let restart = await run(cli, ["gateway", "restart"], timeout: 90)
        Diagnostics.log("hermes", "auto.setup restart ok=\(restart.completed)")
        progress(HL("hermes.auto.step.health"))
        if await waitForHealth(port: port, seconds: 20) { return (port, key) }

        throw SetupError.gatewayNeverCameUp(restart.completed ? install.tail : restart.tail)
    }

    // MARK: - Login Items attribution

    private static let launchdLabel = "ai.hermes.gateway"
    private static var launchdPlist: URL {
        home.appendingPathComponent("Library/LaunchAgents/\(launchdLabel).plist")
    }

    /// Bundle id of the label-carrier bundle (`ensureHelperBundle`).
    private static let helperBundleID = "com.getcuate.hermes-gateway"

    /// Executable inside the helper bundle that launchd actually runs. The
    /// wrapper just `exec "$@"`s the original command — its only purpose is
    /// to BE inside a named bundle: Login Items derives the display name
    /// from the bundle containing the job's executable, and ignores
    /// `AssociatedBundleIdentifiers` for binaries at bare paths (which is
    /// why the entry used to read "python").
    static var helperExecutable: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Cuate/Hermes Gateway (Cuate).app/Contents/MacOS/hermes-gateway")
    }

    /// Creates (idempotently) a minimal app bundle whose only job is to give
    /// the launchd service a human name: System Settings shows the display
    /// name of the bundle a login item's executable lives in, so the toggle
    /// reads "Hermes Gateway (Cuate)" instead of "python". Lives in
    /// Application Support, registered with LaunchServices explicitly.
    private static func ensureHelperBundle() -> Bool {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return false }
        let app = support.appendingPathComponent("Cuate/Hermes Gateway (Cuate).app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        let infoPlist = app.appendingPathComponent("Contents/Info.plist")
        let executable = macOS.appendingPathComponent("hermes-gateway")

        // The wrapper is version-stamped by content: rewriting it on every
        // run keeps old no-op stubs from earlier builds from lingering.
        let wrapper = "#!/bin/sh\n# Runs the Hermes gateway for Cuate (launchd passes the real command).\nexec \"$@\"\n"
        if (try? String(contentsOf: executable, encoding: .utf8)) != wrapper {
            let info: [String: Any] = [
                "CFBundleIdentifier": helperBundleID,
                "CFBundleName": "Hermes Gateway (Cuate)",
                "CFBundleDisplayName": "Hermes Gateway (Cuate)",
                "CFBundleExecutable": "hermes-gateway",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0",
                "LSUIElement": true
            ]
            guard (try? fm.createDirectory(at: macOS, withIntermediateDirectories: true)) != nil,
                  let data = try? PropertyListSerialization.data(
                      fromPropertyList: info, format: .xml, options: 0),
                  (try? data.write(to: infoPlist)) != nil,
                  (try? wrapper.write(to: executable, atomically: true, encoding: .utf8)) != nil,
                  (try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)) != nil
            else { return false }
        }

        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsregister)
        process.arguments = ["-f", app.path]
        try? process.run()
        process.waitUntilExit()
        return true
    }

    /// System Settings → Login Items names a raw launchd job after its
    /// executable — for Hermes' venv that reads "python, Item from
    /// unidentified developer". `AssociatedBundleIdentifiers` attributes the
    /// job to the named stub bundle instead, so the user sees "Hermes
    /// Gateway (Cuate)" on the toggle. The job is then re-registered (enable
    /// covers a previously flipped-off toggle; bootout+bootstrap makes
    /// launchd re-read the plist).
    private static func attributeAndReloadService() async {
        guard let data = try? Data(contentsOf: launchdPlist),
              var plist = (try? PropertyListSerialization.propertyList(
                  from: data, format: nil)) as? [String: Any]
        else { return }

        let helperReady = ensureHelperBundle()
        let bundleID = helperReady
            ? helperBundleID
            : (Bundle.main.bundleIdentifier ?? "com.getcuate.Cuate")
        var mutated = false

        // Route the job through the wrapper INSIDE the named bundle: Login
        // Items derives the entry's name from the bundle containing the
        // executable (a bare venv python shows as "python"), and only
        // renames the existing ai.hermes.gateway record — nothing to delete.
        if helperReady, let wrapper = helperExecutable,
           var args = plist["ProgramArguments"] as? [String],
           args.first != wrapper.path {
            args.removeAll { $0 == wrapper.path } // stale positions, if any
            plist["ProgramArguments"] = [wrapper.path] + args
            mutated = true
        }
        let existing = plist["AssociatedBundleIdentifiers"] as? [String] ?? []
        if existing != [bundleID] {
            plist["AssociatedBundleIdentifiers"] = [bundleID]
            mutated = true
        }
        if mutated {
            guard let out = try? PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0) else { return }
            do { try out.write(to: launchdPlist) } catch { return }
        }

        let domain = "gui/\(getuid())"
        if mutated {
            _ = await run("/bin/launchctl", ["bootout", "\(domain)/\(launchdLabel)"], timeout: 30)
        }
        _ = await run("/bin/launchctl", ["enable", "\(domain)/\(launchdLabel)"], timeout: 10)
        let bootstrap = await run(
            "/bin/launchctl", ["bootstrap", domain, launchdPlist.path], timeout: 30)
        Diagnostics.log("hermes", "auto.attribute mutated=\(mutated) bootstrap=\(bootstrap.completed)")
    }

    // MARK: - .env editing (surgical: never touches unrelated lines)

    private static func readEnv() -> [String: String] {
        guard let text = try? String(contentsOf: envFile, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "="), !line.hasPrefix("#") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            result[key] = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    private static func append(lines: [String]) throws {
        do {
            var text = (try? String(contentsOf: envFile, encoding: .utf8)) ?? ""
            if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
            text += lines.joined(separator: "\n") + "\n"
            try FileManager.default.createDirectory(
                at: envFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: envFile, atomically: true, encoding: .utf8)
        } catch {
            throw SetupError.envNotWritable(error.localizedDescription)
        }
    }

    private static func rewriteOrAppend(key: String, value: String) throws {
        do {
            var text = (try? String(contentsOf: envFile, encoding: .utf8)) ?? ""
            var replaced = false
            var out: [String] = []
            for line in text.components(separatedBy: "\n") {
                if line.hasPrefix("\(key)=") {
                    out.append("\(key)=\(value)")
                    replaced = true
                } else {
                    out.append(line)
                }
            }
            text = out.joined(separator: "\n")
            if !replaced {
                if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
                text += "\(key)=\(value)\n"
            }
            try text.write(to: envFile, atomically: true, encoding: .utf8)
        } catch {
            throw SetupError.envNotWritable(error.localizedDescription)
        }
    }

    private static func randomHex(_ bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    // MARK: - Process + health

    private struct RunResult {
        let completed: Bool
        let tail: String
    }

    /// Runs the CLI headless with output captured; `completed` is exit 0.
    /// `tail` carries the last output lines for error surfaces.
    private static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval) async -> RunResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = args
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: RunResult(completed: false, tail: error.localizedDescription))
                    return
                }
                let deadline = DispatchTime.now() + timeout
                let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: deadline, execute: watchdog)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                let output = String(data: data, encoding: .utf8) ?? ""
                let tail = output.split(separator: "\n").suffix(3).joined(separator: " · ")
                Diagnostics.log("hermes", "auto.cli \(args.joined(separator: " ")) exit=\(process.terminationStatus)")
                continuation.resume(returning: RunResult(
                    completed: process.terminationStatus == 0, tail: tail))
            }
        }
    }

    private static func waitForHealth(port: Int, seconds: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        for _ in 0..<(seconds * 2) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 1.5
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }
}
