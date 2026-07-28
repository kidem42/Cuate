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

    /// Click-to-revive. A visible floating panel of an INACTIVE accessory
    /// app is a zombie: cooperative activation (macOS 14+) can silently
    /// deny the summon-time activate (log: `panel.shown active=false
    /// key=false`), and then every click dies in the "first mouse" attempt
    /// — the window never becomes key and no control ever fires, while
    /// rendering and streams continue (e2e 2026-07-28: the "frozen" panel).
    /// Any click while the app is inactive forces the legacy activation
    /// path and takes key status directly.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            // Breadcrumb for the frozen-panel class of bugs: proves whether
            // clicks reach the app at all, and in what activation state.
            Diagnostics.log("ui", "click role=\(role) key=\(isKeyWindow) active=\(NSApp.isActive)")
            if !NSApp.isActive {
                NSRunningApplication.current.activate()
                if !NSApp.isActive {
                    NSApp.activate(ignoringOtherApps: true)
                }
                makeKeyAndOrderFront(nil)
                Diagnostics.log("ui", "click.revive key=\(isKeyWindow) active=\(NSApp.isActive)")
            }
        }
        super.sendEvent(event)
    }

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
