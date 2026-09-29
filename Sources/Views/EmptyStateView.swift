import SwiftUI

/// What the terminal column shows on first launch, before any session exists.
struct EmptyStateView: View {
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var appState
    @Environment(ConnectionStore.self) private var connectionStore
    @FocusState private var addressFocused: Bool

    /// Only what does something on this screen: with no sessions and no tabs,
    /// New Tab and Close Tab have nothing to act on.
    private let shortcuts = [
        ("Quick connect", "⌘K"),
        ("New session", "⌘N"),
        ("New group", "⇧⌘N"),
        ("Settings", "⌘,"),
    ]

    var body: some View {
        @Bindable var appState = appState

        VStack(alignment: .leading, spacing: 22) {
            PromptGlyph.view(size: 26, color: theme.accent.color)
                .frame(width: 52, height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(theme.accent.tileFill)
                )

            VStack(alignment: .leading, spacing: 8) {
                Text("Connect to a server")
                    .font(SBFont.ui(26, .semibold))
                    .kerning(-0.26)
                    .foregroundStyle(theme.text.color)
                Text("Type an address or pick a session on the \(themeStore.sidebarSide.rawValue) to open a terminal.")
                    .font(SBFont.ui(14))
                    .foregroundStyle(theme.textSecondary.color)
                    .lineSpacing(7)
            }

            HStack(spacing: 8) {
                TextField("user@host:22", text: $appState.quickConnect)
                    .textFieldStyle(.plain)
                    .font(SBFont.mono(14))
                    .foregroundStyle(theme.text.color)
                    .focused($addressFocused)
                    .onSubmit { connectQuickly() }
                    .padding(.horizontal, 14)
                    .frame(height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.window.color)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(theme.borderStrong.color, lineWidth: 1)
                            )
                    )
                    .accessibilityLabel("Server address")

                Button("Connect") { connectQuickly() }
                .buttonStyle(PrimaryButtonStyle(theme: theme, height: 42,
                                                horizontalPadding: 18, fontSize: 14))
            }

            VStack(spacing: 0) {
                Divider1(theme.border)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 24),
                                    GridItem(.flexible(), spacing: 24)],
                          spacing: 8) {
                    ForEach(shortcuts, id: \.0) { label, key in
                        HStack {
                            Text(label)
                                .font(SBFont.ui(13))
                                .foregroundStyle(theme.textSecondary.color)
                            Spacer(minLength: 0)
                            KeyCap(theme: theme, label: key, fontSize: 12)
                                .foregroundStyle(theme.text.color)
                        }
                        .padding(.top, 10)
                    }
                }
            }
            .padding(.top, 6)
        }
        .frame(width: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.terminal.color)
        .onChange(of: appState.quickConnectFocusToken) { addressFocused = true }
    }

    /// Host keys are checked by ssh itself: a host it has not seen asks
    /// yes/no in the terminal, against the real `known_hosts`.
    private func connectQuickly() {
        connectionStore.connect(address: appState.quickConnect)
        appState.quickConnect = ""
    }
}
