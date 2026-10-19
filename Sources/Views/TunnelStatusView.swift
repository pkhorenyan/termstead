import SwiftUI

/// The status bar's count of running tunnels, every session's, and the list
/// behind it: each tunnel with its state and Stop / Start, each session's
/// with Stop All — MobaXterm's tunnel window, in a popover.
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
        .frame(width: 456)
        .frame(maxHeight: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(theme.elevated.color)
    }

    private func section(_ id: String) -> some View {
        let forwards = connectionStore.launchedForwards(of: id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(id)
                    .font(SBFont.ui(13, .semibold))
                    .foregroundStyle(theme.text.color)
                    .lineLimit(1)
                Spacer(minLength: 0)
                small("Stop All") { connectionStore.stopTunnels(sessionID: id) }
                small("Edit…") { appState.route = .portForwarding(sessionID: id) }
            }

            ForEach(forwards) { forward in
                row(forward, of: id)
            }
        }
    }

    /// The tunnel, its state, and Stop / Start right beside the state; a
    /// failure's reason on a line below.
    private func row(_ forward: PortForward, of id: String) -> some View {
        let state = connectionStore.forwardState(forward.id, of: id)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(forward.summary)
                    .font(SBFont.mono(12))
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
                    .frame(width: 210, alignment: .leading)
                if let state {
                    ForwardStateLabel(state: state, showsReason: false)
                        .frame(width: Self.stateWidth, alignment: .leading)
                    let running = state == .running || state == .opening
                    // Stop also while opening: a login that hangs ends here.
                    // One width for both words, so the column does not shift.
                    Button {
                        connectionStore.setForward(forward.id, of: id, running: !running)
                    } label: {
                        Text(running ? "Stop" : "Start").frame(width: 40)
                    }
                    .buttonStyle(SecondaryButtonStyle(theme: theme, height: 24, horizontalPadding: 6,
                                                      fontSize: 11.5, filled: true))
                    if state == .running, let url = forward.browserURL {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(SecondaryButtonStyle(theme: theme, height: 24, horizontalPadding: 7,
                                                          fontSize: 11.5, filled: true))
                        .help("Open \(url.absoluteString) in the browser")
                        .accessibilityLabel("Open in Browser")
                    }
                } else {
                    Text("Not open")
                        .font(SBFont.ui(12))
                        .foregroundStyle(theme.textMuted.color)
                }
                Spacer(minLength: 0)
            }
            if case .failed(let reason)? = state {
                Text(reason)
                    .font(SBFont.ui(11.5))
                    .foregroundStyle(theme.ansiRed.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 218)
            }
        }
    }

    /// Wide enough for "● Opening…", the longest state.
    private static let stateWidth: CGFloat = 92

    private func small(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(SecondaryButtonStyle(theme: theme, height: 24, horizontalPadding: 9,
                                              fontSize: 11.5, filled: true))
    }
}
