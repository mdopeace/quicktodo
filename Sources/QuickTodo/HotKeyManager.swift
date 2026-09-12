import AppKit
import ApplicationServices

// ponytail: NSEvent monitors, not Carbon/RegisterEventHotKey or a hotkey
// pkg — enough for one fixed hotkey; revisit if customization needed.
final class HotKeyManager {
    var onHotKey: (() -> Void)?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    func register() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.matches(event) == true {
                self?.onHotKey?()
                return nil
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.matches(event) == true {
                self?.onHotKey?()
            }
        }
        if globalMonitor == nil {
            // No Accessibility trust → global hotkey silently dead. Prompt once.
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            NSLog("QuickTodo: global hotkey needs Accessibility permission (⌘⌥T works while menu is open regardless)")
        }
    }

    private func matches(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .option]
            && event.charactersIgnoringModifiers?.lowercased() == "t"
    }
}
