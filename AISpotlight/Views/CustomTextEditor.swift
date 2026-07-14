import SwiftUI
import AppKit

/// Multi-line chat input backed by NSTextView.
/// - Return submits, Shift+Return inserts a newline.
/// - Reports its real laid-out text height (word wrap included) through
///   `measuredHeight`, so the field grows like modern chat inputs and shows
///   an inner scroller once it reaches `maxHeight`.
struct CustomTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    var onSubmit: () -> Void
    var isDisabled: Bool

    static let minHeight: CGFloat = 27
    static let maxHeight: CGFloat = 27 + 17 * 4 // ~5 lines, then scroll

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        // Configure text view
        textView.delegate = context.coordinator
        textView.isRichText = false
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

        // Update text if needed
        if textView.string != text {
            textView.string = text
            // Programmatic fills (selection prefill) leave the caret at the
            // end — ready to type an instruction or hit Enter right away.
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            context.coordinator.remeasure()
        }

        // Update disabled state
        textView.isEditable = !isDisabled
        textView.isSelectable = !isDisabled
        textView.textColor = isDisabled ? .secondaryLabelColor : .labelColor
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CustomTextEditor
        weak var textView: NSTextView?

        init(_ parent: CustomTextEditor) {
            self.parent = parent
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
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
