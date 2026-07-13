import Cocoa
import Carbon
import Foundation
import CoreServices

final class HotkeyManager {
    struct Hotkey {
        let identifier: UInt32
        let keyCode: UInt32
        let modifiers: UInt32
        let handler: () -> Void
    }

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var eventHandlerRef: EventHandlerRef?

    init(hotkeys: [Hotkey]) {
        installEventHandler()
        hotkeys.forEach { register($0) }
    }

    deinit {
        for ref in hotKeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, userData) -> OSStatus in
                guard let userData else {
                    return OSStatus(eventNotHandledErr)
                }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard status == noErr else {
                    return OSStatus(eventNotHandledErr)
                }

                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                if let handler = manager.handlers[hotKeyID.id] {
                    handler()
                    return OSStatus(noErr)
                }
                return OSStatus(eventNotHandledErr)
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
    }

    private func register(_ hotkey: Hotkey) {
        // Create a 4-character OSType signature directly instead of using deprecated UTGetOSTypeFromString
        let signature: OSType = (UInt32(UInt8(ascii: "h")) << 24) |
                                (UInt32(UInt8(ascii: "t")) << 16) |
                                (UInt32(UInt8(ascii: "k")) << 8) |
                                UInt32(UInt8(ascii: "1"))
        let hotKeyId = EventHotKeyID(signature: signature, id: hotkey.identifier)
        var hotKeyRef: EventHotKeyRef?

        let status = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.modifiers,
            hotKeyId,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr, let hotKeyRef else {
            NSLog("Failed to register hotkey id: \(hotkey.identifier), status: \(status)")
            return
        }

        hotKeyRefs[hotkey.identifier] = hotKeyRef
        handlers[hotkey.identifier] = hotkey.handler
    }
}
