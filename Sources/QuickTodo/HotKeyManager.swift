import AppKit
import Carbon

// System-global hotkey via Carbon: needs no Accessibility permission,
// unlike NSEvent global monitors (which silently die when untrusted).
//
// Lifetime: AppDelegate owns this for the process lifetime; the Carbon
// handler holds self unretained, so don't release early or move ownership.
final class HotKeyManager {
    var onHotKey: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var registered = false

    func register() {
        guard !registered else { return }
        registered = true

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var type = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue().onHotKey?()
                return noErr
            },
            1, &type, selfPtr, &handlerRef
        )
        if installStatus != noErr {
            NSLog("quicktodo: InstallEventHandler failed (%d) — hotkey dead", installStatus)
        }
        // ⌘⌥T
        var hkID = EventHotKeyID(signature: OSType(0x51545444), id: 1) // 'QTTD'
        let hotKeyStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_T), UInt32(cmdKey | optionKey),
            hkID, GetApplicationEventTarget(), 0, &hotKeyRef
        )
        if hotKeyStatus != noErr {
            NSLog("quicktodo: RegisterEventHotKey failed (%d) — ⌘⌥T may be claimed by another app", hotKeyStatus)
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
