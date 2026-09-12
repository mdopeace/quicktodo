import AppKit
import QuickTodoCore
import SwiftUI

extension Notification.Name {
    static let quickTodoMenuWillOpen = Notification.Name("quickTodoMenuWillOpen")
}

// Menu-anchored presentation: real menu tracking gives the system
// highlight pill + keeps the menubar visible in fullscreen for free.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var menu = NSMenu()
    private var menuOpen = false
    private var hotKeys = HotKeyManager()
    private let store = TodoStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menubar-only, no dock icon

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "checklist", accessibilityDescription: "QuickTodo")
        icon?.isTemplate = true
        statusItem.button?.image = icon

        let host = NSHostingView(rootView: TodoView(store: store))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 380)
        let item = NSMenuItem()
        item.view = host
        menu.addItem(item)
        menu.delegate = self
        statusItem.menu = menu

        hotKeys.onHotKey = { [weak self] in self?.toggle() }
        hotKeys.register()
    }

    @objc func toggle() {
        if menuOpen {
            menu.cancelTracking()
        } else {
            statusItem.button?.performClick(nil)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        NotificationCenter.default.post(name: .quickTodoMenuWillOpen, object: nil)
    }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }
}
