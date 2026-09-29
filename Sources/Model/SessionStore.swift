import SwiftUI

/// The session tree, its presentation state, and the flattening that turns it
/// into sidebar rows. Mirrors the reference mockup's `walk()`.
/// Which sidebar row is highlighted.
enum SidebarSelection: Hashable, Sendable {
    case session(String, inPinned: Bool)
    case group(String)
}

@MainActor
@Observable
final class SessionStore {
    /// Where a row's **icon** sits, per tree level. The disclosure chevron is
    /// drawn in the space to the left of it rather than in front of it, so a
    /// group and a session at the same depth share one icon column and nothing
    /// is pushed right to make room for a triangle.
    ///
    /// The step is narrower than the icon it indents, which is deliberate: the
    /// sidebar is 248pt and a host normally sits two levels down, so every
    /// point spent here comes off the name.
    static let indentStep: CGFloat = 8
    /// **Do not go below `SidebarMetrics.chevronInset` (14).** This is the
    /// gutter the chevron hangs in at the shallowest level, and at 14 there is
    /// none to spare: a smaller value makes that spacer's width negative,
    /// SwiftUI clamps it to zero, and the section headers silently stop lining
    /// up with the icon column beneath them.
    static let indentBase: CGFloat = 14

    var tree: [SessionGroup]
    var sessions: [String: Session]
    /// The one highlighted row in the sidebar. A single value on purpose: a
    /// session id and a group id kept side by side could both be set, and a
    /// pinned session is also listed in the tree, so "which session" alone
    /// lit up two rows. The pinned strip counts as a place of its own.
    var selection: SidebarSelection?
    /// Every tree row that is highlighted — one after a plain click, several
    /// after ⌘- or ⇧-clicks. `selection` is the one of them the keyboard and
    /// menu commands act on, and the anchor a ⇧-click extends from. Rows in the
    /// Pinned strip are never part of this: they are shortcuts, not places.
    var selectedItems: Set<SidebarDragItem> = []

    /// The selected session, wherever it was clicked. Setting it selects the
    /// session's row in the tree.
    var selectedID: String? {
        get {
            if case .session(let id, _) = selection { return id }
            return nil
        }
        set {
            selection = newValue.map { .session($0, inPinned: false) }
            selectedItems = newValue.map { [SidebarDragItem(kind: .session, id: $0)] } ?? []
        }
    }

    var selectedGroupID: String? {
        if case .group(let id) = selection { return id }
        return nil
    }
    var pinnedIDs: [String]
    var collapsedGroupIDs: Set<String>

    init(tree: [SessionGroup], sessions: [String: Session], selectedID: String?, pinnedIDs: [String]) {
        self.tree = tree
        self.sessions = sessions
        selection = selectedID.map { .session($0, inPinned: false) }
        self.pinnedIDs = pinnedIDs
        collapsedGroupIDs = []
    }

    var isEmpty: Bool { sessions.isEmpty }

    func select(session id: String, inPinned: Bool = false) {
        selection = .session(id, inPinned: inPinned)
        selectedItems = inPinned ? [] : [SidebarDragItem(kind: .session, id: id)]
    }

    func select(group id: String) {
        selection = .group(id)
        selectedItems = [SidebarDragItem(kind: .group, id: id)]
    }

    /// How a click on a tree row changes the selection.
    enum SelectionGesture {
        /// A plain click: this row alone.
        case single
        /// ⌘-click: add or remove this row, keep the rest.
        case toggle
        /// ⇧-click: everything from the anchor to this row, in the order shown.
        case extend
    }

    /// - Parameter shown: the rows as the sidebar lists them, which is what a
    ///   ⇧-click range runs along.
    func click(_ item: SidebarDragItem, _ gesture: SelectionGesture, shown: [SidebarDragItem]) {
        switch gesture {
        case .single:
            item.kind == .session ? select(session: item.id) : select(group: item.id)

        case .toggle:
            if selectedItems.contains(item) {
                selectedItems.remove(item)
                if selection.map(Self.item(for:)) == item {
                    selection = shown.first(where: selectedItems.contains).map(Self.selection(for:))
                }
            } else {
                // A pinned-strip highlight is not a place the tree can extend.
                if case .session(_, true) = selection { selectedItems = [] }
                selectedItems.insert(item)
                selection = Self.selection(for: item)
            }

        case .extend:
            guard let anchor = selection.flatMap(Self.item(for:)),
                  let from = shown.firstIndex(of: anchor),
                  let to = shown.firstIndex(of: item)
            else {
                click(item, .single, shown: shown)
                return
            }
            // The anchor stays where it is, so ⇧-clicking again re-ranges from it.
            selectedItems = Set(shown[min(from, to)...max(from, to)])
        }
    }

