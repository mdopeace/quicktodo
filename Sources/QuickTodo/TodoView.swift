import QuickTodoCore
import SwiftUI

struct TodoView: View {
    @ObservedObject var store: TodoStore
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("QuickTodo")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 10)

            Divider()
                .padding(.horizontal, 12)

            HStack(spacing: 8) {
                TextField("New todo…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .onSubmit(submit)
                Button("Add", action: submit)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .onAppear { inputFocused = true }
            .onReceive(NotificationCenter.default.publisher(for: .quickTodoMenuWillOpen)) { _ in
                // Hosting view is reused — onAppear fires only once, refocus every open.
                // Clear first: the menu editor can restore pre-submit text into the
                // binding, and onCommit-style commits must never fire from refocusing.
                draft = ""
                inputFocused = false
                DispatchQueue.main.async { inputFocused = true }
            }

            Divider()
                .padding(.horizontal, 12)

            if store.items.isEmpty {
                Text("Nothing here yet")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.items) { item in
                            HStack(spacing: 8) {
                                Button {
                                    store.toggle(item.id)
                                } label: {
                                    Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                                }
                                .buttonStyle(.plain)
                                Text(item.title)
                                    .strikethrough(item.isDone)
                                    .foregroundStyle(item.isDone ? .secondary : .primary)
                                    .lineLimit(2)
                                    .truncationMode(.tail)
                                Spacer(minLength: 8)
                                Button {
                                    store.delete(item.id)
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            Divider()
                .padding(.horizontal, 12)

            HStack {
                Text("⌘⌥T to open")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .accessibilityLabel("Quit")
                    .help("Quit")
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(width: MenuMetrics.width) // height hugs content; AppDelegate caps it
    }

    private func submit() {
        // Capture + clear first: Return can reach both TextField and Button;
        // the second delivery then sees an empty draft and is ignored.
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        guard !title.isEmpty else { return }
        store.add(title)
    }
}
