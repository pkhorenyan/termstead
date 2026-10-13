import SwiftUI

struct StatusBarView: View {
    @Environment(\.theme) private var theme
    @Environment(SessionStore.self) private var sessionStore
    @Environment(ConnectionStore.self) private var connectionStore
    @Environment(SessionStorage.self) private var storage
    @Environment(ThemeStore.self) private var themeStore

    var body: some View {
        HStack(spacing: 14) {
            if let tab = connectionStore.active {
                // One walk for all three lookups below.
                let index = sessionStore.sessionIndex
                let colorID = tab.sessionID.flatMap { index.colorID[$0] }
                let groupColor = GroupColor.rgb(for: colorID)
                let groupTextColor = GroupColor.rgb(for: colorID, on: theme)

                HStack(spacing: 6) {
                    StatusDot(color: tab.state.isRunning ? theme.accent.color : theme.ansiRed.color)
                    Text(stateLabel(tab.state))
                }

                Text("\(tab.address) · \(tab.keyDescription)")
                    .font(SBFont.mono(11.5))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let path = tab.sessionID.flatMap({ index.path[$0] }), !path.isEmpty {
                    Text(path)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(groupColor?.tileFill ?? theme.elevated.color)
                        )
                        .foregroundStyle((groupTextColor ?? theme.textSecondary).color)
                }

                Spacer(minLength: 0)

                unsavedNote

                if connectionStore.isBroadcasting && connectionStore.canBroadcast {
                    let panes = (0..<connectionStore.layout.paneCount)
                        .filter { connectionStore.receivesBroadcast(pane: $0) }.count
                    Label("Input to \(panes) panes", systemImage: "antenna.radiowaves.left.and.right")
                        .labelStyle(InlineIconLabelStyle(spacing: 5, iconSize: 10))
                        .foregroundStyle(theme.ansiYellow.color)
                        .fixedSize()
                        .layoutPriority(2)
                }

                if themeStore.showServerLoad, let load = tab.serverLoad {
                    ServerLoadView(load: load, theme: theme)
                        // Offered room before the address, which truncates.
                        .layoutPriority(1)
                }

                // Only the size: "UTF-8 · xterm-256color" was the same on
                // every tab, always, so it told nobody anything.
                if tab.columns > 0 {
                    Text("\(tab.columns)×\(tab.rows)")
                        .font(SBFont.mono(11.5))
                        .help("Terminal size: columns × rows")
                }
            } else {
                Text("No active connections")
                Spacer(minLength: 0)
                unsavedNote
            }
        }
        .font(SBFont.ui(11.5))
        .foregroundStyle(theme.textMuted.color)
        .padding(.horizontal, 14)
    }

    /// A launch route or `-sb-sample` keeps the tree in memory. Without a sign
    /// of it, sessions created in such a window look saved and are not — which
    /// is how a debug launch once passed for the real app.
    @ViewBuilder
    private var unsavedNote: some View {
        if storage.url == nil {
            Text("In memory only — not saved")
                .foregroundStyle(theme.ansiYellow.color)
                .accessibilityLabel("Sessions in this window are not saved")
        }
    }

    /// "Connected" means the ssh process is alive — see `Connection.State`.
    private func stateLabel(_ state: Connection.State) -> String {
        switch state {
        case .running: "Connected"
        case .exited: "Disconnected"
        case .failed: "Could not connect"
        }
    }
}

/// The server in front: CPU, memory, the root file system and traffic, with
/// the load average and uptime in the tooltip. What does not fit goes,
/// network first.
private struct ServerLoadView: View {
    var load: ServerLoad
    var theme: Theme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(disk: true, network: true)
            row(disk: true, network: false)
            row(disk: false, network: false)
        }
        .font(SBFont.mono(11.5))
        .help(load.details)
        .accessibilityElement(children: .combine)
    }

    private func row(disk: Bool, network: Bool) -> some View {
        HStack(spacing: 12) {
            figure("CPU", load.cpu.map(ServerLoad.percent) ?? "–", warns: (load.cpu ?? 0) >= 0.9)
            figure("RAM", "\(ServerLoad.gigabytes(load.memoryUsed))/\(ServerLoad.gigabytes(load.memoryTotal)) GB",
                   warns: load.memoryShare >= 0.9)
            if disk, let percent = load.diskPercent {
                figure("Disk", "\(percent)%", warns: percent >= 90)
            }
            if network {
                Text("↓ \(ServerLoad.rate(load.receiveRate))  ↑ \(ServerLoad.rate(load.sendRate))")
            }
        }
        .fixedSize()
    }

    /// Past 90% the figure turns yellow: something worth a look.
    private func figure(_ label: String, _ value: String, warns: Bool) -> some View {
        HStack(spacing: 5) {
            Text(label)
            Text(value).foregroundStyle((warns ? theme.ansiYellow : theme.textSecondary).color)
        }
    }
}

