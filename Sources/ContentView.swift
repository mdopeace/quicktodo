import SwiftUI

// Menu anatomy mirrors the Battery panel 1:1 — section header, rows,
// separator, footer action. No custom metrics: the system draws separators,
// insets, type, and hover selection, so there is nothing to drift.
struct ContentView: View {
    var body: some View {
        Section("QuickTodo") {
            Text("No todos yet")
        }
        Divider()
        Button("Quit QuickTodo") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
