import AppKit
import Carbon

/// A low-level global keystroke monitor built on `CGEventTap`.
///
/// It accumulates the word currently being typed (physical key codes + the
/// character each produced under the active layout) and reports it on a word
/// boundary, and it performs corrections via *tagged* synthesized events the tap
/// ignores. The tap is **active** (`.defaultTap`) so it can swallow a single
/// Backspace pressed right after a correction and turn it into an undo.
///
/// The tap is serviced by a **dedicated thread** with its own run loop — never
/// the app's main run loop. Otherwise every keystroke in the system would wait
/// on the host app's main thread: a busy UI (streaming, rendering) would lag
/// typing Mac-wide, and a stall would trip `tapDisabledByTimeout`. Mutable
/// state (word buffer, undo flags) is guarded by a recursive lock because the
/// synchronous decision callbacks may re-enter (e.g. `armUndo`).
/// Requires the Accessibility permission (the app is not sandboxed).
final class KeystrokeMonitor {

    /// One captured keypress: the physical key + modifier state (for re-rendering
    /// under another layout) and the character it actually produced.
    struct Key {
        let keyCode: UInt16
        let modifierByte: UInt32   // UCKeyTranslate modifier byte
        let character: String
    }

    /// A ready-to-apply replacement decided by the engine.
    struct Correction {
        let deleteCount: Int
        let insert: String
        /// Per-key characters of the corrected rendering — used to rebase the
        /// buffer after a mid-word (early) correction.
        var rebasedChars: [String] = []
    }

    /// Fired on the main thread when a word is completed by a space.
    var onWord: ((_ word: String, _ keys: [Key], _ boundary: Character) -> Void)?

    /// Synchronous decision for the word pending when plain Enter is pressed
    /// (chats!). Non-nil → the Enter is swallowed, the correction applied, and
    /// a tagged Enter re-posted afterwards.
    var onCommitDecision: ((_ word: String, _ keys: [Key]) -> Correction?)?

    /// Synchronous mid-word check (early switch), consulted after
    /// each buffered letter once the word is long enough. Non-nil → correct
    /// immediately and rebase the buffer to the corrected rendering.
    var onEarlyCheck: ((_ word: String, _ keys: [Key]) -> Correction?)?

    /// Fired when the user presses Backspace immediately after a correction —
    /// the caller should revert its last correction.
    var onUndoRequested: (() -> Void)?

    /// Marks synthesized events so the tap skips them (avoids feedback loops).
    private static let injectedTag: Int64 = 0x4C_46_49_58       // "LFIX"
    private static let undoWindow: TimeInterval = 4.0

    /// Notifies the owner that the system disabled the tap (timeout / heavy
    /// input) and it was re-enabled — keystrokes in the gap were lost.
    var onTapAutoReenabled: (() -> Void)?

    /// Auto-capitalize the first letter after ". " / "! " / "? " (and after
    /// Enter). The keyDown event is rewritten in place — no synthetic replays.
    var autoCapitalize = false
    /// Consulted before capitalizing (skip terminals / secure input).
    var capitalizationAllowed: (() -> Bool)?

    /// ". " → armed → first lowercase letter gets uppercased.
    private enum SentenceState { case idle, afterTerminator, armed }
    private var sentenceState: SentenceState = .idle

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private var buffer: [Key] = []

    /// Source for synthesized corrections. CRITICAL: zero the local-events
    /// suppression interval — by default macOS suppresses ~0.25 s of REAL
    /// keyboard input after every synthetic post, which swallowed the user's
    /// next keystrokes right after each correction ("the app went dead for a
    /// moment"). Fast typists hit this constantly.
    private let injectSource: CGEventSource? = {
        let source = CGEventSource(stateID: .privateState)
        source?.localEventsSuppressionInterval = 0
        return source
    }()

    /// Guards `buffer` and the undo flags: the tap callback runs on the tap
    /// thread while `armUndo`/`stop` may be called from the main thread.
    /// Recursive because the sync decision callbacks call back into `armUndo`.
    private let stateLock = NSRecursiveLock()

    /// Synthesized events are posted from a serial background queue — going
    /// through the main queue would make corrections wait on a busy UI.
    private let postQueue = DispatchQueue(label: "LayoutFix.post", qos: .userInteractive)

    private var undoArmed = false
    private var undoArmedAt: Date?

    var isRunning: Bool { tap != nil }

    // MARK: - Lifecycle

    /// Installs the tap. Returns false if the Accessibility permission is missing
    /// (in which case `CGEvent.tapCreate` fails).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        // NB: no `.flagsChanged` — Shift/Option are normal typing modifiers, and
        // resetting the word buffer on every Shift press/release truncated any
        // capitalized word ("AIspotlight" → lost "AI"). ⌘/⌃ chords are caught on
        // the keyDown itself instead.
        let mask: CGEventMask =
            (UInt64(1) << CGEventType.keyDown.rawValue) |
            (UInt64(1) << CGEventType.leftMouseDown.rawValue) |
            (UInt64(1) << CGEventType.rightMouseDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<KeystrokeMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,          // active: lets us swallow the undo Backspace
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        // Service the tap on a dedicated thread with its own run loop, so
        // system-wide keystroke delivery never waits on the app's main thread.
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.tapRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()   // until CFRunLoopStop() in stop()
        }
        thread.name = "LayoutFix.EventTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()   // startup-only, sub-millisecond

