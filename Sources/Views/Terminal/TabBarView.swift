import SwiftUI

struct TabBarView: View {
    @Environment(\.theme) private var theme
    @Environment(SessionStore.self) private var sessionStore
    @Environment(ConnectionStore.self) private var connectionStore
    @Environment(AppState.self) private var appState
    @Environment(ThemeStore.self) private var themeStore

    /// The tab being dragged along the strip.
    @State private var drag: TabDrag?
    /// Each tab's width, which decides when a dragged tab has passed one.
    @State private var widths: [UUID: CGFloat] = [:]

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
                    ScrollView(.horizontal) { tabRow(index) }
                        .scrollIndicators(.never)
                        .onAppear { reveal(connectionStore.activeID, in: proxy) }
                        .onChange(of: connectionStore.activeID) { _, id in reveal(id, in: proxy) }
                }
            }
            // First claim on the width, ahead of the spacer below, so the
            // tabs scroll only when they truly do not fit.
            .layoutPriority(1)

            Button {
                // A new tab to somewhere new. Another shell on a session already
                // open is "Open in New Tab" in the sidebar's context menu.
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
            ForEach(connectionStore.connections) { tab in
                let isDragged = drag?.id == tab.id
                tabView(tab, index: index)
                    .overlay(alignment: .trailing) { Divider1(theme.border, vertical: true) }
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { widths[tab.id] = $0 }
                    .offset(x: isDragged ? drag?.offset ?? 0 : 0)
                    .zIndex(isDragged ? 1 : 0)
                    // The dragged tab follows the pointer exactly: when it
                    // takes a neighbour's slot, its slot and its offset change
                    // together and must not animate apart. The neighbours slide.
                    .transaction { if isDragged { $0.animation = nil } }
            }
        }
    }

    private func reveal(_ id: UUID?, in proxy: ScrollViewProxy) {
        guard let id else { return }
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
    }

    private func dragTab(_ id: UUID, travel: CGFloat) {
        var state = drag.flatMap { $0.id == id ? $0 : nil } ?? TabDrag(id: id)
        state.travel = travel
        let tabs = connectionStore.connections
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
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

    private func endDrag() {
        // Settles into its slot from wherever the pointer left it.
        withAnimation(.easeOut(duration: 0.15)) { drag = nil }
    }

    private func tabView(_ tab: Connection, index: SessionStore.SessionIndex) -> some View {
        let isActive = connectionStore.active?.id == tab.id
        let colorID = tab.sessionID.flatMap { index.colorID[$0] }
        let groupColor = GroupColor.rgb(for: colorID)
        let topLine: Color = if let groupColor {
            isActive ? groupColor.color : groupColor.halfStrength
        } else {
            isActive ? theme.textMuted.color : .clear
        }
        // A quick connection has no saved session, so no icon of its own.
        let icon = tab.sessionID.flatMap { sessionStore.session($0)?.icon } ?? .terminal
        let isLive = tab.state.isRunning
        // Colour belongs to the group here, as in the sidebar: red and green
        // are group colours too, so a red or green icon for closed and live
        // read as a group. A closed tab fades instead.
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
                        .opacity(isLive ? 1 : 0.6)
                        // SF Symbols differ in width; a fixed box keeps the
                        // titles from shifting when an icon changes.
                        .frame(width: 15)
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
    }
}
