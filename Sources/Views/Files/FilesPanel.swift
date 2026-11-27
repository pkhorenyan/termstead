import AppKit
import SwiftUI

/// The sidebar's Files tab: the active tab's server, browsed over SFTP, or
/// this Mac's disk for a local terminal.
struct FilesPanel: View {
    @Environment(\.theme) private var theme
    @Environment(ConnectionStore.self) private var connectionStore
    @Environment(AppState.self) private var appState

    var body: some View {
        if let connection = connectionStore.active {
            if connection.kind == .vnc {
                if let title = connection.fileAccessTitle, connection.fileAccessProblem == nil {
                    FileBrowserView(browser: connection.fileBrowser, title: title)
                        .id(connection.id)
                } else {
                    VStack(spacing: 10) {
                        placeholder("VNC files", connection.fileAccessProblem ??
                                    "To upload or download files, enable SSH file transfer in this VNC session's settings and enter its SSH login there.")
                        if connection.fileAccessTitle != nil, connection.fileAccessProblem != nil {
                            Button("Reconnect File Access") { connection.reconnectFileAccess() }
                                .buttonStyle(PrimaryButtonStyle(theme: theme, height: 28, horizontalPadding: 12))
                        }
                        if let id = connection.sessionID {
                            Button("Set Up File Transfer…") { appState.route = .sessionSettings(id: id) }
                                .buttonStyle(SecondaryButtonStyle(theme: theme, height: 26, fontSize: 12))
                        }
                    }
                }
            } else if connection.kind == .sftp {
                let remote = connection.fileBrowser
                FileBrowserView(browser: appState.localFiles, title: "This Mac",
                                transfer: .init(title: "Upload to Remote Folder", symbol: "arrow.right",
                                                available: connection.isLoggedIn && remote.path != nil) { files in
                    remote.upload(files.map { URL(fileURLWithPath: $0.path) })
                })
            } else if connection.kind == .rdp {
                placeholder("Remote desktop",
                            "Files are browsed over SFTP, which an RDP session does not have.")
            } else if connection.kind == .telnet {
                placeholder("Telnet",
                            "Files are browsed over SFTP, which a Telnet session does not have.")
            } else if connection.state.isRunning {
                FileBrowserView(browser: connection.fileBrowser, title: connection.title)
                    // A fresh view per tab, so a rename field or a scroll
                    // position never carries over to another server.
                    .id(connection.id)
            } else {
                placeholder("Not connected",
                            "Reconnect the tab — press Return in it — to browse its files.")
            }
        } else {
            placeholder("No open tab", "Connect to a session to browse its files here.")
        }
    }

