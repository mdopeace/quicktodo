import AppKit
import Carbon.HIToolbox

// Pure native shell: NSStatusItem + standard NSMenu. Every row — header,
// sections, separators, footer — is drawn by macOS. No custom views, no
// custom fonts, no hardcoded metrics. Non-interactive rows render dimmed;
// that is standard menu semantics (same as any Apple menu), not styling.
//
// Global hotkey (⌥⌘T) uses Carbon RegisterEventHotKey — no permissions
// required, no sandbox exceptions, no dependencies. On fire, toggles the
// status item menu via NSControl.performClick (public API).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?

    @objc func toggleFromHotKey() {
        statusItem.button?.performClick(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "QuickTodo")
            if button.image == nil {
                button.title = "QuickTodo"
            }
        }
        statusItem.menu = makeMenu()
        registerHotKey()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = 300

        let header = NSMenuItem(title: "QuickTodo", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        menu.addItem(.separator())

        let tasksHeader = NSMenuItem(title: "Tasks", action: nil, keyEquivalent: "")
        tasksHeader.isEnabled = false
        menu.addItem(tasksHeader)

        let empty = NSMenuItem(title: "No todos yet", action: nil, keyEquivalent: "")
        empty.isEnabled = false
        menu.addItem(empty)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit QuickTodo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        return menu
    }

    // MARK: - Global Hotkey (⌥⌘T)

    private func registerHotKey() {
        let hotKeyID = EventHotKeyID(signature: 0x51544F44, id: 1) // "QTOD"
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(), hotKeyHandler, 1,
            [EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                           eventKind: UInt32(kEventHotKeyPressed))],
            Unmanaged.passUnretained(self).toOpaque(), // safe: AppDelegate lives for process lifetime
            nil)
        if handlerStatus != noErr {
            NSLog("InstallEventHandler failed: \(handlerStatus)")
        }
        let hotKeyStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_T),
            UInt32(cmdKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef)
        if hotKeyStatus != noErr {
            NSLog("RegisterEventHotKey failed: \(hotKeyStatus)")
        }
    }
}

private func hotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let self_ = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async { self_.toggleFromHotKey() }
    return noErr
}
