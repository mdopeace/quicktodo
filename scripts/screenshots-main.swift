// Drives TodoView through AppKit to produce the screenshots used by
// docs/index.html. Compiled straight into the app's own sources by
// scripts/screenshots.sh, so it sees the real MenuMetrics and the real view.
//
// States that live in TodoView's @State (search text, hover, expanded rows)
// can't be reached from here, so TodoView's init takes them as parameters and
// every shot is varied purely by todo data.

import SwiftUI
import AppKit
import QuickTodoCore

@main
struct Screenshots {
    @MainActor
    static func main() {
        // AppKit needs a live app object before it will draw, and the window
        // has to be styled explicitly or the NSView-backed pieces (the text
        // field) come out in the wrong appearance.
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.prohibited)

        let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try! FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        for shot in Shot.allCases {
            // Updater is a singleton, so its state has to be set every time or
            // the update-available arrow leaks into every later shot.
            Updater.shared.setStateForScreenshots(shot == .update ? .available : .idle)
            let store = makeStore(shot)
            let view = TodoView(
                store: store,
                hovered: shot == .hover ? RowID.hoverMe : nil,
                searchText: shot == .search ? Shot.searchQuery : "",
                editingRow: shot == .edit ? RowID.editingMe : nil
            )
            .environment(\.colorScheme, .dark)
            // Pinned, not .windowBackgroundColor: that shifts between macOS
            // releases and silently rewrites every shot. Calibrated, not Color(white:),
            // which renders this value noticeably darker.
            .background(Color(nsColor: NSColor(calibratedWhite: 23.0 / 255.0, alpha: 1)))
            let size = fittedSize(of: view)
            capture(view.frame(width: size.width, height: size.height),
                    to: outDir.appendingPathComponent("\(shot.rawValue).png"))
            print("\(shot.rawValue).png  \(Int(size.width))x\(Int(size.height))")
        }
    }

    enum Shot: String, CaseIterable {
        case today, overdue, completed, empty, hover, update, search, edit

        /// Must be 3+ characters or TodoStore.searchQuery rejects it, and must match
        /// a strict subset of the todos below or the filter shows no change.
        static let searchQuery = "call"
    }

    /// Fixed so a shot can hover or edit one specific row: the driver writes these
    /// ids into the seeded JSON, then hands the same UUIDs to TodoView.
    enum RowID {
        static let hoverMe = UUID(uuidString: "1B7F4C2A-0000-4000-8000-000000000001")!
        static let editingMe = UUID(uuidString: "1B7F4C2A-0000-4000-8000-000000000002")!
    }

    /// Mirrors AppDelegate.layoutMenu(): fixed width, content height clamped.
    @MainActor
    static func fittedSize(of view: some View) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 1000)
        host.layoutSubtreeIfNeeded()
        let h = min(max(host.fittingSize.height, MenuMetrics.minHeight), MenuMetrics.maxHeight)
        return CGSize(width: MenuMetrics.width, height: h)
    }

    /// ImageRenderer draws SwiftUI fine but renders NSTextField (the add/search
    /// box) as AppKit's missing-image placeholder, so the view is hosted in an
    /// offscreen window and captured through AppKit's own drawing path instead.
    @MainActor
    static func capture(_ view: some View, to url: URL) {
        let host = NSHostingView(rootView: view)
        // Hosted in an NSMenuItem, the way AppDelegate does it: controls inside
        // a menu get different metrics from the same view in a plain window, and
        // that difference is visible on the add button's height.
        let menu = NSMenu()
        let item = NSMenuItem()
        item.view = host
        menu.addItem(item)
        // Measure at a tall frame, then shrink to the content height, exactly as
        // layoutMenu() does. Without the resize the view stays bottom-aligned in
        // the 1000pt frame and the capture comes out mostly empty.
        host.frame = NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 1000)
        host.layoutSubtreeIfNeeded()
        let fitted = min(max(host.fittingSize.height, MenuMetrics.minHeight), MenuMetrics.maxHeight)
        host.frame = NSRect(x: 0, y: 0, width: MenuMetrics.width, height: fitted)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            fatalError("no bitmap rep: \(url.lastPathComponent)")
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            fatalError("no png: \(url.lastPathComponent)")
        }
        try! png.write(to: url)
    }

    // MARK: - Data
    //
    // Written as JSON rather than constructed as TodoItem values: the struct's
    // memberwise init is internal to QuickTodoCore. Dates go in as
    // timeIntervalSinceReferenceDate because TodoStore decodes with a default
    // JSONDecoder, and `order` is set explicitly so rows land in the order
    // listed here rather than by recency.

    @MainActor
    static func makeStore(_ shot: Shot) -> TodoStore {
        let cal = Calendar.current
        func at(daysAgo: Int, hour: Int) -> Date {
            let day = cal.date(byAdding: .day, value: -daysAgo, to: Date())!
            return cal.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        }

        var items: [[String: Any]] = []
        func add(_ title: String, done: Bool = false, daysAgo: Int, hour: Int,
                 repeatRule: Repeat? = nil, id: UUID? = nil) {
            let when = at(daysAgo: daysAgo, hour: hour).timeIntervalSinceReferenceDate
            var item: [String: Any] = [
                "title": title,
                "isDone": done,
                "createdAt": when,
                "updatedAt": when,
                "order": items.count,
            ]
            if let repeatRule { item["repeatRule"] = repeatRule.rawValue }
            // Only the hovered and edited rows need a known id; the rest are
            // decoded with fresh UUIDs by TodoStore.
            if let id { item["id"] = id.uuidString }
            items.append(item)
        }

        switch shot {
        case .today:
            add("Reply to the lease renewal", daysAgo: 0, hour: 9)
            add("Book the dentist", daysAgo: 0, hour: 11, repeatRule: .daily)
            add("Renew the gym membership before it lapses", daysAgo: 0, hour: 14)
            add("Water the plants", daysAgo: 0, hour: 16, repeatRule: .weekly)

        case .overdue:
            add("Pay the electricity bill", daysAgo: 3, hour: 10)
            add("Return the library books", daysAgo: 1, hour: 17)
            add("Call the mechanic back about the noise", daysAgo: 0, hour: 9)
            add("Pick up the dry cleaning", daysAgo: 0, hour: 12)

        case .completed:
            add("Finish the quarterly report", done: true, daysAgo: 0, hour: 8)
            add("Send the invoice", done: true, daysAgo: 0, hour: 9)
            add("Fix the leaky tap", done: true, daysAgo: 12, hour: 15)
            add("File the tax paperwork", daysAgo: 0, hour: 10)
            add("Charge the laptop", daysAgo: 0, hour: 11)

        case .hover:
            // Yesterday + repeating, so the hovered row lights up both the
            // move-to-today arrow and the tinted repeat button at once.
            add("Take the car for a service", daysAgo: 1, hour: 9,
                repeatRule: .weekly, id: RowID.hoverMe)
            add("Call the mechanic back", daysAgo: 0, hour: 11)
            add("Check the tyre pressure", daysAgo: 0, hour: 15, repeatRule: .daily)

        case .search:
            // Only two of the five titles contain the query, so the drop from
            // five rows to two is visible.
            add("Book the dentist", daysAgo: 0, hour: 9)
            add("Call the plumber", daysAgo: 0, hour: 11)
            add("Call the electrician", daysAgo: 0, hour: 13)
            add("Water the plants", daysAgo: 0, hour: 14)
            add("Pay the electricity bill", daysAgo: 0, hour: 16)

        case .update:
            add("Reply to the lease renewal", daysAgo: 0, hour: 9)
            add("Book the dentist", daysAgo: 0, hour: 11, repeatRule: .daily)
            add("Water the plants", daysAgo: 0, hour: 16, repeatRule: .weekly)

        case .edit:
            // The edited row is second, so the pencil's neighbours stay visible and
            // the row below doesn't move — the field swaps the title in place.
            add("Reply to the lease renewal", daysAgo: 0, hour: 9)
            add("Renew the gym membership before it lapses", daysAgo: 0, hour: 11,
                id: RowID.editingMe)
            add("Book the dentist", daysAgo: 0, hour: 14, repeatRule: .daily)

        case .empty:
            break
        }

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quicktodo-shots-\(shot.rawValue).json")
        try! JSONSerialization.data(withJSONObject: items).write(to: tmp)
        return TodoStore(fileURL: tmp)
    }
}
