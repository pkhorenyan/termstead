import SwiftUI

struct StatusBarView: View {
    @Environment(\.theme) private var theme
    @Environment(SessionStore.self) private var sessionStore
    @Environment(ConnectionStore.self) private var connectionStore
    @Environment(SessionStorage.self) private var storage

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
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(groupColor?.tileFill ?? theme.elevated.color)
                        )
                        .foregroundStyle((groupTextColor ?? theme.textSecondary).color)
                }

                Spacer(minLength: 0)

                unsavedNote

                Text(tab.columns > 0 ? "UTF-8 · xterm-256color · \(tab.columns)×\(tab.rows)" : "UTF-8 · xterm-256color")
                    .font(SBFont.mono(11.5))
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
