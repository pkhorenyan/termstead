import SwiftUI

/// Connect to an address without saving it, or open a saved session from the
/// keyboard — the "+" in the tab strip, ⌘T and ⌘K. The field keeps the
/// keyboard throughout: typing filters the list, ↑ ↓ pick a row, ← → fold a
/// group, Return opens (⌥Return in a new tab, ⌘Return the typed address).
struct QuickConnectSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.closeForm) private var close
    @Environment(ConnectionStore.self) private var connectionStore
    @Environment(SessionStore.self) private var sessionStore
    @Environment(ThemeStore.self) private var themeStore

    @State private var address = ""
    @State private var highlighted: String?
    /// Folded in this list only; the sidebar keeps its own.
    @State private var collapsed: Set<String> = []

    private var trimmed: String { address.trimmingCharacters(in: .whitespaces) }

    /// Checked as typed, so a mistyped address is caught here rather than as
    /// an error in a new tab.
    private var problem: String? {
        guard !trimmed.isEmpty else { return nil }
        do {
            _ = try SSHLaunch.parseAddress(trimmed)
            return nil
        } catch {
            return String(describing: error)
        }
    }

    private var rows: [QuickOpenRow] { sessionStore.quickOpenRows(matching: address, collapsed: collapsed,
                                                                  showRecent: themeStore.showRecentInQuickConnect) }

    /// The highlighted row, or the first that can be, so Return always has a target.
    private func current(in rows: [QuickOpenRow]) -> QuickOpenRow? {
        rows.first { $0.id == highlighted && $0.isSelectable } ?? rows.first(where: \.isSelectable)
    }

    var body: some View {
        let rows = rows
        let current = current(in: rows)
        VStack(spacing: 0) {
            SheetHeader(title: "Quick connect",
                        subtitle: "Open a saved session, or connect to an address without adding it to the sidebar.",
                        horizontalPadding: 24)

            VStack(alignment: .leading, spacing: 8) {
                SBTextField(text: $address, placeholder: "Search sessions or type user@host:22",
                            font: SBFont.mono(14))
                    .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return],
                                phases: [.down, .repeat]) { press in handle(press) }
                    .onChange(of: address) { highlighted = nil }
                Text(problem ?? "Keys, the ssh agent and ~/.ssh/config apply as usual.")
                    .font(SBFont.ui(12))
                    .foregroundStyle((problem == nil ? theme.textMuted : theme.ansiRed).color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 10)

            list(rows, current: current)

            HStack(spacing: 10) {
                Text("↩ open   ⌥↩ new tab   ⌘↩ connect to address")
                    .font(SBFont.ui(11.5))
                    .foregroundStyle(theme.textMuted.color)
                Spacer(minLength: 0)
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SecondaryButtonStyle(theme: theme, height: 36,
                                                      horizontalPadding: 16, fontSize: 13.5))
                Button("Connect") { open(self.current(in: self.rows), newTab: false) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PrimaryButtonStyle(theme: theme, height: 36,
                                                    horizontalPadding: 18, fontSize: 13.5))
                    .disabled(current == nil)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .overlay(alignment: .top) { Divider1(theme.border) }
        }
        .frame(width: 560, height: 480)
        .background(theme.chrome.color)
    }

    private func list(_ rows: [QuickOpenRow], current: QuickOpenRow?) -> some View {
        let live = Set(connectionStore.connections.filter { $0.state.isRunning && !$0.isTunnelOnly }
            .compactMap(\.sessionID))
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row, isHighlighted: row.id == current?.id, live: live)
                            .id(row.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .background(ThinScroller(isDark: theme.isDark, alwaysVisible: true))
            }
            .onChange(of: current?.id) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func rowView(_ row: QuickOpenRow, isHighlighted: Bool, live: Set<String>) -> some View {
        switch row {
        case .header(let title):
            Text(title.uppercased())
                .font(SBFont.ui(10.5, .semibold))
                .foregroundStyle(theme.textMuted.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 4)

        case .group(let id, let name, let depth, let colorID, let isCollapsed):
            let tint = GroupColor.rgb(for: colorID, on: theme)
            line(isHighlighted: isHighlighted, height: 26, action: { toggle(id) }) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textMuted.color)
                    .frame(width: 10)
                Image(systemName: colorID == nil ? "folder" : "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle((tint ?? theme.textMuted).color)
                Text(name)
                    .font(SBFont.ui(12.5, .semibold))
                    .foregroundStyle((tint ?? theme.text).color)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 14)
            .accessibilityLabel("\(name), group, \(isCollapsed ? "collapsed" : "expanded")")

        case .session(let data, let depth, let shortcut):
            let tint = data.color(on: theme)
            line(isHighlighted: isHighlighted, height: 38, action: { open(row, newTab: false) }) {
                Image(systemName: data.session.icon.symbolName)
                    .font(.system(size: 13))
                    .foregroundStyle((tint ?? theme.textSecondary).color)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(data.id)
                            .font(SBFont.ui(12.5, .medium))
                            .foregroundStyle((tint ?? theme.text).color)
                            .lineLimit(1)
                        if live.contains(data.id) {
                            StatusDot(color: theme.accent.color, size: 6)
                                .accessibilityLabel("Connected")
                        }
                    }
                    Text(data.session.kind == .telnet ? data.session.statusAddress : data.session.subtitle)
                        .font(SBFont.mono(11))
                        .foregroundStyle(theme.textMuted.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                // The tree already shows where a session sits; flat rows say it.
                VStack(alignment: .trailing, spacing: 1) {
                    if depth == 0 || shortcut != nil {
                        Text(data.path)
                            .font(SBFont.ui(11.5))
                            .foregroundStyle(theme.textSecondary.color)
                            .lineLimit(1)
                    }
                    if let used = data.session.lastConnected {
                        Text(used, format: .relative(presentation: .named))
                            .font(SBFont.ui(11))
                            .foregroundStyle(theme.textMuted.color)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.leading, shortcut != nil ? 0 : CGFloat(depth) * 14)

        case .address(let target):
            line(isHighlighted: isHighlighted, height: 32, action: { open(row, newTab: false) }) {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary.color)
                    .frame(width: 18)
                Text("Connect to ").font(SBFont.ui(12.5)).foregroundStyle(theme.textSecondary.color)
                    + Text(target).font(SBFont.mono(12.5)).foregroundStyle(theme.text.color)
                Spacer(minLength: 0)
            }
        }
    }

    /// A clickable row. A plain `Button`, never paired with a tap gesture
    /// (see the 357 ms pitfall in CLAUDE.md).
    private func line<Content: View>(isHighlighted: Bool, height: CGFloat, action: @escaping () -> Void,
                                     @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            HStack(spacing: 8) { content() }
                .padding(.horizontal, 8)
                .frame(height: height)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if isHighlighted {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.selected.color)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Reads the list afresh: a held key's repeats come faster than a redraw,
    /// and values captured by the last `body` kept every repeat on one row.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let rows = rows
        let current = current(in: rows)
        let selectable = rows.filter(\.isSelectable)
        switch press.key {
        case .upArrow, .downArrow:
            guard !selectable.isEmpty else { return .ignored }
            let at = selectable.firstIndex { $0.id == current?.id } ?? 0
            let next = press.key == .downArrow ? min(at + 1, selectable.count - 1) : max(at - 1, 0)
            highlighted = selectable[next].id
            return .handled
        case .leftArrow, .rightArrow:
            // Only over a group with nothing typed; otherwise the caret moves.
            guard trimmed.isEmpty, case .group(let id, _, _, _, let isCollapsed) = current else { return .ignored }
            if isCollapsed == (press.key == .rightArrow) { toggle(id) }
            return .handled
        case .return:
            if press.modifiers.contains(.command) {
                if (try? SSHLaunch.parseAddress(trimmed)) != nil { open(.address(trimmed), newTab: true) }
            } else {
                open(current, newTab: press.modifiers.contains(.option))
            }
            return .handled
        default:
            return .ignored
        }
    }

    private func toggle(_ groupID: String) {
        if collapsed.contains(groupID) { collapsed.remove(groupID) } else { collapsed.insert(groupID) }
        highlighted = "group:\(groupID)"
    }

    private func open(_ row: QuickOpenRow?, newTab: Bool) {
        switch row {
        case .session(let data, _, _):
            close()
            connectionStore.connect(sessionID: data.id, in: sessionStore, newTab: newTab)
        case .address(let target):
            guard problem == nil else { return }
            close()
            connectionStore.connect(address: target)
        case .group(let id, _, _, _, _):
            toggle(id)
        case .header, nil:
            break
        }
    }
}
