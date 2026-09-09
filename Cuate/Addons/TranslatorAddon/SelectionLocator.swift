import AppKit
import ApplicationServices

/// Where the selection is on screen, so the bubble can sit at its edge
/// instead of at the pointer, which may be far from the text.
///
/// Probed live on 2026-09-09 (Safari, Chrome, TextEdit): the system-wide
/// focused element is not always answered, the frontmost app's own element
/// is; web content (WebKit and Chromium alike) exposes the selection only as
/// a text-marker range whose bounds come from the parameterized
/// `AXBoundsForTextMarkerRange` (the plain `AXBoundsForRange` returns a zero
/// rectangle there), while native text views answer the plain
/// `AXSelectedTextRange` + `AXBoundsForRange`; and Safari may report no
/// focused element at all, in which case the web area is found under the
/// focused window. Rectangles are AppKit screen coordinates (origin at the
/// bottom-left of the primary display). Everything else falls back to the
/// mouse, which is where the hand just finished selecting.
@MainActor
enum SelectionLocator {
    struct Location {
        let rect: CGRect
        let viaAccessibility: Bool
        /// The screen holding the selection (the mouse's screen otherwise).
        let screen: NSScreen
    }

    static func locate() -> Location {
        if let rect = selectionBounds(),
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) {
            return Location(rect: rect, viaAccessibility: true, screen: screen)
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens[0]
        return Location(rect: CGRect(x: mouse.x, y: mouse.y, width: 1, height: 1), viaAccessibility: false, screen: screen)
    }

    // MARK: - The selection's rectangle

    private static let markerRangeAttribute = "AXSelectedTextMarkerRange"
    private static let boundsForMarkerRange = "AXBoundsForTextMarkerRange"
    private static let stringForMarkerRange = "AXStringForTextMarkerRange"

    /// The union rectangle of the selected text, or nil when no element in
    /// reach exposes one.
    static func selectionBounds() -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        // Bound the synchronous cross-process calls: a hung frontmost app
        // must not stall the hotkey.
        AXUIElementSetMessagingTimeout(app, 0.25)

        var candidates: [AXUIElement] = []
        if let focused = focusedElement(app: app) {
            candidates.append(focused)
            // The selection may live on an ancestor (a node inside a web
            // area, which sits many levels below the window in Chromium):
            // walk all the way up to the window.
            var element = focused
            for _ in 0..<40 {
                if attribute(element, kAXRoleAttribute) as? String == kAXWindowRole { break }
                guard let parent = attribute(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                element = parent as! AXUIElement
                candidates.append(element)
            }
        }
        // Safari with nothing focused reports no element at all; a focused
        // element that is not under the web area (a toolbar field) says
        // nothing about the page. Either way the web area under the focused
        // window still holds the page's selection.
        if !candidates.contains(where: { attribute($0, kAXRoleAttribute) as? String == "AXWebArea" }),
           let window = attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID(),
           let web = webArea(under: window as! AXUIElement) {
            candidates.append(web)
        }

        for element in candidates {
            if let rect = markerBounds(of: element) ?? rangeBounds(of: element) {
                return flipped(rect)
            }
        }
        // An element that holds selected text but answers no bounds for it
        // (custom text views): its own frame is still next to the text.
        for element in candidates {
            if let rect = frameOfElementWithSelection(element) {
                return flipped(rect)
            }
        }
        let roles = candidates.map { attribute($0, kAXRoleAttribute) as? String ?? "?" }.joined(separator: ">")
        Diagnostics.log("translator", "bounds.none app=\(front.bundleIdentifier ?? "?") roles=\(roles)")
        return nil
    }

    /// The frame of an element that exposes a non-empty `AXSelectedText`
    /// (native text views answer it even when the range bounds fail);
    /// skipped for elements the size of a whole window, which would say
    /// nothing about where the text is.
    private static func frameOfElementWithSelection(_ element: AXUIElement) -> CGRect? {
        guard let selected = attribute(element, kAXSelectedTextAttribute) as? String,
              !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let positionValue = attribute(element, kAXPositionAttribute), CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue = attribute(element, kAXSizeAttribute), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        let rect = CGRect(origin: position, size: size)
        guard isPlausible(rect), rect.width < 1400 || rect.height < 700 else { return nil }
        Diagnostics.log("translator", "bounds via=frame role=\(attribute(element, kAXRoleAttribute) as? String ?? "?") h=\(Int(rect.height))")
        return rect
    }

    /// The system-wide focused element, then the app's own answer.
    private static func focusedElement(app: AXUIElement) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        if let focused = attribute(systemWide, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
            return (focused as! AXUIElement)
        }
        if let focused = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
            return (focused as! AXUIElement)
        }
        return nil
    }

    /// Web content: the selection as a text-marker range and its bounds.
    /// A collapsed selection has no text and is not a selection.
    private static func markerBounds(of element: AXUIElement) -> CGRect? {
        guard let range = attribute(element, markerRangeAttribute) else { return nil }
        if let text = parameterized(element, stringForMarkerRange, range) as? String,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        guard let rect = rect(parameterized(element, boundsForMarkerRange, range)), isPlausible(rect) else { return nil }
        Diagnostics.log("translator", "bounds via=marker h=\(Int(rect.height))")
        return rect
    }

    /// Native text views: the selected character range and its bounds.
    private static func rangeBounds(of element: AXUIElement) -> CGRect? {
        guard let rangeValue = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.length > 0 else { return nil }
        guard let rect = rect(parameterized(element, kAXBoundsForRangeParameterizedAttribute, rangeValue)), isPlausible(rect) else { return nil }
        Diagnostics.log("translator", "bounds via=range h=\(Int(rect.height))")
        return rect
    }

    /// Breadth-first under the window, bounded: Safari's web area sits a few
    /// levels down (found in ~10 ms live).
    private static func webArea(under root: AXUIElement) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if attribute(element, kAXRoleAttribute) as? String == "AXWebArea" { return element }
            guard depth < 10, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for child in children { queue.append((child, depth + 1)) }
        }
        return nil
    }

    // MARK: - Helpers

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func parameterized(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success ? value : nil
    }

    private static func rect(_ value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(value as! AXValue, .cgRect, &rect) ? rect : nil
    }

    /// Zero rectangles are what web areas answer to the wrong question;
    /// absurd ones are not a selection either.
    private static func isPlausible(_ rect: CGRect) -> Bool {
        (rect.width > 0 || rect.height > 0) && rect.width < 20_000 && rect.height < 20_000
    }

    /// AX rectangles have their origin at the top-left of the primary
    /// display; AppKit's is at its bottom-left.
    private static func flipped(_ rect: CGRect) -> CGRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        return CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}