    private static func item(for selection: SidebarSelection) -> SidebarDragItem? {
        switch selection {
        case .session(let id, let inPinned): inPinned ? nil : SidebarDragItem(kind: .session, id: id)
        case .group(let id): SidebarDragItem(kind: .group, id: id)
        }
    }

    private static func selection(for item: SidebarDragItem) -> SidebarSelection {
        item.kind == .session ? .session(item.id, inPinned: false) : .group(item.id)
    }

    /// What a drag that starts on `item` carries: the whole selection when the
    /// row is part of one, otherwise the row alone.
    func dragPayload(startingAt item: SidebarDragItem) -> [SidebarDragItem] {
        guard selectedItems.count > 1, selectedItems.contains(item) else { return [item] }
        return normalized(Array(selectedItems))
    }

    /// Items in the order the tree holds them, without any that sit inside a
    /// group also being moved — that group carries them along, and moving them
    /// separately as well would pull them out of it.
    func normalized(_ items: [SidebarDragItem]) -> [SidebarDragItem] {
        let wanted = Set(items)
        let movingGroups = Set(items.filter { $0.kind == .group }.map(\.id))
        var out: [SidebarDragItem] = []
        func walk(_ nodes: [TreeNode], insideMovingGroup: Bool) {
            for node in nodes {
                switch node {
                case .session(let id):
                    let item = SidebarDragItem(kind: .session, id: id)
                    if wanted.contains(item), !insideMovingGroup { out.append(item) }
                case .group(let group):
                    let item = SidebarDragItem(kind: .group, id: group.id)
                    if wanted.contains(item), !insideMovingGroup { out.append(item) }
                    walk(group.children, insideMovingGroup: insideMovingGroup || movingGroups.contains(group.id))
                }
            }
        }
        for group in tree {
            let item = SidebarDragItem(kind: .group, id: group.id)
            if wanted.contains(item) { out.append(item) }
            walk(group.children, insideMovingGroup: movingGroups.contains(group.id))
        }
        return out
    }

    func session(_ id: String) -> Session? { sessions[id] }

    func isPinned(_ id: String) -> Bool { pinnedIDs.contains(id) }

    func togglePin(_ id: String) {
        if let index = pinnedIDs.firstIndex(of: id) {
            pinnedIDs.remove(at: index)
        } else {
            pinnedIDs.append(id)
        }
    }

    func toggleCollapsed(_ groupID: String) {
        if collapsedGroupIDs.contains(groupID) {
            collapsedGroupIDs.remove(groupID)
        } else {
            collapsedGroupIDs.insert(groupID)
        }
    }

    /// Only nested groups carry a color; top-level groups are plain folders.
    /// Refreshes the inheritance tables, since the change flows downwards.
    func setColor(_ colorID: String?, forGroup groupID: String) {
        for index in tree.indices {
            var children = tree[index].children
            if Self.mutateGroup(groupID, in: &children, { $0.colorID = colorID }) {
                tree[index].children = children
                return
            }
        }
    }

    func setIcon(_ icon: SessionIcon, forSession id: String) {
        sessions[id]?.icon = icon
    }

    @discardableResult
    private static func mutateGroup(
        _ id: String,
        in nodes: inout [TreeNode],
        _ body: (inout SessionGroup) -> Void
    ) -> Bool {
        for index in nodes.indices {
            guard case .group(var group) = nodes[index] else { continue }
            if group.id == id {
                body(&group)
                nodes[index] = .group(group)
                return true
            }
            var children = group.children
            if mutateGroup(id, in: &children, body) {
                group.children = children
                nodes[index] = .group(group)
                return true
            }
        }
        return false
    }

    // MARK: - Drag and drop

    /// Whether a dragged row may land at this spot. A `nil` parent is the top
    /// level, which only groups can occupy — a session always lives inside a
    /// group.
    func canDrop(_ item: SidebarDragItem, to target: DropTarget) -> Bool {
        switch item.kind {
        case .session:
            guard target.parentGroupID != nil else { return false }
        case .group:
            // A group cannot land inside itself or its own subtree; that would
            // detach the whole branch.
            if let parent = target.parentGroupID,
               subtreeGroupIDs(of: item.id).contains(parent) { return false }
        }
        guard let current = position(of: item) else {
            // Not in the tree yet: the New session sheet creates the session
            // first and then places it.
            return item.kind == .session && sessions[item.id] != nil
        }
        guard current.parent == target.parentGroupID else { return true }
        // Within the same parent only a real change of position counts: landing
        // on either side of your own slot is where you already are, and letting
        // it through makes the row flicker for nothing.
        let destination = target.index ?? childCount(of: target.parentGroupID)
        return destination != current.index && destination != current.index + 1
    }

