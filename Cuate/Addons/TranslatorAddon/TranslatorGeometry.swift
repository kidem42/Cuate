import CoreGraphics

/// Where the translation bubble opens, relative to the selection: pure
/// arithmetic in AppKit screen coordinates (origin bottom-left, y up),
/// compiled standalone by the contract test.
///
/// The bubble behaves like a popover pinned to the selection: above it,
/// left-aligned with its left edge, the tail pointing down at it. With no
/// room above it hangs below the selection; a selection that fills the
/// screen gets it hanging from its first visible line. With no room on the
/// right the bubble is right-aligned with the selection's right edge, and
/// when neither fits it shifts left onto the screen. The bubble's pinned
/// corner never moves while the text grows.
nonisolated struct TranslatorPlacement: Equatable {
    /// The point the bubble's tail points at.
    var anchor: CGPoint
    /// The bubble hangs below the anchor (the tail on its top edge).
    var opensDown: Bool
    /// The bubble's right edge is pinned at the anchor instead of its left.
    var alignRight: Bool
    /// The bubble's caps once the screen's room is known (the whole bubble,
    /// header included).
    var maxWidth: CGFloat
    var maxHeight: CGFloat

    static let widthCap: CGFloat = 400
    static let minWidth: CGFloat = 180
    static let heightCap: CGFloat = 320
    /// Below this much room a side is not worth opening the bubble on.
    static let minHeight: CGFloat = 120
    /// The bubble never takes more than this share of the screen's height.
    static let screenShare: CGFloat = 0.4
    /// The gap between the anchor and the bubble's edge: the tail's length.
    static let tail: CGFloat = 8
    static let edgeMargin: CGFloat = 8
    /// Room around the bubble inside the overlay panel (its shadow).
    static let panelMargin: CGFloat = 20

    static func compute(selection: CGRect, screen: CGRect) -> TranslatorPlacement {
        // Only the visible part of the selection anchors the bubble: a
        // page-wide selection reaches past the screen, and the bubble goes
        // where the eye is.
        var anchor = selection.intersection(screen)
        if anchor.isNull || anchor.isEmpty {
            let x = min(max(selection.minX, screen.minX), screen.maxX)
            let y = min(max(selection.maxY, screen.minY), screen.maxY)
            anchor = CGRect(x: x, y: y, width: 1, height: 1)
        }
        let widthCap = max(minWidth, min(Self.widthCap, screen.width - 2 * edgeMargin))
        let heightCap = min(Self.heightCap, (screen.height * screenShare).rounded(.down))

        // Horizontal: left-aligned with the selection when that fits,
        // right-aligned with it when that fits, shifted left otherwise.
        var x = anchor.minX
        var alignRight = false
        if x + widthCap > screen.maxX - edgeMargin {
            if anchor.maxX - widthCap >= screen.minX + edgeMargin {
                x = anchor.maxX
                alignRight = true
            } else {
                x = screen.maxX - edgeMargin - widthCap
            }
        }
        if !alignRight { x = max(x, screen.minX + edgeMargin) }

        // Vertical: above the selection, else below it, else hanging from
        // its first visible line (a selection that fills the screen).
        let roomAbove = screen.maxY - edgeMargin - (anchor.maxY + tail)
        let roomBelow = (anchor.minY - tail) - (screen.minY + edgeMargin)
        let roomInside = (anchor.maxY - tail) - (screen.minY + edgeMargin)
        let y: CGFloat
        let opensDown: Bool
        let room: CGFloat
        if roomAbove >= minHeight {
            (y, opensDown, room) = (anchor.maxY, false, roomAbove)
        } else if roomBelow >= minHeight {
            (y, opensDown, room) = (anchor.minY, true, roomBelow)
        } else if roomInside >= minHeight {
            (y, opensDown, room) = (anchor.maxY, true, roomInside)
        } else if roomAbove >= roomBelow {
            (y, opensDown, room) = (anchor.maxY, false, roomAbove)
        } else {
            (y, opensDown, room) = (anchor.minY, true, roomBelow)
        }
        return TranslatorPlacement(
            anchor: CGPoint(x: x, y: y),
            opensDown: opensDown,
            alignRight: alignRight,
            maxWidth: widthCap,
            maxHeight: max(80, min(heightCap, room))
        )
    }

    /// The bubble's frame on screen for a bubble of `size`: the corner next
    /// to the anchor is the fixed one, so the bubble grows away from the text.
    func frame(size: CGSize) -> CGRect {
        let x = alignRight ? anchor.x - size.width : anchor.x
        let y = opensDown ? anchor.y - Self.tail - size.height : anchor.y + Self.tail
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// The overlay panel's frame: the bubble plus the room for its shadow.
    func panelFrame(size: CGSize) -> CGRect {
        frame(size: size).insetBy(dx: -Self.panelMargin, dy: -Self.panelMargin)
    }

    /// A screen rectangle expressed in the panel's SwiftUI space (origin at
    /// the panel's top-left, y down).
    static func inPanel(_ rect: CGRect, panel: CGRect) -> CGRect {
        CGRect(x: rect.minX - panel.minX, y: panel.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}
