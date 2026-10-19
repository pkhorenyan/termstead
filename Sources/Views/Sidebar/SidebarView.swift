import SwiftUI


struct SidebarView: View {
    @Environment(\.theme) private var theme
    @Environment(SessionStore.self) private var sessionStore
    @Environment(AppState.self) private var appState
    @Environment(ConnectionStore.self) private var connectionStore
    /// Which edge of the window the sidebar is on; the tab rail keeps to the
    /// window's edge either way.
    var side: ThemeStore.SidebarSide = .left

    @State private var search = ""
    /// Rows waiting for the user to confirm they should be deleted.
    @State private var pendingDeletion: [SidebarDragItem]?
    /// The row whose name is being edited in place, and the text so far.
    @State private var renaming: SidebarDragItem?
    @State private var renameText = ""
    /// The tree's keyboard, which a click on any row hands it.
    @State private var keyboard = TreeKeyboardFocus()
    /// A row the keyboard moved to, waiting to be scrolled into view.
    @State private var reveal: String?

    var body: some View {
        @Bindable var appState = appState

        HStack(spacing: 0) {
            if side == .left {
                SidebarTabRail(selection: $appState.sidebarTab, side: side)
                panel
            } else {
                panel
                SidebarTabRail(selection: $appState.sidebarTab, side: side)
            }
        }
        .alert(deletionTitle, isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )) {
            Button("Delete", role: .destructive) { confirmDeletion() }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(deletionMessage)
        }
    }

    /// The session list stays mounted, hidden, while the SFTP tab shows:
    /// built again on the way back it started at the top, and a long list
    /// lost the place it was scrolled to.
    private var panel: some View {
        let showsSessions = appState.sidebarTab == .sessions
        return ZStack {
            VStack(spacing: 14) {
                searchField

                if sessionStore.isEmpty {
                    emptyTree
                } else {
                    tree
                }

                footer
            }
            .opacity(showsSessions ? 1 : 0)
            .allowsHitTesting(showsSessions)
            .accessibilityHidden(!showsSessions)

            if !showsSessions {
                FilesPanel()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .onChange(of: showsSessions) {
            if !showsSessions { keyboard.release() }
        }
    }

    private var deletionTitle: String {
        guard let items = pendingDeletion.map(sessionStore.normalized) else { return "" }
        if items.count == 1, let item = items.first {
            let name = item.kind == .session ? item.id
                : sessionStore.groupOptions().first { $0.id == item.id }?.name ?? item.id
            return "Delete “\(name)”?"
        }
        return "Delete \(items.count) items?"
    }

    private var deletionMessage: String {
        guard let items = pendingDeletion else { return "" }
        let count = sessionStore.sessionCount(in: items)
        let what = count == 1 ? "1 session" : "\(count) sessions"
        let grouped = items.contains { $0.kind == .group } ? ", including everything inside the groups," : ""
        return "This removes \(what)\(grouped) from the sidebar, and their saved passwords from the Keychain. Open tabs stay open. This cannot be undone."
    }

    private func startRename(_ item: SidebarDragItem) {
        renameText = item.kind == .session ? item.id
            : sessionStore.groupOptions().first { $0.id == item.id }?.name ?? item.id
        renaming = item
    }

    /// A session's name is its id — the tabs, the pins and its Keychain entry
    /// all hang off it — so a rename is carried into each. A name another
    /// session already has is refused and the old one kept.
    private func commitRename() {
        guard let item = renaming else { return }
        renaming = nil
        let name = renameText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        switch item.kind {
        case .group:
            sessionStore.rename(group: item.id, to: name)
        case .session:
            guard name != item.id else { return }
            guard sessionStore.renameSession(item.id, to: name) else {
                NSSound.beep()
                return
            }
            connectionStore.renameSession(from: item.id, to: name)
            KeychainStore.shared.move(SSHLaunch.sessionPasswordAccount(item.id),
                                      to: SSHLaunch.sessionPasswordAccount(name))
        }
    }

    /// ⌫ acts on what is highlighted: the tree selection, or the one Pinned row.
    private func deleteSelection() {
        if !sessionStore.selectedItems.isEmpty {
            pendingDeletion = Array(sessionStore.selectedItems)
        } else if case .session(let id, true) = sessionStore.selection {
            pendingDeletion = [SidebarDragItem(kind: .session, id: id)]
        }
    }

    /// Stored passwords go with their sessions. Key passphrases stay: they
    /// belong to a key file that other sessions may still use.
    /// The copy lands right after the original with its name open for
    /// editing, as Finder's Duplicate does, and connects as the original
    /// does: the saved passwords come along.
    private func duplicate(_ id: String) {
        guard let original = sessionStore.session(id),
              let copy = sessionStore.duplicateSession(id) else { return }
        KeychainStore.shared.copySecrets(of: original, to: copy)
        let item = SidebarDragItem(kind: .session, id: copy.id)
        reveal = listing().rowID(of: .session(copy.id, inPinned: false))
        startRename(item)
    }

    private func confirmDeletion() {
        guard let items = pendingDeletion else { return }
        pendingDeletion = nil
        for session in sessionStore.delete(items) {
            KeychainStore.shared.delete(SSHLaunch.sessionPasswordAccount(session.id))
            for hop in session.jumps {
                KeychainStore.shared.delete(SSHLaunch.hopPasswordAccount(hop.id))
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textMuted.color)

            TextField("Search sessions", text: $search)
                .textFieldStyle(.plain)
                .font(SBFont.ui(12.5))
                .foregroundStyle(theme.text.color)
                .onExitCommand { search = "" }
                .onKeyPress(.downArrow) { enterList() ? .handled : .ignored }

            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textMuted.color)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(FieldBackground(theme: theme, cornerRadius: 7))
        .accessibilityLabel("Search sessions")
    }

    private var emptyTree: some View {
        VStack(spacing: 8) {
            Text("No sessions yet")
                .font(SBFont.ui(13, .medium))
                .foregroundStyle(theme.text.color)
            Text("Saved servers show up here.")
                .font(SBFont.ui(12))
                .foregroundStyle(theme.textMuted.color)
                .lineSpacing(6)
                .multilineTextAlignment(.center)
            Button("Import from ~/.ssh/config") {
                Task { await appState.importSSHConfig(into: sessionStore) }
            }
            .buttonStyle(SecondaryButtonStyle(theme: theme, height: 30, fontSize: 12.5, filled: true))
            .disabled(appState.isImporting)
            .padding(.top, 6)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .contextMenu { blankAreaMenu }
    }

    /// What the Sessions tab lists, top to bottom.
    private struct Listing {
        var pinned: [SessionRowData]
        var rows: [SidebarRow]
        /// The sessions a search lets through; `nil` with no search.
        var matches: Set<String>?

        /// The id a row is drawn under, to scroll to it.
        func rowID(of place: SidebarSelection) -> String? {
            switch place {
            case .session(let id, true): pinned.contains { $0.id == id } ? id : nil
            case .session(let id, false): rows.first { $0.item == SidebarDragItem(kind: .session, id: id) }?.id
            case .group(let id): rows.first { $0.item == SidebarDragItem(kind: .group, id: id) }?.id
            }
        }
    }

    /// Walked once per render: `rows` and `pinned` used to be separate
    /// computed properties, so each read re-flattened the whole tree.
    private func listing() -> Listing {
        let flattened = sessionStore.flattened(matching: search)
        let matches = sessionStore.matchingSessionIDs(search)
        let pinned = sessionStore.pinnedRows(using: flattened.index)
            .filter { matches?.contains($0.id) ?? true }
        return Listing(pinned: pinned, rows: flattened.rows, matches: matches)
    }

    private var tree: some View {
        let listing = listing()
        return ScrollViewReader { proxy in
            list(listing)
                .background(TreeKeyboard(focus: keyboard) { handle($0) })
                .onChange(of: reveal) {
                    guard let reveal else { return }
                    proxy.scrollTo(reveal)
                    self.reveal = nil
                }
        }
        .frame(maxHeight: .infinity)
    }

    private func list(_ listing: Listing) -> some View {
        let pinned = listing.pinned
        let matches = listing.matches

        // With the indicator hidden the list scrolled but gave no sign that it
        // was longer than the window, or where in it you were. It is the
        // system scroller, so it follows the "Show scroll bars" setting.
        return ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 10) {
                if !pinned.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        sectionHeader(title: "Pinned", symbol: "pin.fill")
                        ForEach(pinned) { row in
                            PinnedRowView(
                                row: row,
                                isSelected: sessionStore.selection == .session(row.id, inPinned: true),
                                isLive: connectionStore.isLive(row.id),
                                onSelect: { sessionStore.select(session: row.id, inPinned: true) },
                                onConnect: { connect(row.id, newTab: false, inPinned: true) },
                                onConnectInNewTab: { connect(row.id, newTab: true, inPinned: true) },
                                onOpenSettings: { appState.route = .sessionSettings(id: row.id) },
                                onOpenForwards: { appState.route = .portForwarding(sessionID: row.id) },
                                forwardingItems: connectionStore.forwardingMenuItems(for: row.session, in: sessionStore),
                                forwarding: connectionStore.forwardingSummary(of: row.id),
                                onDuplicate: { duplicate(row.id) },
                                onUnpin: { sessionStore.togglePin(row.id) },
                                onDelete: { pendingDeletion = [SidebarDragItem(kind: .session, id: row.id)] },
                                keyboard: keyboard
                            )
                        }
                    }
                }

                if let matches, matches.isEmpty {
                    Text("No sessions match “\(search.trimmingCharacters(in: .whitespaces))”")
                        .font(SBFont.ui(12))
                        .foregroundStyle(theme.textMuted.color)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                }

                // Lazy so a long host list does not lay out every row that is
                // scrolled out of sight.
                LazyVStack(alignment: .leading, spacing: 1) {
                    let shown = listing.rows.map(\.item)
                    let targets = moveTargets
                    ForEach(listing.rows) { row in
                        rowView(row, shown: shown, targets: targets)
                    }
                }

                RootDropZone(
                    canDrop: { sessionStore.canDrop($0, to: .into(nil)) },
                    onDrop: { sessionStore.drop($0, to: .into(nil)) }
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ThinScroller(isDark: theme.isDark, alwaysVisible: true))
        }
        // The rows' own menus win over this one; it answers everywhere else,
        // the empty space under the last row included.
        .contextMenu { blankAreaMenu }
    }

    @ViewBuilder
    private var blankAreaMenu: some View {
        Button("New Session…") { appState.route = .newSession(parentGroupID: nil) }
        Button("New Group…") { appState.route = .newGroup(parentGroupID: nil) }
        Button("Quick Connect…") { appState.route = .quickConnect }
        Divider()
        Button("Import from ~/.ssh/config") {
            Task { await appState.importSSHConfig(into: sessionStore) }
        }
        .disabled(appState.isImporting)
    }

    /// The list is read when the key arrives, not when the view was drawn:
    /// a key can come before the redraw that follows the one before it.
    private func handle(_ key: TreeKey) {
        let listing = listing()
        switch key {
        case .delete:
            deleteSelection()
        case .step(let step, let extending):
            let place = sessionStore.step(step, extending: extending, pinned: listing.pinned.map(\.id),
                                          rows: listing.rows, canFold: listing.matches == nil)
            reveal = place.flatMap(listing.rowID(of:))
        case .open:
            open(listing)
        case .leave:
            guard let terminal = connectionStore.active?.terminalView else { return }
            terminal.window?.makeFirstResponder(terminal)
        }
    }

    /// Return connects every selected session, the anchor's tab in front, or
    /// opens and closes a lone group.
    private func open(_ listing: Listing) {
        let ids = sessionStore.sessionsToOpen(along: listing.rows)
        guard !ids.isEmpty else {
            if case .group(let id)? = sessionStore.selection, listing.matches == nil {
                sessionStore.toggleCollapsed(id)
            }
            return
        }
        for id in ids { connectionStore.connect(sessionID: id, in: sessionStore) }
        // The same tab `connect` brings forward for a session already open.
        if case .session(let anchor, _)? = sessionStore.selection,
           let tab = connectionStore.connections.first(where: {
               $0.sessionID == anchor && $0.state.isRunning && !$0.isTunnelOnly
           }) {
            connectionStore.activeID = tab.id
        }
    }

    /// ↓ in the search field: the keyboard moves to the first session listed,
    /// so that Return connects it.
    private func enterList() -> Bool {
        let listing = listing()
        let first = listing.pinned.first.map { SidebarSelection.session($0.id, inPinned: true) }
            ?? listing.rows.first { $0.item.kind == .session }.map { .session($0.item.id, inPinned: false) }
        guard case .session(let id, let inPinned)? = first else { return false }
        sessionStore.select(session: id, inPinned: inPinned)
        reveal = first.flatMap(listing.rowID(of:))
        keyboard.take()
        return true
    }

    @ViewBuilder
    private func rowView(_ row: SidebarRow, shown: [SidebarDragItem], targets: [MoveTarget]) -> some View {
        let actions = actions(for: row.item, shown: shown, targets: targets)
        switch row {
        case .topGroup(let data):
            TopGroupHeaderView(
                row: data,
                isCollapsed: sessionStore.collapsedGroupIDs.contains(data.id),
                actions: actions,
                onToggleCollapse: { sessionStore.toggleCollapsed(data.id) },
                onAddSession: { appState.route = .newSession(parentGroupID: data.id) },
                onAddSubgroup: { appState.route = .newGroup(parentGroupID: data.id) },
                onOpenSettings: { appState.route = .groupSettings(id: data.id) }
            )
            .padding(.top, data.isFirst ? 0 : 12)

        case .group(let data):
            GroupRowView(
                row: data,
                onToggleCollapse: { sessionStore.toggleCollapsed(data.id) },
                onAddSession: { appState.route = .newSession(parentGroupID: data.id) },
                onAddSubgroup: { appState.route = .newGroup(parentGroupID: data.id) },
                onOpenSettings: { appState.route = .groupSettings(id: data.id) },
                actions: actions
            )

        case .session(let data):
            SessionRowView(
                row: data,
                isPinned: sessionStore.isPinned(data.id),
                isLive: connectionStore.isLive(data.id),
                onConnect: { connect(data.id, newTab: false) },
                onConnectInNewTab: { connect(data.id, newTab: true) },
                onTogglePin: { sessionStore.togglePin(data.id) },
                onOpenSettings: { appState.route = .sessionSettings(id: data.id) },
                onOpenForwards: { appState.route = .portForwarding(sessionID: data.id) },
                forwardingItems: connectionStore.forwardingMenuItems(for: data.session, in: sessionStore),
                forwarding: connectionStore.forwardingSummary(of: data.id),
                onDuplicate: { duplicate(data.id) },
                actions: actions
            )
        }
    }

    /// The top level, then every group, indented by depth, for Move To.
    private var moveTargets: [MoveTarget] {
        [MoveTarget(groupID: nil, title: "Top Level")]
            + sessionStore.groupOptions().map { option in
                MoveTarget(groupID: option.id,
                           title: String(repeating: "    ", count: option.depth) + option.name)
            }
    }

    /// - Parameter shown: the rows in the order listed, which a ⇧-click range
    ///   runs along — so a search narrows the range to what is on screen.
    private func actions(for item: SidebarDragItem, shown: [SidebarDragItem],
                         targets: [MoveTarget]) -> TreeRowActions {
        let selected = sessionStore.selectedItems
        return TreeRowActions(
            isSelected: selected.contains(item),
            isInMultiSelection: selected.count > 1 && selected.contains(item),
            onSelect: { modifiers in
                let gesture: SessionStore.SelectionGesture =
                    modifiers.contains(.command) ? .toggle : modifiers.contains(.shift) ? .extend : .single
                sessionStore.click(item, gesture, shown: shown)
            },
            dragItems: { sessionStore.dragPayload(startingAt: item) },
            canDrop: { sessionStore.canDrop($0, to: $1) },
            onDrop: { sessionStore.drop($0, to: $1) },
            moveTargets: targets,
            onMove: { groupID in
                sessionStore.drop(sessionStore.dragPayload(startingAt: item), to: .into(groupID))
            },
            onDelete: { pendingDeletion = sessionStore.dragPayload(startingAt: item) },
            keyboard: keyboard,
            isRenaming: renaming == item,
            renameText: $renameText,
            onStartRename: { startRename(item) },
            onCommitRename: { commitRename() },
            onCancelRename: { renaming = nil }
        )
    }

    private func connect(_ id: String, newTab: Bool, inPinned: Bool = false) {
        sessionStore.select(session: id, inPinned: inPinned)
        connectionStore.connect(sessionID: id, in: sessionStore, newTab: newTab)
    }

    private func sectionHeader(title: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
            Text(title.uppercased())
                .font(SBFont.ui(11, .semibold))
                .kerning(0.88)
        }
        .foregroundStyle(theme.textMuted.color)
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
    }

    /// Session and Group, empty tree or not: a first launch offered only
    /// "Add session", and nothing on screen made a group.
    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                appState.route = .newSession(parentGroupID: nil)
            } label: {
                Label("Session", systemImage: "plus")
                    .labelStyle(InlineIconLabelStyle(spacing: 6, iconSize: 11))
            }
            .buttonStyle(DashedButtonStyle(theme: theme))

            Button {
                appState.route = .newGroup(parentGroupID: nil)
            } label: {
                Label("Group", systemImage: "folder.badge.plus")
                    .labelStyle(InlineIconLabelStyle(spacing: 6, iconSize: 11))
            }
            .buttonStyle(DashedButtonStyle(theme: theme))
        }
    }

}

