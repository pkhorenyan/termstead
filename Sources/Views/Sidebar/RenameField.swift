import SwiftUI

/// The editable name a sidebar row shows while it is being renamed, as in
/// Finder: Return keeps the new name, Escape keeps the old one, and clicking
/// elsewhere keeps the new one too.
struct RenameField: View {
    @Environment(\.theme) private var theme
    @Binding var text: String
    var font: Font
    var onCommit: () -> Void
    var onCancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(theme.text.color)
            .focused($focused)
            .onSubmit(onCommit)
            .onExitCommand(perform: onCancel)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(theme.field.color)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(theme.accent.color, lineWidth: 1))
            )
            .onAppear { focused = true }
            // Losing focus — a click elsewhere — keeps what was typed. After
            // Escape the row has already left renaming, so this does nothing.
            .onChange(of: focused) { _, isFocused in
                if !isFocused { onCommit() }
            }
            .accessibilityLabel("Name")
    }
}
