import SwiftUI

/// Connect to an address without saving it — the "+" in the tab strip, ⌘T,
/// and ⌘K once tabs are open. The first-launch screen has the same field
/// inline; this is it for when that screen is not showing.
struct QuickConnectSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.closeForm) private var close
    @Environment(ConnectionStore.self) private var connectionStore

    @State private var address = ""
    /// Checked as typed, so a mistyped address is caught here rather than as
    /// an error in a new tab.
    private var problem: String? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        do {
            _ = try SSHLaunch.parseAddress(trimmed)
            return nil
        } catch {
            return String(describing: error)
        }
    }

    private var canConnect: Bool {
        !address.trimmingCharacters(in: .whitespaces).isEmpty && problem == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Quick connect",
                        subtitle: "Open a connection without adding it to the sidebar.",
                        horizontalPadding: 24)

            VStack(alignment: .leading, spacing: 8) {
                FormField(label: "Address") {
                    SBTextField(text: $address, placeholder: "user@host:22",
                                font: SBFont.mono(14), focused: true)
                        .onSubmit(connect)
                }
                Text(problem ?? "Keys, the ssh agent and ~/.ssh/config apply as usual.")
                    .font(SBFont.ui(12))
                    .foregroundStyle((problem == nil ? theme.textMuted : theme.ansiRed).color)
                    .fixedSize(horizontal: false, vertical: true)
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
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PrimaryButtonStyle(theme: theme, height: 36,
                                                    horizontalPadding: 18, fontSize: 13.5))
                    .disabled(!canConnect)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .overlay(alignment: .top) { Divider1(theme.border) }
        }
        .frame(width: 460, height: 250)
        .background(theme.chrome.color)
    }

    private func connect() {
        guard canConnect else { return }
        let target = address.trimmingCharacters(in: .whitespaces)
        close()
        connectionStore.connect(address: target)
    }
}
