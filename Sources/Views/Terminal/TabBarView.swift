import SwiftUI

/// One pane's tabs. With a single pane, the window's.
struct TabBarView: View {
    @Environment(\.theme) private var theme
    @Environment(SessionStore.self) private var sessionStore
    @Environment(ConnectionStore.self) private var connectionStore
    @Environment(AppState.self) private var appState
    @Environment(ThemeStore.self) private var themeStore

    var pane = 0

    /// The tab being dragged along the strip.
    @State private var drag: TabDrag?
    /// Each tab's width, which decides when a dragged tab has passed one.
    @State private var widths: [UUID: CGFloat] = [:]
    /// Where the pointer last was during a drag, for a drop on another pane.
    @State private var dragPoint: CGPoint?

    private var tabs: [Connection] { connectionStore.tabs(in: pane) }
    /// Several panes, this one not focused: its tab in front is drawn quieter,
    /// so the focused pane is the one that stands out.
    private var isQuiet: Bool {
        connectionStore.layout.paneCount > 1 && connectionStore.focusedPane != pane
    }

    private struct TabDrag {
        var id: UUID
        /// The pointer's travel since the press.
        var travel: CGFloat = 0
        /// How far the tab's slot has moved as it passed its neighbours.
        var shift: CGFloat = 0
        /// Where the tab is drawn, measured from its slot.
        var offset: CGFloat { travel - shift }
    }

    var body: some View {
        // Walked once for the whole strip rather than once per tab.
        let index = sessionStore.sessionIndex

        return HStack(spacing: 0) {
            // Laid out in a plain row while the tabs fit, and scrolled once
            // they do not. A row alone cannot shrink below its tabs' icons and
            // buttons, so many tabs widened the window's content and pushed
            // the sidebar off its left edge.
            ViewThatFits(in: .horizontal) {
                tabRow(index)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) { tabRow(index).background(TabStripScrolling()) }
                        .scrollIndicators(.never)
                        .onAppear { reveal(connectionStore.active(in: pane)?.id, in: proxy) }
                        .onChange(of: connectionStore.active(in: pane)?.id) { _, id in reveal(id, in: proxy) }
                }
            }
            // First claim on the width, ahead of the spacer below, so the
            // tabs scroll only when they truly do not fit.
            .layoutPriority(1)

            Button {
                // A new tab to somewhere new, in this pane. Another shell on a
                // session already open is "Open in New Tab" in the sidebar's
                // context menu.
                connectionStore.focus(pane: pane)
                appState.route = .quickConnect
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textMuted.color)
                    .frame(width: 38)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New tab")

