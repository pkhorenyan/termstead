import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Private to the app: a sidebar row being dragged. Declared in Info.plist
    /// under UTExportedTypeDeclarations so the drag pasteboard carries a type
    /// the system knows about.
    static let termsteadSidebarItem = UTType(exportedAs: "com.pavelkhorenyan.termstead.sidebar-item")
}

/// What a drag from the sidebar carries: which row, and whether it is a session
/// or a group. Both move through the same drop targets.
struct SidebarDragItem: Codable, Hashable, Transferable, Sendable {
    enum Kind: String, Codable, Sendable {
        case session, group
    }

    let kind: Kind
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .termsteadSidebarItem)
    }
}

extension SidebarDragItem {
    /// The drag pasteboard payload: every row being dragged, in tree order.
    /// Read back synchronously in `performDragOperation` — `loadTransferable`
    /// is asynchronous, so a drop routed through it lands a frame or more after
    /// the mouse comes up.
    static func pasteboardData(_ items: [SidebarDragItem]) -> Data? {
        try? JSONEncoder().encode(items)
    }

    static func items(from pasteboard: NSPasteboard) -> [SidebarDragItem]? {
        guard let data = pasteboard.data(forType: .termsteadSidebarItemPasteboard) else { return nil }
        if let items = try? JSONDecoder().decode([SidebarDragItem].self, from: data), !items.isEmpty {
            return items
        }
        return (try? JSONDecoder().decode(SidebarDragItem.self, from: data)).map { [$0] }
    }
}

extension NSPasteboard.PasteboardType {
    static let termsteadSidebarItemPasteboard =
        NSPasteboard.PasteboardType(UTType.termsteadSidebarItem.identifier)
}

/// Where inside a row the pointer is during a drag, which is what decides
/// between reordering and re-parenting.
enum DropEdge: Hashable, Sendable {
    /// Insert above this row, as a sibling.
    case before
    /// Insert below this row, as a sibling.
    case after
    /// Put it inside this group, at the end.
    case into
}

/// A resolved destination: whose child list, and at which position. `nil` index
/// appends. A `nil` parent is the top level, which only groups can occupy.
struct DropTarget: Hashable, Sendable {
    let parentGroupID: String?
    let index: Int?

    static func into(_ groupID: String?) -> DropTarget {
        DropTarget(parentGroupID: groupID, index: nil)
    }
}
