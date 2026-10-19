import SwiftUI

/// The status bar's count of running tunnels, every session's, and the list
/// behind it: each tunnel with its state and Stop / Start, each tunnel-only
/// connection with Disconnect — MobaXterm's tunnel window, in a popover.
struct TunnelStatusItem: View {
    @Environment(\.theme) private var theme
    @Environment(ConnectionStore.self) private var connectionStore

    @State private var isOpen = false

    var body: some View {
        let sessions = connectionStore.sessionsWithTunnels
        if !sessions.isEmpty {
            let states = sessions.flatMap { (connectionStore.forwardStates[$0] ?? [:]).values }
            let running = states.filter { $0 == .running }.count
            let failed = states.contains { if case .failed = $0 { true } else { false } }
            Button { isOpen.toggle() } label: {
                Label("\(running)", systemImage: "arrow.left.arrow.right")
                    .labelStyle(InlineIconLabelStyle(spacing: 5, iconSize: 10))
                    .foregroundStyle((failed ? theme.ansiRed : running > 0 ? theme.accent : theme.textMuted).color)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .layoutPriority(2)
            .help(running == 1 ? "1 tunnel running" : "\(running) tunnels running")
            .accessibilityLabel(running == 1 ? "1 tunnel running" : "\(running) tunnels running")
            .popover(isPresented: $isOpen, arrowEdge: .top) {
                TunnelList(sessions: sessions)
                    .environment(\.theme, theme)
            }
        }
    }
}

private struct TunnelList: View {
    @Environment(\.theme) private var theme
    @Environment(ConnectionStore.self) private var connectionStore
    @Environment(SessionStore.self) private var sessionStore
    @Environment(AppState.self) private var appState

    var sessions: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(sessions, id: \.self) { id in
                    section(id)
                }
            }
            .padding(14)
            .background(ThinScroller(isDark: theme.isDark, alwaysVisible: true))
        }
        .frame(width: 460)
        .frame(maxHeight: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(theme.elevated.color)
    }

    private func section(_ id: String) -> some View {
        let background = connectionStore.tunnels.first { $0.sessionID == id }
        let holder = connectionStore.forwardHolder(of: id)
        let forwards = holder?.plan?.forwards.map(\.forward) ?? sessionStore.session(id)?.forwards ?? []
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(id)
                    .font(SBFont.ui(13, .semibold))
                    .foregroundStyle(theme.text.color)
                    .lineLimit(1)
                Text(where_(background: background, holder: holder))
                    .font(SBFont.ui(11.5))
                    .foregroundStyle(theme.textMuted.color)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let background {
                    if background.state.isRunning {
                        small("Disconnect") { connectionStore.stopTunnels(sessionID: id) }
                    } else {
                        small("Reconnect") { background.restart() }
                        small("Remove") { connectionStore.stopTunnels(sessionID: id) }
                    }
                }
                small("Edit…") { appState.route = .portForwarding(sessionID: id) }
            }

            ForEach(forwards) { forward in
                HStack(spacing: 8) {
                    Text(forward.summary)
                        .font(SBFont.mono(12))
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(1)
                        .frame(width: 210, alignment: .leading)
                    if let state = connectionStore.forwardState(forward.id, of: id) {
                        ForwardStateLabel(state: state)
                        Spacer(minLength: 0)
                        let running = state == .running || state == .opening
                        small(running ? "Stop" : "Start") {
                            connectionStore.setForward(forward.id, of: id, running: !running)
                        }
                        .disabled(state == .opening)
                    } else {
                        Text("Not open")
                            .font(SBFont.ui(12))
                            .foregroundStyle(theme.textMuted.color)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func where_(background: Connection?, holder: Connection?) -> String {
        if let background {
            if background.state.isRunning { return background.isLoggedIn ? "tunnels only" : "connecting…" }
            return "disconnected"
        }
        return holder == nil ? "connecting…" : "in a tab"
    }

    private func small(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(SecondaryButtonStyle(theme: theme, height: 24, horizontalPadding: 9,
                                              fontSize: 11.5, filled: true))
    }
}
