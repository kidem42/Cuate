import AppKit
import Carbon

/// System-aware keyboard-layout engine.
///
/// Instead of a hardcoded RU↔EN table, this reads the *actual keyboard layouts
/// installed & enabled in macOS* (Text Input Source Services) and converts text
/// by re-rendering the physically-pressed key codes through another layout's own
/// data via `UCKeyTranslate`. Any layout the user has enabled — Russian, US,
/// Spanish ISO, … — is supported for free, and switching the active layout uses
/// the same OS API the menu-bar language picker does.
final class SystemLayoutEngine {

    /// A single enabled keyboard layout (not an IME) plus everything needed to
    /// render key codes through it.
    struct Layout {
        let source: TISInputSource
        let id: String
        let localizedName: String
        let languages: [String]
        let uchr: Data
    }

    // MARK: - Enumeration

    /// All enabled keyboard *layouts* (input methods / IMEs are skipped: they
    /// have no `uchr` data to translate through).
    func enabledKeyboardLayouts() -> [Layout] {
        guard let unmanaged = TISCreateInputSourceList(nil, false) else { return [] }
        let cfList = unmanaged.takeRetainedValue()
        let count = CFArrayGetCount(cfList)
        var result: [Layout] = []
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(cfList, i) else { continue }
            let source = unsafeBitCast(raw, to: TISInputSource.self)
            if let layout = makeLayout(from: source) {
                result.append(layout)
            }
        }
        return result
    }

    /// The layout backing the current input source (for an IME this resolves to
    /// its underlying keyboard layout, so we always get renderable `uchr` data).
    func currentLayout() -> Layout? {
        guard let unmanaged = TISCopyCurrentKeyboardLayoutInputSource() else { return nil }
        return makeLayout(from: unmanaged.takeRetainedValue())
    }

    private func makeLayout(from source: TISInputSource) -> Layout? {
        guard boolProperty(source, kTISPropertyInputSourceIsSelectCapable),
              let uchr = dataProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let id = stringProperty(source, kTISPropertyInputSourceID) ?? "unknown"
        let name = stringProperty(source, kTISPropertyLocalizedName) ?? id
        let langs = arrayProperty(source, kTISPropertyInputSourceLanguages)
        return Layout(source: source, id: id, localizedName: name, languages: langs, uchr: uchr)
    }

    // MARK: - Conversion

    /// Re-renders a sequence of `(keyCode, UCKeyTranslate-modifier-byte)` presses
    /// through the given layout — i.e. "what would these physical keystrokes have
    /// typed on that layout". Dead keys are resolved immediately (no accents left
    /// pending) so a whole word converts cleanly.
    func render(keyStrokes: [(keyCode: UInt16, modifierByte: UInt32)], using layout: Layout) -> String {
        var output = ""
        var deadKeyState: UInt32 = 0
        let keyboardType = UInt32(LMGetKbdType())

        layout.uchr.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for stroke in keyStrokes {
                var chars = [UniChar](repeating: 0, count: 8)
                var actualLength = 0
                let status = UCKeyTranslate(
                    base,
                    stroke.keyCode,
                    UInt16(kUCKeyActionDown),
                    stroke.modifierByte,
                    keyboardType,
                    OptionBits(kUCKeyTranslateNoDeadKeysMask),
                    &deadKeyState,
                    chars.count,
                    &actualLength,
                    &chars
                )
                if status == noErr, actualLength > 0 {
                    output.append(String(utf16CodeUnits: chars, count: actualLength))
                }
            }
        }
        return output
    }

    /// Makes the given layout the active system input source. Best-effort.
    func select(_ layout: Layout) {
        TISSelectInputSource(layout.source)
    }

    // MARK: - TIS property helpers

    private func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    private func dataProperty(_ source: TISInputSource, _ key: CFString) -> Data? {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
    }

    private func arrayProperty(_ source: TISInputSource, _ key: CFString) -> [String] {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return [] }
        let cfArray = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue()
        return (cfArray as? [String]) ?? []
    }

    private func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue())
    }
}
