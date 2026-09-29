import SwiftUI

/// Vertical metrics for the tree. The rows are deliberately tight: the list is
/// the primary way of getting around, so more of it on screen beats breathing
/// room between entries.
enum SidebarMetrics {
    static let sessionRowHeight: CGFloat = 35
    static let groupRowHeight: CGFloat = 24
    static let headerHeight: CGFloat = 20
    static let pinnedRowHeight: CGFloat = 26
    /// Icons sit as bare glyphs; a tile behind them would set the row height.
    static let glyphBox: CGFloat = 18
    /// The chevron hangs in the indentation to the left of the icon column, the
    /// way Finder does it, so that a group's icon is not pushed right of a
    /// session's at the same depth — and nothing is pushed right at all.
    static let chevronBox: CGFloat = 12
    static let chevronGap: CGFloat = 2
    /// How far left of the icon the chevron starts.
    static let chevronInset: CGFloat = 12 + 2
    /// Gap between an icon and the text beside it.
    static let iconToText: CGFloat = 6
    static let nameLineHeight: CGFloat = 15
    static let addressLineHeight: CGFloat = 13
    /// Breathing room between the name and the address beneath it.
    static let nameToAddressGap: CGFloat = 3

    /// Where the chevron sits for a row whose icon column is at `indent`. The
    /// mouse layer hands this strip back to SwiftUI so the chevron button under
    /// it still gets the click.
    static func chevronRange(at indent: CGFloat) -> ClosedRange<CGFloat> {
        (indent - chevronInset)...(indent - chevronGap)
    }
}

/// The chevron in front of a folder. A button of its own, so a click on it opens
/// the group while a click anywhere else on the row selects it — the way Finder
/// behaves. It has no competing gesture, so it fires without waiting.
private struct DisclosureChevron: View {
    var isCollapsed: Bool
    var color: RGB
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color.color)
                .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                .frame(width: SidebarMetrics.chevronBox, height: SidebarMetrics.chevronBox)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCollapsed ? "Expand" : "Collapse")
    }
}

/// A top-level folder: just a muted caption. Creating a subgroup lives in the
/// context menu and in the sidebar footer.
struct TopGroupHeaderView: View {
    @Environment(\.theme) private var theme
    var row: TopGroupRow
    var isCollapsed: Bool
    var actions: TreeRowActions
    var onToggleCollapse: () -> Void
    var onAddSession: () -> Void
    var onAddSubgroup: () -> Void
    var onOpenSettings: () -> Void

    private var isSelected: Bool { actions.isSelected }

    var body: some View {
        HStack(spacing: 0) {
            // The chevron sits in the gutter, so the caption starts on the same
            // column the rows below it use for their icons.
            Color.clear
                .frame(width: SessionStore.indentBase - SidebarMetrics.chevronInset)
            DisclosureChevron(isCollapsed: isCollapsed, color: theme.textMuted,
                              action: onToggleCollapse)
            Color.clear.frame(width: SidebarMetrics.chevronGap)

            actions.name(
                Text(row.name.uppercased())
                    .font(SBFont.ui(11, .semibold))
                    .kerning(0.88),
                font: SBFont.ui(12, .semibold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(theme.textMuted.color)
        .frame(height: SidebarMetrics.headerHeight)
        .padding(.trailing, 4)
        .padding(.bottom, 2)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.selected.color)
            }
        }
        .overlay {
            // Out of the way while the name is edited, so the field gets the clicks.
            if !actions.isRenaming {
                RowInteraction(
                    item: SidebarDragItem(kind: .group, id: row.id),
                    dropMode: .intoOnly,
                    theme: theme,
                    dragLabel: row.name,
                    dragSymbol: "folder",
                    dragTint: theme.textSecondary,
                    indicatorLeading: SessionStore.indentBase,
                    passthrough: SidebarMetrics.chevronRange(at: SessionStore.indentBase),
                    dragItems: actions.dragItems,
                    isInMultiSelection: actions.isInMultiSelection,
                    onClick: actions.onSelect,
                    onDoubleClick: onToggleCollapse,
                    canDrop: { items, edge in actions.canDrop(items, row.dropTarget(for: edge)) },
                    performDrop: { items, edge in actions.onDrop(items, row.dropTarget(for: edge)) },
                    onSpringOpen: isCollapsed ? onToggleCollapse : nil,
                    onDeleteKey: actions.onDeleteKey,
                    // A row already in the selection keeps it, so the menu
                    // acts on all of it; any other row becomes the selection.
                    onContextClick: actions.isSelected ? nil : { actions.onSelect([]) }
                )
            }
        }
        .contextMenu {
            Button("New Connection…", action: onAddSession)
            Button("New Subgroup…", action: onAddSubgroup)
            Divider()
            actions.renameItem()
            actions.moveMenu(includingTopLevel: true)
            Button("Group Settings…", action: onOpenSettings)
            actions.deleteItem()
        }
    }
}

