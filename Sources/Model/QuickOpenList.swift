import Foundation

/// One line of Quick connect's list.
enum QuickOpenRow: Identifiable, Hashable {
    case header(String)
    case group(id: String, name: String, depth: Int, colorID: String?, isCollapsed: Bool)
    /// `inRecent` keeps a session's Recent row apart from its row in the tree.
    case session(SessionRowData, depth: Int, inRecent: Bool)
    /// Connect to what was typed, without saving it.
    case address(String)

    var id: String {
        switch self {
        case .header(let title): "header:\(title)"
        case .group(let id, _, _, _, _): "group:\(id)"
        case .session(let row, _, let inRecent): (inRecent ? "recent:" : "session:") + row.id
        case .address: "address"
        }
    }

    var isSelectable: Bool {
        if case .header = self { return false }
        return true
    }
}

extension SessionStore {
    static let quickOpenRecentCount = 5

    /// Quick connect's list. With nothing typed: the last sessions used (if
    /// `showRecent`), then the whole tree with `collapsed` folded away. With a query: the sidebar
    /// search's matches as one flat list, most recently used first, and the
    /// query itself to connect to if it reads as an address.
    func quickOpenRows(matching query: String, collapsed: Set<String>, showRecent: Bool = true) -> [QuickOpenRow] {
        let index = sessionIndex
        func row(_ id: String) -> SessionRowData? {
            guard let session = sessions[id] else { return nil }
            return SessionRowData(id: id, session: session, groupID: index.groupID[id] ?? "",
                                  childIndex: 0, indent: 0, colorID: index.colorID[id],
                                  path: index.path[id] ?? "")
        }
        // Tree order breaks ties, so sessions never used keep the sidebar's order.
        var treeOrder: [String: Int] = [:]
        func number(_ nodes: [TreeNode]) {
            for node in nodes {
                switch node {
                case .session(let id): treeOrder[id] = treeOrder.count
                case .group(let group): number(group.children)
                }
            }
        }
        tree.forEach { number($0.children) }
        func byUse(_ a: String, _ b: String) -> Bool {
            let (da, db) = (sessions[a]?.lastConnected, sessions[b]?.lastConnected)
            if da != db { return (da ?? .distantPast) > (db ?? .distantPast) }
            return treeOrder[a, default: .max] < treeOrder[b, default: .max]
        }

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if let matches = matchingSessionIDs(trimmed) {
            var out = matches.sorted(by: byUse).compactMap { id in
                row(id).map { QuickOpenRow.session($0, depth: 0, inRecent: false) }
            }
            if (try? SSHLaunch.parseAddress(trimmed)) != nil { out.append(.address(trimmed)) }
            return out
        }

        var out: [QuickOpenRow] = []
        let recent = !showRecent ? [] : sessions.values.filter { $0.lastConnected != nil }.map(\.id).sorted(by: byUse)
            .prefix(Self.quickOpenRecentCount)
        if !recent.isEmpty {
            out.append(.header("Recent"))
            out += recent.compactMap { id in row(id).map { .session($0, depth: 0, inRecent: true) } }
            out.append(.header("All sessions"))
        }
        func walk(_ nodes: [TreeNode], depth: Int, inherited: String?) {
            for node in nodes {
                switch node {
                case .session(let id):
                    if let data = row(id) { out.append(.session(data, depth: depth, inRecent: false)) }
                case .group(let group):
                    let color = group.colorID ?? inherited
                    let folded = collapsed.contains(group.id)
                    out.append(.group(id: group.id, name: group.name, depth: depth,
                                      colorID: color, isCollapsed: folded))
                    if !folded { walk(group.children, depth: depth + 1, inherited: color) }
                }
            }
        }
        for group in tree {
            let folded = collapsed.contains(group.id)
            out.append(.group(id: group.id, name: group.name, depth: 0, colorID: nil, isCollapsed: folded))
            if !folded { walk(group.children, depth: 1, inherited: nil) }
        }
        return out
    }
}
