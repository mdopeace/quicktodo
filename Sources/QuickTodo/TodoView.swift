import QuickTodoCore
import SwiftUI

private let rowAnimation = Animation.spring(response: 0.3, dampingFraction: 0.8)

/// Aligns the header with `sectionHeader` and rows at the standard 12pt inset;
/// the built-in style stacks its own padding on top (24pt). Draws no chevron —
/// `label` supplies it.
private struct InlineDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 0) {
            configuration.label
                .padding(.horizontal, 12)
                .padding(.top, 8)
                // Collapsed, the header needs the same trailing air as its top padding;
                // expanded, that would separate it from its own rows.
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

/// `label` doubles as the tooltip and the VoiceOver name.
private struct FooterLink: View {
    let systemName: String
    let label: String
    let url: String

    var body: some View {
        Link(destination: URL(string: url)!) {
            Image(systemName: systemName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel(label)
        .help(label)
        .buttonStyle(.plain)
    }
}

/// A section with a header control: delete it, or move it to today. The
/// labels double as tooltips and VoiceOver names.
private enum BulkTarget: Equatable {
    case recent, older
    case day(Date)

    var icon: String {
        switch self {
        case .recent, .older: "trash"
        case .day: "arrow.forward"
        }
    }

    var idleLabel: String {
        switch self {
        case .recent: "Delete all completed"
        case .older: "Delete all older"
        case .day: "Move all to today"
        }
    }

    /// Confirm text; the count is the point.
    func confirmLabel(_ count: Int) -> String {
        switch self {
        case .recent: "Delete \(count) completed"
        case .older: "Delete \(count) older"
        case .day: "Move \(count) to today"
        }
    }
}

extension Repeat {
    var tint: Color {
        switch self {
        case .daily: .blue
        case .weekly: .orange
        }
    }
}

struct TodoView: View {
    @ObservedObject var store: TodoStore
    @StateObject private var updater = Updater.shared
    @State private var draft = ""
    @State private var search = ""
    @State private var scrollTopTick = 0
    @State private var expandedItems: Set<UUID> = []
    @State private var hoveredItem: UUID?
    @State private var olderExpanded = false
    /// Non-nil while a section's delete prompt is open.
    @State private var bulkTarget: BulkTarget?
    /// The row being renamed, and the text in its field.
    @State private var editing: UUID?
    @State private var editDraft = ""
    @FocusState private var inputFocused: Bool
    @FocusState private var editFocused: Bool

    /// The three defaults are for `scripts/screenshots.sh`, which seeds the states
    /// a pointer or the keyboard would normally set. The app always passes none.
    init(store: TodoStore, hovered: UUID? = nil, searchText: String = "", editingRow: UUID? = nil) {
        self.store = store
        _hoveredItem = State(initialValue: hovered)
        _search = State(initialValue: searchText)
        _editing = State(initialValue: editingRow)
        // The field has to start holding the title, or the shot shows it empty.
        _editDraft = State(initialValue: store.items.first { $0.id == editingRow }?.title ?? "")
    }

    /// Bind to a `let` in `body` — reading this inline re-walks the store on
    /// every keystroke.
    private var progress: ProgressTracker {
        let older = store.olderCompletedItems.count
        let done = store.visibleItems.filter(\.isDone).count - older
        let total = store.visibleItems.count - older
        let value = total > 0 ? Double(done) / Double(total) : 0
        return ProgressTracker(
            value: value,
            // n/n stays raw; compacting rounds 1199/1200 and 1200/1200 to the same "1.2K".
            text: "\(done)/\(total) (\(TodoStore.compact(older)))",
            // VoiceOver reads "1.5K" literally, so spell the counts out.
            spoken: older > 0
                ? "\(done) of \(total) done, \(older) completed over a week ago"
                : "\(done) of \(total) done"
        )
    }

    /// Debounced view of `draft`. Zero matches resolves to the full list here, per
    /// render, so deleting the last match mid-search never empties the menu.
    private var query: String? {
        guard !search.isEmpty,
            store.visibleItems.contains(where: {
                $0.title.localizedCaseInsensitiveContains(search)
            })
        else { return nil }
        return search
    }

    private func matching(_ items: [TodoItem], _ query: String?) -> [TodoItem] {
        guard let query else { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    // Resolve `query` once per property; reading it per section re-scans every
    // item, and body re-runs on each keystroke.
    private var visibleSections: [(day: Date, items: [TodoItem])] {
        let q = query
        return store.activeByDay.compactMap { section -> (day: Date, items: [TodoItem])? in
            let items = matching(section.items, q)
            return items.isEmpty ? nil : (section.day, items)
        }
    }

    private var visibleRecentDone: (today: [TodoItem], earlier: [TodoItem]) {
        let (today, earlier) = store.recentCompletedByDay
        let q = query
        return (matching(today, q), matching(earlier, q))
    }
    private var visibleOlderDone: [TodoItem] { matching(store.olderCompletedItems, query) }

    /// A section control acts on every row, so hide it while searching.
    private var canBulkAct: Bool { query == nil }

    private func ids(for target: BulkTarget) -> [UUID] {
        switch target {
        case .recent: store.recentCompletedItems.map(\.id)
        case .older: store.olderCompletedItems.map(\.id)
        case .day(let day):
            store.activeByDay.first { $0.day == day }?.items.map(\.id) ?? []
        }
    }

    /// Only past day sections offer the move.
    private func moveTarget(_ day: Date) -> BulkTarget? {
        Calendar.current.isDateInToday(day) ? nil : .day(day)
    }

    /// Idle action icon, or confirm + cancel once opened. Icons fit the header
    /// row; text would wrap the title.
    @ViewBuilder
    private func bulkControl(_ target: BulkTarget) -> some View {
        if bulkTarget == target {
            let ids = ids(for: target)
            HStack(spacing: 8) {
                Button {
                    withAnimation(rowAnimation) {
                        switch target {
                        case .recent, .older: store.delete(ids: ids)
                        case .day: store.moveToToday(ids: ids)
                        }
                        bulkTarget = nil
                    }
                } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.green)
                .accessibilityLabel(target.confirmLabel(ids.count))
                .help(target.confirmLabel(ids.count))
                Button {
                    withAnimation(rowAnimation) { bulkTarget = nil }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel")
                .help("Cancel")
            }
        } else {
            Button {
                withAnimation(rowAnimation) { bulkTarget = target }
            } label: {
                Image(systemName: target.icon)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(target.idleLabel)
            .help(target.idleLabel)
        }
    }

    /// Matches land only in the collapsed week-old section, so open it — otherwise
    /// the panel is a single header row.
    private var onlyOlderMatches: Bool {
        guard query != nil, visibleSections.isEmpty else { return false }
        let recent = visibleRecentDone
        return recent.today.isEmpty && recent.earlier.isEmpty && !visibleOlderDone.isEmpty
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
                    // Overlay, not prompt text: stays right-aligned at any
                    // version length and hides while typing.
                    .overlay(alignment: .trailing) {
                        Text("v\(appVersion)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.trailing, 8)
                            .opacity(draft.isEmpty ? 1 : 0)
                            .allowsHitTesting(false)
                            // Opacity alone leaves this in the a11y tree.
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
                // Each keystroke changes the id, cancelling the in-flight sleep, so only
                // the last one writes `search`. Guard is load-bearing: `try?`
                // swallows the CancellationError.
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
                hoveredItem = nil
                // Don't reopen still showing the previous prompt.
                bulkTarget = nil
                editing = nil
                scrollTopTick += 1
                DispatchQueue.main.async { inputFocused = true }
            }
            .onChange(of: store.items) { newItems in
                let currentIDs = Set(newItems.map(\.id))
                expandedItems = expandedItems.intersection(currentIDs)
                // Emptying the section unmounts its header but not this state, so the
                // prompt would re-arm when the section returns.
                if let bulkTarget, ids(for: bulkTarget).isEmpty { self.bulkTarget = nil }
            }

            Divider()
                .padding(.horizontal, 12)

            if store.visibleItems.isEmpty {
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
                                    TodoStore.dayLabel(for: section.day),
                                    bulk: moveTarget(section.day))
                                ForEach(section.items) { item in
                                    row(item, in: section.items)
                                }
                            }
                            // Bound once: each read re-walks the store.
                            let visibleRecent = visibleRecentDone
                            if !visibleRecent.today.isEmpty || !visibleRecent.earlier.isEmpty {
                                sectionHeader("Completed", bulk: .recent)
                                ForEach(visibleRecent.today) { item in
                                    row(item, in: visibleRecent.today)
                                }
                                if !visibleRecent.today.isEmpty
                                    && !visibleRecent.earlier.isEmpty
                                {
                                    Divider()
                                        .padding(.horizontal, 36)
                                        .padding(.vertical, 4)
                                }
                                ForEach(visibleRecent.earlier) { item in
                                    row(item, in: visibleRecent.earlier)
                                }
                            }
                            let visibleOlder = visibleOlderDone
                            if !visibleOlder.isEmpty {
                                DisclosureGroup(
                                    isExpanded: $olderExpanded,
                                    content: {
                                        ForEach(visibleOlder) { item in
                                            row(item, in: visibleOlder)
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
                                            // On the Button, which is what VoiceOver focuses.
                                            .accessibilityLabel(
                                                "Completed over a week ago, \(visibleOlder.count)"
                                            )
                                            Spacer()
                                            if canBulkAct {
                                                bulkControl(.older)
                                            }
                                        }
                                        .font(.caption)
                                        .buttonStyle(.plain)
                                    }
                                )
                                // Padding now lives in the style, so rows keep their own 12.
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
                FooterLink(
                    systemName: "lightbulb",
                    label: "See all features",
                    url: "https://github.com/mdopeace/quicktodo#features"
                )
                FooterLink(
                    systemName: "heart",
                    label: "Buy me a coffee",
                    url: "https://buymeacoffee.com/mdopeace"
                )
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
        // Filtering changes list height without touching the store, so the hosting
        // view has to be told to re-measure.
        .onChange(of: search) { _ in
            // Search hides the control but leaves bulkTarget set, so clearing it here
            // would re-arm the prompt on its own.
            bulkTarget = nil
            // The editor can be filtered out of the list, and come back open.
            editing = nil
            if onlyOlderMatches {
                withAnimation(rowAnimation) { olderExpanded = true }
            }
            NotificationCenter.default.post(name: .quickTodoContentHeightChanged, object: nil)
        }
    }

    private func submit() {
        // Capture + clear first: Return reaches both the TextField and the Button, so
        // the second delivery sees an empty draft and is ignored.
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        // Clear the filter too, or the debounce leaves the old rows on screen.
        search = ""
        guard !title.isEmpty else { return }
        withAnimation(rowAnimation) {
            store.add(title)
        }
        scrollTopTick += 1
    }

    private func beginEdit(_ item: TodoItem) {
        // Raw title: the row renders "->" as "→", and saving that back would
        // rewrite the stored text.
        editDraft = item.title
        withAnimation(rowAnimation) { editing = item.id }
        editFocused = true
    }

    /// A blank field cancels — `editTitle` ignores it — so no extra guard here.
    private func commitEdit() {
        guard let id = editing else { return }
        withAnimation(rowAnimation) {
            store.editTitle(id, to: editDraft)
            editing = nil
        }
        // Hand the caret back so adding the next one needs no click.
        DispatchQueue.main.async { inputFocused = true }
    }

    private func cancelEdit() {
        withAnimation(rowAnimation) { editing = nil }
        DispatchQueue.main.async { inputFocused = true }
    }

    /// `bulk` adds the control; nil for Today.
    private func sectionHeader(_ label: String, bulk: BulkTarget?) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let bulk, canBulkAct {
                bulkControl(bulk)
            }
        }
        .font(.caption)
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func row(_ item: TodoItem, in section: [TodoItem]) -> some View {
        let content = HStack(spacing: 8) {
            // Hidden while editing: ticking the row done would carry the field
            // into the Completed section with it.
            if editing != item.id {
                Button {
                    withAnimation(rowAnimation) {
                        store.toggle(item.id)
                    }
                } label: {
                    Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.plain)
            }
            // Tap-to-expand rides on the text, so it goes when the field does.
            Group {
                if editing == item.id {
                    TextField("Todo", text: $editDraft)
                        .textFieldStyle(.roundedBorder)
                        .focused($editFocused)
                        .onSubmit(commitEdit)
                        .accessibilityLabel("Edit todo")
                } else {
                    Text(item.title.replacingOccurrences(of: "->", with: "→"))
                        .strikethrough(item.isDone)
                        .foregroundStyle(item.isDone ? .secondary : .primary)
                        .lineLimit(expandedItems.contains(item.id) ? nil : 1)
                        .truncationMode(.tail)
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
                        .accessibilityLabel(
                            expandedItems.contains(item.id) ? "Collapse" : "Expand"
                        )
                        .accessibilityHint(
                            "Double tap to \(expandedItems.contains(item.id) ? "collapse" : "expand") this item"
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if editing == item.id {
                Button(action: commitEdit) {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.green)
                .accessibilityLabel("Save")
                .help("Save")
                // `editing == nil` on the cluster so a half-typed edit can't be
                // dropped by clicking another row's pencil.
            } else if !item.isDone, editing == nil, hoveredItem == item.id {
                if !Calendar.current.isDateInToday(item.updatedAt) {
                    Button {
                        withAnimation(rowAnimation) {
                            store.moveToToday(ids: [item.id])
                        }
                    } label: {
                        Image(systemName: "arrow.forward")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Move to today")
                    .accessibilityLabel("Move to today")
                }
                Button {
                    beginEdit(item)
                } label: {
                    Image(systemName: "pencil")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Edit")
                .accessibilityLabel("Edit")
                Button {
                    store.cycleRepeat(item.id)
                } label: {
                    Image(systemName: "repeat")
                        .foregroundStyle(item.repeatRule?.tint ?? .secondary)
                }
                .buttonStyle(.plain)
                .help(repeatLabel(item))
                .accessibilityLabel(repeatLabel(item))
                .accessibilityHint("Click to cycle daily, weekly and off")
            }
            // Stays put while editing, but turns into Cancel.
            Button {
                if editing == item.id {
                    cancelEdit()
                } else {
                    withAnimation(rowAnimation) {
                        store.delete(item.id)
                    }
                }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            // Matches the bulk confirm pair: dimmed while deleting, not while cancelling.
            .foregroundStyle(editing == item.id ? Color.primary : Color.secondary)
            .accessibilityLabel(editing == item.id ? "Cancel" : "Delete")
            .help(editing == item.id ? "Cancel" : "Delete")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onHover { inside in
            if inside {
                hoveredItem = item.id
            } else if hoveredItem == item.id {
                hoveredItem = nil
            }
        }

        // Only done rows get a createdAt tooltip; an empty help would still be read
        // out and inherit onto the row's child buttons.
        return Group {
            if item.isDone {
                content.help(
                    item.repeatRule == nil
                        ? "Created: \(TodoStore.dayLabel(for: item.createdAt))"
                        : "Created: \(TodoStore.dayLabel(for: item.createdAt)) · \(repeatLabel(item))"
                )
            } else {
                // Reorder controls are active-only: done rows sit in their own
                // sections, so offering them would be a no-op.
                let row =
                    content
                    .draggable(item.id.uuidString)
                    .dropDestination(for: String.self) { payloads, _ in
                        // A filtered list would renumber only the visible rows.
                        guard query == nil,
                            let raw = payloads.first,
                            let dragged = UUID(uuidString: raw)
                        else { return false }
                        let ids = section.map(\.id)
                        guard let from = ids.firstIndex(of: dragged),
                            let at = ids.firstIndex(of: item.id),
                            from != at
                        else { return false }
                        // Downward drops shift one slot, matching move's post-lift indexing.
                        withAnimation(rowAnimation) {
                            store.move(dragged, to: from < at ? at - 1 : at)
                        }
                        return true
                    }
                    // Drag is pointer-only; this is the keyboard/VoiceOver route.
                    .accessibilityAction(named: Text("Move up")) {
                        nudge(item.id, by: -1, in: section)
                    }
                    .accessibilityAction(named: Text("Move down")) {
                        nudge(item.id, by: 1, in: section)
                    }
                    .accessibilityAction(named: Text("Change repeat")) {
                        store.cycleRepeat(item.id)
                    }
                    .accessibilityAction(named: Text("Edit")) {
                        beginEdit(item)
                    }
                // Hover is pointer-only, so keyboard users need this route too — but only
                // where the button shows, or it's a no-op.
                if Calendar.current.isDateInToday(item.updatedAt) {
                    row
                } else {
                    row.accessibilityAction(named: Text("Move to today")) {
                        withAnimation(rowAnimation) {
                            store.moveToToday(ids: [item.id])
                        }
                    }
                }
            }
        }
    }

    private func repeatLabel(_ item: TodoItem) -> String {
        item.repeatRule.map { "Repeats \($0.title.lowercased())" } ?? "Repeat off"
    }

    private func nudge(_ id: UUID, by step: Int, in section: [TodoItem]) {
        let ids = section.map(\.id)
        guard query == nil, let i = ids.firstIndex(of: id) else { return }
        let j = i + step
        guard ids.indices.contains(j) else { return }
        withAnimation(rowAnimation) { store.move(id, to: j) }
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
