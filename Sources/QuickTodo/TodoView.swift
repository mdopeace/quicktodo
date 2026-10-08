import QuickTodoCore
import SwiftUI

private let rowAnimation = Animation.spring(response: 0.3, dampingFraction: 0.8)

/// Replaces `DisclosureGroup`'s built-in layout so the header lines up with
/// `sectionHeader` and the content rows sit at the same 12pt inset as every
/// other row. The default style reserves ~4pt of trailing space on the label
/// row that Apple documents no value for, and the group's own horizontal
/// padding stacked on the rows' padding (24pt total).
///
/// Draws no disclosure control of its own: `label` supplies the chevron and the
/// toggle, so there is exactly one thing to click and one VoiceOver stop.
private struct InlineDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 0) {
            configuration.label
                .padding(.horizontal, 12)
                .padding(.top, 8)
                // Collapsed, the header is the last row before the footer, so it
                // gets the same 8pt of trailing air the top padding gives the
                // row above. Expanded, 8pt would separate it from its own rows.
                .padding(.bottom, configuration.isExpanded ? 2 : 8)
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

private struct ProgressTracker {
    /// 0...1, drives the bar's fill and the green-at-complete styling.
    let value: Double
    let text: String
    /// Spoken form of `text` for VoiceOver.
    let spoken: String
}

struct TodoView: View {
    @ObservedObject var store: TodoStore
    @StateObject private var updater = Updater.shared
    @State private var draft = ""
    @State private var search = ""
    @State private var scrollTopTick = 0
    @State private var expandedItems: Set<UUID> = []
    @State private var olderExpanded = false
    @FocusState private var inputFocused: Bool

    /// Bind to a `let` in `body` — reading this inline re-walks the store on
    /// every keystroke.
    private var progress: ProgressTracker {
        let older = store.olderCompletedItems.count
        let done = store.items.filter(\.isDone).count - older
        let total = store.items.count - older
        let value = total > 0 ? Double(done) / Double(total) : 0
        return ProgressTracker(
            value: value,
            // n/n stays raw: it's read against the bar, and compacting rounds
            // 1199/1200 and 1200/1200 onto the same "1.2K/1.2K".
            text: "\(done)/\(total) (\(TodoStore.compact(older)))",
            // "1.5K" is announced literally, so spell the counts out. Drop the
            // trailing clause when empty.
            spoken: older > 0
                ? "\(done) of \(total) done, \(older) completed over a week ago"
                : "\(done) of \(total) done"
        )
    }

    /// Debounced view of `draft`. The zero-match fallback is resolved here, per
    /// render, so deleting the last match mid-search degrades to the default list
    /// instead of leaving an empty menu.
    private var query: String? {
        guard !search.isEmpty,
            store.items.contains(where: { $0.title.localizedCaseInsensitiveContains(search) })
        else { return nil }
        return search
    }

