import QuickTodoCore
import SwiftUI

struct TodoView: View {
    @ObservedObject var store: TodoStore
    @State private var draft = ""
    @State private var scrollTopTick = 0
    @FocusState private var inputFocused: Bool

    private var progressValue: Double {
        guard !store.items.isEmpty else { return 0 }
        let done = Double(store.items.filter(\.isDone).count)
        return done / Double(store.items.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("QuickTodo")
                    .font(.headline)
                Spacer()
                Text("⌘⌥T")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 10)

            Divider()
                .padding(.horizontal, 12)

            HStack(spacing: 8) {
                TextField("Start typing to add...", text: $draft)
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
                scrollTopTick += 1
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
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(store.orderedItems) { item in
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
                    .onChange(of: scrollTopTick) { _ in
                        guard let first = store.orderedItems.first else { return }
                        DispatchQueue.main.async {
                            proxy.scrollTo(first.id, anchor: .top)
                        }
                    }
                }
            }

            Divider()
                .padding(.horizontal, 12)

            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.18))
                            .frame(width: 44, height: 6)
                        Capsule()
                            .fill(progressValue >= 1 ? .green : .blue)
                            .frame(width: 44 * CGFloat(progressValue), height: 6)
                    }
                    Text("\(store.items.filter(\.isDone).count)/\(store.items.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(progressValue >= 1 ? .green : .secondary)
                }
                Spacer()
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "power")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Quit")
                .help("Quit")
                .padding(.vertical, 6)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
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
        scrollTopTick += 1
    }
}
