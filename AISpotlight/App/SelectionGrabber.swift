import AppKit
import ApplicationServices
import Carbon

/// Captures the text selected in the frontmost app at the moment the panel
/// is summoned, so ChatWindow can prefill its input field ("select →
/// ⌘⇧Space → Enter" flows, e.g. instant translation with a translator preset).
///
/// Strategy: the Accessibility selected-text attribute first (instant, no
/// side effects); a clipboard round-trip via synthesized ⌘C as a fallback for
/// apps that don't expose it (Chromium/Electron web content). Returns nil
/// when nothing is selected or the Accessibility permission is missing —
/// summoning the panel must never block on a permission prompt.
@MainActor
enum SelectionGrabber {

    /// Clipboard managers skip transient pasteboard writes marked with this
    /// well-known type (nspasteboard.org convention).
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Pathologically large selections are cut — they would bog down the
    /// input field's layout.
    private static let maxLength = 50_000

    static func grab() async -> String? {
        guard AXIsProcessTrusted() else { return nil } // silent — never prompt here
        // Our own windows' selection (Settings etc.) is never interesting.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                != ProcessInfo.processInfo.processIdentifier else { return nil }

        switch axSelection() {
        case .text(let text):
            Diagnostics.log("ui", "prefill.grab via=ax chars=\(text.count)")
            return String(text.prefix(maxLength))
        case .empty where !frontmostIsChatApp():
            return nil // a text context with nothing selected — no fallback needed
        case .empty, .unavailable:
            // Chat apps keep focus in the compose box while the selection
            // lives in the message list — the focused element honestly says
            // "empty" and only ⌘C can reach the real selection.
            guard let text = await clipboardSelection() else { return nil }
            Diagnostics.log("ui", "prefill.grab via=clipboard chars=\(text.count)")
            return String(text.prefix(maxLength))
        }
    }

    /// Messengers whose focused element (the compose box) never holds the
    /// selection the user made in the conversation list.
    private static let chatAppBundleIDs: Set<String> = [
        "net.whatsapp.WhatsApp", "WhatsApp",
        "ru.keepcoder.Telegram", "org.telegram.desktop",
        "com.tinyspeck.slackmacgap", "com.hnc.Discord",
        "org.whispersystems.signal-desktop", "com.viber.osx",
    ]

    private static func frontmostIsChatApp() -> Bool {
        guard let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return chatAppBundleIDs.contains(bundle)
    }

    // MARK: - Quote formatting (pure — e2e-tested)

    /// Formats captured text as a markdown blockquote for the composer:
    /// every line prefixed with "> " (bare ">" for inner empty lines so the
    /// block stays contiguous). The result is plain editable text the model
    /// reads as a quotation — see `AppSettings.mandatoryPromptRules`.
    nonisolated static func quoteBlock(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let content = line.trimmingCharacters(in: .whitespaces)
                return content.isEmpty ? ">" : "> \(content)"
            }
            .joined(separator: "\n")
    }

    /// Assembles the outgoing message from the composer parts: the quote (as
    /// a markdown blockquote) on top, the typed instruction below. The "> "
    /// markers exist only in the sent text — the editor shows the quote as a
    /// styled region without any markup.
    nonisolated static func message(quote: String?, instruction: String) -> String {
        let quoted = quote.map(quoteBlock) ?? ""
        let body = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if quoted.isEmpty { return body }
        return body.isEmpty ? quoted : quoted + "\n\n" + body
    }

    // MARK: - Accessibility attribute (fast path)

    private enum AXSelection {
        case text(String)
        case empty       // the focused element exposes selection, none is made
        case unavailable // no focused element / attribute not exposed
    }

    private static func axSelection() -> AXSelection {
        let systemWide = AXUIElementCreateSystemWide()
        // Bound the synchronous cross-process AX calls: a busy/hung frontmost
        // app must not stall the panel's focus handoff.
        AXUIElementSetMessagingTimeout(systemWide, 0.2)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return .unavailable
        }
        let element = focusedRef as! AXUIElement
        var selectedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedRef) == .success,
              let text = selectedRef as? String else {
            return .unavailable
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .text(text)
    }

    // MARK: - Clipboard fallback (synthesized ⌘C)

    /// Same technique as LayoutFix's copySelection: a unique sentinel
    /// distinguishes "nothing was copied" from real content, and the user's
    /// clipboard is restored afterwards.
    /// Internal (not private) so the e2e harness can exercise the sentinel /
    /// restore mechanics directly.
    static func clipboardSelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        let sentinel = "‹aispotlight-grab-\(pasteboard.changeCount)›"
        pasteboard.declareTypes([.string, transientType], owner: nil)
        pasteboard.setString(sentinel, forType: .string)

        // Let the summon chord (⌘⇧Space) physically release first — its Shift
        // must not merge into the ⌘C (⌘⇧C opens dev tools in browsers).
        // Polled, not a fixed sleep: the chord is typically up within ~50 ms,
        // and this wait delays the panel's appearance on screen.
        await waitForModifierRelease(timeout: .milliseconds(300))
        let countBeforeCopy = pasteboard.changeCount
        postKey(kVK_ANSI_C, flags: .maskCommand)
        // The copy typically lands in 30–80 ms; poll instead of a fixed wait.
        // The timeout only bites when nothing was selected (the target app
        // never writes the pasteboard) — kept tight (120 ms) so an empty grab
        // can't hold the panel's focus hostage. Real copies land well inside it.
        await waitForPasteboardChange(pasteboard, from: countBeforeCopy, timeout: .milliseconds(120))

        defer { restore(saved, to: pasteboard) }

        // A non-text copy (Finder files and the like) is not a text selection.
        if pasteboard.types?.contains(.fileURL) == true { return nil }
        guard let value = pasteboard.string(forType: .string),
              value != sentinel,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    /// Polls the hardware modifier state until ⌘/⇧/⌃/⌥ are all up (10 ms
    /// steps). Falls through at `timeout` — a stuck modifier must not hold
    /// the panel hostage.
    private static func waitForModifierRelease(timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]).isEmpty {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Polls until the pasteboard's changeCount moves past `from` (the ⌘C
    /// landed), or gives up at `timeout` (nothing was selected).
    private static func waitForPasteboardChange(_ pasteboard: NSPasteboard, from: Int, timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if pasteboard.changeCount != from { return }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    private static func restore(_ saved: String?, to pasteboard: NSPasteboard) {
        guard let saved else { return }
        // Also transient: clipboard managers recorded the original already —
        // re-recording the restore would duplicate their history entry.
        pasteboard.declareTypes([.string, transientType], owner: nil)
        pasteboard.setString(saved, forType: .string)
    }

    private static func postKey(_ keyCode: Int, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
