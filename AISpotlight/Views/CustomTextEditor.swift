import SwiftUI
import AppKit

/// NSTextView that draws a QuoteBlockView-style accent bar along the quote
/// region, so the composer quote looks exactly like it will in the sent
/// bubble: rounded 3pt accent stripe on the left, muted indented text.
final class QuoteComposerTextView: NSTextView {

    /// Host-installed hook: return true when the pasteboard was consumed as
    /// an image attachment (⌘V of a picture); false falls through to the
    /// normal text paste.
    var onPasteImage: ((NSPasteboard) -> Bool)?

    override func paste(_ sender: Any?) {
        if let onPasteImage, onPasteImage(NSPasteboard.general) { return }
        super.paste(sender)
    }

    // MARK: - Terminal block caret

    /// Set → the system insertion point is hidden and a terminal-style
    /// blinking block is drawn at the caret instead (Terminal theme's
    /// signature). nil → the regular caret.
    var blockCaretColor: NSColor? {
        didSet {
            guard blockCaretColor != oldValue else { return }
            // TextKit 2 (macOS 14+) draws the caret via NSTextInsertionIndicator;
            // a clear insertionPointColor hides it on every macOS we target.
            insertionPointColor = blockCaretColor == nil ? .labelColor : .clear
            configureCaretBlink()
            needsDisplay = true
        }
    }
    private var caretBlinkTimer: Timer?
    private var caretOn = true

