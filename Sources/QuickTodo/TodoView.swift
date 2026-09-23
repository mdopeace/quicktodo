import QuickTodoCore
import SwiftUI

private let rowAnimation = Animation.spring(response: 0.3, dampingFraction: 0.8)

struct TodoView: View {
    @ObservedObject var store: TodoStore
    @StateObject private var updater = Updater.shared
    @State private var draft = ""
    @State private var scrollTopTick = 0
    @State private var expandedItems: Set<UUID> = []
    @State private var olderExpanded = false
    @FocusState private var inputFocused: Bool

    private var totalDone: Int {
        store.items.filter(\.isDone).count
    }
    private var olderDone: Int {
        store.olderCompletedItems.count
    }
    private var progressValue: Double {
        guard !store.items.isEmpty else { return 0 }
        return Double(totalDone) / Double(store.items.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(alignment: .bottom, spacing: 8) {
                    Text("QuickTodo")
                        .font(.headline)
                    Text("—")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("v\(appVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("⌘⌥T")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()
                .padding(.horizontal, 12)

            HStack(spacing: 8) {
                TextField("Start typing...", text: $draft)
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
            }
            .onReceive(NotificationCenter.default.publisher(for: .quickTodoMenuWillOpen)) { _ in
                draft = ""
                inputFocused = false
                expandedItems.removeAll()
                scrollTopTick += 1
                DispatchQueue.main.async { inputFocused = true }
            }
            .onChange(of: store.items) { newItems in
                let currentIDs = Set(newItems.map(\.id))
                expandedItems = expandedItems.intersection(currentIDs)
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
                            if !store.recentCompletedItems.isEmpty {
                                sectionHeader("Completed")
                                ForEach(store.recentCompletedItems) { item in
                                    row(item)
                                }
                            }
                            if !store.olderCompletedItems.isEmpty {
                                DisclosureGroup(
                                    isExpanded: $olderExpanded,
                                    content: {
                                        ForEach(store.olderCompletedItems) { item in
                                            row(item)
                                        }
                                    },
                                    label: {
                                        Button {
                                            withAnimation(rowAnimation) {
                                                olderExpanded.toggle()
                                            }
                                        } label: {
                                            Text(
                                                "Older than a week (\(store.olderCompletedItems.count))"
                                            )
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                )
                                .padding(.horizontal, 12)
                                .padding(.top, 8)
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
                    Text("\(totalDone)/\(store.items.count) (\(olderDone))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(progressValue >= 1 ? .green : .secondary)
                }
                Spacer()
                UpdateIndicator(state: updater.state) {
                    switch updater.state {
                    case .available: updater.downloadAndInstall()
                    case .error, .idle: updater.checkManually()
                    default: break
                    }
                }
                .help(updater.state.helpText)
                .transition(.opacity.combined(with: .scale))
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Quit")
                .help("Quit")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(width: MenuMetrics.width)  // height hugs content; AppDelegate caps it
    }

    private func submit() {
        // Capture + clear first: Return can reach both TextField and Button;
        // the second delivery then sees an empty draft and is ignored.
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        guard !title.isEmpty else { return }
        withAnimation(rowAnimation) {
            store.add(title)
        }
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
                withAnimation(rowAnimation) {
                    store.toggle(item.id)
                }
            } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.plain)
            Text(item.title)
                .strikethrough(item.isDone)
                .foregroundStyle(item.isDone ? .secondary : .primary)
                .lineLimit(expandedItems.contains(item.id) ? nil : 1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(rowAnimation) {
                        if expandedItems.contains(item.id) {
                            expandedItems.remove(item.id)
                        } else {
                            expandedItems.insert(item.id)
                        }
                    }
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(expandedItems.contains(item.id) ? "Collapse" : "Expand")
                .accessibilityHint(
                    "Double tap to \(expandedItems.contains(item.id) ? "collapse" : "expand") this item"
                )
            Spacer(minLength: 8)
            Button {
                withAnimation(rowAnimation) {
                    store.delete(item.id)
                }
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

    @State private var spinTrigger = 0
    @State private var pulseOpacity = 1.0

    private var isPulsing: Bool {
        [Updater.State.available, .downloading].contains(state)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: iconName)
                .font(.caption)
                .foregroundStyle(iconColor)
                .rotationEffect(.degrees(state == .checking || state == .installing ? 360 : 0))
                .opacity(pulseOpacity)
                .animation(
                    (state == .checking || state == .installing)
                        ? .linear(duration: 1).repeatForever(autoreverses: false)
                        : .default,
                    value: spinTrigger
                )
                .animation(
                    isPulsing
                        ? .easeInOut(duration: 1).repeatForever(autoreverses: true)
                        : .default,
                    value: pulseOpacity
                )
                .onAppear { updateAnimations() }
                .onChange(of: state) { _ in updateAnimations() }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func updateAnimations() {
        if state == .checking || state == .installing {
            spinTrigger += 1
        }
        pulseOpacity = isPulsing ? 0.6 : 1.0
    }

    var iconName: String {
        switch state {
        case .checking, .idle, .error, .upToDate: "arrow.clockwise.circle"
        case .available, .downloading: "arrow.down.circle"
        case .installing: "gear.circle"
        }
    }

    var iconColor: Color {
        switch state {
        case .available, .downloading, .installing: .blue
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
        case .error: "Update error - click to retry"
        case .idle: "Check for updates"
        case .upToDate: "You're on the latest version"
        }
    }
}
