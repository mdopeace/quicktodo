import AppKit

// Classic AppKit entry, no SwiftUI App/Scene lifecycle: the app owns no
// scenes, so the system can never open a window for it.
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
