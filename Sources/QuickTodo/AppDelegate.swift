import AppKit
import Combine
import QuickTodoCore
import SwiftUI

extension Notification.Name {
    static let quickTodoMenuWillOpen = Notification.Name("quickTodoMenuWillOpen")
}

// Single source for menu geometry (TodoView references MenuMetrics.width).
enum MenuMetrics {
    static let width: CGFloat = 300
    static let minHeight: CGFloat = 120
    /// ≈ static sections + 220 list (ScrollView maxHeight) + menu insets.
    static let maxHeight: CGFloat = 345
}

// Menu-anchored presentation: real menu tracking gives the system
// highlight pill + keeps the menubar visible in fullscreen for free.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var menu = NSMenu()
    private var menuOpen = false
    private var host: NSHostingView<TodoView>!
    private var cancellables = Set<AnyCancellable>()
    private var hotKeys = HotKeyManager()
    private let store = TodoStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menubar-only, no dock icon

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "checklist", accessibilityDescription: "QuickTodo")
        icon?.isTemplate = true
        statusItem.button?.image = icon

        let host = NSHostingView(rootView: TodoView(store: store))
        self.host = host
        let item = NSMenuItem()
        item.view = host
        menu.addItem(item)
        menu.delegate = self
        statusItem.menu = menu
        layoutMenu() // synchronous initial size; $items replay below is async
        store.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.layoutMenu() }
            .store(in: &cancellables)

        hotKeys.onHotKey = { [weak self] in self?.openMenu() }
        hotKeys.register()
    }

    // Hotkey is open-only (Spotlight-style): closing stays on
    // Escape / click-outside via native menu tracking.
    @objc func openMenu() {
        if !menuOpen {
            statusItem.button?.performClick(nil)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        layoutMenu() // defense: guarantee size before showing
        NotificationCenter.default.post(name: .quickTodoMenuWillOpen, object: nil)
    }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    // Hug content: measure the SwiftUI ideal height so short lists leave no void.
    private func layoutMenu() {
        host.frame = NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 1000)
        host.layoutSubtreeIfNeeded()
        let h = min(max(host.fittingSize.height, MenuMetrics.minHeight), MenuMetrics.maxHeight)
        host.frame.size.height = h
        if menuOpen { menu.update() }
    }
}
