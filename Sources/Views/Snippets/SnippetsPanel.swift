import SwiftUI
import UniformTypeIdentifiers

/// The sidebar's Snippets tab: commands to send to the tab in front with a
/// double-click — and, with broadcast input on, to every pane.
struct SnippetsPanel: View {
    @Environment(\.theme) private var theme
    @Environment(SnippetStore.self) private var snippets
    @Environment(ConnectionStore.self) private var connectionStore
    @Environment(AppState.self) private var appState

    @State private var selection: UUID?
    @State private var deleting: Snippet?

    var body: some View {
        VStack(spacing: 8) {
            header
            if snippets.snippets.isEmpty {
                empty
            } else {
                list
            }
        }
        .alert("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let deleting { snippets.delete(deleting.id) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 2) {
            Text(target.map { "To \($0)" } ?? "No tab to send to")
                .font(SBFont.ui(12))
                .foregroundStyle(theme.textMuted.color)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button { appState.route = .snippet(id: nil) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary.color)
            }
            .buttonStyle(IconButtonStyle(theme: theme, size: CGSize(width: 24, height: 26)))
            .help("New snippet")
            .accessibilityLabel("New snippet")
        }
        .padding(.leading, 4)
    }

    /// Where a double-click goes, as the header says it.
    private var target: String? {
        guard let tab = connectionStore.snippetTarget else { return nil }
        if connectionStore.isBroadcasting && connectionStore.canBroadcast {
            let panes = (0..<connectionStore.layout.paneCount).filter { connectionStore.receivesBroadcast(pane: $0) }.count
            return "\(tab.title) and \(max(panes - 1, 0)) more panes"
        }
        return tab.title
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(theme.textFaint.color)
            Text("No snippets yet")
                .font(SBFont.ui(13, .medium))
                .foregroundStyle(theme.text.color)
            Text("Save the commands you type often, then double-click one to send it to the tab in front.")
                .font(SBFont.ui(12))
                .foregroundStyle(theme.textMuted.color)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            Button("New Snippet…") { appState.route = .snippet(id: nil) }
                .buttonStyle(SecondaryButtonStyle(theme: theme, height: 28, fontSize: 12.5, filled: true))
                .padding(.top, 4)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(Array(snippets.snippets.enumerated()), id: \.element.id) { index, snippet in
                    row(snippet, at: index)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ThinScroller(isDark: theme.isDark, alwaysVisible: true))
        }
        .frame(maxHeight: .infinity)
        .contextMenu {
            Button("New Snippet…") { appState.route = .snippet(id: nil) }
        }
    }

    private func row(_ snippet: Snippet, at index: Int) -> some View {
        SnippetRow(snippet: snippet, isSelected: selection == snippet.id, theme: theme)
            .overlay(ContextClickDetector { selection = snippet.id })
            // Both taps, simultaneously: selection must not wait out the
            // double-click interval (see CLAUDE.md, the 357 ms lesson).
            .onTapGesture(count: 2) { send(snippet) }
            .simultaneousGesture(TapGesture().onEnded { selection = snippet.id })
            .onDrag { NSItemProvider(object: snippet.id.uuidString as NSString) }
            .onDrop(of: [.text], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let text = object as? String, let id = UUID(uuidString: text) else { return }
                    Task { @MainActor in snippets.move(id, to: index) }
                }
                return true
            }
            .contextMenu {
                Button("Send") { send(snippet) }
                    .disabled(connectionStore.snippetTarget == nil)
                Button("Edit…") { appState.route = .snippet(id: snippet.id) }
                Button("Duplicate") { selection = snippets.duplicate(snippet.id)?.id }
                Divider()
                Button("Delete…", role: .destructive) { deleting = snippet }
            }
    }

    private func send(_ snippet: Snippet) {
        selection = snippet.id
        connectionStore.send(snippet)
    }
}

private struct SnippetRow: View {
    var snippet: Snippet
    var isSelected: Bool
    var theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(snippet.name)
                    .font(SBFont.ui(12.5, .medium))
                    .foregroundStyle(theme.text.color)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !snippet.pressReturn {
                    // Left on the prompt, to finish by hand.
                    Image(systemName: "text.cursor")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textFaint.color)
                        .help("Sent without Return")
                }
            }
            Text(snippet.firstLine)
                .font(SBFont.mono(11))
                .foregroundStyle(theme.textMuted.color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? theme.selected.color : Color.clear)
        )
        .contentShape(Rectangle())
        .help(snippet.text)
    }
}
