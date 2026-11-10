import SwiftUI
import UniformTypeIdentifiers

struct SessionTransferSheet: View {
    static let fileType = UTType(exportedAs: SessionArchive.format, conformingTo: .json)
    enum Mode {
        case export(groupID: String?), importFile(groupID: String?)
        var id: String {
            switch self {
            case .export(let id): "export:\(id ?? "all")"
            case .importFile(let id): "import:\(id ?? "top")"
            }
        }
        var title: String { isExport ? "Export sessions" : "Import sessions" }
        var isExport: Bool { if case .export = self { return true }; return false }
    }
    var mode: Mode
    @Environment(\.theme) private var theme
    @Environment(\.closeForm) private var close
    @Environment(SessionStore.self) private var store

    @State private var groupID: String?
    @State private var keepFolders = true
    @State private var includePasswords = false
    @State private var password = ""
    @State private var confirmation = ""
    @State private var conflict = SessionTransfer.Conflict.keepBoth
    @State private var fileName = ""
    @State private var fileData: Data?
    @State private var encrypted = false
    @State private var contents: SessionArchive.Contents?
    @State private var busy = false
    @State private var problem: String?
    @State private var result: String?

    private var snapshot: SessionSnapshot { SessionTransfer.exportSnapshot(store.snapshot, groupID: groupID) }
    private var plan: SessionTransfer.Plan? {
        guard let contents else { return nil }
        return try? SessionTransfer.plan(contents, into: store.snapshot, conflict: conflict,
                                         destinationGroupID: groupID, keepFolders: keepFolders)
    }
    private var ready: Bool {
        if busy || result != nil { return false }
        if mode.isExport { return !snapshot.sessions.isEmpty && (!includePasswords || (!password.isEmpty && password == confirmation)) }
        return contents != nil && (plan?.added.isEmpty == false)
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: mode.title,
                subtitle: mode.isExport ? "Move your connections to another Mac, or keep a backup."
                    : "Review the file before adding anything to your sidebar.", horizontalPadding: 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if mode.isExport { exportOptions } else { importOptions }
                    if busy { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
                    if let problem { Text(problem).font(SBFont.ui(12.5)).foregroundStyle(theme.ansiRed.color).textSelection(.enabled) }
                    if let result { Text(result).font(SBFont.ui(13)).foregroundStyle(theme.text.color).textSelection(.enabled) }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                Spacer()
                Button(result == nil ? "Cancel" : "Done") { close() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SecondaryButtonStyle(theme: theme, height: 36, horizontalPadding: 16, fontSize: 13.5))
                    .disabled(busy)
                if result == nil {
                    Button(mode.isExport ? "Export…" : "Import") {
                        if mode.isExport { chooseDestination() } else { importSessions() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PrimaryButtonStyle(theme: theme, height: 36, horizontalPadding: 18, fontSize: 13.5))
                    .disabled(!ready)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            .overlay(alignment: .top) { Divider1(theme.border) }
        }
        .frame(width: 580, height: 620)
        .background(theme.chrome.color)
        .background(TransferWorkGuard(isWorking: busy))
        .onAppear {
            switch mode {
            case .export(let id), .importFile(let id): groupID = id
            }
        }
    }

    private var exportOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            FormField(label: "Sessions") {
                Picker("Sessions", selection: $groupID) {
                    Text("All sessions").tag(String?.none)
                    ForEach(store.groupOptions(), id: \.id) { group in
                        Text(String(repeating: "  ", count: group.depth) + group.name).tag(Optional(group.id))
                    }
                }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            }
            InsetNote(text: "\(snapshot.sessions.count) sessions. Folder structure, colors, jump hosts and tunnels are included. Required jump-host sessions from other folders are included automatically.")
            Toggle("Include saved passwords and key passphrases", isOn: $includePasswords)
                .toggleStyle(.checkbox).tint(theme.accent.color)
            if includePasswords {
                passwordField("File password", text: $password)
                passwordField("Confirm password", text: $confirmation)
                if !confirmation.isEmpty && confirmation != password {
                    Text("Passwords do not match.").font(SBFont.ui(12)).foregroundStyle(theme.ansiRed.color)
                }
                InsetNote(text: "The entire file will be encrypted. Keep its password: it cannot be recovered. macOS may ask you to allow access to saved passwords.")
            } else {
                InsetNote(text: "Saved passwords are excluded. On another Mac, enter them when connecting. The file contains server addresses and usernames.")
            }
            InsetNote(text: "SSH private-key files, ssh config and local shared folders are not copied. Their paths are kept; check them on the destination Mac.")
        }
        .font(SBFont.ui(13)).foregroundStyle(theme.text.color)
        .disabled(busy || result != nil)
    }

