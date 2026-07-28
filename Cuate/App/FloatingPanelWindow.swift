import AppKit

final class FloatingPanelWindow: NSWindow {
    /// Which panel this is. The chat panel and the World Time panel are BOTH
    /// this class, so anything that looks one of them up by type alone gets
    /// whichever happens to sit first in `NSApp.windows` — that is how the
    /// attach dialog could have docked itself onto World Time, and how Esc
    /// could have found the wrong panel to close.
    enum Role {
        case chat
        case worldTime
        /// The agent management column — a CHILD window docked to the chat
        /// panel's left edge (its own surface; the chat panel never resizes).
        case agentSidebar
    }

    var role: Role = .chat

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// The chat panel, whatever else is on screen.
    static var chatPanel: FloatingPanelWindow? {
        NSApp.windows.lazy.compactMap { $0 as? FloatingPanelWindow }.first { $0.role == .chat }
    }
}

// Transparent overlay view that allows dragging the window when clicked and dragged.
final class DragRegionView: NSView {
    override func mouseDown(with event: NSEvent) {
        self.window?.performDrag(with: event)
    }
}
