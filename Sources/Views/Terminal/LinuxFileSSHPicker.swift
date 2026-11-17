import SwiftUI

/// The file clipboard needs SSH access to the same Linux desktop, but a VNC
/// port and an SSH port need not share an address (tunnels and jump hosts).
/// Temporary VNC tabs cannot save an SSH association; suggest exact host
/// matches and keep every saved SSH setting reachable by search.
struct LinuxFileSSHPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var sessionStore
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    let desktop: VNCDesktop
    let vncHost: String

    private var choices: [Session] {
        let ssh = sessionStore.sessions.values.filter { $0.kind == .ssh }
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty {
            return ssh.filter { session in
                session.id.localizedStandardContains(search) ||
                session.address.localizedStandardContains(search) ||
                session.subtitle.localizedStandardContains(search)
            }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        }
        return ssh.filter { $0.host.caseInsensitiveCompare(vncHost) == .orderedSame }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Linux File Clipboard")
                .font(.title2.weight(.semibold))
            Text("Choose SSH access for this temporary VNC tab, using the desktop user. Save a VNC session to keep this setting for later tabs.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Search SSH sessions by name or address", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
            Text(query.isEmpty ? "Same host" : "Search results")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(choices, id: \.id) { ssh in
                        Button {
                            do {
                                let plan = try ConnectionStore.launchPlan(for: ssh, in: sessionStore)
                                desktop.connectLinuxFiles(plan: plan, title: ssh.id)
                                dismiss()
                            } catch {
                                desktop.reportLinuxFilesError(String(describing: error))
                                dismiss()
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ssh.id).fontWeight(.medium)
                                Text(ssh.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if choices.isEmpty {
                        Text(query.isEmpty
                             ? "No SSH session uses this host. Search above to choose another address."
                             : "No SSH sessions found.")
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 380)
        .task { searchFocused = true }
    }
}