/// A nested folder. Its color is edited in the group settings sheet, not here.
struct GroupRowView: View {
    @Environment(\.theme) private var theme
    var row: GroupRowData
    var onToggleCollapse: () -> Void
    var onAddSession: () -> Void
    var onAddSubgroup: () -> Void
    var onOpenSettings: () -> Void
    var actions: TreeRowActions

    private var isSelected: Bool { actions.isSelected }

    private var tint: RGB? { row.effectiveColor(on: theme) }

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: row.indent - SidebarMetrics.chevronInset)
            DisclosureChevron(isCollapsed: row.isCollapsed, color: theme.textMuted,
                              action: onToggleCollapse)
            Color.clear.frame(width: SidebarMetrics.chevronGap)

            Image(systemName: row.effectiveColor == nil ? "folder" : "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle((tint ?? theme.textMuted).color)
                .frame(width: SidebarMetrics.glyphBox)

            actions.name(
                Text(row.name)
                    .font(SBFont.ui(12.5, .semibold))
                    .foregroundStyle((tint ?? theme.text).color)
                    .lineLimit(1)
                    .truncationMode(.tail),
                font: SBFont.ui(12.5, .semibold))
                .padding(.leading, SidebarMetrics.iconToText)

            Spacer(minLength: 0)
        }
        .frame(height: SidebarMetrics.groupRowHeight)
        .padding(.trailing, 4)
        .padding(.vertical, 1)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.selected.color)
            }
        }
        .overlay {
            // Out of the way while the name is edited, so the field gets the clicks.
            if !actions.isRenaming {
                RowInteraction(
                    item: SidebarDragItem(kind: .group, id: row.id),
                    dropMode: .intoAndBetween,
                    theme: theme,
                    dragLabel: row.name,
                    dragSymbol: row.effectiveColor == nil ? "folder" : "folder.fill",
                    dragTint: tint,
                    indicatorLeading: row.indent,
                    passthrough: SidebarMetrics.chevronRange(at: row.indent),
                    dragItems: actions.dragItems,
                    isInMultiSelection: actions.isInMultiSelection,
                    onClick: actions.onSelect,
                    onDoubleClick: onToggleCollapse,
                    canDrop: { items, edge in actions.canDrop(items, row.dropTarget(for: edge)) },
                    performDrop: { items, edge in actions.onDrop(items, row.dropTarget(for: edge)) },
                    onSpringOpen: row.isCollapsed ? onToggleCollapse : nil,
                    onDeleteKey: actions.onDeleteKey,
                    // A row already in the selection keeps it, so the menu
                    // acts on all of it; any other row becomes the selection.
                    onContextClick: actions.isSelected ? nil : { actions.onSelect([]) }
                )
            }
        }
        .accessibilityLabel(row.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            Button("New Connection…", action: onAddSession)
            Button("New Subgroup…", action: onAddSubgroup)
            Divider()
            actions.renameItem()
            actions.moveMenu(includingTopLevel: true)
            Button("Group Settings…", action: onOpenSettings)
            actions.deleteItem()
        }
    }
}

/// A session: icon, name in the group's color, and the address underneath.
struct SessionRowView: View {
    @Environment(\.theme) private var theme
    var row: SessionRowData
    var isPinned: Bool
    /// An ssh process is running for this session in some tab.
    var isLive: Bool
    var onConnect: () -> Void
    var onConnectInNewTab: () -> Void
    var onTogglePin: () -> Void
    var onOpenSettings: () -> Void
    var actions: TreeRowActions

    private var isSelected: Bool { actions.isSelected }

    private var tint: RGB? { row.color(on: theme) }

