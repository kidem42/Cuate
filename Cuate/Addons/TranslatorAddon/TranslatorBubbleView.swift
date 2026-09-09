import SwiftUI
import AppKit

/// The panel's content: the bubble pinned to the corner nearest the
/// selection, so it grows away from the text, with a spring on arrival.
struct TranslatorBubbleRoot: View {
    @ObservedObject var model: TranslatorBubbleModel
    let actions: TranslatorBubbleActions

    private var alignment: Alignment {
        model.opensDown
            ? (model.alignRight ? .topTrailing : .topLeading)
            : (model.alignRight ? .bottomTrailing : .bottomLeading)
    }

    private var anchor: UnitPoint {
        model.opensDown
            ? (model.alignRight ? .topTrailing : .topLeading)
            : (model.alignRight ? .bottomTrailing : .bottomLeading)
    }

    var body: some View {
        ZStack(alignment: alignment) {
            Color.clear
            TranslatorBubbleView(model: model, actions: actions)
                .frame(width: model.bubbleSize.width, height: model.bubbleSize.height)
                .scaleEffect(model.revealed ? 1 : 0.7, anchor: anchor)
                .opacity(model.revealed ? 1 : 0)
                .animation(.spring(response: 0.28, dampingFraction: 0.72), value: model.revealed)
                .padding(TranslatorPlacement.panelMargin)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
}

/// The bubble itself, in the dictation island's material: a dark fill over
/// a blur, a white hairline, the drop shadow, white ink. Header: the target
/// language chip (a menu), the chunk progress, copy, open in chat, and the
/// linger ring that doubles as the close button. Body: the text, scrolling
/// past the placement's cap with a fade at the bottom.
struct TranslatorBubbleView: View {
    @ObservedObject var model: TranslatorBubbleModel
    let actions: TranslatorBubbleActions

    static let fill = Color(red: 0.078, green: 0.086, blue: 0.11)
    static let ink = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.55)
    static let hairline = Color.white.opacity(0.16)
    private let corner: CGFloat = 14

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        VStack(spacing: 0) {
            header
                .frame(height: TranslatorBubbleMetrics.headerHeight)
            bodyView
                .frame(height: model.bodyHeight)
                .padding(.top, TranslatorBubbleMetrics.bodyTop)
                .padding(.bottom, TranslatorBubbleMetrics.bodyBottom)
        }
        .background(shape.fill(.ultraThinMaterial))
        .background(shape.fill(Self.fill.opacity(0.86)))
        .overlay(shape.stroke(Self.hairline, lineWidth: 1))
        .overlay(alignment: tailAlignment) {
            BubbleTail(pointsDown: !model.opensDown)
                .fill(Self.fill.opacity(0.94))
                .frame(width: 14, height: 8)
                .offset(y: model.opensDown ? -7 : 7)
                .padding(.horizontal, 14)
        }
        .shadow(color: .black.opacity(0.45), radius: 10, y: 8)
        .background(HoverSensor { [weak model] inside in model?.hovering = inside })
    }

    private var tailAlignment: Alignment {
        model.opensDown
            ? (model.alignRight ? .topTrailing : .topLeading)
            : (model.alignRight ? .bottomTrailing : .bottomLeading)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            languageChip
            if model.chunkCount > 1, model.phase == .streaming || model.phase == .thinking {
                Text("\(min(model.chunkIndex + 1, model.chunkCount)) / \(model.chunkCount)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Self.secondary)
            }
            Spacer(minLength: 4)
            if model.phase == .done || model.phase == .streaming {
                Button(action: actions.copy) {
                    Image(systemName: model.copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.copied ? Color.green : Self.secondary)
                .help(TRL(model.copied ? "tr.bubble.copied" : "tr.help.copy"))
                Button(action: actions.openInChat) {
                    // The app's own glyph: "continue this in Cuate".
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Self.secondary)
                .help(TRL("tr.help.chat"))
            }
            Button(action: actions.dismiss) {
                // A close button whose ring empties as the bubble's time runs out.
                ZStack {
                    LingerRing(remaining: model.phase == .done || model.phase == .failed || model.phase == .nothing ? model.remaining : 1)
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Self.ink)
                }
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(TRL("tr.help.dismiss"))
        }
        .padding(.horizontal, TranslatorBubbleMetrics.sidePadding)
        .padding(.top, 2)
    }

    private var languageChip: some View {
        Menu {
            ForEach(AppSettings.dictationLanguages, id: \.self) { language in
                Button {
                    actions.switchLanguage(language)
                } label: {
                    if language == model.targetLanguage {
                        Label(language, systemImage: "checkmark")
                    } else {
                        Text(language)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(AppSettings.dictationISOCode(for: model.targetLanguage))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(0.7)
            }
            .foregroundStyle(Self.ink)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.14)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.original.isEmpty)
        .help(TRL("tr.help.language"))
    }

    // MARK: - Body

    @ViewBuilder
    private var bodyView: some View {
        if model.phase == .thinking {
            HStack {
                ThinkingDots()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, TranslatorBubbleMetrics.sidePadding)
        } else {
            // A real text view: the translation can be selected with the
            // mouse and copied in pieces (⌘C, or Copy in the context menu).
            SelectableTextBody(text: model.text, color: model.phase == .failed ? .systemOrange : NSColor.white.withAlphaComponent(0.92))
                .mask(
                    LinearGradient(
                        stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
        }
    }
}

/// The island's warm-up rhythm: three dots breathing in turn.
struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = (sin(time * 2 * .pi / 1.2 - Double(index) * 0.9) + 1) / 2
                    Circle()
                        .fill(TranslatorBubbleView.ink)
                        .frame(width: 6, height: 6)
                        .scaleEffect(0.8 + 0.35 * phase)
                        .opacity(0.35 + 0.65 * phase)
                }
            }
            .frame(height: TranslatorBubbleMetrics.dotsHeight)
        }
    }
}

/// The linger clock: a ring that empties as the bubble's time runs out.
struct LingerRing: View {
    let remaining: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: max(0, min(1, remaining)))
                .stroke(TranslatorBubbleView.ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(2)
    }
}

/// The small triangle on the bubble's edge that points at the selection.
struct BubbleTail: Shape {
    let pointsDown: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if pointsDown {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        }
        path.closeSubpath()
        return path
    }
}

/// Hover that works in a window that is never key: an always-active
/// tracking area, transparent to clicks.
struct HoverSensor: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> HoverView {
        let view = HoverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: HoverView, context: Context) {
        view.onChange = onChange
    }

    final class HoverView: NSView {
        var onChange: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
            super.updateTrackingAreas()
        }

        override func mouseEntered(with event: NSEvent) { onChange?(true) }
        override func mouseExited(with event: NSEvent) { onChange?(false) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The bubble's text as an AppKit text view inside its own scroll view:
/// selectable, not editable, transparent, the island's ink; the selection
/// highlight is light so it reads on the dark fill.
struct SelectableTextBody: NSViewRepresentable {
    let text: String
    let color: NSColor

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = TranslatorBubbleMetrics.font
        textView.textColor = color
        textView.selectedTextAttributes = [.backgroundColor: NSColor.white.withAlphaComponent(0.28)]
        textView.textContainerInset = NSSize(width: TranslatorBubbleMetrics.sidePadding, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            textView.font = TranslatorBubbleMetrics.font
        }
        if textView.textColor != color {
            textView.textColor = color
        }
    }
}
