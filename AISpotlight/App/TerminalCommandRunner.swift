import AppKit
import ApplicationServices
import Carbon

/// What the ▶ button on a shell code block does (Settings → General).
enum TerminalRunMode: String, CaseIterable, Identifiable {
    /// No ▶ button at all.
    case off
    /// Open Terminal with the command typed in — the user reads it and
    /// presses Enter themselves. Safe default: nothing runs without a human.
    case insert
    /// Open Terminal and execute immediately (asks the system Automation
    /// permission on first use).
    case autorun

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return L("terminal.mode.off")
        case .insert: return L("terminal.mode.insert")
        case .autorun: return L("terminal.mode.autorun")
        }
    }
}

/// Sends a model-produced shell command to Terminal.app — the "hands" behind
/// the ▶ button on code blocks. Two delivery modes (see `TerminalRunMode`):
///
/// - insert: a new Terminal window is opened via `NSWorkspace` (no Apple
///   Events involved) and the command is pasted with a synthesized ⌘V — the
///   same Accessibility-backed technique as `SelectionGrabber`'s ⌘C. The
///   command sits in the prompt awaiting the user's Enter.
/// - autorun: classic `do script` Apple Event through osascript; macOS shows
///   its standard "wants to control Terminal" consent dialog once, after
///   which the user manages it in Settings → Privacy → Automation.
@MainActor
enum TerminalCommandRunner {

    private static let terminalBundleID = "com.apple.Terminal"

    /// Fence languages that mark a block as an executable shell command.
    /// Deliberately conservative: untagged blocks and other languages never
    /// grow a ▶ button.
    nonisolated static func isShellLanguage(_ language: String) -> Bool {
        ["bash", "sh", "zsh", "shell", "console", "terminal"].contains(language)
    }

    /// Strips console-transcript prompts: when every non-empty line starts
    /// with "$ " (or "% "), the markers are decoration, not content.
    nonisolated static func sanitize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        for marker in ["$ ", "% "] {
            if !nonEmpty.isEmpty, nonEmpty.allSatisfy({ $0.hasPrefix(marker) }) {
                return lines.map { $0.hasPrefix(marker) ? String($0.dropFirst(marker.count)) : $0 }
                    .joined(separator: "\n")
            }
        }
        return trimmed
    }

    static func run(_ rawCommand: String) {
        let command = sanitize(rawCommand)
        guard !command.isEmpty else { return }
        switch AppSettings.shared.terminalRunMode {
        case .off:
            return
        case .insert:
            Task { await insert(command) }
        case .autorun:
            autorun(command)
        }
    }

    // MARK: - Insert mode (paste, wait for the user's Enter)

    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Consecutive ▶ clicks land in the window the first click opened, so a
    /// multi-step flow (run → stop → check) reads like one session. Reset
    /// implicitly when Terminal quits or its last window closes.
    private static var insertSessionStarted = false

    private static func insert(_ command: String) async {
        let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: terminalBundleID).first
        if insertSessionStarted, let running, terminalHasWindows(running) {
            // Session window exists — just bring Terminal forward and paste
            // into whatever is active there (a shell prompt or a REPL).
            running.activate(options: [])
        } else {
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminalBundleID) else {
                Diagnostics.log("terminal", "run.insert terminal-app-not-found")
                return
            }
            // Opening a folder "with Terminal" spawns a fresh window cd'd
            // there — no Apple Events, so no Automation permission needed in
            // this mode.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            do {
                try await NSWorkspace.shared.open(
                    [FileManager.default.homeDirectoryForCurrentUser],
                    withApplicationAt: appURL,
                    configuration: configuration
                )
            } catch {
                Diagnostics.log("terminal", "run.insert open-failed \(error.localizedDescription)")
                return
            }
        }

        // Wait until Terminal is actually frontmost — keystrokes must not
        // land in another app.
        for _ in 0..<30 {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == terminalBundleID { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == terminalBundleID else {
            Diagnostics.log("terminal", "run.insert terminal-never-frontmost")
            return
        }
        // A fresh window needs a beat before its shell prompt accepts input.
        try? await Task.sleep(nanoseconds: 400_000_000)
        insertSessionStarted = true

        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        pasteboard.declareTypes([.string, transientType], owner: nil)
        pasteboard.setString(command, forType: .string)

        guard AXIsProcessTrusted() else {
            // No Accessibility → can't synthesize ⌘V. Degrade gracefully:
            // Terminal is open and the command is on the clipboard for a
            // manual paste (clipboard deliberately not restored).
            Diagnostics.log("terminal", "run.insert no-accessibility, left-on-clipboard")
            return
        }
        postKey(kVK_ANSI_V, flags: .maskCommand)
        try? await Task.sleep(nanoseconds: 250_000_000)
        if let saved {
            pasteboard.declareTypes([.string, transientType], owner: nil)
            pasteboard.setString(saved, forType: .string)
        }
        Diagnostics.log("terminal", "run.insert ok chars=\(command.count)")
    }

    /// Accessibility-based window check (the permission is already granted
    /// for the paste itself): detects "Terminal runs but the user closed our
    /// window", where a plain activate would swallow the ⌘V.
    private static func terminalHasWindows(_ app: NSRunningApplication) -> Bool {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }
        return !windows.isEmpty
    }

    private static func postKey(_ keyCode: Int, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - Autorun mode (do script)

    /// Terminal window id of the autorun session: later commands run in the
    /// window the first ▶ created (sequential flows stay in one window). A
    /// command typed while something runs there (a REPL, a server) goes to
    /// that process's stdin — which is what a follow-up like `/bye` needs.
    private static var autorunWindowID: Int?

    private static func autorun(_ command: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var reuse = ""
        if let id = autorunWindowID {
            reuse = """
            if exists window id \(id) then
                do script "\(escaped)" in window id \(id)
                set index of window id \(id) to 1
                return \(id)
            end if
            """ + "\n"
        }
        let script = """
        tell application "Terminal"
            activate
            \(reuse)do script "\(escaped)"
            return id of front window
        end tell
        """
        // osascript instead of NSAppleScript: the first-use Automation consent
        // dialog blocks the caller, and NSAppleScript is main-thread-bound —
        // a child process keeps the UI alive while the user decides.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { proc in
            let status = proc.terminationStatus
            if status != 0 {
                let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                Diagnostics.log("terminal", "run.auto failed status=\(status) \(message)")
                return
            }
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let windowID = String(data: data, encoding: .utf8)
                .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            Task { @MainActor in
                autorunWindowID = windowID
                Diagnostics.log("terminal", "run.auto ok window=\(windowID.map(String.init) ?? "?")")
            }
        }
        do {
            try process.run()
        } catch {
            Diagnostics.log("terminal", "run.auto spawn-failed \(error.localizedDescription)")
        }
    }
}
