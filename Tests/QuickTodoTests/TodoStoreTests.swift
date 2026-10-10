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
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: dir.path)
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
        TodoStore.adoptSandboxedStore(
            into: fresh, container: tmp.appendingPathComponent("nope.json"))
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
        try
            #"[{"id":"00000000-0000-0000-0000-000000000001","title":"Legacy","isDone":true,"createdAt":721692800}]"#
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

    // MARK: - Manual reorder

    /// Same-day todos stamped noon so assertions can't drift across midnight.
    private func storeWithThreeToday() -> (TodoStore, URL, [UUID]) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let store = TodoStore(fileURL: url)
        let noon = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        store.add("A", createdAt: noon, updatedAt: noon)
        store.add("B", createdAt: noon, updatedAt: noon.addingTimeInterval(60))
        store.add("C", createdAt: noon, updatedAt: noon.addingTimeInterval(120))
        return (store, url, store.items.map(\.id))
    }

    func test_unreordered_list_still_falls_back_to_recency() throws {
        let (store, _, _) = storeWithThreeToday()
        XCTAssertNil(store.items[0].order)
        XCTAssertEqual(store.activeByDay.flatMap(\.items).map(\.title), ["C", "B", "A"])
    }

    func test_move_beats_recency_and_persists() throws {
        let (store, url, ids) = storeWithThreeToday()
        // A is the oldest, so recency puts it last; a drag to the top wins.
        store.move(ids[0], to: 0)
        XCTAssertEqual(store.activeByDay.flatMap(\.items).map(\.title), ["A", "C", "B"])
        // Renumbered densely, not left as a single 0.
        XCTAssertEqual(store.items.map(\.order), [0, 2, 1])

        let reloaded = TodoStore(fileURL: url)
        XCTAssertEqual(reloaded.activeByDay.flatMap(\.items).map(\.title), ["A", "C", "B"])
    }

    func test_move_down_indexes_after_lifting_out() throws {
        let (store, _, ids) = storeWithThreeToday()
        // Visual order is C, B, A. Index 1 is B, but lifting A out leaves C, B.
        store.move(ids[0], to: 1)
        XCTAssertEqual(store.activeByDay.flatMap(\.items).map(\.title), ["C", "A", "B"])
    }

    func test_move_out_of_range_clamps() throws {
        let (store, _, ids) = storeWithThreeToday()
        // `to` is a slot in the section after C is lifted out, so 99 clamps to 2.
        store.move(ids[2], to: 99)
        XCTAssertEqual(store.activeByDay.flatMap(\.items).map(\.title), ["B", "A", "C"])

        // Now C sits last, and -5 clamps to 0, the top.
        store.move(ids[2], to: -5)
        XCTAssertEqual(store.activeByDay.flatMap(\.items).map(\.title), ["C", "B", "A"])
    }

    func test_move_to_current_position_is_not_a_write() throws {
        let (store, _, ids) = storeWithThreeToday()
        store.move(ids[0], to: 2)  // A already sits last
        XCTAssertTrue(store.items.allSatisfy { $0.order == nil })
        XCTAssertEqual(store.activeByDay.flatMap(\.items).map(\.title), ["C", "B", "A"])
    }

    func test_new_todo_lands_above_a_reordered_section() throws {
        let (store, _, ids) = storeWithThreeToday()
        store.move(ids[0], to: 0)
        XCTAssertEqual(store.activeByDay.flatMap(\.items).map(\.title), ["A", "C", "B"])

        let noon = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        store.add("Fresh", createdAt: noon, updatedAt: noon.addingTimeInterval(180))
        XCTAssertEqual(store.activeByDay.flatMap(\.items).map(\.title), ["Fresh", "A", "C", "B"])
    }

    func test_toggle_clears_manual_order() throws {
        let (store, _, ids) = storeWithThreeToday()
        store.move(ids[0], to: 0)
        XCTAssertEqual(store.items[0].order, 0)

        store.toggle(ids[0], updatedAt: Date())
        XCTAssertNil(store.items[0].order)
        // Untoggling returns it to the top of Today, as recency already did.
        store.toggle(ids[0], updatedAt: Date().addingTimeInterval(60))
        XCTAssertFalse(store.items[0].isDone)
        XCTAssertTrue(
            store.activeByDay.flatMap(\.items).first.map(\.id) == ids[0],
            "untoggled item should return to the top of its day")
    }

    func test_move_ignores_done_items_and_other_days() throws {
        let cal = Calendar.current
        let noon = cal.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        let yesterday = cal.date(byAdding: .day, value: -1, to: noon)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let store = TodoStore(fileURL: url)
        store.add("Today 1", createdAt: noon, updatedAt: noon)
        store.add("Today 2", createdAt: noon, updatedAt: noon.addingTimeInterval(60))
        store.add("Yesterday", createdAt: yesterday, updatedAt: yesterday)
        store.toggle(store.items[0].id, updatedAt: noon)

        // A completed row has no day section, so it never moves.
        store.move(store.items[0].id, to: 0)
        XCTAssertNil(store.items[0].order)
        XCTAssertEqual(
            store.activeByDay.first { $0.day == cal.startOfDay(for: noon) }?.items.map(\.title),
            ["Today 2"])

        // Reordering Today leaves Yesterday's section untouched.
        store.move(store.items[1].id, to: 0)
        XCTAssertEqual(
            store.activeByDay.first { $0.day == cal.startOfDay(for: noon) }?.items.map(\.title),
            ["Today 2"])
        let otherDay = store.activeByDay.first { $0.day == cal.startOfDay(for: yesterday) }
        XCTAssertEqual(otherDay?.items.map(\.title), ["Yesterday"])
    }

    func test_legacy_json_without_order_decodes_as_unreordered() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        try #"[{"id":"00000000-0000-0000-0000-000000000001","title":"Legacy","isDone":false}]"#
            .write(to: url, atomically: true, encoding: .utf8)
        let store = TodoStore(fileURL: url)
        XCTAssertNil(store.items[0].order)
        XCTAssertEqual(store.activeByDay.flatMap(\.items).map(\.title), ["Legacy"])
    }

    // MARK: - Repeat

    /// One noon-today task already carrying `rule`.
    private func storeWithRepeating(
        _ rule: Repeat
    ) throws -> (store: TodoStore, id: UUID, url: URL) {
        let cal = Calendar.current
        let noon = cal.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let store = TodoStore(fileURL: url)
        store.add("Water plants", createdAt: noon, updatedAt: noon)
        let id = store.items[0].id
        store.setRepeat(rule, for: id)
        return (store, id, url)
    }

    func test_completing_a_repeat_spawns_the_next_occurrence() throws {
        let (store, id, _) = try storeWithRepeating(.daily)
        let noon = store.items[0].updatedAt

        store.toggle(id, updatedAt: noon)

        XCTAssertEqual(store.items.count, 2)
        let (done, next) = (store.items[0], store.items[1])
        XCTAssertTrue(done.isDone)
        XCTAssertEqual(next.title, "Water plants")
        XCTAssertFalse(next.isDone)
        XCTAssertEqual(next.repeatRule, .daily)
        XCTAssertNotEqual(next.id, done.id)
        XCTAssertNil(next.order)

        let expected = Calendar.current.date(byAdding: .day, value: 1, to: noon)!
        XCTAssertEqual(next.createdAt, noon)  // authored today, not on the due date
        XCTAssertEqual(next.updatedAt, expected)
        XCTAssertEqual(store.recentCompletedItems.map(\.id), [id])
        XCTAssertTrue(store.activeByDay.isEmpty)
    }

    func test_unmarking_a_repeat_retracts_the_occurrence_it_spawned() throws {
        let (store, id, _) = try storeWithRepeating(.daily)
        store.toggle(id, updatedAt: Date())
        XCTAssertEqual(store.items.count, 2)

        store.toggle(id, updatedAt: Date().addingTimeInterval(60))
        // Undoing the completion takes tomorrow's copy with it.
        XCTAssertEqual(store.items.count, 1)
        XCTAssertFalse(store.items[0].isDone)

        // Re-completing yields exactly one occurrence, not a duplicate.
        store.toggle(id, updatedAt: Date().addingTimeInterval(120))
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.items.filter { !$0.isDone }.count, 1)
    }

    func test_unmarking_keeps_an_occurrence_that_was_already_completed() throws {
        let (store, id, _) = try storeWithRepeating(.daily)
        store.toggle(id, updatedAt: Date())  // done today, spawns tomorrow's copy
        let copyID = store.items[1].id
        store.toggle(copyID, updatedAt: Date())  // that occurrence completed too

        store.toggle(id, updatedAt: Date())  // un-mark the original

        // Tomorrow's work is real, not a leftover, so it survives.
        XCTAssertEqual(store.items.count, 3)
        XCTAssertTrue(store.items.contains { $0.id == copyID && $0.isDone })
    }

    func test_unmarking_a_plain_task_spawns_nothing() throws {
        let (store, id, _) = try storeWithRepeating(.daily)
        store.setRepeat(nil, for: id)
        store.toggle(id, updatedAt: Date())
        store.toggle(id, updatedAt: Date().addingTimeInterval(60))
        XCTAssertEqual(store.items.count, 1)
    }

    func test_monthly_repeat_keeps_its_day_of_month_after_a_short_month() throws {
        let cal = Calendar.current
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 1
        comps.day = 31
        comps.hour = 9
        let jan31 = cal.date(from: comps)!

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let store = TodoStore(fileURL: url)
        store.add("Rent check", createdAt: jan31, updatedAt: jan31)
        store.setRepeat(.monthly, for: store.items[0].id)
        XCTAssertEqual(store.items[0].repeatDay, 31)

        // February can't hold the 31st, so it clamps...
        store.toggle(store.items[0].id, updatedAt: jan31)
        let feb = store.items[1]
        var expected = DateComponents()
        expected.year = 2026
        expected.month = 2
        expected.day = 28  // 2026 is not a leap year
        expected.hour = 9
        XCTAssertEqual(feb.updatedAt, cal.date(from: expected))

        // ...but March can, so it must go back to the 31st rather than stick
        // at the 28th the way a plain calendar increment would.
        store.toggle(feb.id, updatedAt: feb.updatedAt)
        expected.month = 3
        expected.day = 31
        XCTAssertEqual(store.items[2].updatedAt, cal.date(from: expected))
    }

    func test_anchor_day_is_only_set_for_monthly() throws {
        let (store, id, _) = try storeWithRepeating(.daily)
        XCTAssertNil(store.items[0].repeatDay)

        store.cycleRepeat(id)  // -> weekly
        XCTAssertNil(store.items[0].repeatDay)

        store.cycleRepeat(id)  // -> monthly
        XCTAssertEqual(store.items[0].repeatDay, Calendar.current.component(.day, from: Date()))

        store.cycleRepeat(id)  // -> off
        XCTAssertNil(store.items[0].repeatRule)
        XCTAssertNil(store.items[0].repeatDay)
    }

    func test_set_repeat_nil_clears_it() throws {
        let (store, id, _) = try storeWithRepeating(.weekly)
        store.setRepeat(nil, for: id)
        store.toggle(id, updatedAt: Date())
        XCTAssertEqual(store.items.count, 1)
    }

    func test_repeat_survives_reload() throws {
        let (store, id, url) = try storeWithRepeating(.weekly)
        store.toggle(id, updatedAt: Date())

        let reloaded = TodoStore(fileURL: url)
        XCTAssertEqual(reloaded.items.map(\.repeatRule), [.weekly, .weekly])
        XCTAssertEqual(reloaded.items[1].repeatDay, store.items[1].repeatDay)
        XCTAssertEqual(reloaded.items[1].spawnedFrom, id)
    }

    func test_legacy_json_without_repeat_decodes_as_non_repeating() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        try #"[{"id":"00000000-0000-0000-0000-000000000001","title":"Legacy","isDone":false}]"#
            .write(to: url, atomically: true, encoding: .utf8)
        let store = TodoStore(fileURL: url)
        XCTAssertNil(store.items[0].repeatRule)
    }

    func test_cycle_walks_daily_weekly_monthly_then_off() throws {
        let (store, id, _) = try storeWithRepeating(.daily)
        XCTAssertEqual(store.items[0].repeatRule, .daily)  // start mid-cycle

        store.cycleRepeat(id)
        XCTAssertEqual(store.items[0].repeatRule, .weekly)
        store.cycleRepeat(id)
        XCTAssertEqual(store.items[0].repeatRule, .monthly)
        store.cycleRepeat(id)
        XCTAssertNil(store.items[0].repeatRule)
    }

    func test_cycle_from_off_starts_at_daily_and_never_spawns_when_cleared() throws {
        let (store, id, _) = try storeWithRepeating(.weekly)
        store.setRepeat(nil, for: id)

        store.cycleRepeat(id)
        XCTAssertEqual(store.items[0].repeatRule, .daily)
        store.cycleRepeat(id)
        store.cycleRepeat(id)
        store.cycleRepeat(id)
        XCTAssertNil(store.items[0].repeatRule)

        store.toggle(id, updatedAt: Date())
        XCTAssertEqual(store.items.count, 1, "a cleared cadence must not spawn")
    }

    // MARK: - Future occurrences

    private func storeWithTomorrowSpawn() throws -> (store: TodoStore, tomorrow: Date) {
        let cal = Calendar.current
        let noon = cal.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let store = TodoStore(fileURL: url)
        store.add("Water plants", createdAt: noon, updatedAt: noon)
        store.setRepeat(.daily, for: store.items[0].id)
        store.toggle(store.items[0].id, updatedAt: noon)
        return (store, cal.date(byAdding: .day, value: 1, to: noon)!)
    }

    func test_occurrence_spawns_dated_tomorrow_and_stays_hidden() throws {
        let (store, tomorrow) = try storeWithTomorrowSpawn()

        // Spawned but dated tomorrow, so nothing is actionable today.
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.items[1].updatedAt, tomorrow)
        XCTAssertTrue(store.activeByDay.isEmpty)
        XCTAssertEqual(store.visibleItems.map(\.isDone), [true])
    }

    func test_hidden_occurrences_leave_the_progress_count_but_today_survives() throws {
        let (store, _) = try storeWithTomorrowSpawn()
        XCTAssertEqual(store.visibleItems.count, 1)  // the completed original only

        let cal = Calendar.current
        let noon = cal.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        store.add("Today", createdAt: noon, updatedAt: noon)

        XCTAssertEqual(store.visibleItems.count, 2)
        XCTAssertEqual(store.activeByDay.flatMap { $0.items }.map(\.title), ["Today"])
    }

    func test_occurrence_keeps_the_series_authoring_date() throws {
        let (store, tomorrow) = try storeWithTomorrowSpawn()
        let authored = store.items[0].createdAt

        XCTAssertEqual(store.items[1].createdAt, authored)
        XCTAssertNotEqual(store.items[1].updatedAt, authored)
        XCTAssertEqual(store.items[1].updatedAt, tomorrow)
    }

    func test_completed_items_are_never_hidden() throws {
        let (store, _) = try storeWithTomorrowSpawn()
        let pendingID = store.items[1].id  // tomorrow's occurrence
        store.add("Old", createdAt: Date().addingTimeInterval(-60), updatedAt: Date())
        store.toggle(store.items.last!.id, updatedAt: Date().addingTimeInterval(-60))

        XCTAssertFalse(store.visibleItems.contains { $0.id == pendingID })
        XCTAssertEqual(store.recentCompletedItems.count, 2)
    }

    func test_deleting_the_completed_original_leaves_nothing_visible() throws {
        let (store, _) = try storeWithTomorrowSpawn()
        store.delete(store.items[0].id)  // the completed one; only tomorrow's copy remains

        // Not empty in the store, but nothing to show — so the row's empty
        // state and its search filter must not key off raw `items`.
        XCTAssertEqual(store.items.count, 1)
        XCTAssertTrue(store.visibleItems.isEmpty)
        XCTAssertTrue(store.activeByDay.isEmpty)
    }

    func test_retracting_the_last_occurrence_clears_the_row_entirely() throws {
        let (store, id, _) = try storeWithRepeating(.daily)
        store.toggle(id, updatedAt: Date())
        store.toggle(id, updatedAt: Date().addingTimeInterval(60))

        // Un-marking took the pending copy with it, so the todo is back to being
        // a single ordinary active row.
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.activeByDay.flatMap(\.items).map(\.id), [id])
    }
}