    private func placeholder(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(theme.textFaint.color)
            Text(title)
                .font(SBFont.ui(13, .medium))
                .foregroundStyle(theme.text.color)
            Text(detail)
                .font(SBFont.ui(12))
                .foregroundStyle(theme.textMuted.color)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FileBrowserView: View {
    struct Transfer {
        var title: String
        var symbol: String
        var available: Bool
        var run: ([RemoteFile]) -> Void
    }

    @Environment(\.theme) private var theme
    @Environment(ConnectionStore.self) private var connectionStore
    @Bindable var browser: FileBrowser
    var title: String
    var transfer: Transfer? = nil
    var onFocus: () -> Void = {}
    var defaultListStyle: FileBrowser.ListStyle = .compact

    private let listOutlineOutset: CGFloat = 3
    private let panelCornerRadius: CGFloat = 8

    @State private var pathText = ""
    @State private var renaming: RemoteFile?
    @State private var newName = ""
    @State private var creatingFolder = false
    @State private var pendingDeletion: [RemoteFile]?
    @State private var dropTargeted = false
    @State private var targetedFolder: String?
    @State private var transferConflict: FileTransferQueue.Conflict?
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            toolbar
            HStack(spacing: 8) {
                pathField
                viewMenu
            }
            list
            // Its own view, so a progress tick re-renders the strip and not
            // the file list above it.
            FileActivityStrip(browser: browser, theme: theme) { transferConflict = browser.transfers.conflict }
        }
        .onAppear {
            browser.isShown = true
            browser.start()
            pathText = browser.path ?? ""
        }
        .onDisappear { browser.isShown = false }
        .onChange(of: browser.path) { pathText = browser.path ?? "" }
        .onChange(of: browser.sourceRevision) {
            renaming = nil
            creatingFolder = false
            pendingDeletion = nil
        }
        .onChange(of: browser.transfers.conflict?.id, initial: true) {
            transferConflict = browser.transfers.conflict
        }
        .sheet(item: $transferConflict) { conflict in
            TransferConflictSheet(conflict: conflict, queue: browser.transfers)
                .interactiveDismissDisabled()
        }
        .alert("Rename “\(renaming?.name ?? "")”", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let renaming { browser.rename(renaming, to: newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("New Folder", isPresented: $creatingFolder) {
            TextField("Name", text: $newName)
            Button("Create") { browser.makeDirectory(named: newName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("In \(browser.path ?? "the current folder")")
        }
        .alert(deleteTitle, isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { files in
            Button("Delete", role: .destructive) {
                browser.delete(files)
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { files in
            let includesFolders = files.contains { $0.kind == .directory }
            if browser.isLocal {
                Text(includesFolders
                     ? "The selected items, including the contents of any folders, will be moved to the Trash."
                     : "The selected files will be moved to the Trash.")
            } else {
                Text(includesFolders
                     ? "The selected items, including the contents of any folders, will be permanently deleted from \(title)."
                     : "The selected files will be permanently deleted from \(title).")
            }
        }
    }

    // MARK: - Toolbar and path

    private var toolbar: some View {
        // No gaps: at the sidebar's narrowest the panel has 176pt. With 2pt
        // gaps the row took 186, and the overflow pushed the tab rail past
        // the window's edge.
        HStack(spacing: 0) {
            tool("arrow.up", help: "Enclosing folder") { browser.goUp() }
                .disabled(browser.path == nil || browser.path == "/")
            tool("house", help: "Home folder") { browser.goHome() }
            tool("arrow.clockwise", help: "Refresh") { browser.refresh() }
            if browser.canFollowTerminal {
                tool("link", help: browser.followsTerminal
                        ? "Following the terminal's folder — click to stop"
                        : "Follow the terminal's folder",
                     isOn: browser.followsTerminal) {
                    browser.followsTerminal.toggle()
                }
            }
            Spacer(minLength: 4)
            tool("folder.badge.plus", help: "New folder") {
                newName = ""
                creatingFolder = true
            }
            .disabled(browser.path == nil)
            tool("square.and.arrow.up", help: browser.isLocal ? "Copy files or folders here" : "Upload files or folders") { chooseUploads() }
                .disabled(browser.path == nil)
            if let transfer {
                tool(transfer.symbol, help: transfer.title) { transfer.run(browser.selectedFiles) }
                    .disabled(!transfer.available || browser.selectedFiles.isEmpty)
            }
            tool(browser.showHidden ? "eye" : "eye.slash",
                 help: browser.showHidden ? "Hide hidden files" : "Show hidden files") {
                browser.showHidden.toggle()
            }
        }
    }

    private func tool(_ symbol: String, help: String, isOn: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: isOn ? .semibold : .medium))
                .foregroundStyle((isOn ? theme.accent : theme.textSecondary).color)
        }
        .buttonStyle(IconButtonStyle(theme: theme, size: CGSize(width: 24, height: 26)))
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var pathField: some View {
        TextField("", text: $pathText, prompt: Text("/path").foregroundStyle(theme.textFaint.color))
            .textFieldStyle(.plain)
            .font(SBFont.mono(11.5))
            .foregroundStyle(theme.text.color)
            .onSubmit { browser.go(to: pathText) }
            .accessibilityLabel(browser.isLocal ? "Local folder" : "Remote folder")
            .padding(.leading, 9 + listOutlineOutset)
            .padding(.trailing, 8)
            .frame(height: 28)
            .background(FieldBackground(theme: theme, cornerRadius: panelCornerRadius))
            .padding(.horizontal, -listOutlineOutset)
    }

    // MARK: - List

    private var listStyle: FileBrowser.ListStyle { browser.listStyle ?? defaultListStyle }

    private var viewMenu: some View {
        Menu {
            Picker("View as", selection: Binding(
                get: { listStyle },
                set: { browser.listStyle = $0 }
            )) {
                ForEach(FileBrowser.ListStyle.allCases) { style in
                    Text(style.rawValue).tag(style)
                }
            }
            .pickerStyle(.inline)
            if listStyle == .compact {
                Divider()
                Picker("Sort by", selection: $browser.sortField) {
                    ForEach(FileBrowser.SortField.allCases) { field in
                        Text(field.rawValue).tag(field)
                    }
                }
                Picker("Sort order", selection: $browser.sortAscending) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
            }
        } label: {
            Image(systemName: listStyle == .compact ? "list.bullet" : "list.bullet.rectangle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textSecondary.color)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .help("File view options")
        .accessibilityLabel("File view options")
        .accessibilityValue(listStyle.rawValue)
    }

    private var list: some View {
        GeometryReader { viewport in
            let columns = listStyle == .detailed ? FileListColumns(width: viewport.size.width) : nil
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    LazyVStack(alignment: .leading, spacing: 1, pinnedViews: .sectionHeaders) {
                        Section {
                            ForEach(browser.visibleFiles) { file in
                                row(file, columns: columns)
                            }
                        } header: {
                            if let columns { columnHeaders(columns) }
                        }
                    }
                    Spacer(minLength: 0)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            browser.clearSelection()
                            listFocused = true
                        }
                        .overlay {
                            if !browser.visibleFiles.isEmpty { dropTarget() }
                        }
                }
                .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .topLeading)
                .background(ThinScroller(isDark: theme.isDark, alwaysVisible: true))
            }
        }
        .frame(maxHeight: .infinity)
        .focusable()
        .focusEffectDisabled()
        .focused($listFocused)
        .onKeyPress(phases: .down) { press in
            guard press.modifiers == .command else { return .ignored }
            switch press.key {
            case "c":
                guard !browser.selectedFiles.isEmpty else { return .ignored }
                browser.copySelected()
                return .handled
            case "v":
                browser.paste()
                return .handled
            default: return .ignored
            }
        }
        .overlay { listOverlay }
        .overlay {
            if browser.visibleFiles.isEmpty { dropTarget() }
        }
        .overlay {
            RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                .strokeBorder(listOutlineColor, lineWidth: 1)
                .padding(-listOutlineOutset)
                .opacity(listFocused || dropTargeted ? 1 : 0)
                .allowsHitTesting(false)
        }
        .contextMenu {
            Button("New Folder…") { newName = ""; creatingFolder = true }
            Button(browser.isLocal ? "Copy Here…" : "Upload…") { chooseUploads() }
            Button("Paste") { browser.paste() }
            Divider()
            Button("Refresh") { browser.refresh() }
        }
    }

    private func columnHeaders(_ columns: FileListColumns) -> some View {
        HStack(spacing: FileListColumns.spacing) {
            sortHeader(.name, title: "Name", alignment: .leading)
                .frame(maxWidth: .infinity)
            sortHeader(.size, title: "Size", alignment: .trailing)
                .frame(width: columns.sizeWidth)
            sortHeader(.modified, title: "Date", alignment: .leading)
                .frame(width: columns.dateWidth)
        }
        .padding(.horizontal, FileListColumns.inset)
        .frame(height: 24)
        .background(theme.sidebar.color)
        .overlay(alignment: .bottom) { Divider1(theme.border).allowsHitTesting(false) }
    }

    private func sortHeader(_ field: FileBrowser.SortField, title: String, alignment: Alignment) -> some View {
        let isActive = browser.sortField == field
        return Button {
            browser.sort(by: field)
        } label: {
            HStack(spacing: 4) {
                Text(title).font(SBFont.ui(11, .semibold)).lineLimit(1)
                if isActive {
                    Image(systemName: browser.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
            }
            .foregroundStyle((isActive ? theme.text : theme.textMuted).color)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sort by \(field.rawValue.lowercased())")
        .accessibilityLabel(field.rawValue)
        .accessibilityValue(isActive ? (browser.sortAscending ? "Ascending" : "Descending") : "")
    }

    private var listOutlineColor: Color {
        if theme.id == Theme.sepia.id { return theme.ansiBlue.color }
        return Color(nsColor: .keyboardFocusIndicatorColor)
    }

    @ViewBuilder
    private var listOverlay: some View {
        if browser.isLoading && browser.files.isEmpty {
            ProgressView().controlSize(.small)
        } else if let problem = browser.problem {
            VStack(spacing: 8) {
                Text(problem)
                    .font(SBFont.ui(12))
                    .foregroundStyle(theme.textMuted.color)
                    .multilineTextAlignment(.center)
                Button("Try Again") { browser.refresh() }
                    .buttonStyle(SecondaryButtonStyle(theme: theme, height: 26, fontSize: 12))
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.sidebar.color)
        } else if browser.visibleFiles.isEmpty && browser.path != nil {
            VStack(spacing: 8) {
                Text(browser.hasHiddenContents ? "This folder contains hidden files" : "Empty folder")
                    .font(SBFont.ui(12))
                    .foregroundStyle(theme.textFaint.color)
                    .multilineTextAlignment(.center)
                if browser.hasHiddenContents {
                    Button("Show Hidden Files") { browser.showHidden = true }
                        .buttonStyle(SecondaryButtonStyle(theme: theme, height: 26, fontSize: 12))
                }
            }
        }
    }

    private func row(_ file: RemoteFile, columns: FileListColumns?) -> some View {
        FileRow(file: file, isSelected: browser.selectedPaths.contains(file.path), theme: theme, columns: columns)
            .overlay {
                if targetedFolder == file.path {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(listOutlineColor, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .overlay(FileDrag(file: file, browser: browser, onFocus: focusList))
            .overlay(ContextClickDetector { browser.selectForContextMenu(file); focusList() })
            .overlay {
                if file.kind == .directory { dropTarget(into: file.path) }
            }
            .contextMenu {
                Button(file.kind == .directory ? "Open" : "Open in Mac App") { browser.open(file) }
                if let transfer {
                    Button(transfer.title) { transfer.run(browser.selectedFiles) }
                        .disabled(!transfer.available)
                }
                Button("Download to Downloads") { browser.download(file) }
                Button("Copy") { browser.copySelected() }
                    .disabled(file.kind == .symlink)
                if file.kind == .directory {
                    Button("Paste Into Folder") { browser.paste(into: file.path) }
                }
                Divider()
                Button("Rename…") {
                    newName = file.name
                    renaming = file
                }
                Button("Delete…", role: .destructive) { pendingDeletion = browser.filesForAction(on: file) }
                Divider()
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.path, forType: .string)
                }
            }
    }

    private var deleteTitle: String {
        guard let files = pendingDeletion, let first = files.first else { return "Delete Items?" }
        return files.count == 1 ? "Delete “\(first.name)”?" : "Delete \(files.count) items?"
    }

    private func focusList() {
        listFocused = true
        onFocus()
    }

    private func dropTarget(into folder: String? = nil) -> some View {
        FileDropTarget(browser: browser, folder: folder, onTargeted: { targeted in
            if let folder {
                if targeted { targetedFolder = folder }
                else if targetedFolder == folder { targetedFolder = nil }
            } else {
                dropTargeted = targeted
            }
        }) { payload in
            guard let destination = folder ?? browser.path else { return false }
            switch payload {
            case .local(let urls):
                browser.upload(urls, into: destination)
                return true
            case .remote(let reference):
                if FileDrop.download(reference, into: browser, directory: destination, in: connectionStore) {
                    return true
                }
                _ = browser.addActivity("Drop Files", state: .failed("The dragged files are no longer available."))
                return false
            }
        }
    }

    private func chooseUploads() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = browser.isLocal ? "Copy" : "Upload"
        panel.message = "\(browser.isLocal ? "Copy" : "Upload") to \(browser.path ?? "the server")"
        guard panel.runModal() == .OK else { return }
        browser.upload(panel.urls)
    }

}

/// Standard file URLs from Finder and the local browser use the same drop path.
@MainActor
enum FileDrop {
    enum Payload: Equatable {
        case local([URL])
        case remote(RemoteFileDragReference)
    }

    static func read(_ pasteboard: NSPasteboard) -> Payload? {
        if let data = pasteboard.data(forType: RemoteFileDragReference.pasteboardType),
           let reference = try? JSONDecoder().decode(RemoteFileDragReference.self, from: data) {
            return .remote(reference)
        }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.isEmpty ? nil : .local(urls)
    }

    static func download(_ reference: RemoteFileDragReference, into local: FileBrowser,
                         directory: String, in store: ConnectionStore) -> Bool {
        guard let connection = store.connections.first(where: { $0.id == reference.connectionID }) else { return false }
        return connection.fileBrowser.downloadDrag(reference, into: local, directory: directory)
    }
}

/// Transfers in progress and their outcomes, under the list.
private struct TransferConflictSheet: View {
    let conflict: FileTransferQueue.Conflict
    let queue: FileTransferQueue
    @State private var applyToBatch = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("“\(conflict.name)” already exists")
                .font(.headline)
            Text(conflict.folder)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Toggle("Apply to the remaining conflicts in this group", isOn: $applyToBatch)
            HStack {
                Button("Cancel Transfer", role: .cancel) { queue.cancel(conflict.id) }
                Spacer()
                action("Skip", .skip)
                if conflict.canReplace { action("Replace", .replace) }
                action("Keep Both", .keepBoth).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private func action(_ title: String, _ choice: FileTransferQueue.Choice) -> some View {
        Button(title) { queue.resolve(conflict.id, with: choice, forBatch: applyToBatch) }
    }
}

struct FileActivityStrip: View {
    var browser: FileBrowser
    var theme: Theme
    var onResolve: (() -> Void)? = nil

    var body: some View {
        if !browser.activities.isEmpty {
            let queue = browser.transfers
            let failed = browser.activities.filter(queue.canRetry)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(browser.activities.allSatisfy(\.isTransfer) ? "Transfers" : "File Operations")
                        .font(SBFont.ui(11, .semibold))
                    Spacer()
                    if failed.count > 1 {
                        Button("Retry Failed") { queue.retry(failed.map(\.id)) }.controlSize(.small)
                    }
                }
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(browser.activities) { activity in
                            ActivityRow(activity: activity, theme: theme, queue: queue, onResolve: onResolve,
                                        onDismiss: { browser.dismiss(activity.id) })
                        }
                    }
                }
                .frame(maxHeight: min(160, CGFloat(browser.activities.count) * 68))
            }
        }
    }
}

private struct FileListColumns {
    static let spacing: CGFloat = 7
    static let inset: CGFloat = 7
    let width: CGFloat

    var sizeWidth: CGFloat { min(84, width * 0.21) }

    var dateWidth: CGFloat {
        // Use room for the time only as the panel gets wider.
        let widthWithTime = 58 + max(0, width - 270) * 0.5
        return min(164, width * 0.34, widthWithTime)
    }
}

private struct FileRow: View {
    var file: RemoteFile
    var isSelected: Bool
    var theme: Theme
    var columns: FileListColumns?

    var body: some View {
        HStack(spacing: FileListColumns.spacing) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle((file.kind == .directory ? theme.accent : theme.textMuted).color)
                    .frame(width: 16)
                Text(file.name)
                    .font(SBFont.ui(12.5))
                    .foregroundStyle((file.isHidden ? theme.textMuted : theme.text).color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let columns {
                fileSize
                    .minimumScaleFactor(0.8)
                    .frame(width: columns.sizeWidth, alignment: .trailing)
                modificationDate
                    .frame(width: columns.dateWidth, alignment: .leading)
            } else if file.kind == .file {
                fileSize.fixedSize()
            }
        }
        .padding(.horizontal, FileListColumns.inset)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? theme.selected.color : Color.clear)
        )
        .contentShape(Rectangle())
        .help(details)
    }

    private var fileSize: some View {
        Text(file.kind == .file ? ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file) : "")
            .font(SBFont.mono(10.5))
            .foregroundStyle(theme.textFaint.color)
            .lineLimit(1)
    }

    @ViewBuilder
    private var modificationDate: some View {
        if let modified = file.modified {
            ViewThatFits(in: .horizontal) {
                Text(modified, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                    .fixedSize(horizontal: true, vertical: false)
                Text(modified, format: .dateTime.day().month(.twoDigits).year(.twoDigits))
                    .minimumScaleFactor(0.8)
            }
            .font(SBFont.ui(11))
            .foregroundStyle(theme.textMuted.color)
            .lineLimit(1)
        } else {
            Text("")
        }
    }

    private var symbol: String {
        switch file.kind {
        case .directory: "folder.fill"
        case .symlink: "arrow.up.right.square"
        case .file: "doc"
        }
    }

    private var details: String {
        var parts = ["\(file.permissions)  \(file.owner):\(file.group)"]
        if let modified = file.modified {
            parts.append(modified.formatted(date: .abbreviated, time: .shortened))
        }
        return file.name + "\n" + parts.joined(separator: "\n")
    }
}

private struct ActivityRow: View {
    var activity: FileBrowser.Activity
    var theme: Theme
    var queue: FileTransferQueue
    var onResolve: (() -> Void)?
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            status
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title)
                    .font(SBFont.ui(11.5))
                    .foregroundStyle(theme.text.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if case .failed(let message) = activity.state {
                    Text(message)
                        .font(SBFont.ui(11))
                        .foregroundStyle(theme.ansiRed.color)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .running(let progress?) = activity.state {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(theme.accent.color)
                        .controlSize(.mini)
                }
            }
            Spacer(minLength: 0)
            if let url = activity.localURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 10.5, weight: .semibold))
                }
                .buttonStyle(IconButtonStyle(theme: theme, size: CGSize(width: 20, height: 20)))
                .foregroundStyle(theme.textSecondary.color)
                .help("Show in Finder")
            }
            if queue.canRetry(activity) {
                Button { queue.retry([activity.id]) } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(IconButtonStyle(theme: theme, size: CGSize(width: 20, height: 20)))
                .help("Retry Transfer")
                .accessibilityLabel("Retry Transfer")
            }
            if activity.state == .waitingForChoice, let onResolve {
                Button(action: onResolve) {
                    Image(systemName: "ellipsis.circle").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(IconButtonStyle(theme: theme, size: CGSize(width: 20, height: 20)))
                .help("Resolve Name Conflict")
                .accessibilityLabel("Resolve Name Conflict")
            }
            let label = canCancel ? "Cancel Transfer" : "Dismiss"
            if canCancel || isFinished {
                Button { if canCancel { queue.cancel(activity.id) } else { onDismiss() } } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(IconButtonStyle(theme: theme, size: CGSize(width: 20, height: 20)))
                .foregroundStyle(theme.textSecondary.color)
                .help(label)
                .accessibilityLabel(label)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.elevated.color)
        )
    }

    private var canCancel: Bool { queue.finishing != activity.id && queue.canCancel(activity) }

    private var isFinished: Bool {
        switch activity.state {
        case .queued, .waitingForChoice, .running: false
        default: true
        }
    }

    @ViewBuilder
    private var status: some View {
        switch activity.state {
        case .queued:
            Image(systemName: "clock").help("Queued")
        case .waitingForChoice:
            Image(systemName: "questionmark.circle").help("Waiting for a choice")
        case .running: ProgressView().controlSize(.mini)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(theme.ansiGreen.color)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(theme.ansiRed.color)
        case .cancelled:
            Image(systemName: "xmark.circle").help("Cancelled")
        case .skipped:
            Image(systemName: "forward.circle").help("Skipped")
        }
    }
}
