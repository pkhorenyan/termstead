import SwiftUI

/// A new snippet, or one being changed: its name, the lines it types, and
/// whether Return follows them.
struct SnippetSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.closeForm) private var close
    @Environment(SnippetStore.self) private var snippets

    /// `nil` for a new one.
    var snippetID: UUID?

    @State private var name = ""
    @State private var text = ""
    @State private var pressReturn = true
    @State private var didLoad = false
    @FocusState private var textFocused: Bool

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: snippetID == nil ? "New snippet" : "Edit snippet",
                        subtitle: "Typed into the tab in front, line by line, as if you typed it.",
                        horizontalPadding: 24)

            VStack(alignment: .leading, spacing: 14) {
                FormField(label: "Name") {
                    SBTextField(text: $name, placeholder: "Restart nginx", font: SBFont.ui(13.5),
                                focusOnAppear: true)
                }
                FormField(label: "Commands") {
                    TextEditor(text: $text)
                        .font(SBFont.mono(13))
                        .foregroundStyle(theme.text.color)
                        .scrollContentBackground(.hidden)
                        .focused($textFocused)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .frame(height: 150)
                        .background(FieldBackground(theme: theme, focused: textFocused))
                }
                Toggle(isOn: $pressReturn) {
                    Text("Press Return after the last line")
                        .font(SBFont.ui(13))
                        .foregroundStyle(theme.text.color)
                }
                .toggleStyle(.checkbox)
                .tint(theme.accent.color)
                InsetNote(text: pressReturn
                          ? "Every line runs, the last one included."
                          : "The last line is left on the prompt, to finish or change before running it.")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(maxHeight: .infinity, alignment: .top)

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SecondaryButtonStyle(theme: theme, height: 36,
                                                      horizontalPadding: 16, fontSize: 13.5))
                // No Return shortcut: Return is a new line in the commands.
                Button("Save", action: save)
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(PrimaryButtonStyle(theme: theme, height: 36,
                                                    horizontalPadding: 18, fontSize: 13.5))
                    .disabled(!canSave)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .overlay(alignment: .top) { Divider1(theme.border) }
        }
        .frame(width: 520, height: 470)
        .background(theme.chrome.color)
        .onAppear(perform: load)
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        guard let snippetID, let snippet = snippets.snippet(snippetID) else { return }
        name = snippet.name
        text = snippet.text
        pressReturn = snippet.pressReturn
    }

    private func save() {
        guard canSave else { return }
        var snippet = snippetID.flatMap(snippets.snippet) ?? Snippet(name: "", text: "")
        snippet.name = name.trimmingCharacters(in: .whitespaces)
        snippet.text = text
        snippet.pressReturn = pressReturn
        snippets.save(snippet)
        close()
    }
}
