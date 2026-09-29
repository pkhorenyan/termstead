import AppKit
import SwiftUI

/// Find in the active tab's output, scrollback included (⌘F).
///
/// SwiftTerm ships a find bar of its own; this one exists because that one
/// takes its colours from AppKit rather than the theme.
struct FindBar: View {
    @Environment(AppState.self) private var appState
    var theme: Theme
    var terminal: SSHTerminalView

    @FocusState private var fieldFocused: Bool

    var body: some View {
        @Bindable var appState = appState

        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textMuted.color)
                .padding(.leading, 8)

            TextField("", text: $appState.findQuery,
                      prompt: Text("Find").foregroundStyle(theme.textFaint.color))
                .textFieldStyle(.plain)
                .font(SBFont.ui(13))
                .foregroundStyle(theme.text.color)
                .frame(width: 170)
                .focused($fieldFocused)
                .onSubmit {
                    // Return searches up, ⇧Return down; `onSubmit` carries no
                    // event, so the modifier is read from the current one.
                    let down = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
                    appState.find(in: terminal, upward: !down)
                    fieldFocused = true
                }
                .onExitCommand { close() }
                .onChange(of: appState.findQuery) { appState.findStatus = .idle }
                .accessibilityLabel("Find in terminal")

            if appState.findStatus == .notFound {
                Text("Not found")
                    .font(SBFont.ui(12))
                    .foregroundStyle(theme.ansiRed.color)
                    .fixedSize()
            }

            Button {
                appState.findCaseSensitive.toggle()
                appState.findStatus = .idle
            } label: {
                Text("Aa")
                    .font(SBFont.ui(12, .semibold))
                    .foregroundStyle((appState.findCaseSensitive ? theme.onAccent : theme.textSecondary).color)
                    .frame(width: 26, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(appState.findCaseSensitive ? theme.accent.color : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .help("Match case")
            .accessibilityLabel("Match case")
            .accessibilityAddTraits(appState.findCaseSensitive ? .isSelected : [])

            iconButton("chevron.up", help: "Find next — older output (Return, ⌘G)") {
                appState.find(in: terminal, upward: true)
            }
            iconButton("chevron.down", help: "Find previous — newer output (⇧Return, ⇧⌘G)") {
                appState.find(in: terminal, upward: false)
            }
            iconButton("xmark", help: "Close (Esc)") { close() }
                .padding(.trailing, 4)
        }
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(theme.elevated.color)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(theme.borderStrong.color, lineWidth: 1)
        )
        .onAppear { fieldFocused = true }
        .onChange(of: appState.findFocusToken) { fieldFocused = true }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(theme.textSecondary.color)
        }
        .buttonStyle(IconButtonStyle(theme: theme, size: CGSize(width: 24, height: 24)))
        .help(help)
        .accessibilityLabel(help)
    }

    private func close() {
        appState.closeFind()
        terminal.window?.makeFirstResponder(terminal)
    }
}
