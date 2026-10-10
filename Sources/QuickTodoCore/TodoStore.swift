import Combine
import Foundation

public struct TodoItem: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var title: String
    public var isDone = false
    public var createdAt = Date()
    public var updatedAt = Date()
    /// Manual position in its day section; nil = never reordered, so it falls
    /// back to recency.
    public var order: Int?
    public var repeatRule: Repeat?
    /// Set on the spawned occurrence, so un-ticking the completion retracts it.
    public var spawnedFrom: UUID?

    private enum CodingKeys: String, CodingKey {
        case id, title, isDone, createdAt, updatedAt, order, repeatRule, spawnedFrom
    }
}

extension TodoItem {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        isDone = try c.decodeIfPresent(Bool.self, forKey: .isDone) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        // Not Date(): a legacy item must stay in the day it was created.
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        order = try c.decodeIfPresent(Int.self, forKey: .order)
        // Unknown cadence must decode to nil, not throw: a throw here fails
        // the whole array and costs the user every todo.
        repeatRule = try c.decodeIfPresent(String.self, forKey: .repeatRule)
            .flatMap(Repeat.init(rawValue:))
        spawnedFrom = try c.decodeIfPresent(UUID.self, forKey: .spawnedFrom)
    }
}

public enum Repeat: String, Codable {
    case daily, weekly

    public var title: String { rawValue.capitalized }

    /// A fixed day offset from the completion, so finishing late keeps the weekday.
    func next(after date: Date, calendar: Calendar = .current) -> Date? {
        calendar.date(byAdding: .day, value: self == .daily ? 1 : 7, to: date)
    }
}

public final class TodoStore: ObservableObject {
    @Published public private(set) var items: [TodoItem] = []

    /// Off by default; flip on to exercise repeat spawning.
    public var showFutureTasks = false

    /// Future occurrences stay hidden until their day comes.
    public var visibleItems: [TodoItem] {
        guard !showFutureTasks else { return items }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return items.filter { $0.isDone || cal.startOfDay(for: $0.updatedAt) <= today }
    }

    /// `order` wins; nil sorts above ordered rows so a fresh add lands on top.
    /// sorted isn't stable, so tiebreak on recency then insertion order.
    private static func precedes(
        _ a: (offset: Int, element: TodoItem), _ b: (offset: Int, element: TodoItem)
    ) -> Bool {
        switch (a.element.order, b.element.order) {
        case (let x?, let y?):
            return x == y
                ? (a.element.updatedAt, a.offset) > (b.element.updatedAt, b.offset)
                : x < y
        case (nil, nil):
            return (a.element.updatedAt, a.offset) > (b.element.updatedAt, b.offset)
        case (nil, _): return true
        case (_, nil): return false
        }
    }

