import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The sidebar's Files tab: the active tab's server, browsed over SFTP.
struct FilesPanel: View {
    @Environment(\.theme) private var theme
    @Environment(ConnectionStore.self) private var connectionStore

    var body: some View {
        if let connection = connectionStore.active {
            if connection.state.isRunning {
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

private struct FileBrowserView: View {
    @Environment(\.theme) private var theme
    @Bindable var browser: FileBrowser
    var title: String

    @State private var pathText = ""
    @State private var renaming: RemoteFile?
    @State private var newName = ""
    @State private var creatingFolder = false
    @State private var deleting: RemoteFile?
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 8) {
            toolbar
            pathField
            list
            // Its own view, so a progress tick re-renders the strip and not
            // the file list above it.
            ActivityStrip(browser: browser, theme: theme)
        }
        .onAppear {
            browser.isShown = true
            browser.start()
            pathText = browser.path ?? ""
        }
        .onDisappear { browser.isShown = false }
        .onChange(of: browser.path) { pathText = browser.path ?? "" }
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
        .alert("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let deleting { browser.delete(deleting) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text(deleting?.kind == .directory
                 ? "The folder and everything in it are deleted from \(title). This cannot be undone."
                 : "The file is deleted from \(title). This cannot be undone.")
        }
    }

    // MARK: - Toolbar and path

    private var toolbar: some View {
        HStack(spacing: 2) {
            tool("arrow.up", help: "Enclosing folder") { browser.goUp() }
                .disabled(browser.path == nil || browser.path == "/")
            tool("house", help: "Home folder") { browser.goHome() }
            tool("arrow.clockwise", help: "Refresh") { browser.refresh() }
            tool("link", help: browser.followsTerminal
                    ? "Following the terminal's folder — click to stop"
                    : "Follow the terminal's folder",
                 isOn: browser.followsTerminal) {
                browser.followsTerminal.toggle()
            }
            Spacer(minLength: 4)
            tool("folder.badge.plus", help: "New folder") {
                newName = ""
                creatingFolder = true
            }
            .disabled(browser.path == nil)
            tool("square.and.arrow.up", help: "Upload files or folders") { chooseUploads() }
                .disabled(browser.path == nil)
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
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(FieldBackground(theme: theme, cornerRadius: 7))
            .accessibilityLabel("Remote folder")
    }

    // MARK: - List

    private var list: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(browser.visibleFiles) { file in
                    row(file)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ThinScroller(isDark: theme.isDark, alwaysVisible: true))
        }
        .frame(maxHeight: .infinity)
        .overlay { listOverlay }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.accent.color, lineWidth: 2)
                .opacity(dropTargeted ? 1 : 0)
                .allowsHitTesting(false)
        }
        // Files dropped from Finder go into the folder on show.
        .dropDestination(for: URL.self) { urls, _ in
            let local = urls.filter(\.isFileURL)
            guard !local.isEmpty else { return false }
            browser.upload(local)
            return true
        } isTargeted: { dropTargeted = $0 }
        .contextMenu {
            Button("New Folder…") { newName = ""; creatingFolder = true }
            Button("Upload…") { chooseUploads() }
            Divider()
            Button("Refresh") { browser.refresh() }
        }
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
            Text(browser.files.isEmpty ? "Empty folder" : "Only hidden files")
                .font(SBFont.ui(12))
                .foregroundStyle(theme.textFaint.color)
        }
    }

    private func row(_ file: RemoteFile) -> some View {
        FileRow(file: file, isSelected: browser.selection == file.path, theme: theme)
            // The row the menu is for is highlighted before the menu opens.
            .overlay(ContextClickDetector { browser.selection = file.path })
            // Both taps, simultaneously: selection must not wait out the
            // double-click interval (see CLAUDE.md, the 357 ms lesson).
            .onTapGesture(count: 2) { browser.open(file) }
            .simultaneousGesture(TapGesture().onEnded { browser.selection = file.path })
            .onDrag { Self.provider(for: file, client: browser.client) }
            .dropDestination(for: URL.self) { urls, _ in
                guard file.kind == .directory else { return false }
                browser.upload(urls.filter(\.isFileURL), into: file.path)
                return true
            }
            .contextMenu {
                Button(file.kind == .directory ? "Open" : "Open in Mac App") { browser.open(file) }
                Button("Download to Downloads") { browser.download(file) }
                Divider()
                Button("Rename…") {
                    newName = file.name
                    renaming = file
                }
                Button("Delete…", role: .destructive) { deleting = file }
                Divider()
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.path, forType: .string)
                }
            }
    }

    /// Dragging a row to Finder downloads it: the promise is kept only once
    /// Finder asks for the file, into a folder of the system's choosing.
    private static func provider(for file: RemoteFile, client: SFTPClient?) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = file.name
        guard let client else { return provider }
        let type = file.kind == .directory ? UTType.folder : UTType.data
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [],
                                            visibility: .all) { completion in
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("sb-drag-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
            Task {
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try await client.download(file.path, recursive: file.kind == .directory,
                                              to: folder, as: file.name)
                    completion(folder.appendingPathComponent(file.name), false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }

    private func chooseUploads() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Upload to \(browser.path ?? "the server")"
        guard panel.runModal() == .OK else { return }
        browser.upload(panel.urls)
    }

}

/// Transfers in progress and their outcomes, under the list.
private struct ActivityStrip: View {
    var browser: FileBrowser
    var theme: Theme

    var body: some View {
        if !browser.activities.isEmpty {
            VStack(spacing: 4) {
                ForEach(browser.activities) { activity in
                    ActivityRow(activity: activity, theme: theme,
                                onDismiss: { browser.dismiss(activity.id) })
                }
            }
        }
    }
}

private struct FileRow: View {
    var file: RemoteFile
    var isSelected: Bool
    var theme: Theme

    var body: some View {
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
            Spacer(minLength: 6)
            if file.kind == .file {
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .font(SBFont.mono(10.5))
                    .foregroundStyle(theme.textFaint.color)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? theme.selected.color : Color.clear)
        )
        .contentShape(Rectangle())
        .help(details)
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
            if case .running = activity.state {} else {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(IconButtonStyle(theme: theme, size: CGSize(width: 20, height: 20)))
                .foregroundStyle(theme.textSecondary.color)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.elevated.color)
        )
    }

    @ViewBuilder
    private var status: some View {
        switch activity.state {
        case .running: ProgressView().controlSize(.mini)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(theme.ansiGreen.color)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(theme.ansiRed.color)
        }
    }
}
