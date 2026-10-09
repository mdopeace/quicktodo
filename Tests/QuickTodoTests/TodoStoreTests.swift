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

        // Persistence: a new instance loads from the same file.
        let reloaded = TodoStore(fileURL: url)
        XCTAssertEqual(reloaded.items.count, 1)
        XCTAssertTrue(reloaded.items[0].isDone)
        XCTAssertEqual(reloaded.items[0].updatedAt, store.items[0].updatedAt)

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

    func test_done_leaves_active_list() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let store = TodoStore(fileURL: url)
        store.add("A")
        store.add("B")
        store.toggle(store.items[1].id)
        XCTAssertEqual(store.activeByDay.flatMap { $0.items }.map(\.title), ["A"])
        XCTAssertEqual(store.recentCompletedItems.map(\.title), ["B"])
    }

    func test_done_newest_first_at_top() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let store = TodoStore(fileURL: url)
        let base = Date()
        store.add("A")
        store.add("B")
        store.add("C")
        store.toggle(store.items[1].id, updatedAt: base)
        store.toggle(store.items[2].id, updatedAt: base.addingTimeInterval(60))
        XCTAssertEqual(store.activeByDay.flatMap { $0.items }.map(\.title), ["A"])
        XCTAssertEqual(store.recentCompletedItems.map(\.title), ["C", "B"])
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

        // Moved aside, not clobbered…
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let dir = url.deletingLastPathComponent()
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(url.lastPathComponent) && $0.contains("corrupt-") }
        XCTAssertEqual(backups.count, 1)

        // …and a later save writes a fresh store, backup untouched.
        store.add("Fresh start")
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(url.lastPathComponent) && $0.contains("corrupt-") }.count, 1)
        let reloaded = TodoStore(fileURL: url)
        XCTAssertEqual(reloaded.items.map(\.title), ["Fresh start"])
    }

    func test_adopts_sandboxed_store_only_when_missing() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let live = tmp.appendingPathComponent("todos.json")
        let legacy = tmp.appendingPathComponent("sandboxed.json")
        try "from-container".write(to: legacy, atomically: true, encoding: .utf8)

        // No local file → seed from the container.
        TodoStore.adoptSandboxedStore(into: live, container: legacy)
        XCTAssertEqual(try String(contentsOf: live, encoding: .utf8), "from-container")

        // Both exist → never overwrite, the user decides.
        try "from-app-support".write(to: live, atomically: true, encoding: .utf8)
        TodoStore.adoptSandboxedStore(into: live, container: legacy)
        XCTAssertEqual(try String(contentsOf: live, encoding: .utf8), "from-app-support")

        // No container at all → create nothing, don't fail.
        let fresh = tmp.appendingPathComponent("fresh.json")
        TodoStore.adoptSandboxedStore(into: fresh, container: tmp.appendingPathComponent("nope.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
    }

    func test_add_sets_timestamps() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let store = TodoStore(fileURL: url)
        let before = Date()
        store.add("Dated")
        let after = Date()
        XCTAssertGreaterThanOrEqual(store.items[0].createdAt, before)
        XCTAssertLessThanOrEqual(store.items[0].createdAt, after)
        XCTAssertGreaterThanOrEqual(store.items[0].updatedAt, before)
        XCTAssertLessThanOrEqual(store.items[0].updatedAt, after)
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

    func test_legacy_json_without_updatedAt_backfills_from_createdAt() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        // 721692800 is 2023-11-14 in JSONDecoder's reference date.
        try #"[{"id":"00000000-0000-0000-0000-000000000001","title":"Legacy","isDone":true,"createdAt":721692800}]"#
            .write(to: url, atomically: true, encoding: .utf8)
        let store = TodoStore(fileURL: url)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items[0].updatedAt, store.items[0].createdAt)
        XCTAssertFalse(Calendar.current.isDateInToday(store.items[0].updatedAt))
        XCTAssertEqual(store.olderCompletedItems.map(\.title), ["Legacy"])
    }

    func test_active_grouped_by_day_newest_day_first() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let store = TodoStore(fileURL: url)
        let cal = Calendar.current
        // Noon keeps the +60s item inside today, so the intra-day ordering assertion
        // can't drift across midnight.
        let today = cal.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        let todayLater = today.addingTimeInterval(60)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let older = cal.date(byAdding: .day, value: -5, to: today)!
        store.add("Today A", updatedAt: today)
        store.add("Old", updatedAt: older)
        store.add("Yesterday", updatedAt: yesterday)
        store.add("Today B", updatedAt: todayLater)
        let groups = store.activeByDay
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.map { TodoStore.dayLabel(for: $0.day) }[0], "Today")
        XCTAssertEqual(groups.map { TodoStore.dayLabel(for: $0.day) }[1], "Yesterday")
        // Newest updatedAt first within a day
        XCTAssertEqual(groups[0].items.map(\.title), ["Today B", "Today A"])
    }

    func test_active_ties_break_to_newest_inserted() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let store = TodoStore(fileURL: url)
        let day = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        store.add("A", createdAt: day)
        store.add("B", createdAt: day)
        XCTAssertEqual(store.activeByDay.flatMap { $0.items }.map(\.title), ["B", "A"])
    }

    func test_completed_sorted_newest_updated_first() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let store = TodoStore(fileURL: url)
        let base = Date()
        store.add("A")
        store.add("B")
        store.add("C")
        store.toggle(store.items[1].id, updatedAt: base)
        store.toggle(store.items[2].id, updatedAt: base.addingTimeInterval(60))
        XCTAssertEqual(store.recentCompletedItems.map(\.title), ["C", "B"])
        XCTAssertTrue(store.activeByDay.flatMap { $0.items }.map(\.title) == ["A"])
    }

    func test_completed_splits_recent_and_older_than_week() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let store = TodoStore(fileURL: url)
        let cal = Calendar.current
        let now = Date()
        let old = cal.date(byAdding: .day, value: -8, to: now)!
        store.add("Recent", updatedAt: now)
        store.add("Old", updatedAt: now)
        store.toggle(store.items[0].id, updatedAt: now)
        store.toggle(store.items[1].id, updatedAt: old)
        XCTAssertEqual(store.recentCompletedItems.map(\.title), ["Recent"])
        XCTAssertEqual(store.olderCompletedItems.map(\.title), ["Old"])
    }

    func test_toggle_bumps_updatedAt_in_both_directions() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let store = TodoStore(fileURL: url)
        store.add("T", updatedAt: Date(timeIntervalSince1970: 0))
        let id = store.items[0].id
        XCTAssertFalse(store.items[0].isDone)

        store.toggle(id, updatedAt: Date(timeIntervalSince1970: 100))
        XCTAssertTrue(store.items[0].isDone)
        XCTAssertEqual(store.items[0].updatedAt, Date(timeIntervalSince1970: 100))

        store.toggle(id, updatedAt: Date(timeIntervalSince1970: 200))
        XCTAssertFalse(store.items[0].isDone)
        XCTAssertEqual(store.items[0].updatedAt, Date(timeIntervalSince1970: 200))
    }

    func test_untoggle_returns_item_to_todays_active_list() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let store = TodoStore(fileURL: url)
        let old = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        store.add("Resurrected", updatedAt: old)
        store.toggle(store.items[0].id, updatedAt: old)
        XCTAssertEqual(store.olderCompletedItems.map(\.title), ["Resurrected"])
        XCTAssertTrue(store.activeByDay.isEmpty)

        store.toggle(store.items[0].id)
        XCTAssertFalse(store.items[0].isDone)
        XCTAssertEqual(store.activeByDay.count, 1)
        XCTAssertEqual(TodoStore.dayLabel(for: store.activeByDay[0].day), "Today")
        XCTAssertTrue(store.olderCompletedItems.isEmpty)
    }

    func test_search_query_needs_three_characters() throws {
        XCTAssertNil(TodoStore.searchQuery(""))
        XCTAssertNil(TodoStore.searchQuery("B"))
        XCTAssertNil(TodoStore.searchQuery("Bu"))
        XCTAssertEqual(TodoStore.searchQuery("Buy"), "Buy")
        // Verbatim; case folding happens at match time.
        XCTAssertEqual(TodoStore.searchQuery("bUY"), "bUY")
    }

    func test_search_query_trims_before_counting() throws {
        // A trailing space must not consume a character of the floor.
        XCTAssertEqual(TodoStore.searchQuery("Buy "), "Buy")
        XCTAssertNil(TodoStore.searchQuery("Bu "))
        XCTAssertNil(TodoStore.searchQuery("   "))
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

    func test_compact_renders_compact_notation() throws {
        // Only catches the locale pin being dropped, where the system locale spells
        // numbers differently (en_IN: 1_000_000 -> "10L"). Locale.current is
        // read-only, so a test can't force the case.
        XCTAssertEqual(TodoStore.compact(0), "0")
        XCTAssertEqual(TodoStore.compact(999), "999")
        XCTAssertEqual(TodoStore.compact(1000), "1K")
        XCTAssertEqual(TodoStore.compact(1500), "1.5K")
        XCTAssertEqual(TodoStore.compact(999_999), "1M")
        XCTAssertEqual(TodoStore.compact(1_000_000), "1M")
        XCTAssertEqual(TodoStore.compact(2_300_000), "2.3M")
    }

    func test_bulk_delete_removes_only_given_ids() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let store = TodoStore(fileURL: url)
        let now = Date()
        let old = Calendar.current.date(byAdding: .day, value: -8, to: now)!
        store.add("Recent done", updatedAt: now)
        let recentID = store.items[0].id
        store.add("Old done", updatedAt: now)
        let oldID = store.items[1].id
        store.add("Active", updatedAt: now)
        store.toggle(recentID, updatedAt: now)
        store.toggle(oldID, updatedAt: old)

        store.delete(ids: [recentID])

        // Only the named id goes. Asserted by title: id sets from post-delete `items`
        // would hold whatever is left either way.
        XCTAssertEqual(store.items.map(\.title), ["Old done", "Active"])
        XCTAssertFalse(store.items.contains { $0.id == recentID })
        XCTAssertEqual(store.recentCompletedItems.map(\.title), [])
        XCTAssertEqual(store.olderCompletedItems.map(\.title), ["Old done"])
        XCTAssertEqual(store.activeByDay.flatMap(\.items).map(\.title), ["Active"])

        // Persisted, not just held in memory.
        let reloaded = TodoStore(fileURL: url)
        XCTAssertEqual(reloaded.items.map(\.title), ["Old done", "Active"])

        // No ids is a no-op, not an empty write.
        store.delete(ids: [])
        XCTAssertEqual(store.items.count, 2)
    }
}
