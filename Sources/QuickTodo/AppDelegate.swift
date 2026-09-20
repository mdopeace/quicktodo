import AppKit
import Combine
import QuickTodoCore
import ServiceManagement
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
        installMainMenu() // classic entry: no SwiftUI-provided menu, wire Quit ⌘Q ourselves

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

        #if !DEBUG
        registerLaunchAtLogin()
        #endif

        // Start auto-update check on launch (background, non-blocking)
        Updater.shared.checkOnLaunch()
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

        // Check for updates on menu open (debounced: max once per 4h)
        Updater.shared.checkOnMenuOpen()
    }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    // Minimum main menu: with no SwiftUI lifecycle nothing installs the
    // standard app menu, so route Quit ⌘Q ourselves (accessory policy keeps
    // the menu bar hidden; this only restores the key equivalent).
    // Note: .keyboardShortcut on the Quit button is NOT a substitute — key
    // events during menu tracking are matched against menus, never reach
    // the hosted view (verified: shortcut variant never fired).
    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit QuickTodo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
    }

    private func registerLaunchAtLogin() {
        guard SMAppService.mainApp.status != .enabled else { return }

        do {
            try SMAppService.mainApp.register()
        } catch {
            NSLog("quicktodo: launch-at-login registration failed: %@", error.localizedDescription)
        }
    }

    // Hug content: measure the SwiftUI ideal height so short lists leave no void.
    private func layoutMenu() {
        host.frame = NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 1000)
        host.layoutSubtreeIfNeeded()
        let h = min(max(host.fittingSize.height, MenuMetrics.minHeight), MenuMetrics.maxHeight)
        host.frame.size.height = h
        if menuOpen { menu.update() }
    }
}
