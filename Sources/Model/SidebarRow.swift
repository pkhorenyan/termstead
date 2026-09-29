import SwiftUI

/// The flattened sidebar. `SessionStore` walks the tree once and produces these
/// with indentation and inherited color already resolved, so the views stay
/// free of tree logic.
enum SidebarRow: Identifiable, Hashable, Sendable {
    case topGroup(TopGroupRow)
    case group(GroupRowData)
    case session(SessionRowData)

    var id: String {
        switch self {
        case .topGroup(let row): "top:\(row.id)"
        case .group(let row): "group:\(row.id)"
        case .session(let row): "session:\(row.id)"
        }
    }
}

struct TopGroupRow: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let count: Int
    /// Extra space above every header but the first.
    let isFirst: Bool

    /// A header only ever takes things inside itself; reordering the top level
    /// happens through the strip under the last row.
    func dropTarget(for edge: DropEdge) -> DropTarget { .into(id) }
}

struct GroupRowData: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let count: Int
    let indent: CGFloat
    /// The group holding this one. Never nil: a top-level group is a
    /// `TopGroupRow`, so every `GroupRowData` is nested.
    let parentGroupID: String
    /// Position among its parent's children, which is what a drop above or
    /// below this row inserts at.
    let childIndex: Int
    /// The color set on this group itself, if any.
    let ownColorID: String?
    /// What it actually shows: its own color, or the nearest ancestor's.
    let effectiveColorID: String?
    let isCollapsed: Bool

    var ownColor: RGB? { GroupColor.rgb(for: ownColorID) }
    var effectiveColor: RGB? { GroupColor.rgb(for: effectiveColorID) }

    /// The variant that reads as text on the given theme.
    func effectiveColor(on theme: Theme) -> RGB? {
        GroupColor.rgb(for: effectiveColorID, on: theme)
    }

    func dropTarget(for edge: DropEdge) -> DropTarget {
        switch edge {
        case .into: .into(id)
        case .before: DropTarget(parentGroupID: parentGroupID, index: childIndex)
        case .after: DropTarget(parentGroupID: parentGroupID, index: childIndex + 1)
        }
    }
}

struct SessionRowData: Identifiable, Hashable, Sendable {
    let id: String
    let session: Session
    /// The group this session currently sits in — a drop onto this row lands
    /// there rather than on the session itself.
    let groupID: String
    /// Position among its group's children, which is what a drop above or below
    /// this row inserts at.
    let childIndex: Int
    let indent: CGFloat
    /// Inherited from the nearest coloured ancestor group.
    let colorID: String?
    /// Group path, e.g. "Production / Web".
    let path: String

    var color: RGB? { GroupColor.rgb(for: colorID) }

    /// The variant that reads as text on the given theme.
    func color(on theme: Theme) -> RGB? {
        GroupColor.rgb(for: colorID, on: theme)
    }

    var groupName: String { path.split(separator: "/").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "" }

    /// A session is never a container, so `.into` falls back to landing beside
    /// it rather than being refused.
    func dropTarget(for edge: DropEdge) -> DropTarget {
        switch edge {
        case .before: DropTarget(parentGroupID: groupID, index: childIndex)
        case .after, .into: DropTarget(parentGroupID: groupID, index: childIndex + 1)
        }
    }
}