    private func configureCaretBlink() {
        caretBlinkTimer?.invalidate()
        caretBlinkTimer = nil
        caretOn = true
        guard blockCaretColor != nil else { return }
        // Hard on/off blink, matching the design's `blink 1.1s step-end`.
        let timer = Timer(timeInterval: 0.55, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.caretOn.toggle()
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        caretBlinkTimer = timer
    }

    /// Keep the block solid while the caret moves/types (like real terminals).
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if blockCaretColor != nil {
            caretOn = true
            configureCaretBlink()
            needsDisplay = true
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, blockCaretColor != nil { configureCaretBlink(); needsDisplay = true }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { caretBlinkTimer?.invalidate(); caretBlinkTimer = nil; needsDisplay = true }
        return ok
    }

    /// The caret's frame in view coordinates (zero-length selection only).
    private var blockCaretRect: NSRect? {
        let sel = selectedRange()
        guard sel.length == 0 else { return nil }
        var frame: NSRect?
        if let tlm = textLayoutManager, let cm = tlm.textContentManager,
           let loc = cm.location(cm.documentRange.location, offsetBy: sel.location) {
            tlm.enumerateTextSegments(in: NSTextRange(location: loc), type: .selection,
                                      options: [.rangeNotRequired]) { _, rect, _, _ in
                frame = rect
                return false
            }
        }
        guard var r = frame else { return nil }
        // One monospace character cell, like a real terminal cursor (terminals
        // are a grid of fixed-width cells; SF Mono's cell ≈ 0.6em). The
        // composer font is proportional, so measure the mono font's advance.
        let size = (self.font ?? .systemFont(ofSize: 13)).pointSize
        let mono = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        r.size.width = ("0" as NSString).size(withAttributes: [.font: mono]).width
        r.origin.x += textContainerInset.width
        r.origin.y += textContainerInset.height
        return r
    }

    private func drawBlockCaret() {
        guard let color = blockCaretColor, caretOn,
              window?.firstResponder === self,
              let rect = blockCaretRect else { return }
        // Translucent block UNDER the glyphs (drawn before super) — the
        // character stays readable inside the cursor, terminal-style.
        color.withAlphaComponent(0.55).setFill()
        rect.fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        drawQuoteBar()
        drawBlockCaret()
        super.draw(dirtyRect)
    }

    private func drawQuoteBar() {
        guard let storage = textStorage, storage.length > 0 else { return }
        var start = NSNotFound
        var end = 0
        storage.enumerateAttribute(CustomTextEditor.quoteAttribute,
                                   in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard (value as? Bool) == true else { return }
            if start == NSNotFound { start = range.location }
            end = max(end, range.location + range.length)
        }
        guard start != NSNotFound else { return }
        let quoteRange = NSRange(location: start, length: end - start)

        // Union of the region's line-fragment rects (TextKit 2, TK1 fallback).
        var union = NSRect.null
        if let tlm = textLayoutManager, let cm = tlm.textContentManager,
           let from = cm.location(cm.documentRange.location, offsetBy: quoteRange.location),
           let to = cm.location(from, offsetBy: quoteRange.length),
           let textRange = NSTextRange(location: from, end: to) {
            tlm.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
                union = union.union(frame)
                return true
            }
        } else if let lm = layoutManager, let tc = textContainer {
            let glyphs = lm.glyphRange(forCharacterRange: quoteRange, actualCharacterRange: nil)
            lm.enumerateEnclosingRects(forGlyphRange: glyphs,
                                       withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                       in: tc) { rect, _ in union = union.union(rect) }
        }
        guard !union.isNull, union.height > 0 else { return }

        let bar = NSRect(x: textContainerInset.width + 1,
                         y: union.minY + textContainerInset.height,
                         width: 3,
                         height: union.height)
        NSColor.controlAccentColor.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

/// Multi-line chat input backed by NSTextView.
/// - Return submits, Shift+Return inserts a newline.
/// - Reports its real laid-out text height (word wrap included) through
///   `measuredHeight`, so the field grows like modern chat inputs and shows
///   an inner scroller once it reaches `maxHeight`.
/// - A captured selection lives INSIDE the editor as a visually styled,
///   freely editable quote region (marked with `quoteAttribute` — no "> "
///   markers on screen; they are added at send time, see
///   `SelectionGrabber.message`). `text` binds the instruction part only,
///   `quotedText` mirrors the quote region's current content.
struct CustomTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var quotedText: String?
    /// One-shot trigger: set to place a captured selection into the editor.
    @Binding var quoteToInsert: String?
    @Binding var measuredHeight: CGFloat
    var onSubmit: () -> Void
    var isDisabled: Bool
    /// Called on ⌘V when the pasteboard may hold an image. Return true to
    /// consume the paste (the image became an attachment).
    var onPasteImage: ((NSPasteboard) -> Bool)? = nil
    /// Terminal theme's block caret color; nil keeps the system caret.
    var blockCaretColor: NSColor? = nil

    static let minHeight: CGFloat = 27
    static let maxHeight: CGFloat = 27 + 17 * 4 // ~5 lines, then scroll

    // MARK: - Quote region (attribute-marked, e2e-tested)

    /// Marks characters belonging to the captured-quote region.
    static let quoteAttribute = NSAttributedString.Key("aispotlight.capturedQuote")

    static var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 13),
         .foregroundColor: NSColor.labelColor]
    }

    /// Quote look — mirrors the sent bubble's QuoteBlockView: muted text,
    /// indented past the accent bar (drawn by `QuoteComposerTextView`).
    static var quoteAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 12
        paragraph.headIndent = 12
        return [.font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
                quoteAttribute: true]
    }

    /// Heals the quote region after edits: characters typed INSIDE the quote
    /// arrive with body typing attributes, which would split the region and
    /// let a later rebuild relocate them below the quote. Everything before
    /// the last quote-attributed character belongs to the quote.
    static func normalizeQuoteRegion(in storage: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: storage.length)
        var lastQuoteEnd = 0
        storage.enumerateAttribute(quoteAttribute, in: full) { value, range, _ in
            if (value as? Bool) == true { lastQuoteEnd = max(lastQuoteEnd, range.location + range.length) }
        }
        guard lastQuoteEnd > 0 else { return }
        storage.beginEditing()
        storage.addAttributes(quoteAttributes, range: NSRange(location: 0, length: lastQuoteEnd))
        storage.endEditing()
    }

    /// Full editor document from its parts: styled quote on top (if any),
    /// a plain separator newline, then the instruction body.
    static func buildDocument(quote: String?, body: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let trimmedQuote = quote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedQuote.isEmpty {
            result.append(NSAttributedString(string: trimmedQuote, attributes: quoteAttributes))
            result.append(NSAttributedString(string: "\n", attributes: bodyAttributes))
        }
        result.append(NSAttributedString(string: body, attributes: bodyAttributes))
        return result
    }

    /// Splits a document back into (quote, body) by the marker attribute —
    /// robust to any user edits inside or around the quote region.
    static func extractParts(from storage: NSAttributedString) -> (quote: String?, body: String) {
        let full = storage.string as NSString
        var quote = ""
        var body = ""
        storage.enumerateAttribute(quoteAttribute, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            let piece = full.substring(with: range)
            if (value as? Bool) == true { quote += piece } else { body += piece }
        }
        let cleanQuote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanQuote.isEmpty, body.hasPrefix("\n") {
            body.removeFirst() // the separator newline is structural, not content
        }
        return (cleanQuote.isEmpty ? nil : cleanQuote, body)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // Manual construction (instead of NSTextView.scrollableTextView) so
        // the document view can be our accent-bar-drawing subclass.
        let textView = QuoteComposerTextView(usingTextLayoutManager: true)
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.allowsUndo = true
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)

        // Configure text view
        textView.delegate = context.coordinator
        // Route ⌘V through the coordinator so the closure the host passed on
        // the LATEST update is used (the representable struct is recreated).
        textView.onPasteImage = { [weak coordinator = context.coordinator] pasteboard in
            coordinator?.parent.onPasteImage?(pasteboard) ?? false
        }
        textView.isRichText = false
        textView.blockCaretColor = blockCaretColor
        textView.font = .systemFont(ofSize: 13)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        // Set text container insets to control padding
        textView.textContainerInset = NSSize(width: 5, height: 5)
        textView.textContainer?.lineFragmentPadding = 0
        textView.typingAttributes = Self.bodyAttributes

        // Configure scroll view: scroll appears only when maxHeight is reached
        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none

        // Re-measure when the width changes (window resize changes word wrap)
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.frameDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: scrollView.contentView
        )

        context.coordinator.textView = textView
        DispatchQueue.main.async { context.coordinator.remeasure() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        (textView as? QuoteComposerTextView)?.blockCaretColor = blockCaretColor

        if let pending = quoteToInsert {
            // A captured selection arrives: (re)build the document with the
            // new quote on top; the typed instruction is preserved.
            let doc = Self.buildDocument(quote: pending, body: context.coordinator.lastBody)
            setDocument(doc, in: textView, coordinator: context.coordinator)
            let inserted = context.coordinator.lastQuote
            DispatchQueue.main.async {
                quoteToInsert = nil
                quotedText = inserted
            }
        } else if text != context.coordinator.lastBody || quotedText != context.coordinator.lastQuote {
            // External change (e.g. the composer is cleared after sending).
            let doc = Self.buildDocument(quote: quotedText, body: text)
            setDocument(doc, in: textView, coordinator: context.coordinator)
        }

        // Update disabled state
        textView.isEditable = !isDisabled
        textView.isSelectable = !isDisabled
        textView.alphaValue = isDisabled ? 0.6 : 1.0
    }

    /// Replaces the editor content, leaves the caret at the end ready for
    /// typing, and refreshes the coordinator's split-state snapshot.
    private func setDocument(_ doc: NSAttributedString, in textView: NSTextView, coordinator: Coordinator) {
        textView.textStorage?.setAttributedString(doc)
        textView.typingAttributes = Self.bodyAttributes
        textView.setSelectedRange(NSRange(location: doc.length, length: 0))
        let parts = Self.extractParts(from: doc)
        coordinator.lastQuote = parts.quote
        coordinator.lastBody = parts.body
        coordinator.remeasure()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CustomTextEditor
        weak var textView: NSTextView?
        /// Snapshot of the last known (quote, body) split — updateNSView uses
        /// it to tell user edits apart from external binding changes.
        var lastQuote: String?
        var lastBody: String = ""

        init(_ parent: CustomTextEditor) {
            self.parent = parent
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if let storage = textView.textStorage {
                CustomTextEditor.normalizeQuoteRegion(in: storage)
                if storage.length == 0 {
                    // Deleting everything must not leave quote typing attrs.
                    textView.typingAttributes = CustomTextEditor.bodyAttributes
                }
            }
            let parts = CustomTextEditor.extractParts(from: textView.attributedString())
            lastQuote = parts.quote
            lastBody = parts.body
            parent.quotedText = parts.quote
            parent.text = parts.body
            textView.needsDisplay = true // the accent bar tracks the region
            remeasure()
        }

        @objc func frameDidChange(_ notification: Notification) {
            remeasure()
        }

        /// Measures the actual laid-out height of the text (TextKit 2 first —
        /// touching `layoutManager` before checking would silently downgrade
        /// the view to TextKit 1).
        func remeasure() {
            guard let tv = textView else { return }
            let contentHeight: CGFloat
            if let tlm = tv.textLayoutManager {
                tlm.ensureLayout(for: tlm.documentRange)
                contentHeight = tlm.usageBoundsForTextContainer.height
            } else if let lm = tv.layoutManager, let tc = tv.textContainer {
                lm.ensureLayout(for: tc)
                contentHeight = lm.usedRect(for: tc).height
            } else {
                return
            }

            let total = contentHeight + tv.textContainerInset.height * 2
            let clamped = min(max(total, CustomTextEditor.minHeight), CustomTextEditor.maxHeight)
            guard abs(clamped - parent.measuredHeight) > 0.5 else { return }

            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.12)) {
                    self.parent.measuredHeight = clamped
                }
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Keep the bar crisp while the caret moves through the region.
            (notification.object as? NSTextView)?.needsDisplay = true
        }

        // Handle Return and Shift+Return
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // Check if Shift is held
                if NSEvent.modifierFlags.contains(.shift) {
                    // Shift+Return: insert newline
                    textView.insertNewline(nil)
                    return true
                } else {
                    // Return: submit
                    parent.onSubmit()
                    return true
                }
            }
            return false
        }
    }
}
