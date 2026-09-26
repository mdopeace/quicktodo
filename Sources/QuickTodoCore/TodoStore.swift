import Combine
import Foundation

public struct TodoItem: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var title: String
    public var isDone = false
    public var createdAt = Date()
    public var updatedAt = Date()

    private enum CodingKeys: String, CodingKey {
        case id, title, isDone, createdAt, updatedAt
    }
}

public extension TodoItem {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        isDone = try c.decodeIfPresent(Bool.self, forKey: .isDone) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        // Pre-updatedAt items inherit createdAt so they keep the bucket they
        // already sit in; defaulting to now would reset everyone's history.
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

public extension TodoItem {
    // ponytail: longest-match chain, so a run of 3+ dashes ("<---", "--->")
    // still leaks a dash. Swap for one NSRegularExpression pass with
    // (?<!-)/(?!-) lookaround if that ever shows up in real titles.
    var prettyTitle: String {
        title
            .replacingOccurrences(of: "<->", with: "↔")
            .replacingOccurrences(of: "<--", with: "←")
            .replacingOccurrences(of: "-->", with: "→")
            .replacingOccurrences(of: "->", with: "→")
            .replacingOccurrences(of: "<-", with: "←")
    }
}

public final class TodoStore: ObservableObject {
    @Published public private(set) var items: [TodoItem] = []
    /// Active grouped by day, newest day first; newest updatedAt first within a day,
    /// ties broken by newest inserted.
    public var activeByDay: [(day: Date, items: [TodoItem])] {
        let cal = Calendar.current
        var buckets: [Date: [TodoItem]] = [:]
        // Array.sorted isn't stable, so carry insertion order as a tiebreaker;
        // without it equal updatedAt values would fall back to oldest-inserted.
        let byRecency = items.enumerated()
            .sorted { ($0.element.updatedAt, $0.offset) > ($1.element.updatedAt, $1.offset) }
        for item in byRecency.map(\.element) where !item.isDone {
            let day = cal.startOfDay(for: item.updatedAt)
            buckets[day, default: []].append(item)
        }
        return buckets.keys.sorted(by: >).map { (day: $0, items: buckets[$0]!) }
    }
    /// Done within the last 7 days (by updatedAt). Newest-first.
    public var recentCompletedItems: [TodoItem] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) else { return [] }
        return items.filter { $0.isDone && $0.updatedAt >= cutoff }.sorted { $0.updatedAt > $1.updatedAt }
    }
    /// Done with updatedAt older than 7 days. Newest-first, shown collapsed.
    public var olderCompletedItems: [TodoItem] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) else { return [] }
        return items.filter { $0.isDone && $0.updatedAt < cutoff }.sorted { $0.updatedAt > $1.updatedAt }
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
            Self.adoptSandboxedStore(into: self.fileURL)
        }
        load()
    }

    /// Sandboxed releases kept todos in the App Sandbox container. Unsandboxed we
    /// read ~/Library/Application Support, so seed it from the container once.
    /// Never overwrites: if both exist they have diverged and only the user can
    /// say which to keep.
    static func adoptSandboxedStore(into fileURL: URL, container: URL? = nil) {
        let fm = FileManager.default
        // Deliberately hardcoded to the bundle id the *sandboxed* releases shipped
        // with, not Bundle.main.bundleIdentifier. If the id is ever renamed this
        // must keep pointing at the old container, or existing todos are stranded
        // in a path nothing reads. Do not "fix" this to track Info.plist.
        let legacy = container ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers/com.mdopeace.quicktodo/Data/Library/Application Support/QuickTodo/todos.json")
        guard !fm.fileExists(atPath: fileURL.path) else { return }
        guard fm.fileExists(atPath: legacy.path) else { return } // fresh install, nothing to migrate
        guard let data = try? Data(contentsOf: legacy),
              (try? data.write(to: fileURL, options: .atomic)) != nil else {
            NSLog("QuickTodo: sandboxed store %@ found but unreadable — todos not migrated", legacy.path)
            return
        }
        NSLog("QuickTodo: seeded store from sandbox container %@", legacy.path)
    }

    public func add(_ title: String, createdAt: Date = Date(), updatedAt: Date? = nil) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Default updatedAt to createdAt so a backdated item groups under the
        // day it was written, matching the tooltip rather than contradicting it.
        items.append(TodoItem(title: trimmed, createdAt: createdAt, updatedAt: updatedAt ?? createdAt))
        save()
    }

    public func toggle(_ id: UUID, updatedAt: Date = Date()) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].isDone.toggle()
        items[i].updatedAt = updatedAt
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