    private func matching(_ items: [TodoItem], _ query: String?) -> [TodoItem] {
        guard let query else { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    // Each property resolves `query` once. Reading it per section re-scans every
    // item (S+5)x per body pass, and body re-runs on every keystroke because
    // `draft` is bound directly in it.
    private var visibleSections: [(day: Date, items: [TodoItem])] {
        let q = query
        return store.activeByDay.compactMap { section -> (day: Date, items: [TodoItem])? in
            let items = matching(section.items, q)
            return items.isEmpty ? nil : (section.day, items)
        }
    }

    private var visibleRecentDone: [TodoItem] { matching(store.recentCompletedItems, query) }
    private var visibleOlderDone: [TodoItem] { matching(store.olderCompletedItems, query) }

    /// A query whose only survivors sit in the collapsed week-old section leaves
    /// the panel a single header row, so the section opens itself.
    private var onlyOlderMatches: Bool {
        query != nil && visibleSections.isEmpty && visibleRecentDone.isEmpty
            && !visibleOlderDone.isEmpty
    }

    var body: some View {
        let progress = progress
        return VStack(spacing: 0) {
            HStack {
                Text("QuickTodo")
                    .font(.headline)
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
                TextField("Add or search...", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .onSubmit(submit)
                    // Trailing overlay, not prompt text: keeps the look of a
                    // placeholder hint while staying right-aligned for any
                    // version length, and hides while typing so it never sits
                    // under real input.
                    .overlay(alignment: .trailing) {
                        Text("v\(appVersion)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.trailing, 8)
                            .opacity(draft.isEmpty ? 1 : 0)
                            .allowsHitTesting(false)
                            // Opacity alone leaves this in the a11y tree, so it
                            // would still be read out while invisible.
                            .accessibilityHidden(true)
                    }
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
            .task(id: draft) {
                // Each keystroke changes the id, which cancels the in-flight
                // sleep, so only the final one survives to write `search`. The
                // guard is load-bearing: `try?` swallows the CancellationError.
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                search = TodoStore.searchQuery(draft) ?? ""
            }
            .onReceive(NotificationCenter.default.publisher(for: .quickTodoMenuWillOpen)) { _ in
                draft = ""
                search = ""
                inputFocused = false
                expandedItems.removeAll()
                olderExpanded = false
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
                            ForEach(visibleSections, id: \.day) { section in
                                sectionHeader(
                                    TodoStore.dayLabel(for: section.day), showDeleteButton: false)
                                ForEach(section.items) { item in
                                    row(item)
                                }
                            }
                            if !visibleRecentDone.isEmpty {
                                sectionHeader("Completed", showDeleteButton: true)
                                ForEach(visibleRecentDone) { item in
                                    row(item)
                                }
                            }
                            // Bound once: every read walks the store and
                            // re-filters by query.
                            let visibleOlder = visibleOlderDone
                            if !visibleOlder.isEmpty {
                                DisclosureGroup(
                                    isExpanded: $olderExpanded,
                                    content: {
                                        ForEach(visibleOlder) { item in
                                            row(item)
                                        }
                                    },
                                    label: {
                                        HStack {
                                            Button {
                                                withAnimation(rowAnimation) {
                                                    olderExpanded.toggle()
                                                }
                                            } label: {
                                                HStack(spacing: 6) {
                                                    Image(systemName: "chevron.right")
                                                        .font(.caption)
                                                        .rotationEffect(
                                                            .degrees(olderExpanded ? 90 : 0))
                                                    Text(
                                                        "Completed over a week ago (\(TodoStore.compact(visibleOlder.count)))"
                                                    )
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                }
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                            // On the Button, which is what VoiceOver
                                            // focuses — not the Text inside it.
                                            .accessibilityLabel(
                                                "Completed over a week ago, \(visibleOlder.count)"
                                            )
                                            Spacer()
                                            Button {
                                                withAnimation(rowAnimation) {
                                                    store.delete(
                                                        ids: store.olderCompletedItems.map(\.id))
                                                }
                                            } label: {
                                                Image(systemName: "trash")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                            .padding(.trailing, 2)
                                        }
                                    }
                                )
                                // Horizontal padding now lives in the style, so
                                // the rows below keep their own 12 instead of 24.
                                .disclosureGroupStyle(InlineDisclosureStyle())
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
                            .fill(progress.value >= 1 ? .green : .blue)
                            .frame(width: 44 * CGFloat(progress.value), height: 6)
                    }
                    Text(progress.text)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(progress.value >= 1 ? .green : .secondary)
                        .accessibilityLabel(progress.spoken)
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
        // Filtering changes the list height without touching the store, so the
        // hosting view has to be told to re-measure.
        .onChange(of: search) { _ in
            if onlyOlderMatches {
                withAnimation(rowAnimation) { olderExpanded = true }
            }
            NotificationCenter.default.post(name: .quickTodoContentHeightChanged, object: nil)
        }
    }

    private func submit() {
        // Capture + clear first: Return can reach both TextField and Button;
        // the second delivery then sees an empty draft and is ignored.
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        // Clear the filter too: waiting out the debounce would leave the old
        // filtered rows on screen immediately after the item is added.
        search = ""
        guard !title.isEmpty else { return }
        withAnimation(rowAnimation) {
            store.add(title)
        }
        scrollTopTick += 1
    }

    private func sectionHeader(_ label: String, showDeleteButton: Bool) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if showDeleteButton {
                Button {
                    withAnimation(rowAnimation) {
                        store.delete(ids: store.recentCompletedItems.map(\.id))
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func row(_ item: TodoItem) -> some View {
        let content = HStack(spacing: 8) {
            Button {
                withAnimation(rowAnimation) {
                    store.toggle(item.id)
                }
            } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.plain)
            Text(item.title.replacingOccurrences(of: "->", with: "→"))
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

        // Only done rows get a createdAt tooltip; an empty help would still be
        // read out and inherit onto the row's child buttons.
        return Group {
            if item.isDone {
                content.help("Created: \(TodoStore.dayLabel(for: item.createdAt))")
            } else {
                content
            }
        }
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
        case .checking, .idle, .error, .upToDate: "arrow.clockwise"
        case .available, .downloading: "arrow.down"
        case .installing: "gear"
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
