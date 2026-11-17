import Foundation
import os

/// Counters the hang watchdog turns into energy breadcrumbs: how many
/// animation gates see their window on screen, whether the mic unit is open
/// and whether it is recording. State only — never audio, text or keys.
///
/// Field case it exists for (2026-11-17): every window hidden, the mic open
/// for hours after a warm window, the process at 230 % CPU — and nothing in
/// the log said so until someone sampled it by hand.
nonisolated enum PowerTelemetry {
    private struct State {
        var visibleMotionGates = 0
        var micOpenSince: TimeInterval?
        var recording = false
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    struct Snapshot {
        let visibleMotionGates: Int
        /// Seconds the mic unit has been open while NOT recording; nil = closed
        /// or recording.
        let micIdleOpenFor: TimeInterval?
        let recording: Bool
    }

    /// A motion gate's window became visible (+1) or hidden (−1).
    static func motionGateVisibilityChanged(visible: Bool) {
        state.withLock { $0.visibleMotionGates = max(0, $0.visibleMotionGates + (visible ? 1 : -1)) }
    }

    static func micUnit(open: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        state.withLock { $0.micOpenSince = open ? ($0.micOpenSince ?? now) : nil }
    }

    /// Recording starts/stops; an open unit's idle clock restarts when a
    /// recording ends, so the warm window is measured from there.
    static func micRecording(_ on: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        state.withLock {
            if $0.recording, !on, $0.micOpenSince != nil { $0.micOpenSince = now }
            $0.recording = on
        }
    }

    static func snapshot() -> Snapshot {
        let now = ProcessInfo.processInfo.systemUptime
        return state.withLock { s in
            Snapshot(visibleMotionGates: s.visibleMotionGates,
                     micIdleOpenFor: s.recording ? nil : s.micOpenSince.map { now - $0 },
                     recording: s.recording)
        }
    }
}
