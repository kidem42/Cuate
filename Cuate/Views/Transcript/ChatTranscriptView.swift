import SwiftUI
import AppKit

/// SwiftUI bridge for the AppKit transcript engine. Deliberately thin: it
/// forwards the row set to `TranscriptEngineView.apply` (which does point
/// updates) and relays the engine's geometry reports back to SwiftUI state
/// on the next runloop tick (mutating state from inside `updateNSView`
/// would re-enter the SwiftUI update).
struct ChatTranscriptView: NSViewRepresentable {
    let items: [TranscriptItem]
    /// Identity of the conversation on screen. A change replaces the whole
    /// transcript and re-pins it to the newest message.
    let resetToken: String
    let controller: TranscriptController
    var onNearBottomChange: (Bool) -> Void = { _ in }
    var onContentFitsChange: (Bool) -> Void = { _ in }
    var onViewportWidthChange: (CGFloat) -> Void = { _ in }
    var onNeedOlder: () -> Void = {}
    var onNeedNewer: () -> Void = {}

    final class Coordinator {
        var onNearBottomChange: (Bool) -> Void = { _ in }
        var onContentFitsChange: (Bool) -> Void = { _ in }
        var onViewportWidthChange: (CGFloat) -> Void = { _ in }
        var onNeedOlder: () -> Void = {}
        var onNeedNewer: () -> Void = {}
        // Latest row set waiting for the deferred apply (see updateNSView).
        var pendingItems: [TranscriptItem] = []
        var pendingResetToken = ""
        var applyScheduled = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TranscriptEngineView {
        let engine = TranscriptEngineView()
        controller.engine = engine
        // The engine holds ONE set of closures for its whole life; they
        // read the freshest SwiftUI closures through the coordinator, so
        // updateNSView only has to refresh the coordinator.
        let coordinator = context.coordinator
        engine.onNearBottomChange = { value in
            DispatchQueue.main.async { coordinator.onNearBottomChange(value) }
        }
        engine.onContentFitsChange = { value in
            DispatchQueue.main.async { coordinator.onContentFitsChange(value) }
        }
        engine.onViewportWidthChange = { value in
            DispatchQueue.main.async { coordinator.onViewportWidthChange(value) }
        }
        engine.onNeedOlder = {
            DispatchQueue.main.async { coordinator.onNeedOlder() }
        }
        engine.onNeedNewer = {
            DispatchQueue.main.async { coordinator.onNeedNewer() }
        }
        return engine
    }

    /// The transcript greedily fills whatever the layout offers — so say
    /// exactly that, cheaply. Without this override SwiftUI measures the
    /// engine through AppKit (`measureMin:max:ideal:`), which runs an Auto
    /// Layout solve over EVERY hosted row on EVERY graph transaction; with a
    /// long window that solve reached ~100% of a core, and worse, its result
    /// could oscillate and feed the next transaction — a self-sustaining
    /// layout loop that burned CPU for hours in a HIDDEN panel
    /// (hang-20260803-191709, Energy Impact 5300+ while idle).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranscriptEngineView,
                      context: Context) -> CGSize? {
        // Finite proposals are taken verbatim (min probe 0 → we shrink,
        // concrete → we fill). Unspecified/infinite axes get a sane floor —
        // the panel always proposes concrete sizes, this is just a backstop.
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 480
        let height = proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 320
        return CGSize(width: width, height: height)
    }

    func updateNSView(_ engine: TranscriptEngineView, context: Context) {
        controller.engine = engine
        let coordinator = context.coordinator
        coordinator.onNearBottomChange = onNearBottomChange
        coordinator.onContentFitsChange = onContentFitsChange
        coordinator.onViewportWidthChange = onViewportWidthChange
        coordinator.onNeedOlder = onNeedOlder
        coordinator.onNeedNewer = onNeedNewer
        // Apply OUTSIDE the SwiftUI update transaction. `apply` builds
        // hosting views and forces their layout, which evaluates row bodies
        // right here inside updateNSView — and anything they touch that
        // publishes fires SwiftUI's "Publishing changes from within view
        // updates is not allowed" fault (148× in one session's unified log).
        // On macOS 26 that undefined behavior escalated to the window's
        // whole update cycle wedging: frozen composer layers, dead controls
        // (e2e 2026-07-28). Deferring one runloop tick keeps every apply in
        // its own clean transaction; back-to-back updates coalesce to the
        // newest row set.
        coordinator.pendingItems = items
        coordinator.pendingResetToken = resetToken
        guard !coordinator.applyScheduled else { return }
        coordinator.applyScheduled = true
        DispatchQueue.main.async { [weak engine] in
            coordinator.applyScheduled = false
            guard let engine else { return }
            engine.apply(items: coordinator.pendingItems,
                         resetToken: coordinator.pendingResetToken)
        }
    }
}
