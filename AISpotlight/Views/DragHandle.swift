import SwiftUI
import AppKit

struct DragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = DragRegionView(frame: .zero)
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.clear.cgColor
        return v
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        // No dynamic updates needed
    }
}