/// Strip under the last row that pulls a group back out to the top level.
///
/// It is a sibling of the rows, not an ancestor: mounted on the enclosing
/// scroll view it swallowed every drop before the row underneath could see it,
/// since a session can never land at the top level.
private struct RootDropZone: View {
    @Environment(\.theme) private var theme
    var canDrop: ([SidebarDragItem]) -> Bool
    var onDrop: ([SidebarDragItem]) -> Bool

    var body: some View {
        Color.clear
            .frame(height: 96)
            .overlay {
                RowInteraction(
                    item: nil,
                    dropMode: .intoOnly,
                    theme: theme,
                    dragLabel: "",
                    dragSymbol: "folder",
                    dragTint: nil,
                    onClick: { _ in },
                    onDoubleClick: {},
                    canDrop: { items, _ in canDrop(items) },
                    performDrop: { items, _ in onDrop(items) }
                )
            }
            .accessibilityLabel("Move to top level")
    }
}

/// Keeps the glyph and the text on one line at the sizes the design uses;
/// `.titleAndIcon` would inherit the system label metrics instead.
struct InlineIconLabelStyle: LabelStyle {
    var spacing: CGFloat = 6
    var iconSize: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon
                .font(.system(size: iconSize, weight: .medium))
            configuration.title
        }
    }
}
