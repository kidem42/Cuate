import Foundation
import AppKit
import os

/// Local, opt-in diagnostics (Settings → General): a rotating file log, an
/// in-memory breadcrumb ring buffer, and a main-thread hang watchdog
/// (`HangWatchdog`). Everything stays on this Mac until the user explicitly
/// exports it with "Export Logs".
///
/// Logging rules: event names and metadata only (durations, sizes, counts,
/// provider/model ids) — never chat texts, prompts, transcripts or API keys.
///
/// `nonisolated`: the project defaults to MainActor isolation, but diagnostics
/// must be callable from any thread — including while the main thread is hung.
nonisolated enum Diagnostics {

    static let defaultsKey = "diagnosticsEnabled"

    /// Cheap check for hot call sites; `log()` already guards on it.
    static var isEnabled: Bool { DiagnosticsCore.shared.enabled }

    /// Call once at launch, before other subsystems produce events.
    @MainActor
    static func startIfEnabled() {
        if UserDefaults.standard.bool(forKey: defaultsKey) {
            setEnabled(true)
        }
    }

    /// Turns the whole system (file log + watchdog) on or off at runtime.
    @MainActor
    static func setEnabled(_ on: Bool) {
        DiagnosticsCore.shared.setEnabled(on)
    }

    /// Records one event: mirrored to the unified log (Console.app), appended
    /// to the file log, and kept in the breadcrumb buffer that hang reports
    /// and exports embed. No-op while diagnostics are off. Safe from any thread.
    static func log(_ category: String, _ event: String) {
        DiagnosticsCore.shared.log(category: category, event: event)
    }

    /// Directory holding the rotating log and hang reports.
    static var logsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cuate/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func openLogsFolder() {
        NSWorkspace.shared.open(logsDirectory)
    }

    /// Last N breadcrumbs, oldest first (embedded into hang reports/exports).
    static func crumbsSnapshot() -> [String] {
        DiagnosticsCore.shared.crumbsSnapshot()
    }

    /// Non-secret configuration snapshot for reports. Reads UserDefaults
    /// directly so it works from any thread — including while the main
    /// thread (and thus @MainActor `AppSettings`) is hung.
    static func systemSnapshot() -> String {
        let d = UserDefaults.standard
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let models = (d.dictionary(forKey: "selectedModels") as? [String: String]) ?? [:]
        return [
            "app=\(version) (\(build))",
            "macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)",
            "uptime=\(Int(ProcessInfo.processInfo.systemUptime))s",
            "provider=\(d.string(forKey: "chatProvider") ?? "?") model=\(models[d.string(forKey: "chatProvider") ?? ""] ?? "?")",
            "preset=\(d.string(forKey: "activePresetName") ?? "?")",
            "reasoning=\(d.string(forKey: "reasoningMode") ?? "auto") maxTokens=\(d.object(forKey: "maxTokens") as? Int ?? 8192)",
            "webSearch=\(d.object(forKey: "webSearchEnabled") as? Bool ?? true)",
            "dictation=\(d.object(forKey: "dictationEnabled") as? Bool ?? true) chunked=\(d.object(forKey: "dictationChunked") as? Bool ?? true) cleanup=\(d.object(forKey: "dictationCleanup") as? Bool ?? true) stt=\(d.string(forKey: "sttProvider") ?? "mistral")",
            "layoutFix=\(d.bool(forKey: "layoutFix.enabled")) auto=\(d.bool(forKey: "layoutFix.autoEnabled"))",
        ].joined(separator: "\n")
    }

    // MARK: - Export

    /// Zips the logs + a fresh snapshot + recent macOS crash/hang reports for
    /// this app into ~/Downloads and reveals the file in Finder. Blocking —
    /// call off the main thread.
    @discardableResult
    static func exportToDownloads() throws -> URL {
        let fm = FileManager.default
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = df.string(from: Date())

        let staging = fm.temporaryDirectory.appendingPathComponent("Cuate-logs-\(stamp)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // 1. Our own log + hang reports.
        for item in (try? fm.contentsOfDirectory(at: logsDirectory, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.copyItem(at: item, to: staging.appendingPathComponent(item.lastPathComponent))
        }

        // 2. Fresh configuration snapshot + current breadcrumbs.
        let info = systemSnapshot()
            + "\n\n--- Breadcrumbs (oldest first) ---\n"
            + crumbsSnapshot().joined(separator: "\n") + "\n"
        try? info.write(to: staging.appendingPathComponent("system-info.txt"), atomically: true, encoding: .utf8)

        // 3. Recent macOS crash/spin reports mentioning the app (last 14 days) —
        //    covers crashes and system-detected hangs without bundling a crash SDK.
        let diagDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let cutoff = Date().addingTimeInterval(-14 * 24 * 3600)
        for item in (try? fm.contentsOfDirectory(at: diagDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where item.lastPathComponent.localizedCaseInsensitiveContains("cuate") {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified > cutoff {
                try? fm.copyItem(at: item, to: staging.appendingPathComponent(item.lastPathComponent))
            }
        }

        // 4. Zip into ~/Downloads (ditto ships with macOS — no dependencies).
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let zip = downloads.appendingPathComponent("Cuate-logs-\(stamp).zip")
        try? fm.removeItem(at: zip)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", staging.path, zip.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, fm.fileExists(atPath: zip.path) else {
            throw DiagnosticsError.exportFailed
        }

        log("diag", "export written=\(zip.lastPathComponent)")
        NSWorkspace.shared.activateFileViewerSelecting([zip])
        return zip
    }
}

nonisolated enum DiagnosticsError: LocalizedError {
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .exportFailed:
            return "Could not create the log archive in Downloads."
        }
    }
}

// MARK: - Core (file log + breadcrumbs)

/// Owns the log file, its rotation, and the breadcrumb ring buffer.
/// All mutable state is confined to `queue`; `enabled` is behind a lock so
/// `log()` stays cheap on hot paths while diagnostics are off.
nonisolated private final class DiagnosticsCore: @unchecked Sendable {
    static let shared = DiagnosticsCore()

    private let queue = DispatchQueue(label: "com.getcuate.Cuate.diagnostics", qos: .utility)
    private let osLog = Logger(subsystem: "com.getcuate.Cuate", category: "diagnostics")
    private let enabledLock = OSAllocatedUnfairLock(initialState: false)

    // Accessed only on `queue`.
    private var handle: FileHandle?
    private var logSize = 0
    private var crumbs: [String] = []

    // Created/destroyed only from the main thread (AppSettings didSet / launch).
    private var watchdog: HangWatchdog?

    private let crumbCapacity = 300
    private let maxLogBytes = 2 * 1024 * 1024

    /// Formatter used exclusively on `queue` (DateFormatter isn't thread-safe).
    private let timestampFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return df
    }()

    var enabled: Bool { enabledLock.withLock { $0 } }

    @MainActor
    func setEnabled(_ on: Bool) {
        if on {
            let changed = enabledLock.withLock { state -> Bool in
                guard !state else { return false }
                state = true
                return true
            }
            guard changed else { return }
            queue.async { self.openLogFile() }
            log(category: "diag", event: "enabled — file log + hang watchdog on")
            watchdog = HangWatchdog()
            watchdog?.start()
        } else {
            guard enabled else { return }
            log(category: "diag", event: "disabled")
            watchdog?.stop()
            watchdog = nil
            enabledLock.withLock { $0 = false }
            queue.async { self.closeLogFile() }
        }
    }

    func log(category: String, event: String) {
        guard enabled else { return }
        let now = Date()
        osLog.info("[\(category, privacy: .public)] \(event, privacy: .public)")
        queue.async {
            let line = "\(self.timestampFormatter.string(from: now)) [\(category)] \(event)"
            self.append(line)
        }
    }

    func crumbsSnapshot() -> [String] {
        queue.sync { crumbs }
    }

    // MARK: Queue-confined internals

    private var logFileURL: URL {
        Diagnostics.logsDirectory.appendingPathComponent("app.log")
    }

    private func openLogFile() {
        let url = logFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        logSize = (attrs?[.size] as? NSNumber)?.intValue ?? 0
    }

    private func closeLogFile() {
        try? handle?.close()
        handle = nil
    }

    private func append(_ line: String) {
        crumbs.append(line)
        if crumbs.count > crumbCapacity {
            crumbs.removeFirst(crumbs.count - crumbCapacity)
        }
        guard handle != nil, let data = (line + "\n").data(using: .utf8) else { return }
        if logSize + data.count > maxLogBytes {
            rotate() // replaces `handle` with a fresh file
        }
        try? handle?.write(contentsOf: data)
        logSize += data.count
    }

    /// app.log → app.log.1 (previous generation is dropped), fresh app.log.
    private func rotate() {
        closeLogFile()
        let old = logFileURL
        let archived = Diagnostics.logsDirectory.appendingPathComponent("app.log.1")
        try? FileManager.default.removeItem(at: archived)
        try? FileManager.default.moveItem(at: old, to: archived)
        openLogFile()
    }
}
