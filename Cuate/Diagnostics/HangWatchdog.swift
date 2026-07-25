import Foundation

/// Main-thread hang detector. A timer on a background queue sends a ping to
/// the main queue and measures how long it takes to come back; longer than
/// `threshold` means the UI is frozen. On detection it writes a hang report:
/// configuration snapshot + breadcrumbs + all-thread stack traces captured
/// with /usr/bin/sample (works on our own pid — the app is not sandboxed).
/// When the main thread recovers, the hang's total duration is logged too.
///
/// Uses GCD only — Swift Concurrency is useless here since the main actor is
/// exactly what's hung. `nonisolated` opts out of the project's default
/// MainActor isolation for the same reason.
nonisolated final class HangWatchdog: @unchecked Sendable {
    /// Main thread not responding for this long counts as a hang.
    private let threshold: TimeInterval = 2.0
    private let interval: TimeInterval = 0.25
    /// At most one sample-based report per cooldown (and per session cap),
    /// so a struggling machine doesn't fill the disk with reports.
    private let reportCooldown: TimeInterval = 60
    private let maxReportsPerSession = 10

    private let queue = DispatchQueue(label: "com.getcuate.Cuate.watchdog", qos: .userInitiated)

    // Accessed only on `queue`.
    private var timer: DispatchSourceTimer?
    private var pingSentAt: TimeInterval?
    private var hangActive = false
    private var lastReportAt: TimeInterval = -.infinity
    private var reportsWritten = 0

    func start() {
        queue.async {
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.interval, repeating: self.interval)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.pingSentAt = nil
            self.hangActive = false
        }
    }

    /// One ping in flight at a time: a new ping is sent only after the
    /// previous one came back, so the delay is measured from before the hang.
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if let sent = pingSentAt {
            if !hangActive, now - sent > threshold {
                hangActive = true
                reportHang()
            }
        } else {
            pingSentAt = now
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.queue.async {
                    if self.hangActive, let sent = self.pingSentAt {
                        let duration = ProcessInfo.processInfo.systemUptime - sent
                        self.hangActive = false
                        Diagnostics.log("watchdog", String(format: "hang.end duration=%.2fs", duration))
                    }
                    self.pingSentAt = nil
                }
            }
        }
    }

    private func reportHang() {
        Diagnostics.log("watchdog", "hang.detected mainThread>\(threshold)s")
        let now = ProcessInfo.processInfo.systemUptime
        guard reportsWritten < maxReportsPerSession, now - lastReportAt > reportCooldown else { return }
        lastReportAt = now
        reportsWritten += 1

        // Off the watchdog queue so ticks keep running (hang.end still logs)
        // while `sample` spends ~2s collecting stacks.
        DispatchQueue.global(qos: .userInitiated).async {
            Self.writeReport()
        }
    }

    private static func writeReport() {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let url = Diagnostics.logsDirectory.appendingPathComponent("hang-\(df.string(from: Date())).txt")

        var text = "Cuate hang report — \(Date())\n\n"
        text += Diagnostics.systemSnapshot()
        text += "\n\n--- Breadcrumbs (oldest first) ---\n"
        text += Diagnostics.crumbsSnapshot().joined(separator: "\n")
        text += "\n\n--- sample: all-thread stacks over 2s (look at 'Thread <main>') ---\n"
        text += runSample() ?? "(sample failed — stacks unavailable)"
        try? text.write(to: url, atomically: true, encoding: .utf8)
        Diagnostics.log("watchdog", "hang.report file=\(url.lastPathComponent)")
    }

    /// Samples our own process for 2 seconds. Sampling your own pid needs no
    /// special rights for a non-hardened, same-user process.
    private static func runSample() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "2", "-mayDie"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