    /// Active, newest day first.
    public var activeByDay: [(day: Date, items: [TodoItem])] {
        let cal = Calendar.current
        var buckets: [Date: [TodoItem]] = [:]
        for item in visibleItems.enumerated().sorted(by: Self.precedes).map(\.element)
        where !item.isDone {
            let day = cal.startOfDay(for: item.updatedAt)
            buckets[day, default: []].append(item)
        }
        return buckets.keys.sorted(by: >).map { (day: $0, items: buckets[$0]!) }
    }
    /// Done within the last 7 days (by updatedAt). Newest-first.
    public var recentCompletedItems: [TodoItem] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) else {
            return []
        }
        return items.filter { $0.isDone && $0.updatedAt >= cutoff }.sorted {
            $0.updatedAt > $1.updatedAt
        }
    }
    /// Done with updatedAt older than 7 days. Newest-first, shown collapsed.
    public var olderCompletedItems: [TodoItem] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) else {
            return []
        }
        return items.filter { $0.isDone && $0.updatedAt < cutoff }.sorted {
            $0.updatedAt > $1.updatedAt
        }
    }

    public static func dayLabel(for date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return dayFormatter.string(from: date)
    }

    /// e.g. 1000 -> "1K". Locale pinned like `dayFormatter`; en_IN gives "10L".
    public static func compact(_ n: Int) -> String {
        n.formatted(compactCount)
    }

    private static let compactCount: IntegerFormatStyle<Int> = .number
        .locale(Locale(identifier: "en_US_POSIX"))
        .notation(.compactName)

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, MMM d, yyyy"
        return f
    }()

    private let fileURL: URL

    /// Search at 3+ chars; below that the draft is add-only. Trim first so a
    /// trailing space can't count toward the floor.
    public static func searchQuery(_ draft: String) -> String? {
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.count >= 3 ? q : nil
    }

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("QuickTodo", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("todos.json")
            Self.adoptSandboxedStore(into: self.fileURL)
        }
        load()
    }

    /// One-time seed from the old sandbox container. Never overwrites: if both
    /// stores exist they have diverged and only the user can pick.
    static func adoptSandboxedStore(into fileURL: URL, container: URL? = nil) {
        let fm = FileManager.default
        // Hardcoded to the *sandboxed* bundle id on purpose, not
        // Bundle.main.bundleIdentifier. Renaming the id would strand existing
        // todos here. Do not "fix" this to track Info.plist.
        let legacy =
            container
            ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(
                "Library/Containers/com.mdopeace.quicktodo/Data/Library/Application Support/QuickTodo/todos.json"
            )
        guard !fm.fileExists(atPath: fileURL.path) else { return }
        guard fm.fileExists(atPath: legacy.path) else { return }  // fresh install, nothing to migrate
        guard let data = try? Data(contentsOf: legacy),
            (try? data.write(to: fileURL, options: .atomic)) != nil
        else {
            NSLog(
                "QuickTodo: sandboxed store %@ found but unreadable — todos not migrated",
                legacy.path)
            return
        }
        NSLog("QuickTodo: seeded store from sandbox container %@", legacy.path)
    }

    public func add(_ title: String, createdAt: Date = Date(), updatedAt: Date? = nil) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Backdated items group under the day they were written, matching the tooltip.
        items.append(
            TodoItem(title: trimmed, createdAt: createdAt, updatedAt: updatedAt ?? createdAt))
        save()
    }

    public func toggle(_ id: UUID, updatedAt: Date = Date()) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let wasDone = items[i].isDone
        items[i].isDone.toggle()
        items[i].updatedAt = updatedAt
        // Toggling re-buckets into another day; a stale rank would land it mid-list.
        items[i].order = nil
        if wasDone {
            // Pending only: a completed occurrence is real work, not a leftover.
            items.removeAll { $0.spawnedFrom == id && !$0.isDone }
        } else if let rule = items[i].repeatRule, let next = rule.next(after: updatedAt) {
            var copy = items[i]
            copy.id = UUID()
            copy.isDone = false
            // updatedAt files the occurrence; createdAt stays put for the tooltip.
            copy.updatedAt = next
            copy.spawnedFrom = items[i].id
            items.append(copy)
        }
        save()
    }

    public func setRepeat(_ rule: Repeat?, for id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].repeatRule = rule
        save()
    }

    /// Off is in the cycle so one more click always clears it.
    public func cycleRepeat(_ id: UUID) {
        let order: [Repeat?] = [nil, .daily, .weekly]
        let i =
            items.first(where: { $0.id == id })
            .flatMap { order.firstIndex(of: $0.repeatRule) } ?? 0
        setRepeat(order[(i + 1) % order.count], for: id)
    }

    /// Manual reorder within a day section. `index` counts positions *after* `id`
    /// is lifted out, so one destination works moving up or down.
    public func move(_ id: UUID, to index: Int) {
        let cal = Calendar.current
        // Completed rows are in their own sections, not a day bucket.
        guard let from = items.firstIndex(where: { $0.id == id }), !items[from].isDone
        else { return }
        let day = cal.startOfDay(for: items[from].updatedAt)
        // Must match what the list renders, or `index` means nothing.
        var section = items.enumerated()
            .sorted(by: Self.precedes)
            .map(\.offset)
            .filter { !items[$0].isDone && cal.startOfDay(for: items[$0].updatedAt) == day }
        guard let pos = section.firstIndex(of: from) else { return }
        section.remove(at: pos)
        let to = min(max(index, 0), section.count)
        guard to != pos else { return }  // dropped where it already was
        section.insert(from, at: to)
        for (n, i) in section.enumerated() { items[i].order = n }
        save()
    }

    public func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    /// Bulk remove in a single write — looping `delete(_:)` would save per item.
    public func delete(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let doomed = Set(ids)
        items.removeAll { doomed.contains($0.id) }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }  // first launch
        do {
            items = try JSONDecoder().decode([TodoItem].self, from: data)
        } catch {
            // Don't overwrite corrupt data on next save — move it aside.
            let backup = fileURL.appendingPathExtension(
                "corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            NSLog(
                "QuickTodo: corrupt store %@, moved to %@ (%@)", fileURL.path, backup.path,
                error.localizedDescription)
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog(
                "QuickTodo: failed to save store %@ (%@)", fileURL.path, error.localizedDescription)
        }
    }
}