        self.tap = tap
        self.runLoopSource = source
        self.tapThread = thread
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapRunLoop {
            if let runLoopSource { CFRunLoopRemoveSource(tapRunLoop, runLoopSource, .commonModes) }
            CFRunLoopStop(tapRunLoop)
        }
        tap = nil
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil
        stateLock.lock()
        buffer = []
        stateLock.unlock()
        disarmUndo()
    }

    func resetBuffer() {
        stateLock.lock()
        buffer = []
        stateLock.unlock()
    }

    // MARK: - Undo arming (called by the switcher after a correction)

    func armUndo() {
        stateLock.lock()
        undoArmed = true
        undoArmedAt = Date()
        stateLock.unlock()
    }

    func disarmUndo() {
        stateLock.lock()
        undoArmed = false
        undoArmedAt = nil
        stateLock.unlock()
    }

    private var undoStillValid: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let at = undoArmedAt else { return false }
        return Date().timeIntervalSince(at) < Self.undoWindow
    }

    // MARK: - Event handling (tap thread)

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that's too slow or during heavy input — re-arm it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            onTapAutoReenabled?()
            return Unmanaged.passUnretained(event)
        }

        // Ignore our own synthesized correction events.
        if event.getIntegerValueField(.eventSourceUserData) == Self.injectedTag {
            return Unmanaged.passUnretained(event)
        }

        // Everything below touches the buffer / undo flags — hold the lock for
        // the whole event (recursive: decision callbacks may call armUndo).
        stateLock.lock()
        defer { stateLock.unlock() }

        switch type {
        case .leftMouseDown, .rightMouseDown:
            // Cursor may have moved — the buffer is no longer contiguous with it.
            buffer = []
            sentenceState = .idle
            disarmUndo()

        case .keyDown:
            // Undo interception: a plain Backspace right after a correction
            // reverts it instead of deleting a character.
            if undoArmed {
                let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                let flags = event.flags
                let plainBackspace = keyCode == UInt16(kVK_Delete)
                    && !flags.contains(.maskCommand)
                    && !flags.contains(.maskControl)
                    && !flags.contains(.maskAlternate)
                if plainBackspace, undoStillValid {
                    disarmUndo()
                    buffer = []
                    onUndoRequested?()
                    return nil   // swallow: it becomes an undo, not a delete
                }
                disarmUndo()     // any other key cancels the undo offer
            }
            return processKeyDown(event)   // may swallow a deferred Enter

        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    /// Returns nil to swallow the event (Enter that got deferred for a fix).
    private func processKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // ⌘/⌃ mean a shortcut, not typing.
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            buffer = []
            sentenceState = .idle
            return Unmanaged.passUnretained(event)
        }

        // Plain Enter with a pending word: last chance to fix it (the common
        // chat case). If the engine wants a fix, swallow the Enter, correct,
        // then re-post a tagged Enter so the message is sent with clean text.
        if keyCode == UInt16(kVK_Return) || keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            let word = buffer.map { $0.character }.joined()
            let keys = buffer
            buffer = []
            sentenceState = .armed   // a new line / message starts a sentence
            if !word.isEmpty, let fix = onCommitDecision?(word, keys) {
                applyCorrection(deleteCount: fix.deleteCount, insert: fix.insert)
                let enterKey = keyCode
                postQueue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    self?.postKeyCode(enterKey)
                }
                return nil   // swallow the original Enter
            }
            return Unmanaged.passUnretained(event)
        }

        // Navigation / control keys break the word without correcting.
        if Self.resetKeyCodes.contains(keyCode) {
            buffer = []
            sentenceState = .idle
            return Unmanaged.passUnretained(event)
        }
        if keyCode == UInt16(kVK_Delete) {           // backspace pops a char
            if !buffer.isEmpty { buffer.removeLast() }
            sentenceState = .idle    // user is editing — don't force a capital
            return Unmanaged.passUnretained(event)
        }

        // The character this key produced under the active layout.
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &chars)
        let produced = length > 0 ? String(utf16CodeUnits: chars, count: length) : ""

        guard let ch = produced.first else { buffer = []; return Unmanaged.passUnretained(event) }

        // A word character: a real letter, OR a key that types a letter in
        // another installed layout. In US-QWERTY "[" types х, "," types б, ";"
        // types ж, etc., so a Russian word typed in the wrong layout (e.g.
        // "хочу" → "[jxe", "чтобы" → "xnj,s") isn't torn apart on those keys.
        if ch.isLetter || Self.wordPositionKeys.contains(keyCode) {
            var charStr = produced
            var modifierByte = Self.ucModifierByte(flags)

            // Auto-capitalize: first lowercase letter of a fresh word right
            // after ". " (or Enter) — the keyDown is rewritten in place. The
            // buffered key is recorded as if Shift were held, so layout
            // re-rendering still reproduces the window ("Ghbdtn" ↔ "Привет").
            if autoCapitalize, sentenceState == .armed, buffer.isEmpty,
               ch.isLetter, ch.isLowercase, produced.count == 1,
               capitalizationAllowed?() ?? false {
                charStr = produced.uppercased()
                modifierByte = (UInt32(shiftKey) >> 8) & 0xFF
                var units = Array(charStr.utf16)
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            }

            if ch.isLetter {
                sentenceState = .idle
            } else if ".!?".contains(ch) {
                sentenceState = .afterTerminator   // "." typed on the ю / RU-slash key
            } else {
                sentenceState = .idle
            }

            buffer.append(Key(keyCode: keyCode, modifierByte: modifierByte, character: charStr))

            // Early switch: once the word is clearly impossible in
            // its layout, fix it mid-word without waiting for the boundary.
            if buffer.count >= 4, let onEarlyCheck {
                let word = buffer.map { $0.character }.joined()
                if let fix = onEarlyCheck(word, buffer) {
                    applyCorrection(deleteCount: fix.deleteCount, insert: fix.insert)
                    // Rebase: the screen now shows the corrected rendering, so
                    // the buffer must describe it for later boundary checks.
                    if fix.rebasedChars.count == buffer.count {
                        for (i, ch) in fix.rebasedChars.enumerated() {
                            buffer[i] = Key(keyCode: buffer[i].keyCode,
                                            modifierByte: buffer[i].modifierByte,
                                            character: ch)
                        }
                    }
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // A real separator ends the word. A space fires a correction; anything
        // else (digits, symbols; Tab was already filtered) just flushes.
        let word = buffer.map { $0.character }.joined()
        let keys = buffer
        buffer = []
        if ch == " " {
            // ". " arms capitalization; further spaces keep it armed.
            sentenceState = (sentenceState == .afterTerminator || sentenceState == .armed) ? .armed : .idle
            if !word.isEmpty { onWord?(word, keys, ch) }
        } else if ".!?".contains(ch) {
            sentenceState = .afterTerminator       // "!"/"?" arrive as shifted digits
        } else {
            sentenceState = .idle
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: - Correction (synthesized, tagged)

    /// Deletes `deleteCount` characters before the caret and types `insert`.
    /// Runs slightly deferred so the triggering keystroke has landed first.
    /// Posted from the serial background queue — the main queue could be busy
    /// (or stalled) and corrections must not wait on it.
    func applyCorrection(deleteCount: Int, insert: String) {
        postQueue.asyncAfter(deadline: .now() + 0.012) { [weak self] in
            guard let self else { return }
            for _ in 0..<deleteCount { self.postKeyCode(UInt16(kVK_Delete)) }
            if !insert.isEmpty { self.postUnicode(insert) }
        }
    }

    private func postKeyCode(_ keyCode: UInt16) {
        let down = CGEvent(keyboardEventSource: injectSource, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: injectSource, virtualKey: keyCode, keyDown: false)
        tag(down); tag(up)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func postUnicode(_ string: String) {
        var units = Array(string.utf16)
        let down = CGEvent(keyboardEventSource: injectSource, virtualKey: 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: injectSource, virtualKey: 0, keyDown: false)
        down?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        up?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        tag(down); tag(up)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func tag(_ event: CGEvent?) {
        event?.setIntegerValueField(.eventSourceUserData, value: Self.injectedTag)
    }

    // MARK: - Classification

    /// Keys that are punctuation in US-QWERTY but *letters* in Russian ЙЦУКЕН,
    /// so they must count as part of a word rather than a boundary:
    /// х([) ъ(]) ж(;) э(') б(,) ю(.) .(/) ё(`).
    private static let wordPositionKeys: Set<UInt16> = [
        UInt16(kVK_ANSI_LeftBracket), UInt16(kVK_ANSI_RightBracket),
        UInt16(kVK_ANSI_Semicolon), UInt16(kVK_ANSI_Quote),
        UInt16(kVK_ANSI_Comma), UInt16(kVK_ANSI_Period),
        UInt16(kVK_ANSI_Slash), UInt16(kVK_ANSI_Grave)
    ]

    /// Modifiers in the byte layout `UCKeyTranslate` expects (Carbon modifiers
    /// shifted right by 8).
    private static func ucModifierByte(_ flags: CGEventFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.maskShift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.maskAlternate) { carbon |= UInt32(optionKey) }
        if flags.contains(.maskAlphaShift) { carbon |= UInt32(alphaLock) }
        return (carbon >> 8) & 0xFF
    }

    /// Keys that end the current word without being typed into it.
    /// (Return/keypad-Enter are handled explicitly — commit correction.)
    private static let resetKeyCodes: Set<UInt16> = [
        UInt16(kVK_LeftArrow), UInt16(kVK_RightArrow), UInt16(kVK_UpArrow), UInt16(kVK_DownArrow),
        UInt16(kVK_Home), UInt16(kVK_End), UInt16(kVK_PageUp), UInt16(kVK_PageDown),
        UInt16(kVK_Escape), UInt16(kVK_ForwardDelete), UInt16(kVK_Tab)
    ]
}
