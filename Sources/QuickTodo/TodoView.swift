import QuickTodoCore
import SwiftUI

struct TodoView: View {
    @ObservedObject var store: TodoStore
    @StateObject private var updater = Updater.shared
    @State private var draft = ""
    @State private var scrollTopTick = 0
    @State private var isInApplications = false
    @FocusState private var inputFocused: Bool

    private var progressValue: Double {
        guard !store.items.isEmpty else { return 0 }
        let done = Double(store.items.filter(\.isDone).count)
        return done / Double(store.items.count)
    }

    private static let appsFolder = URL(fileURLWithPath: "/Applications/quicktodo.app")

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
                Button(action: submit) {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add")
                .help("Add")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .onAppear {
                inputFocused = true
                isInApplications = FileManager.default.fileExists(atPath: Self.appsFolder.path)
            }
            .onReceive(NotificationCenter.default.publisher(for: .quickTodoMenuWillOpen)) { _ in
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
                            Color.clear.frame(height: 0).id("listTop")
                            ForEach(store.activeByDay, id: \.day) { section in
                                sectionHeader(TodoStore.dayLabel(for: section.day))
                                ForEach(section.items) { item in
                                    row(item)
                                }
                            }
                            if !store.completedItems.isEmpty {
                                sectionHeader("Completed")
                                ForEach(store.completedItems) { item in
                                    row(item)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    .onChange(of: scrollTopTick) { _ in
                        guard !store.items.isEmpty else { return }
                        DispatchQueue.main.async {
                            proxy.scrollTo("listTop", anchor: .top)
                        }
                    }
                }
            }

            Divider()
                .padding(.horizontal, 12)

            HStack(spacing: 8) {
                Link(destination: URL(string: "https://buymeacoffee.com/mdopeace")!) {
                    Image(systemName: "heart")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Buy me a coffee")
                .help("Buy me a coffee")
                .buttonStyle(.plain)
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
                if !isInApplications {
                    Button {
                        updater.installCurrentAppToApplications()
                    } label: {
                        Image(systemName: "square.and.arrow.down.on.square")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Install to Applications")
                    .help("Install to Applications")
                }
                if updater.state != .idle {
                    UpdateIndicator(state: updater.state) {
                        switch updater.state {
                        case .available: updater.downloadAndInstall()
                        case .idle, .checking: updater.checkManually()
                        case .error: updater.checkManually()
                        default: break
                        }
                    }
                    .help(updater.state.helpText)
                    .transition(.opacity.combined(with: .scale))
                }
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

    private func sectionHeader(_ label: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func row(_ item: TodoItem) -> some View {
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

struct UpdateIndicator: View {
    let state: Updater.State
    let action: () -> Void

    @State private var rotation = 0.0

    var body: some View {
        Button(action: action) {
            Image(systemName: iconName)
                .font(.caption)
                .foregroundStyle(iconColor)
                .rotationEffect(.degrees(rotation))
                .animation(
                    state == .checking ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                    value: rotation
                )
                .opacity(state == .available ? 1 : 1)
                .animation(
                    state == .available ? .easeInOut(duration: 1).repeatForever(autoreverses: true) : .default,
                    value: state == .available
                )
                .onAppear {
                    if state == .checking {
                        rotation = 360
                    }
                }
                .onChange(of: state) { newState in
                    if newState == .checking {
                        rotation = 360
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    var iconName: String {
        switch state {
        case .checking: "arrow.clockwise.circle"
        case .available: "arrow.down.circle.fill"
        case .downloading: "arrow.down.circle"
        case .installing: "gear.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .idle: ""
        }
    }

    var iconColor: Color {
        switch state {
        case .available: .blue
        case .error: .orange
        default: .secondary
        }
    }

    var accessibilityLabel: String {
        switch state {
        case .checking: "Checking for updates"
        case .available: "Update available"
        case .downloading: "Downloading update"
        case .installing: "Installing update"
        case .error: "Update error"
        case .idle: ""
        }
    }
}
