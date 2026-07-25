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

    final class Coordinator {
        var onNearBottomChange: (Bool) -> Void = { _ in }
        var onContentFitsChange: (Bool) -> Void = { _ in }
        var onViewportWidthChange: (CGFloat) -> Void = { _ in }
        var onNeedOlder: () -> Void = {}
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
        return engine
    }

    func updateNSView(_ engine: TranscriptEngineView, context: Context) {
        controller.engine = engine
        let coordinator = context.coordinator
        coordinator.onNearBottomChange = onNearBottomChange
        coordinator.onContentFitsChange = onContentFitsChange
        coordinator.onViewportWidthChange = onViewportWidthChange
        coordinator.onNeedOlder = onNeedOlder
        engine.apply(items: items, resetToken: resetToken)
    }
}
