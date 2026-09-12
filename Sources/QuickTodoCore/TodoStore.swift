import Combine
import Foundation

public struct TodoItem: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var title: String
    public var isDone = false
}

public final class TodoStore: ObservableObject {
    @Published public private(set) var items: [TodoItem] = []
    /// Active newest-first on top, done newest-first at the bottom.
    public var orderedItems: [TodoItem] {
        let newestFirst = items.reversed()
        return newestFirst.filter { !$0.isDone } + newestFirst.filter { $0.isDone }
    }
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

    public func add(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(TodoItem(title: trimmed))
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