    private var importOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            FormField(label: "Import into") {
                Picker("Import into", selection: $groupID) {
                    Text("Top level").tag(String?.none)
                    ForEach(store.groupOptions(), id: \.id) { group in
                        Text(store.groupPath(group.id).joined(separator: " / ")).tag(Optional(group.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if groupID != nil {
                Toggle("Keep folders from file", isOn: $keepFolders)
                    .toggleStyle(.checkbox).tint(theme.accent.color)
                InsetNote(text: keepFolders
                    ? "Folders from the file will be added inside the selected group."
                    : "All imported sessions will be added directly to the selected group.")
            }
            HStack {
                Text(fileName.isEmpty ? "Choose a Termstead session file" : fileName)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose File…", action: chooseSource)
                    .buttonStyle(SecondaryButtonStyle(theme: theme, height: 30, horizontalPadding: 12, fontSize: 12.5))
            }
            if encrypted && contents == nil {
                passwordField("File password", text: $password)
                Button("Unlock", action: unlock).disabled(password.isEmpty)
            }
            if let contents {
                Text("\(contents.snapshot.sessions.count) supported sessions · \(contents.credentials.count) saved credentials")
                    .font(SBFont.ui(13, .medium))
                Picker("If a session already exists", selection: $conflict) {
                    ForEach(SessionTransfer.Conflict.allCases) { Text($0.label).tag($0) }
                }
                if let plan {
                    InsetNote(text: "\(plan.added.count) will be added, \(plan.renamed.count) renamed, \(plan.skipped) skipped. Existing sessions and passwords are kept. Sessions depending on an unrelated skipped jump host are skipped too.")
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(plan.added.prefix(12)) { session in
                            Text("\(session.id) · \(session.kind.label) · \(session.host)")
                                .font(SBFont.ui(12)).lineLimit(1).truncationMode(.middle)
                        }
                        if plan.added.count > 12 { Text("…and \(plan.added.count - 12) more").font(SBFont.ui(12)) }
                    }
                } else {
                    Text(planningProblem).font(SBFont.ui(12.5)).foregroundStyle(theme.ansiRed.color)
                }
                if contents.unsupportedCount > 0 {
                    InsetNote(text: "\(contents.unsupportedCount) sessions use unsupported types (\(contents.unsupportedTypes.joined(separator: ", "))) and will be skipped. Their saved passwords will not be imported.")
                }
                if contents.snapshot.sessions.isEmpty {
                    InsetNote(text: "There are no supported sessions to import in this version of Termstead.")
                }
                InsetNote(text: "Imported passwords are stored in this Mac’s Keychain. SSH key files and shared-folder paths may need updating. Import does not open any connections.")
            }
        }
        .font(SBFont.ui(13)).foregroundStyle(theme.text.color)
        .disabled(busy || result != nil)
    }

    private var planningProblem: String {
        guard let contents else { return "" }
        do {
            _ = try SessionTransfer.plan(contents, into: store.snapshot, conflict: conflict,
                                         destinationGroupID: groupID, keepFolders: keepFolders)
            return ""
        }
        catch { return error.localizedDescription }
    }

    private func passwordField(_ label: String, text: Binding<String>) -> some View {
        FormField(label: label) {
            SBTextField(text: text, placeholder: label, font: SBFont.ui(13.5), isSecure: true)
                .accessibilityLabel(label)
        }
    }

    private func chooseSource() {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.fileType, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            fileName = url.lastPathComponent
            contents = nil; fileData = nil; encrypted = false; password = ""; problem = nil; busy = true
            Task { @MainActor in
                defer { busy = false }
                do {
                    let data = try await BlockingWork.run { try SessionArchive.read(from: url) }
                    encrypted = try SessionArchive.isEncrypted(data)
                    fileData = data
                    if !encrypted { contents = try SessionArchive.decode(data) }
                } catch { problem = error.localizedDescription }
            }
        }
    }

    private func unlock() {
        guard let fileData else { return }
        let password = password
        busy = true; problem = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                contents = try await BlockingWork.run { try SessionArchive.decode(fileData, password: password) }
                self.password = ""
            } catch { problem = error.localizedDescription }
        }
    }

    private func chooseDestination() {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.fileType]
        panel.nameFieldStringValue = "Termstead sessions.termstead"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let snapshot = snapshot
            let include = includePasswords
            let password = include ? password : nil
            busy = true; problem = nil
            Task { @MainActor in
                defer { busy = false }
                do {
                    try await BlockingWork.run {
                        let credentials = include ? try SessionTransfer.credentials(for: snapshot, using: KeychainStore.shared) : []
                        let data = try SessionArchive.encode(SessionArchive.document(snapshot, credentials: credentials), password: password)
                        try SessionArchive.write(data, to: url)
                    }
                    self.password = ""; confirmation = ""
                    result = "Exported \(snapshot.sessions.count) sessions to \(url.lastPathComponent)."
                } catch { problem = error.localizedDescription }
            }
        }
    }

    private func importSessions() {
        guard let contents else { return }
        busy = true; problem = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let (plan, saved) = try await SessionTransfer.importSessions(contents, into: store, conflict: conflict,
                    destinationGroupID: groupID, keepFolders: keepFolders)
                self.contents = nil; fileData = nil
                result = "Imported \(plan.added.count) sessions and saved \(saved) credentials in Keychain. \(plan.skipped) existing or dependent sessions were skipped."
            } catch { problem = error.localizedDescription }
        }
    }
}

/// Keep a transfer's model and Keychain commit together, even if Escape or
/// the titlebar's close button is pressed while Keychain is answering.
private struct TransferWorkGuard: NSViewRepresentable {
    var isWorking: Bool
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {
        nsView.isWorking = isWorking
        nsView.updateWindow()
    }
    final class Probe: NSView {
        var isWorking = false
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateWindow() }
        func updateWindow() {
            guard let window = window as? FormWindow else { return }
            window.isWorking = isWorking
            window.standardWindowButton(.closeButton)?.isEnabled = !isWorking
        }
    }
}