    /// Several rows at once. One row keeps the stricter single-row rule —
    /// landing next to its own slot is refused so the indicator does not show a
    /// move that changes nothing; for several, that spot can still reorder the
    /// others.
    func canDrop(_ items: [SidebarDragItem], to target: DropTarget) -> Bool {
        let items = normalized(items)
        guard !items.isEmpty else { return false }
        if items.count == 1 { return canDrop(items[0], to: target) }
        for item in items {
            switch item.kind {
            case .session:
                guard target.parentGroupID != nil else { return false }
            case .group:
                if let parent = target.parentGroupID,
                   subtreeGroupIDs(of: item.id).contains(parent) { return false }
            }
        }
        return true
    }

    /// Moves several rows to one place, keeping the order they had in the tree.
    @discardableResult
    func drop(_ items: [SidebarDragItem], to target: DropTarget) -> Bool {
        let items = normalized(items)
        guard canDrop(items, to: target) else { return false }
        if items.count == 1 { return drop(items[0], to: target) }

        // Everything taken out of the destination above the insertion point
        // moves that point up by one.
        var index = target.index ?? childCount(of: target.parentGroupID)
        index -= items.filter { item in
            guard let position = position(of: item) else { return false }
            return position.parent == target.parentGroupID && position.index < index
        }.count

        var nodes: [TreeNode] = []
        for item in items {
            switch item.kind {
            case .session:
                detachSession(item.id)
                nodes.append(.session(item.id))
            case .group:
                if let group = detachGroup(item.id) { nodes.append(.group(group)) }
            }
        }
        for (offset, node) in nodes.enumerated() {
            insert(node, into: target.parentGroupID, at: index + offset)
        }
        if let parent = target.parentGroupID { collapsedGroupIDs.remove(parent) }
        return true
    }

    /// Performs the move a drop asks for, expanding the destination so the
    /// result is visible. Returns false when the drop was not allowed.
    @discardableResult
    func drop(_ item: SidebarDragItem, to target: DropTarget) -> Bool {
        guard canDrop(item, to: target) else { return false }
        let current = position(of: item)
        var index = target.index ?? childCount(of: target.parentGroupID)

        let node: TreeNode
        switch item.kind {
        case .session:
            detachSession(item.id)
            node = .session(item.id)
        case .group:
            guard let detached = detachGroup(item.id) else { return false }
            node = .group(detached)
        }

        // Detaching closed the gap, so everything past the old slot moved up.
        if let current, current.parent == target.parentGroupID, current.index < index {
            index -= 1
        }
        insert(node, into: target.parentGroupID, at: index)
        if let parent = target.parentGroupID { collapsedGroupIDs.remove(parent) }
        return true
    }

    /// Where a node sits now: whose child list, and at which index. `nil`
    /// parent means the top level.
    func position(of item: SidebarDragItem) -> (parent: String?, index: Int)? {
        if item.kind == .group, let index = tree.firstIndex(where: { $0.id == item.id }) {
            return (nil, index)
        }
        func walk(_ nodes: [TreeNode], owner: String) -> (parent: String?, index: Int)? {
            for (childIndex, node) in nodes.enumerated() {
                switch node {
                case .session(let id):
                    if item.kind == .session, id == item.id { return (owner, childIndex) }
                case .group(let group):
                    if item.kind == .group, group.id == item.id { return (owner, childIndex) }
                    if let found = walk(group.children, owner: group.id) { return found }
                }
            }
            return nil
        }
        for group in tree {
            if let found = walk(group.children, owner: group.id) { return found }
        }
        return nil
    }

    private func childCount(of parentGroupID: String?) -> Int {
        guard let parentGroupID else { return tree.count }
        return findGroup(parentGroupID)?.children.count ?? 0
    }

    private func findGroup(_ id: String) -> SessionGroup? {
        func walk(_ nodes: [TreeNode]) -> SessionGroup? {
            for node in nodes {
                guard case .group(let group) = node else { continue }
                if group.id == id { return group }
                if let found = walk(group.children) { return found }
            }
            return nil
        }
        for group in tree {
            if group.id == id { return group }
            if let found = walk(group.children) { return found }
        }
        return nil
    }

    /// Puts a detached node back at a given position, clamping an index that
    /// the tree has since outgrown.
    private func insert(_ node: TreeNode, into parentGroupID: String?, at index: Int) {
        guard let parentGroupID else {
            // Only a group can sit at the top level, and a top-level group is a
            // plain folder: the color it carried while nested does not apply.
            guard case .group(let group) = node else { return }
            tree.insert(SessionGroup(id: group.id, name: group.name,
                                     colorID: nil, children: group.children),
                        at: min(max(index, 0), tree.count))
            return
        }

        if let slot = tree.firstIndex(where: { $0.id == parentGroupID }) {
            tree[slot].children.insert(node, at: min(max(index, 0), tree[slot].children.count))
            return
        }
        for slot in tree.indices {
            var children = tree[slot].children
            let landed = Self.mutateGroup(parentGroupID, in: &children) { group in
                group.children.insert(node, at: min(max(index, 0), group.children.count))
            }
            if landed {
                tree[slot].children = children
                return
            }
        }

        // The destination vanished mid-drag: keep the node reachable rather
        // than dropping it out of the tree.
        if case .group(let group) = node {
            tree.append(SessionGroup(id: group.id, name: group.name,
                                     colorID: nil, children: group.children))
        } else if !tree.isEmpty {
            tree[0].children.append(node)
        }
    }