    var body: some View {
        HStack(spacing: SidebarMetrics.iconToText) {
            Image(systemName: row.session.icon.symbolName)
                .font(.system(size: 13))
                .foregroundStyle((tint ?? theme.textSecondary).color)
                .frame(width: SidebarMetrics.glyphBox, height: SidebarMetrics.glyphBox)
                .padding(.leading, row.indent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: SidebarMetrics.nameToAddressGap) {
                HStack(spacing: 6) {
                    actions.name(
                        Text(row.id)
                            .font(SBFont.ui(12.5, .medium))
                            .foregroundStyle((tint ?? theme.text).color)
                            .lineLimit(1)
                            .truncationMode(.tail),
                        font: SBFont.ui(12.5, .medium))
                    if isLive {
                        StatusDot(color: theme.accent.color, size: 6)
                            .accessibilityLabel("Connected")
                    }
                    Spacer(minLength: 0)
                    // Marks a tree row that is also in the Pinned strip. The
                    // strip's own rows need no mark — their heading says it.
                    // A marker, not a button: pinning is in the context menu.
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(theme.textSecondary.color)
                            .accessibilityLabel("Pinned")
                    }
                }
                .frame(height: SidebarMetrics.nameLineHeight)

                Text(row.session.subtitle)
                    .font(SBFont.mono(11))
                    .foregroundStyle(theme.textMuted.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: SidebarMetrics.addressLineHeight, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 4)
            .padding(.vertical, 2)

        }
        .padding(.trailing, 4)
        .frame(height: SidebarMetrics.sessionRowHeight)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.selected.color)
            }
        }
        .overlay {
            // Out of the way while the name is edited, so the field gets the clicks.
            if !actions.isRenaming {
                RowInteraction(
                    item: SidebarDragItem(kind: .session, id: row.id),
                    dropMode: .between,
                    theme: theme,
                    dragLabel: row.id,
                    dragSymbol: row.session.icon.symbolName,
                    dragTint: tint,
                    indicatorLeading: row.indent,
                    dragItems: actions.dragItems,
                    isInMultiSelection: actions.isInMultiSelection,
                    onClick: actions.onSelect,
                    onDoubleClick: onConnect,
                    canDrop: { items, edge in actions.canDrop(items, row.dropTarget(for: edge)) },
                    performDrop: { items, edge in actions.onDrop(items, row.dropTarget(for: edge)) },
                    onDeleteKey: actions.onDeleteKey,
                    // A row already in the selection keeps it, so the menu
                    // acts on all of it; any other row becomes the selection.
                    onContextClick: actions.isSelected ? nil : { actions.onSelect([]) }
                )
            }
        }
        .contextMenu {
            Button("Connect", action: onConnect)
            Button("Open in New Tab", action: onConnectInNewTab)
            Divider()
            actions.renameItem()
            actions.moveMenu(includingTopLevel: false)
            Button("Session Settings…", action: onOpenSettings)
            Button(isPinned ? "Unpin" : "Pin to Top", action: onTogglePin)
            actions.deleteItem()
        }
    }
}

/// Compact row in the Pinned strip: glyph, name, and the owning group.
struct PinnedRowView: View {
    @Environment(\.theme) private var theme
    var row: SessionRowData
    var isSelected: Bool
    var isLive: Bool
    var onSelect: () -> Void
    var onConnect: () -> Void
    var onConnectInNewTab: () -> Void
    var onOpenSettings: () -> Void
    var onUnpin: () -> Void
    var onDelete: () -> Void

    private var tint: RGB? { row.color(on: theme) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: row.session.icon.symbolName)
                .font(.system(size: 12))
                .foregroundStyle((tint ?? theme.textSecondary).color)
                .frame(width: SidebarMetrics.glyphBox, height: SidebarMetrics.glyphBox)

            Text(row.id)
                .font(SBFont.ui(12.5, .medium))
                .foregroundStyle((tint ?? theme.text).color)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            Text(row.groupName)
                .font(SBFont.ui(10.5))
                .foregroundStyle(theme.textMuted.color)
                .lineLimit(1)

            if isLive {
                StatusDot(color: theme.accent.color, size: 6)
                    .accessibilityLabel("Connected")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: SidebarMetrics.pinnedRowHeight)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.selected.color)
            }
        }
        .background {
            // The strip mirrors rows that live further down the tree, so it is
            // neither a drag source nor a drop target — only clicks.
            RowInteraction(
                item: nil,
                dropMode: .between,
                theme: theme,
                dragLabel: row.id,
                dragSymbol: row.session.icon.symbolName,
                dragTint: tint,
                onClick: { _ in onSelect() },
                onDoubleClick: onConnect,
                canDrop: { _, _ in false },
                performDrop: { _, _ in false },
                onDeleteKey: onDelete,
                onContextClick: isSelected ? nil : onSelect
            )
        }
        .contextMenu {
            Button("Connect", action: onConnect)
            Button("Open in New Tab", action: onConnectInNewTab)
            Divider()
            Button("Session Settings…", action: onOpenSettings)
            Button("Unpin", action: onUnpin)
            Divider()
            Button("Delete…", role: .destructive, action: onDelete)
        }
    }
}
