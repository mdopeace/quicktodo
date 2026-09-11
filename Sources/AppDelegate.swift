import AppKit

// Pure native shell: NSStatusItem + standard NSMenu. Every row — header,
// sections, separators, footer — is drawn by macOS. No custom views, no
// custom fonts, no hardcoded metrics. Non-interactive rows render dimmed;
// that is standard menu semantics (same as any Apple menu), not styling.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "QuickTodo")
            if button.image == nil {
                button.title = "QuickTodo"
            }
        }
        statusItem.menu = makeMenu()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

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
}
