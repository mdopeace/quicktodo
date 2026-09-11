import SwiftUI

// .menu style (not .window): the click opens a genuine menu presented by the
// system in a menu-tracking session. Tracking pins the menu bar visible —
// including under "Automatically hide and show the menu bar" — exactly like
// Battery / Wi-Fi / Ollama (AppKit NSStatusItem + NSMenu, verified in the
// Ollama binary: NSMenu + setMenu, no panels). .window is a popover-like
// window in our process: no tracking, so an auto-hiding bar hides.
@main
struct QuickTodoApp: App {
    var body: some Scene {
        MenuBarExtra("QuickTodo", systemImage: "checklist") {
            ContentView()
        }
        .menuBarExtraStyle(.menu)
    }
}
