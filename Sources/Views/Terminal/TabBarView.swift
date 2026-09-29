import SwiftUI

struct TabBarView: View {
    @Environment(\.theme) private var theme
    @Environment(SessionStore.self) private var sessionStore
    @Environment(ConnectionStore.self) private var connectionStore
    @Environment(AppState.self) private var appState
    @Environment(ThemeStore.self) private var themeStore

    var body: some View {
        // Walked once for the whole strip rather than once per tab.
        let index = sessionStore.sessionIndex

        return HStack(spacing: 0) {
            ForEach(connectionStore.connections) { tab in
                tabView(tab, index: index)
                    .overlay(alignment: .trailing) { Divider1(theme.border, vertical: true) }
            }

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

    private func tabView(_ tab: Connection, index: SessionStore.SessionIndex) -> some View {
        let isActive = connectionStore.active?.id == tab.id
        let groupColor = GroupColor.rgb(for: tab.sessionID.flatMap { index.colorID[$0] })
        let topLine: Color = if let groupColor {
            isActive ? groupColor.color : groupColor.halfStrength
        } else {
            isActive ? theme.textMuted.color : .clear
        }

        return HStack(spacing: 2) {
            Button {
                connectionStore.activeID = tab.id
            } label: {
                HStack(spacing: 8) {
                    StatusDot(color: tab.state.isRunning ? theme.accent.color : theme.ansiRed.color)
                    Text(tab.title)
                        .font(SBFont.ui(12.5))
                        .foregroundStyle((isActive ? theme.text : theme.textSecondary).color)
                }
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

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
