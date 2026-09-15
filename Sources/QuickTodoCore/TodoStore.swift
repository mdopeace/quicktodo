import Combine
import Foundation

public struct TodoItem: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var title: String
    public var isDone = false
    public var createdAt = Date()

    private enum CodingKeys: String, CodingKey {
        case id, title, isDone, createdAt
    }
}

public extension TodoItem {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        isDone = try c.decodeIfPresent(Bool.self, forKey: .isDone) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

public final class TodoStore: ObservableObject {
    @Published public private(set) var items: [TodoItem] = []
    /// Active grouped by day, newest day first; newest-first within a day.
    public var activeByDay: [(day: Date, items: [TodoItem])] {
        let cal = Calendar.current
        var buckets: [Date: [TodoItem]] = [:]
        for item in items.reversed() where !item.isDone {
            let day = cal.startOfDay(for: item.createdAt)
            buckets[day, default: []].append(item)
        }
        return buckets.keys.sorted(by: >).map { (day: $0, items: buckets[$0]!) }
    }
    /// All done, oldest-first at the bottom.
    public var completedItems: [TodoItem] {
        items.filter { $0.isDone }
    }
    /// Done within the last 7 days (by createdAt). Oldest-first.
    public var recentCompletedItems: [TodoItem] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        return items.filter { $0.isDone && $0.createdAt >= cutoff }
    }
    /// Done with createdAt older than 7 days. Oldest-first, shown collapsed.
    public var olderCompletedItems: [TodoItem] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        return items.filter { $0.isDone && $0.createdAt < cutoff }
    }

    public static func dayLabel(for date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return dayFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, MMM d, yyyy"
        return f
    }()
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("QuickTodo", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("todos.json")
        }
        load()
    }

    public func add(_ title: String, createdAt: Date = Date()) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(TodoItem(title: trimmed, createdAt: createdAt))
        save()
    }

    public func toggle(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].isDone.toggle()
        save()
    }

    public func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return } // first launch
        do {
            items = try JSONDecoder().decode([TodoItem].self, from: data)
        } catch {
            // Don't overwrite corrupt data on next save — move it aside.
            let backup = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            NSLog("QuickTodo: corrupt store %@, moved to %@ (%@)", fileURL.path, backup.path, error.localizedDescription)
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("QuickTodo: failed to save store %@ (%@)", fileURL.path, error.localizedDescription)
        }
    }
}
