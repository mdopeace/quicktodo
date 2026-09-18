import XCTest
@testable import QuickTodoCore

final class TodoStoreTests: XCTestCase {
    func test_add_toggle_delete() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let store = TodoStore(fileURL: url)
        XCTAssertTrue(store.items.isEmpty)

        store.add("Buy milk")
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items[0].title, "Buy milk")
        XCTAssertFalse(store.items[0].isDone)

        store.toggle(store.items[0].id)
        XCTAssertTrue(store.items[0].isDone)

        // Persistence: new instance loads from same file
        let reloaded = TodoStore(fileURL: url)
        XCTAssertEqual(reloaded.items.count, 1)
        XCTAssertTrue(reloaded.items[0].isDone)

        store.delete(store.items[0].id)
        XCTAssertTrue(store.items.isEmpty)
    }

    func test_newest_first() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let store = TodoStore(fileURL: url)
        store.add("A")
        store.add("B")
        XCTAssertEqual(store.activeByDay.flatMap { $0.items }.map(\.title), ["B", "A"])
    }

    func test_done_sinks_to_bottom() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let store = TodoStore(fileURL: url)
        store.add("A")
        store.add("B")
        store.toggle(store.items[1].id)
        XCTAssertEqual(store.activeByDay.flatMap { $0.items }.map(\.title), ["A"])
        XCTAssertEqual(store.completedItems.map(\.title), ["B"])
    }

    func test_done_oldest_first_at_bottom() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let store = TodoStore(fileURL: url)
        store.add("A")
        store.add("B")
        store.add("C")
        store.toggle(store.items[1].id) // B done
        store.toggle(store.items[2].id) // C done
        XCTAssertEqual(store.activeByDay.flatMap { $0.items }.map(\.title), ["A"])
        XCTAssertEqual(store.completedItems.map(\.title), ["B", "C"])
    }

    func test_blank_title_ignored() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let store = TodoStore(fileURL: url)
        store.add("   ")
        XCTAssertTrue(store.items.isEmpty)
    }

    func test_corrupt_file_backed_up_not_overwritten() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        try "not-json{{{".write(to: url, atomically: true, encoding: .utf8)

        let store = TodoStore(fileURL: url)
        XCTAssertTrue(store.items.isEmpty)

        // Original moved aside, not silently clobbered…
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let dir = url.deletingLastPathComponent()
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(url.lastPathComponent) && $0.contains("corrupt-") }
        XCTAssertEqual(backups.count, 1)

        // …and a subsequent save writes a fresh valid store, backup untouched.
        store.add("Fresh start")
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(url.lastPathComponent) && $0.contains("corrupt-") }.count, 1)
        let reloaded = TodoStore(fileURL: url)
        XCTAssertEqual(reloaded.items.map(\.title), ["Fresh start"])
    }

    func test_add_sets_createdAt() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let store = TodoStore(fileURL: url)
        let before = Date()
        store.add("Dated")
        let after = Date()
        XCTAssertGreaterThanOrEqual(store.items[0].createdAt, before)
        XCTAssertLessThanOrEqual(store.items[0].createdAt, after)
    }

    func test_legacy_json_without_createdAt_backfills_to_today() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        try #"[{"id":"00000000-0000-0000-0000-000000000001","title":"Legacy","isDone":false}]"#
            .write(to: url, atomically: true, encoding: .utf8)
        let store = TodoStore(fileURL: url)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertTrue(Calendar.current.isDateInToday(store.items[0].createdAt))
        XCTAssertEqual(store.activeByDay.count, 1)
        XCTAssertEqual(TodoStore.dayLabel(for: store.activeByDay[0].day), "Today")
    }

    func test_active_grouped_by_day_newest_day_first() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let store = TodoStore(fileURL: url)
        let cal = Calendar.current
        let today = Date()
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let older = cal.date(byAdding: .day, value: -5, to: today)!
        store.add("Today A", createdAt: today)
        store.add("Old", createdAt: older)
        store.add("Yesterday", createdAt: yesterday)
        store.add("Today B", createdAt: today)
        let groups = store.activeByDay
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.map { TodoStore.dayLabel(for: $0.day) }[0], "Today")
        XCTAssertEqual(groups.map { TodoStore.dayLabel(for: $0.day) }[1], "Yesterday")
        // Newest-first within a day
        XCTAssertEqual(groups[0].items.map(\.title), ["Today B", "Today A"])
    }

    func test_completed_collapsed_oldest_first() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let store = TodoStore(fileURL: url)
        store.add("A")
        store.add("B")
        store.add("C")
        store.toggle(store.items[1].id) // B done
        store.toggle(store.items[2].id) // C done
        XCTAssertEqual(store.completedItems.map(\.title), ["B", "C"])
        XCTAssertTrue(store.activeByDay.flatMap { $0.items }.map(\.title) == ["A"])
    }

    func test_completed_splits_recent_and_older_than_week() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let store = TodoStore(fileURL: url)
        let cal = Calendar.current
        let now = Date()
        let old = cal.date(byAdding: .day, value: -8, to: now)!
        store.add("Recent", createdAt: now)
        store.add("Old", createdAt: old)
        store.toggle(store.items[0].id)
        store.toggle(store.items[1].id)
        XCTAssertEqual(store.recentCompletedItems.map(\.title), ["Recent"])
        XCTAssertEqual(store.olderCompletedItems.map(\.title), ["Old"])
    }

    func test_dayLabel_formats_older_dates() throws {
        let cal = Calendar.current
        let today = Date()
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        XCTAssertEqual(TodoStore.dayLabel(for: today), "Today")
        XCTAssertEqual(TodoStore.dayLabel(for: yesterday), "Yesterday")
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 8
        comps.day = 13
        let date = cal.date(from: comps)!
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "EEE, MMM d, yyyy"
        XCTAssertEqual(TodoStore.dayLabel(for: date), fmt.string(from: date))
        XCTAssertEqual(TodoStore.dayLabel(for: date), "Thu, Aug 13, 2026")
    }
}
