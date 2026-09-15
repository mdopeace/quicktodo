import AppKit

// Classic AppKit entry (no SwiftUI App/Scene lifecycle): the app owns no
// scenes, so the system can never open a window for it. Previously the
// `Settings { EmptyView() }` placeholder scene surfaced an empty
// "QuickTodo Settings" window whenever the app was activated
// (e.g. Spotlight/Xcode launch).
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