    // MARK: - Flattening

    /// One pass over the tree: the rows to draw, plus the inherited color and
    /// group path of every session — including sessions hidden inside collapsed
    /// branches, which the tab strip and status bar still need.
    struct Flattened: Sendable {
        var rows: [SidebarRow] = []
        var index = SessionIndex()
    }

    /// Where each session sits, independent of what is expanded.
    struct SessionIndex: Sendable {
        var colorID: [String: String] = [:]
        var path: [String: String] = [:]
        var groupID: [String: String] = [:]
    }

    /// Deliberately pure. An earlier version cached the lookup tables in stored
    /// properties, but this runs straight from `body`, so every render wrote to
    /// observed state and invalidated the view that was drawing it.
    ///
    /// Call it **once** per `body` and read both rows and index off the result:
    /// each call walks the whole tree.
    var flattened: Flattened { flattened(matching: "") }

    /// The sidebar rows, narrowed to what matches `query` when there is one.
    ///
    /// While searching, a session outside the matches and a group with none
    /// below it get no row, and every group that does show is open whatever
    /// `collapsedGroupIDs` says — without changing it, so clearing the search
    /// puts the tree back as it was. Hidden sessions are still recorded in
    /// `index`, and rows keep their real `childIndex`, so a drag made while
    /// searching lands where it looks like it does.
    func flattened(matching query: String) -> Flattened {
        let matches = matchingSessionIDs(query)
        var out = Flattened()

        /// Whether a group has anything to show under the current search.
        func hasMatch(_ nodes: [TreeNode]) -> Bool {
            guard let matches else { return true }
            return nodes.contains { node in
                switch node {
                case .session(let id): matches.contains(id)
                case .group(let group): hasMatch(group.children)
                }
            }
        }

        /// Returns how many sessions the nodes hold, so the counts come out of
        /// the same pass. Asking each group for its own `sessionCount` walked
        /// its subtree again, making the whole flattening quadratic.
        @discardableResult
        func walk(_ nodes: [TreeNode], depth: Int, inherited: String?,
                  path: [String], owner: String) -> Int {
            var total = 0
            for (childIndex, node) in nodes.enumerated() {
                let indent = Self.indentBase + CGFloat(depth) * Self.indentStep
                switch node {
                case .session(let id):
                    guard let session = sessions[id] else { continue }
                    total += 1
                    let joined = path.joined(separator: " / ")
                    let color = GroupColor.sessionColorID(own: session.colorID, inherited: inherited)
                    out.index.colorID[id] = color
                    out.index.path[id] = joined
                    out.index.groupID[id] = owner
                    if let matches, !matches.contains(id) { continue }
                    out.rows.append(.session(SessionRowData(
                        id: id, session: session, groupID: owner,
                        childIndex: childIndex, indent: indent,
                        colorID: color, path: joined
                    )))

                case .group(let group):
                    let effective = group.colorID ?? inherited
                    let childPath = path + [group.name]
                    guard hasMatch(group.children) else {
                        total += markHidden(group.children, inherited: effective,
                                            path: childPath, owner: group.id)
                        continue
                    }
                    let collapsed = matches == nil && collapsedGroupIDs.contains(group.id)
                    // The row is appended before its children are counted, so
                    // remember where to write the count back.
                    let slot = out.rows.count
                    out.rows.append(.group(GroupRowData(
                        id: group.id, name: group.name, count: 0,
                        indent: indent, parentGroupID: owner, childIndex: childIndex,
                        ownColorID: group.colorID,
                        effectiveColorID: effective, isCollapsed: collapsed
                    )))

                    let inside: Int
                    if collapsed {
                        inside = markHidden(group.children, inherited: effective,
                                            path: childPath, owner: group.id)
                    } else {
                        inside = walk(group.children, depth: depth + 1, inherited: effective,
                                      path: childPath, owner: group.id)
                    }
                    total += inside
                    out.rows[slot] = .group(GroupRowData(
                        id: group.id, name: group.name, count: inside,
                        indent: indent, parentGroupID: owner, childIndex: childIndex,
                        ownColorID: group.colorID,
                        effectiveColorID: effective, isCollapsed: collapsed
                    ))
                }
            }
            return total
        }

        /// Records where hidden sessions live without emitting rows for them.
        @discardableResult
        func markHidden(_ nodes: [TreeNode], inherited: String?,
                        path: [String], owner: String) -> Int {
            var total = 0
            for node in nodes {
                switch node {
                case .session(let id):
                    total += 1
                    out.index.colorID[id] = GroupColor.sessionColorID(own: sessions[id]?.colorID,
                                                                      inherited: inherited)
                    out.index.path[id] = path.joined(separator: " / ")
                    out.index.groupID[id] = owner
                case .group(let group):
                    total += markHidden(group.children, inherited: group.colorID ?? inherited,
                                        path: path + [group.name], owner: group.id)
                }
            }
            return total
        }

        var shownTopGroups = 0
        for group in tree {
            guard hasMatch(group.children) else {
                markHidden(group.children, inherited: nil, path: [group.name], owner: group.id)
                continue
            }
            let isFirst = shownTopGroups == 0
            shownTopGroups += 1
            let slot = out.rows.count
            out.rows.append(.topGroup(TopGroupRow(id: group.id, name: group.name,
                                                  count: 0, isFirst: isFirst)))
            let collapsed = matches == nil && collapsedGroupIDs.contains(group.id)
            let inside = collapsed
                ? markHidden(group.children, inherited: nil,
                             path: [group.name], owner: group.id)
                : walk(group.children, depth: 1, inherited: nil,
                       path: [group.name], owner: group.id)
            out.rows[slot] = .topGroup(TopGroupRow(id: group.id, name: group.name,
                                                   count: inside, isFirst: isFirst))
        }
        return out
    }