            Spacer(minLength: 0)
        }
        // A click on the strip's empty part focuses the pane.
        .background {
            Color.clear.contentShape(Rectangle())
                .onTapGesture { connectionStore.focus(pane: pane) }
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { appState.paneStrips[pane] = $0 }
        .overlay {
            if appState.dropPane == pane {
                Rectangle()
                    .fill(theme.accent.color.opacity(0.14))
                    .overlay(Rectangle().strokeBorder(theme.accent.color, lineWidth: 2))
                    .allowsHitTesting(false)
            }
        }
        // The active tab is painted in the terminal colour so it reads as
        // continuous with the transcript below. Without this clip that fill
        // escapes upwards into the safe area under the titlebar — SwiftUI
        // backgrounds bleed there — and hangs a black block over the window
        // chrome. The strip above the tabs is painted by this view's own
        // background, applied in `MainView`, which still bleeds and is meant to.
        .clipped()
    }

    private func tabRow(_ index: SessionStore.SessionIndex) -> some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                let isDragged = drag?.id == tab.id
                tabView(tab, index: index)
                    .overlay(alignment: .trailing) { Divider1(theme.border, vertical: true) }
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
                        widths[tab.id] = frame.width
                        appState.tabFrames[tab.id] = frame
                    }
                    .offset(x: isDragged ? shownOffset(of: tab) : 0)
                    .zIndex(isDragged ? 1 : 0)
                    // The dragged tab follows the pointer exactly: when it
                    // takes a neighbour's slot, its slot and its offset change
                    // together and must not animate apart. The neighbours slide.
                    .transaction { if isDragged { $0.animation = nil } }
            }
        }
    }

    @ViewBuilder
    private func menu(for tab: Connection) -> some View {
        let tabs = tabs
        let layout = connectionStore.layout
        let saved = tab.sessionID.flatMap { sessionStore.session($0) }
        if !tab.state.isRunning {
            Button("Reconnect") { tab.restart() }
        }
        Button("Duplicate Tab") { duplicate(tab) }
            // A session deleted since the tab opened has nothing to copy.
            .disabled(tab.sessionID != nil && saved == nil)
        if let saved {
            Button("Session Settings…") { appState.route = .sessionSettings(id: saved.id) }
        }
        if layout.paneCount > 1 {
            Menu("Move to Pane") {
                ForEach(0..<layout.paneCount, id: \.self) { target in
                    Button(layout.name(ofPane: target)) { connectionStore.move(tab.id, toPane: target) }
                        .disabled(target == pane)
                }
            }
        }
        Divider()
        Button("Close Tab") {
            appState.requestClose(tab.id, in: connectionStore, confirm: themeStore.confirmClosingConnection)
        }
        Button("Close Other Tabs") {
            connectionStore.activeID = tab.id
            appState.requestClose(tabs.filter { $0.id != tab.id }.map(\.id), in: connectionStore,
                                  confirm: themeStore.confirmClosingConnection)
        }
        .disabled(tabs.count < 2)
        Button("Close Tabs to the Right") {
            let right = tabs.drop { $0.id != tab.id }.dropFirst().map(\.id)
            appState.requestClose(Array(right), in: connectionStore, confirm: themeStore.confirmClosingConnection)
        }
        .disabled(tabs.last?.id == tab.id)
    }

    /// Another tab to the same place, in the same pane: the session as saved,
    /// or the same address.
    private func duplicate(_ tab: Connection) {
        connectionStore.focus(pane: pane)
        if let id = tab.sessionID {
            connectionStore.connect(sessionID: id, in: sessionStore, newTab: true)
        } else {
            connectionStore.connect(address: tab.address)
        }
    }

    private func shownOffset(of tab: Connection) -> CGFloat {
        guard let drag else { return 0 }
        let tabs = tabs
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return 0 }
        return TabReorder.clamped(drag.offset, at: index, widths: tabs.map { widths[$0.id] ?? 0 })
    }

    private func reveal(_ id: UUID?, in proxy: ScrollViewProxy) {
        guard let id else { return }
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
    }

    private func dragTab(_ id: UUID, travel: CGFloat) {
        var state = drag.flatMap { $0.id == id ? $0 : nil } ?? TabDrag(id: id)
        state.travel = travel
        let tabs = tabs
        // Over another pane's strip the tab is going there, not along this one.
        guard appState.dropPane == nil, let from = tabs.firstIndex(where: { $0.id == id }) else {
            drag = state
            return
        }
        let slot = TabReorder.slot(from: from, offset: state.offset,
                                   widths: tabs.map { widths[$0.id] ?? 0 })
        guard slot.index != from else {
            drag = state
            return
        }
        state.shift += slot.shift
        withAnimation(.easeOut(duration: 0.15)) {
            connectionStore.move(id, to: slot.index)
            drag = state
        }
    }

    /// Notes which other pane's strip, if any, the dragged tab is over.
    private func trackDrag(at point: CGPoint) {
        dragPoint = point
        let count = connectionStore.layout.paneCount
        // A little slack above and below: a strip is only 36pt tall.
        let target = appState.paneStrips.first { pane, frame in
            pane != self.pane && pane < count && frame.insetBy(dx: 0, dy: -12).contains(point)
        }?.key
        if appState.dropPane != target { appState.dropPane = target }
    }

    private func endDrag() {
        if let target = appState.dropPane, let id = drag?.id, let point = dragPoint {
            // Before the first tab whose middle is right of the pointer.
            let index = connectionStore.tabs(in: target)
                .filter { (appState.tabFrames[$0.id]?.midX ?? .infinity) < point.x }.count
            appState.dropPane = nil
            drag = nil
            dragPoint = nil
            connectionStore.move(id, toPane: target, at: index)
            return
        }
        dragPoint = nil
        // Settles into its slot from wherever the pointer left it.
        withAnimation(.easeOut(duration: 0.15)) { drag = nil }
    }

    private func tabView(_ tab: Connection, index: SessionStore.SessionIndex) -> some View {
        let isActive = connectionStore.active(in: pane)?.id == tab.id
        let isLoud = isActive && !isQuiet
        let colorID = tab.sessionID.flatMap { index.colorID[$0] }
        let groupColor = GroupColor.rgb(for: colorID)
        let topLine: Color = if let groupColor {
            isLoud ? groupColor.color : groupColor.halfStrength
        } else {
            isActive ? (isLoud ? theme.textMuted : theme.border).color : .clear
        }
        // A quick connection has no saved session, so no icon of its own.
        let icon = tab.sessionID.flatMap { sessionStore.session($0)?.icon } ?? .terminal
        let isLive = tab.state.isRunning
        // Colour belongs to the group here, as in the sidebar: red and green
        // are group colours too, so a red or green icon for closed and live
        // read as a group. A closed tab is struck through and greyed instead;
        // fading alone was read as a colour gone wrong.
        let iconColor = isLive ? GroupColor.rgb(for: colorID, on: theme) ?? theme.textSecondary : theme.textMuted
        let titleColor = isLive ? (isActive ? theme.text : theme.textSecondary) : theme.textMuted

        return HStack(spacing: 2) {
            Button {
                connectionStore.activeID = tab.id
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: icon.symbolName)
                        .font(.system(size: 12))
                        .foregroundStyle(iconColor.color)
                        // SF Symbols differ in width; a fixed box keeps the
                        // titles from shifting when an icon changes.
                        .frame(width: 15, height: 15)
                        .modifier(StruckThrough(isOn: !isLive, color: iconColor.color))
                        .accessibilityLabel(isLive ? "Connected" : "Disconnected")
                    Text(tab.title)
                        .font(SBFont.ui(12.5))
                        .foregroundStyle(titleColor.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        // Capped, so one long address does not take the strip;
                        // fixed, so a short title is not stretched to the cap.
                        .frame(maxWidth: Metrics.tabTitleMaxWidth, alignment: .leading)
                        .fixedSize()
                }
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay {
                TabInteraction(
                    onSelect: { connectionStore.activeID = tab.id },
                    onMiddleClick: {
                        appState.requestClose(tab.id, in: connectionStore,
                                              confirm: themeStore.confirmClosingConnection)
                    },
                    onDrag: { dragTab(tab.id, travel: $0) },
                    onDragPointer: { trackDrag(at: $0) },
                    onDragEnd: endDrag)
            }

            Button {
                appState.requestClose(tab.id, in: connectionStore,
                                      confirm: themeStore.confirmClosingConnection)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.textMuted.color)
            }
            .buttonStyle(IconButtonStyle(theme: theme, cornerRadius: 5))
            .accessibilityLabel("Close tab")
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .frame(maxHeight: .infinity)
        .background(isActive ? theme.terminal.color : Color.clear)
        .overlay(alignment: .top) {
            Rectangle().fill(topLine).frame(height: isActive ? 3 : 2)
        }
        .contextMenu { menu(for: tab) }
    }
}

/// A line through a closed tab's icon, the way macOS marks something switched
/// off (`wifi.slash`, `mic.slash`). The icon is cut where the line crosses, so
/// it reads on any background without knowing which.
private struct StruckThrough: ViewModifier {
    var isOn: Bool
    var color: Color

    func body(content: Content) -> some View {
        if isOn {
            content
                .mask {
                    ZStack {
                        Rectangle()
                        Slash().stroke(style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                }
                .overlay { Slash().stroke(color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round)) }
        } else {
            content
        }
    }

    private struct Slash: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX + 1.5, y: rect.minY + 1.5))
            path.addLine(to: CGPoint(x: rect.maxX - 1.5, y: rect.maxY - 1.5))
            return path
        }
    }
}
