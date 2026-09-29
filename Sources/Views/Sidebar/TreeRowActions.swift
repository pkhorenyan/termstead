import AppKit
import SwiftUI

/// What every tree row does with selection and moving: the same for a
/// top-level header, a nested group and a session.
@MainActor
struct TreeRowActions {
    /// Highlighted, alone or with others.
    var isSelected: Bool
    /// One of several highlighted rows — see `RowInteraction.isInMultiSelection`.
    var isInMultiSelection: Bool
    var onSelect: (NSEvent.ModifierFlags) -> Void
    /// What a drag from this row carries.
    var dragItems: () -> [SidebarDragItem]
    var canDrop: ([SidebarDragItem], DropTarget) -> Bool
    var onDrop: ([SidebarDragItem], DropTarget) -> Bool
    /// Destinations for the context menu's Move To, and what choosing one does
    /// with this row — or with the whole selection, if the row is part of it.
    var moveTargets: [MoveTarget]
    var onMove: (String?) -> Void
    /// Asks to delete this row — or the selection it is part of.
    var onDelete: () -> Void
    /// ⌫ with the sidebar focused: asks to delete whatever is selected.
    var onDeleteKey: () -> Void
    /// This row's name is being edited in place.
    var isRenaming: Bool
    var renameText: Binding<String>
    var onStartRename: () -> Void
    var onCommitRename: () -> Void
    var onCancelRename: () -> Void
}

/// A place the context menu can move rows to. `nil` is the top level.
struct MoveTarget: Identifiable, Hashable {
    let groupID: String?
    let title: String
    var id: String { groupID ?? "top-level" }
}

extension TreeRowActions {
    func renameItem() -> some View {
        let onStartRename = onStartRename
        return Button("Rename") { onStartRename() }
    }

    /// The row's name, or the field to edit it.
    @ViewBuilder
    func name(_ text: some View, font: Font) -> some View {
        if isRenaming {
            RenameField(text: renameText, font: font,
                        onCommit: onCommitRename, onCancel: onCancelRename)
        } else {
            text
        }
    }

    /// Last in every row's context menu, after a divider.
    func deleteItem() -> some View {
        let onDelete = onDelete
        return Group {
            Divider()
            Button("Delete…", role: .destructive) { onDelete() }
        }
    }

    /// Move To, as a submenu of the row's context menu. The menu is the way to
    /// move rows without dragging — including into a group scrolled out of view.
    func moveMenu(includingTopLevel: Bool) -> some View {
        let onMove = onMove
        return Menu("Move To") {
            ForEach(moveTargets.filter { includingTopLevel || $0.groupID != nil }) { target in
                Button(target.title) { onMove(target.groupID) }
            }
        }
    }
}