    /// Sessions matching a search, or `nil` when there is nothing to search
    /// for. Every word of the query has to be found — in the session's name,
    /// host, user or address, in a jump host, or in the name of a group it sits
    /// in — so "prod" shows all of Production and "prod db" only its database.
    func matchingSessionIDs(_ query: String) -> Set<String>? {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }

        var result: Set<String> = []
        func walk(_ nodes: [TreeNode], groupNames: [String]) {
            for node in nodes {
                switch node {
                case .session(let id):
                    guard let session = sessions[id] else { continue }
                    let haystack = [id, session.host, session.user, session.address]
                        + session.jumps.map(\.host) + groupNames
                    if words.allSatisfy({ word in haystack.contains { $0.localizedStandardContains(word) } }) {
                        result.insert(id)
                    }
                case .group(let group):
                    walk(group.children, groupNames: groupNames + [group.name])
                }
            }
        }
        for group in tree { walk(group.children, groupNames: [group.name]) }
        return result
    }

    /// Just the lookup tables — no rows, and **no read of `collapsedGroupIDs`**.
    /// The tab strip and status bar use this, so expanding a group no longer
    /// invalidates them: a session's color and path do not depend on what is
    /// folded away.
    var sessionIndex: SessionIndex {
        var out = SessionIndex()
        func walk(_ nodes: [TreeNode], inherited: String?, path: [String], owner: String) {
            for node in nodes {
                switch node {
                case .session(let id):
                    out.colorID[id] = GroupColor.sessionColorID(own: sessions[id]?.colorID,
                                                                inherited: inherited)
                    out.path[id] = path.joined(separator: " / ")
                    out.groupID[id] = owner
                case .group(let group):
                    walk(group.children, inherited: group.colorID ?? inherited,
                         path: path + [group.name], owner: group.id)
                }
            }
        }
        for group in tree {
            walk(group.children, inherited: nil, path: [group.name], owner: group.id)
        }
        return out
    }

    func rows() -> [SidebarRow] { flattened.rows }

    func colorID(forSession id: String) -> String? { sessionIndex.colorID[id] }
    func color(forSession id: String) -> RGB? { GroupColor.rgb(for: colorID(forSession: id)) }
    func path(forSession id: String) -> String { sessionIndex.path[id] ?? "" }

    /// The pinned strip at the top of the sidebar.
    func pinnedRows(using index: SessionIndex? = nil) -> [SessionRowData] {
        let lookup = index ?? sessionIndex
        return pinnedIDs.compactMap { id in
            guard let session = sessions[id] else { return nil }
            return SessionRowData(
                id: id,
                session: session,
                groupID: lookup.groupID[id] ?? "",
                // The pinned strip cannot be reordered or dropped onto, so the
                // position is never read.
                childIndex: 0,
                indent: 0,
                colorID: lookup.colorID[id],
                path: lookup.path[id] ?? ""
            )
        }
    }

    /// Every group that can be a parent, in tree order, for the New group sheet.
    func groupOptions() -> [(id: String, name: String, depth: Int, colorID: String?)] {
        var out: [(id: String, name: String, depth: Int, colorID: String?)] = []
        func walk(_ nodes: [TreeNode], depth: Int) {
            for node in nodes {
                guard case .group(let group) = node else { continue }
                out.append((group.id, group.name, depth, group.colorID))
                walk(group.children, depth: depth + 1)
            }
        }
        for group in tree {
            out.append((group.id, group.name, 0, nil))
            walk(group.children, depth: 1)
        }
        return out
    }

    // MARK: - Lookups used by the settings sheets

    /// The group and everything under it — the set that cannot be its parent.
    func subtreeGroupIDs(of id: String) -> Set<String> {
        descendantGroupIDs(of: id).union([id])
    }

    func parentID(ofGroup id: String) -> String? { currentParentID(of: id) }

    /// The color a group shows: its own, or the nearest coloured ancestor's.
    func effectiveColorID(ofGroup id: String) -> String? {
        func walk(_ nodes: [TreeNode], inherited: String?) -> String?? {
            for node in nodes {
                guard case .group(let group) = node else { continue }
                let effective = group.colorID ?? inherited
                if group.id == id { return .some(effective) }
                if let found = walk(group.children, inherited: effective) { return found }
            }
            return nil
        }
        for group in tree {
            if group.id == id { return nil }
            if let found = walk(group.children, inherited: nil) { return found }
        }
        return nil
    }

    func colorID(ofGroup id: String) -> String? {
        func walk(_ nodes: [TreeNode]) -> String?? {
            for node in nodes {
                guard case .group(let group) = node else { continue }
                if group.id == id { return .some(group.colorID) }
                if let found = walk(group.children) { return found }
            }
            return nil
        }
        for group in tree {
            if group.id == id { return group.colorID }
            if let found = walk(group.children) { return found }
        }
        return nil
    }

    // MARK: - Editing

    /// Adds a group and returns its id. A `nil` parent creates a top-level
    /// folder, which by design carries no color.
    @discardableResult
    func createGroup(name: String, parentID: String?, colorID: String?) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let id = uniqueGroupID(basedOn: trimmed)

        if let parentID {
            let group = SessionGroup(id: id, name: trimmed, colorID: colorID, children: [])
            guard attach(group: group, under: parentID) else { return nil }
        } else {
            tree.append(SessionGroup(id: id, name: trimmed, colorID: nil, children: []))
        }
        return id
    }

    /// Adds a session under a group and returns its id (the name).
    @discardableResult
    func createSession(_ session: Session, parentID: String?) -> String? {
        let name = session.id.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, sessions[name] == nil else { return nil }
        var stored = session
        stored.id = name
        sessions[name] = stored

        let target = parentID ?? tree.first?.id
        if let target {
            move(session: name, toGroup: target)
        } else {
            tree.append(SessionGroup(id: uniqueGroupID(basedOn: Self.firstGroupName),
                                     name: Self.firstGroupName, colorID: nil,
                                     children: [.session(name)]))
        }
        return name
    }

    /// Adds sessions imported from `~/.ssh/config` to a top-level group of
    /// their own. A name that is already a session is left alone, so importing
    /// again only brings in hosts added since.
    @discardableResult
    func importSessions(_ imported: [Session], groupName: String = "SSH config") -> (added: Int, skipped: Int) {
        let new = imported.filter { sessions[$0.id] == nil }
        guard !new.isEmpty else { return (0, imported.count) }
        let groupID = tree.first { $0.name == groupName }?.id
            ?? createGroup(name: groupName, parentID: nil, colorID: nil)
        var added = 0
        for session in new where createSession(session, parentID: groupID) != nil { added += 1 }
        if let groupID { collapsedGroupIDs.remove(groupID) }
        return (added, imported.count - added)
    }

    /// The group a session goes into when there is none yet.
    static let firstGroupName = "Sessions"

    private func uniqueGroupID(basedOn name: String) -> String {
        let base = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let taken = Set(groupOptions().map(\.id))
        var candidate = base.isEmpty ? "group" : base
        var suffix = 2
        while taken.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    /// Applies everything the group settings sheet can change. Moving is done
    /// before renaming so that the lookup still works on the original id.
    func applyGroupEdits(id: String, name: String, colorID: String?, parentID: String?) {
        move(group: id, toParent: parentID)
        rename(group: id, to: name)
        // Top-level groups are plain folders, so a group moved out to the top
        // loses whatever color it carried.
        setColor(parentID == nil ? nil : colorID, forGroup: id)
    }

    func rename(group id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        for index in tree.indices where tree[index].id == id {
            tree[index].name = trimmed
            return
        }
        for index in tree.indices {
            var children = tree[index].children
            if Self.mutateGroup(id, in: &children, { $0.name = trimmed }) {
                tree[index].children = children
                return
            }
        }
    }

    /// Re-parents a group, appending it to the destination. A `nil` parent
    /// moves it to the top level.
    ///
    /// The settings sheet picks a parent from a list without saying where inside
    /// it the group should go, so leaving the parent alone stays a no-op —
    /// saving the sheet must not shuffle the group to the end of its own parent.
    func move(group id: String, toParent parentID: String?) {
        guard currentParentID(of: id) != parentID else { return }
        drop(SidebarDragItem(kind: .group, id: id), to: .into(parentID))
    }

    func isTopLevel(_ id: String) -> Bool {
        tree.contains { $0.id == id }
    }

    private func currentParentID(of id: String) -> String? {
        func walk(_ nodes: [TreeNode], parent: String?) -> String?? {
            for node in nodes {
                guard case .group(let group) = node else { continue }
                if group.id == id { return .some(parent) }
                if let found = walk(group.children, parent: group.id) { return found }
            }
            return nil
        }
        for group in tree {
            if group.id == id { return nil }
            if let found = walk(group.children, parent: group.id) { return found }
        }
        return nil
    }

    private func descendantGroupIDs(of id: String) -> Set<String> {
        func collect(_ nodes: [TreeNode], into set: inout Set<String>) {
            for node in nodes {
                guard case .group(let group) = node else { continue }
                set.insert(group.id)
                collect(group.children, into: &set)
            }
        }
        var out: Set<String> = []
        if let index = tree.firstIndex(where: { $0.id == id }) {
            collect(tree[index].children, into: &out)
            return out
        }
        func find(_ nodes: [TreeNode]) -> SessionGroup? {
            for node in nodes {
                guard case .group(let group) = node else { continue }
                if group.id == id { return group }
                if let found = find(group.children) { return found }
            }
            return nil
        }
        for group in tree {
            if let found = find(group.children) {
                collect(found.children, into: &out)
                return out
            }
        }
        return out
    }

    /// Removes a group from the tree and hands it back.
    private func detachGroup(_ id: String) -> SessionGroup? {
        if let index = tree.firstIndex(where: { $0.id == id }) {
            return tree.remove(at: index)
        }
        func walk(_ nodes: inout [TreeNode]) -> SessionGroup? {
            for index in nodes.indices {
                guard case .group(var group) = nodes[index] else { continue }
                if group.id == id {
                    nodes.remove(at: index)
                    return group
                }
                var children = group.children
                if let found = walk(&children) {
                    group.children = children
                    nodes[index] = .group(group)
                    return found
                }
            }
            return nil
        }
        for index in tree.indices {
            var children = tree[index].children
            if let found = walk(&children) {
                tree[index].children = children
                return found
            }
        }
        return nil
    }

    @discardableResult
    private func attach(group: SessionGroup, under parentID: String) -> Bool {
        if let index = tree.firstIndex(where: { $0.id == parentID }) {
            tree[index].children.append(.group(group))
            return true
        }
        for index in tree.indices {
            var children = tree[index].children
            if Self.mutateGroup(parentID, in: &children, { $0.children.append(.group(group)) }) {
                tree[index].children = children
                return true
            }
        }
        return false
    }

    /// Renames a session in place. Refused — returning false — for an empty
    /// name or one another session already has, since the name is the id.
    @discardableResult
    func renameSession(_ id: String, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != id, var session = sessions[id],
              sessions[trimmed] == nil else { return false }
        session.id = trimmed
        applySessionEdits(originalID: id, updated: session, parentID: nil)
        return true
    }

    /// Applies everything the session settings sheet can change, including a
    /// rename (the name is the id) and a move to another group.
    func applySessionEdits(originalID: String, updated: Session, parentID: String?) {
        let newID = updated.id.trimmingCharacters(in: .whitespaces)
        guard !newID.isEmpty else { return }

        sessions[originalID] = nil
        var stored = updated
        stored.id = newID
        sessions[newID] = stored

        if newID != originalID {
            replaceSessionID(originalID, with: newID)
            pinnedIDs = pinnedIDs.map { $0 == originalID ? newID : $0 }
            if case .session(originalID, let inPinned) = selection {
                selection = .session(newID, inPinned: inPinned)
            }
            let old = SidebarDragItem(kind: .session, id: originalID)
            if selectedItems.remove(old) != nil {
                selectedItems.insert(SidebarDragItem(kind: .session, id: newID))
            }
        }
        if let parentID {
            move(session: newID, toGroup: parentID)
        }
    }

    private func replaceSessionID(_ oldID: String, with newID: String) {
        func walk(_ nodes: inout [TreeNode]) {
            for index in nodes.indices {
                switch nodes[index] {
                case .session(let id) where id == oldID:
                    nodes[index] = .session(newID)
                case .group(var group):
                    var children = group.children
                    walk(&children)
                    group.children = children
                    nodes[index] = .group(group)
                default:
                    break
                }
            }
        }
        for index in tree.indices {
            var children = tree[index].children
            walk(&children)
            tree[index].children = children
        }
    }

    /// Moves a session to the end of another group, a no-op when it is already
    /// there. The settings sheet uses this; a drag uses `drop(_:to:)` so it can
    /// say where in the group the session lands.
    func move(session id: String, toGroup parentID: String) {
        guard currentGroupID(ofSession: id) != parentID else { return }
        drop(SidebarDragItem(kind: .session, id: id), to: .into(parentID))
    }

    func currentGroupID(ofSession id: String) -> String? {
        func walk(_ nodes: [TreeNode], owner: String) -> String? {
            for node in nodes {
                switch node {
                case .session(let sessionID) where sessionID == id: return owner
                case .group(let group):
                    if let found = walk(group.children, owner: group.id) { return found }
                default: break
                }
            }
            return nil
        }
        for group in tree {
            if let found = walk(group.children, owner: group.id) { return found }
        }
        return nil
    }

    private func detachSession(_ id: String) {
        func walk(_ nodes: inout [TreeNode]) {
            var index = 0
            while index < nodes.count {
                switch nodes[index] {
                case .session(let sessionID) where sessionID == id:
                    nodes.remove(at: index)
                    continue
                case .group(var group):
                    var children = group.children
                    walk(&children)
                    group.children = children
                    nodes[index] = .group(group)
                default:
                    break
                }
                index += 1
            }
        }
        for index in tree.indices {
            var children = tree[index].children
            walk(&children)
            tree[index].children = children
        }
    }

    /// Ancestor names for a group, outermost first, e.g. ["Production", "Web"].
    func groupPath(_ id: String) -> [String] {
        func walk(_ nodes: [TreeNode], prefix: [String]) -> [String]? {
            for node in nodes {
                guard case .group(let group) = node else { continue }
                let path = prefix + [group.name]
                if group.id == id { return path }
                if let found = walk(group.children, prefix: path) { return found }
            }
            return nil
        }
        for group in tree {
            if group.id == id { return [group.name] }
            if let found = walk(group.children, prefix: [group.name]) { return found }
        }
        return []
    }

    func clearAll() {
        tree = []
        sessions = [:]
        pinnedIDs = []
        selectedID = nil
    }

    /// Removes rows for good: a session, or a group with everything inside it.
    /// Rows inside a group that is also being deleted count once. Returns the
    /// sessions that went, so their stored passwords can go with them.
    @discardableResult
    func delete(_ items: [SidebarDragItem]) -> [Session] {
        var deletedSessions: [String] = []
        var deletedGroups: Set<String> = []

        func collect(_ nodes: [TreeNode]) {
            for node in nodes {
                switch node {
                case .session(let id): deletedSessions.append(id)
                case .group(let group):
                    deletedGroups.insert(group.id)
                    collect(group.children)
                }
            }
        }

        for item in normalized(items) {
            switch item.kind {
            case .session:
                detachSession(item.id)
                deletedSessions.append(item.id)
            case .group:
                if let group = detachGroup(item.id) {
                    deletedGroups.insert(group.id)
                    collect(group.children)
                }
            }
        }

        let removed = deletedSessions.compactMap { sessions.removeValue(forKey: $0) }
        let gone = Set(deletedSessions)
        pinnedIDs.removeAll { gone.contains($0) }
        collapsedGroupIDs.subtract(deletedGroups)
        selectedItems = selectedItems.filter { item in
            item.kind == .session ? !gone.contains(item.id) : !deletedGroups.contains(item.id)
        }
        switch selection {
        case .session(let id, _) where gone.contains(id): selection = nil
        case .group(let id) where deletedGroups.contains(id): selection = nil
        default: break
        }
        return removed
    }

    /// How many sessions `delete` would remove, groups' contents included —
    /// for the confirmation.
    func sessionCount(in items: [SidebarDragItem]) -> Int {
        normalized(items).reduce(0) { total, item in
            switch item.kind {
            case .session: return total + 1
            case .group:
                return total + (findGroup(item.id).map { TreeNode.group($0).sessionCount } ?? 0)
            }
        }
    }

    /// Puts the test lab's group into whatever tree is loaded — the real one
    /// included, so the lab sessions can be saved and edited like any other.
    /// Sessions that already exist under those names are left as they are;
    /// the group itself is replaced, and its sessions are taken out of any
    /// other place in the tree first so none appears twice.
    func addTestLab() {
        let lab = SessionStore.testLab()
        for session in lab.sessions where sessions[session.id] == nil {
            sessions[session.id] = session
        }
        tree.removeAll { $0.id == lab.group.id }
        for session in lab.sessions { detachSession(session.id) }
        tree.append(lab.group)
        collapsedGroupIDs.subtract([lab.group.id, "testlab-direct", "testlab-jump"])
    }

    func loadSample() {
        let sample = SessionStore.sample()
        tree = sample.tree
        sessions = sample.sessions
        pinnedIDs = sample.pinnedIDs
        selectedID = sample.selectedID
        collapsedGroupIDs = sample.collapsedGroupIDs
    }
}
