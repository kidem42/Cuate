import SwiftUI
import AppKit
import Carbon

/// Row with a shortcut "recorder" button: click → press the new combination
/// (must include ⌘, ⌃ or ⌥) → saved. Esc cancels recording.
struct ShortcutRecorderView: View {
    let title: String
    @Binding var combo: HotkeyCombo
    /// Combos this one must not collide with (the other actions' shortcuts).
    var conflictingCombos: [HotkeyCombo] = []

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                Text(isRecording ? "Press keys… (⎋ to cancel)" : combo.displayString)
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 120)
            }
            .tint(isRecording ? .accentColor : nil)
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        isRecording = true
        hint = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Esc cancels
            if event.keyCode == UInt16(kVK_Escape), event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                stopRecording()
                return nil
            }

            let carbonModifiers = Self.carbonModifiers(from: event.modifierFlags)
            // Require a real chord — at least ⌘, ⌃ or ⌥ (plain/⇧-only keys would
            // fire while typing in other apps).
            guard carbonModifiers & UInt32(cmdKey | controlKey | optionKey) != 0 else {
                hint = "Add ⌘, ⌃ or ⌥"
                return nil
            }

            let newCombo = HotkeyCombo(keyCode: UInt32(event.keyCode), modifiers: carbonModifiers)
            if conflictingCombos.contains(newCombo) {
                hint = "Already used by another action"
                NSSound.beep()
                return nil
            }

            combo = newCombo
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }
}
