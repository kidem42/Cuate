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

        var errorDescription: String? {
            switch self {
            case .cliNotFound: return HL("hermes.auto.err.cli")
            case .envNotWritable(let detail): return HL("hermes.auto.err.env") + " " + detail
            case .installFailed(let detail): return HL("hermes.auto.err.install") + " " + detail
            case .gatewayNeverCameUp(let detail): return HL("hermes.auto.err.timeout") + (detail.isEmpty ? "" : " " + detail)
            }
        }
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
