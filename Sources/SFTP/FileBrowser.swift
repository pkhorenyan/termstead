import AppKit
import Observation

/// The Files panel's state for one tab: where it is, what is there, and what
/// is being transferred. Lives as long as its `Connection`, so switching tabs
/// and back keeps the folder you were in.
@MainActor
@Observable
final class FileBrowser {
    /// One line in the panel's activity strip.
    struct Activity: Identifiable, Equatable {
        enum State: Equatable {
            case queued
            case waitingForChoice
            /// `progress` is nil when it cannot be measured.
            case running(progress: Double?)
            case done
            case failed(String)
            case cancelled
            case skipped
        }

        let id = UUID()
        var title: String
        var state: State
        var isTransfer = false
        /// Where a finished download landed, for "Show in Finder".
        var localURL: URL?
    }

    private(set) var path: String?
    private(set) var files: [RemoteFile] = [] {
        didSet { visibleFiles = Self.sortedForDisplay(files, showHidden: showHidden) }
    }
    private(set) var isLoading = false
    private(set) var problem: String?
    private(set) var activities: [Activity] = []
    var showHidden = false {
        didSet { visibleFiles = Self.sortedForDisplay(files, showHidden: showHidden) }
    }
    var selection: String?
    var selectedPaths: Set<String> = []
    @ObservationIgnored private var selectionAnchor: String?

    func select(_ file: RemoteFile, modifiers: NSEvent.ModifierFlags = []) {
        let path = file.path
        if modifiers.contains(.shift), let anchor = selectionAnchor,
           let first = visibleFiles.firstIndex(where: { $0.path == anchor }),
           let last = visibleFiles.firstIndex(where: { $0.path == path }) {
            selectedPaths = Set(visibleFiles[min(first, last)...max(first, last)].map(\.path))
        } else if modifiers.contains(.command) {
            if selectedPaths.contains(path) { selectedPaths.remove(path) }
            else { selectedPaths.insert(path) }
            selectionAnchor = selectedPaths.contains(path) ? path : selectedPaths.first
        } else {
            selectedPaths = [path]
            selectionAnchor = path
        }
        selection = selectedPaths.contains(path) ? path : selectedPaths.first
    }

    func selectForContextMenu(_ file: RemoteFile) {
        if !selectedPaths.contains(file.path) { select(file) }
    }

    func clearSelection() {
        selection = nil
        selectedPaths = []
        selectionAnchor = nil
    }

    /// What the list shows. Stored, not computed: sorting a big folder with
    /// `localizedStandardCompare` on every read cost two full sorts per
    /// render — each click, each progress tick.
    private(set) var visibleFiles: [RemoteFile] = []

    var hasHiddenContents: Bool {
        let local = isLocal
        return files.contains { file in
            file.isHidden && (!local || (file.name != ".DS_Store" && file.name != ".localized"))
        }
    }

    static func sortedForDisplay(_ files: [RemoteFile], showHidden: Bool) -> [RemoteFile] {
        let shown = showHidden ? files : files.filter { !$0.isHidden }
        // Folders first, as in Finder's list view with "Keep folders on top".
        return shown.sorted { lhs, rhs in
            let lhsFolder = lhs.kind == .directory, rhsFolder = rhs.kind == .directory
            if lhsFolder != rhsFolder { return lhsFolder }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    @ObservationIgnored private weak var connection: Connection?
    private let localSource: LocalFiles?
    @ObservationIgnored private var retry: Task<Void, Never>?
    /// Waits between tries while the terminal is still logging in: 1, 2, 4,
    /// then 5 s. It sat at 1 s forever, a `sftp` launch a second for as long
    /// as a password prompt went unanswered.
    @ObservationIgnored private var retryDelay: Duration = .seconds(1)
    @ObservationIgnored private var edits: [String: RemoteEdit] = [:]
    @ObservationIgnored private var loadRequest = UUID()
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var copyRequest = UUID()
    private(set) var sourceRevision = UUID()
    @ObservationIgnored private var remoteDrag: (token: UUID, files: [RemoteFile])?
    @ObservationIgnored private(set) lazy var transfers = FileTransferQueue(browser: self)
    /// Tests use a private pasteboard; the app uses the normal Finder clipboard.
    @ObservationIgnored var pasteboard: NSPasteboard = .general
    /// Clipboard files must outlive a tab: Finder may paste after it closes.
    static let clipboardDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("termstead-file-clipboard-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    @ObservationIgnored private var pendingSaves: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private lazy var editDirectory: URL = {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-edit-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
    }()

    /// Overridable for tests; the real one belongs to the tab.
    @ObservationIgnored var clientOverride: (any FileSource)?
    var client: (any FileSource)? { clientOverride ?? localSource ?? connection?.files }
    var transferClient: (any FileSource)? {
        if let connection, !connection.isLocalShell {
            let access = connection.kind == .vnc ? connection.fileAccess : connection
            guard access?.isLoggedIn == true else { return nil }
        }
        return client
    }
    var canFollowTerminal: Bool { localSource == nil && connection?.kind != .sftp }
    /// This Mac's files, for a local terminal.
    var isLocal: Bool { client?.isLocal ?? connection?.isLocalShell ?? false }

    /// Where downloads go.
    @ObservationIgnored var downloadsDirectory = FileManager.default.urls(for: .downloadsDirectory,
                                                                          in: .userDomainMask)[0]

    init(connection: Connection?) {
        self.connection = connection
        localSource = nil
    }

    init(localFiles: LocalFiles) {
        localSource = localFiles
    }

    // MARK: - Browsing

    /// Go wherever the terminal goes, as MobaXterm's "Follow terminal folder".
    /// One setting for every tab.
    var followsTerminal = UserDefaults.standard.object(forKey: "files.followTerminal") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(followsTerminal, forKey: "files.followTerminal")
            if followsTerminal { Task { await followTerminal() } }
        }
    }
    /// Set by the panel: nothing is asked of the server while nobody looks.
    @ObservationIgnored var isShown = false
    @ObservationIgnored private var follow: Task<Void, Never>?

    /// Shows the terminal's folder (or the home folder) the first time, and
    /// catches up with the terminal each time the panel comes back.
    func start() {
        guard !stopped, !isLoading else { return }
        retryDelay = .seconds(1)
        if path == nil {
            Task { await loadFirstFolder() }
        } else if localSource != nil {
            refresh()
        } else {
            Task { await followTerminal() }
        }
    }

    /// A VNC tab may switch SSH accounts while its file browser stays open.
    func sourceChanged() {
        sourceRevision = UUID()
        copyRequest = UUID()
        stopEditing()
        transfers.sourceChanged()
    }

    func resetForNewSource() {
        remoteDrag = nil
        retry?.cancel()
        follow?.cancel()
        loadRequest = UUID()
        isLoading = false
        path = nil
        files = []
        clearSelection()
        problem = nil
        if isShown { start() }
    }

    private func loadFirstFolder() async {
        guard !stopped, !Task.isCancelled else { return }
        let request = beginLoad()
        defer { if request == loadRequest { isLoading = false } }
        let directory: String?
        if canFollowTerminal && followsTerminal { directory = await client?.terminalDirectory() } else { directory = nil }
        guard isCurrent(request) else { return }
        await load(directory, request: request)
    }

    /// Loads a folder before the panel is shown, so that it opens on files
    /// rather than on a wait. False when there is nothing to show: a server
    /// without SFTP — a switch, a router — or a connection already gone.
    func loadAfterLogin() async -> Bool {
        if let path { await load(path) } else { await loadFirstFolder() }
        return problem == nil && path != nil
    }

    /// Return was pressed in the terminal; a `cd` may have run.
    func terminalMayHaveMoved() {
        guard followsTerminal, isShown else { return }
        follow?.cancel()
        follow = Task { [weak self] in
            // The shell runs the line after Return arrives; give it a moment.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.followTerminal()
        }
    }

    private func followTerminal() async {
        guard !stopped, !Task.isCancelled else { return }
        let request = loadRequest
        guard canFollowTerminal, followsTerminal, let client, let directory = await client.terminalDirectory(),
              isCurrent(request), followsTerminal, directory != path else { return }
        await load(directory)
    }

    func refresh() { Task { await load(path) } }
    func goUp() { if let path { Task { await load(RemotePath.parent(of: path)) } } }
    func goHome() { Task { await load(nil) } }
    func go(to path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task { await load(trimmed) }
    }

    /// `nil` means the home folder.
    func load(_ target: String?) async {
        guard !stopped, !Task.isCancelled else { return }
        await load(target, request: beginLoad())
    }

    private func beginLoad() -> UUID {
        retry?.cancel()
        retry = nil
        loadRequest = UUID()
        isLoading = true
        return loadRequest
    }

    private func isCurrent(_ request: UUID) -> Bool {
        request == loadRequest && !stopped && !Task.isCancelled
    }

    private func load(_ target: String?, request: UUID) async {
        defer { if request == loadRequest { isLoading = false } }
        guard isCurrent(request) else { return }
        guard let client else {
            problem = "Not connected."
            return
        }
        do {
            let directory: String
            if let target { directory = target } else { directory = try await client.home() }
            guard isCurrent(request) else { return }
            let listing = try await client.list(directory)
            guard isCurrent(request) else { return }
            path = listing.path
            files = listing.files
            problem = nil
            retryDelay = .seconds(1)
            if let selection, !files.contains(where: { $0.path == selection }) { self.selection = nil }
            selectedPaths.formIntersection(Set(files.map(\.path)))
            if let selectionAnchor, !selectedPaths.contains(selectionAnchor) { self.selectionAnchor = nil }
        } catch SFTPError.notReady {
            guard isCurrent(request) else { return }
            // The terminal is still logging in — a password prompt, say.
            // Check again shortly rather than making the user press Refresh.
            problem = SFTPError.notReady.description
            // Only while someone is looking; showing the panel starts over.
            guard isShown else { return }
            let delay = retryDelay
            retryDelay = min(retryDelay * 2, .seconds(5))
            retry = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard let self, isCurrent(request), isShown else { return }
                // Do not cancel this task when load starts its next request.
                retry = nil
                await load(target)
            }
        } catch {
            guard isCurrent(request) else { return }
            problem = (error as? SFTPError)?.description ?? error.localizedDescription
        }
    }

    /// Double-click: a folder opens in the panel, a file in its Mac app.
    /// A symlink is whichever it turns out to point at.
    func open(_ file: RemoteFile) {
        let revision = sourceRevision
        Task {
            guard !stopped, revision == sourceRevision else { return }
            switch file.kind {
            case .directory:
                await load(file.path)
            case .symlink:
                let isDirectory = await client?.isDirectory(file.path) ?? false
                guard !stopped, revision == sourceRevision else { return }
                if isDirectory {
                    await load(file.path)
                } else {
                    await edit(file)
                }
            case .file:
                await edit(file)
            }
        }
    }

    // MARK: - Changes

    func makeDirectory(named name: String) {
        guard let path, let client, let name = Self.validName(name) else { return }
        Task {
            await perform("New folder “\(name)”") { try await client.makeDirectory(RemotePath.join(path, name)) }
            await load(path)
            selection = RemotePath.join(path, name)
        }
    }

    func rename(_ file: RemoteFile, to name: String) {
        guard let client, let name = Self.validName(name), name != file.name else { return }
        let target = RemotePath.join(RemotePath.parent(of: file.path), name)
        Task {
            await perform("Rename to “\(name)”") { try await client.rename(file.path, to: target) }
            await load(path)
            selection = target
        }
    }

    func delete(_ files: [RemoteFile]) {
        guard let client, !files.isEmpty else { return }
        let directory = path
        Task {
            for file in files {
                await perform("Delete “\(file.name)”") {
                    if file.kind == .directory {
                        try await client.removeDirectory(file.path)
                    } else {
                        try await client.removeFile(file.path)
                    }
                }
            }
            if path == directory, !isLoading { await load(directory) }
        }
    }

    /// A slash would make it a path, and `.`/`..` are not names at all.
    static func validName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), trimmed != ".", trimmed != ".." else { return nil }
        return trimmed
    }

    // MARK: - Transfers

    var selectedFile: RemoteFile? {
        guard let selection else { return nil }
        return files.first { $0.path == selection }
    }

    var selectedFiles: [RemoteFile] {
        let paths = selectedPaths.isEmpty ? Set(selection.map { [$0] } ?? []) : selectedPaths
        return visibleFiles.filter { paths.contains($0.path) }
    }

    func filesForAction(on file: RemoteFile) -> [RemoteFile] {
        let selected = selectedFiles
        return selected.contains(where: { $0.path == file.path }) ? selected : [file]
    }

    func beginRemoteDrag(_ files: [RemoteFile]) -> RemoteFileDragReference? {
        guard !stopped, let connection, !files.isEmpty,
              files.allSatisfy({ Self.validName($0.name) != nil && !$0.name.utf8.contains(0) }) else { return nil }
        let token = UUID()
        remoteDrag = (token, files)
        return RemoteFileDragReference(connectionID: connection.id, token: token)
    }

    func downloadDrag(_ reference: RemoteFileDragReference, into local: FileBrowser, directory: String) -> Bool {
        guard reference.connectionID == connection?.id, let remoteDrag, remoteDrag.token == reference.token,
              !stopped, local.isLocal else { return false }
        self.remoteDrag = nil
        download(remoteDrag.files, into: local, directory: directory)
        return true
    }

    func copySelected() {
        let files = selectedFiles
        guard !files.isEmpty else { return }
        Task { await copyToClipboard(files) }
    }

    func copyToClipboard(_ file: RemoteFile) async {
        await copyToClipboard([file])
    }

    func copyToClipboard(_ files: [RemoteFile]) async {
        guard !files.isEmpty else { return }
        guard let client, !stopped else { return }
        copyRequest = UUID()
        let request = copyRequest
        let change = pasteboard.changeCount
        if client.isLocal {
            pasteboard.clearContents()
            pasteboard.writeObjects(files.map { URL(fileURLWithPath: $0.path) as NSURL })
            return
        }
        guard files.allSatisfy({ Self.validName($0.name) == $0.name && $0.kind != .symlink }) else {
            activities.append(Activity(title: "Copy", state: .failed("Symbolic links and invalid file names cannot be copied to Finder.")))
            return
        }
        let folder = Self.clipboardDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            activities.append(Activity(title: "Copy", state: .failed(error.localizedDescription)))
            return
        }
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: folder) } }
        for file in files {
            let ready = await perform("Copy “\(file.name)”", isTransfer: true, expectedSize: file.kind == .file ? file.size : nil,
                                      growing: folder.appendingPathComponent(file.name)) {
                try await client.download(file.path, recursive: file.kind == .directory, to: folder, as: file.name)
            }
            guard ready, !stopped, request == copyRequest else { return }
        }
        guard pasteboard.changeCount == change else {
            activities.append(Activity(title: "Copy", state: .failed("Clipboard changed before download finished. Copy again.")))
            return
        }
        pasteboard.clearContents()
        published = pasteboard.writeObjects(files.map { folder.appendingPathComponent($0.name) as NSURL })
    }

    func paste(into directory: String? = nil) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            activities.append(Activity(title: "Paste", state: .failed("Copy files in Finder first.")))
            return
        }
        upload(urls, into: directory)
    }

    static func cleanClipboardFiles() {
        try? FileManager.default.removeItem(at: clipboardDirectory)
    }

    func download(_ file: RemoteFile) {
        transfers.download([file], to: downloadsDirectory)
    }

    func download(_ files: [RemoteFile], into local: FileBrowser, directory: String? = nil) {
        guard local.isLocal, let path = directory ?? local.path else { return }
        transfers.download(files, to: URL(fileURLWithPath: path, isDirectory: true), refresh: local)
    }

    /// Files and folders dropped from Finder or picked with Upload.
    func upload(_ urls: [URL], into directory: String? = nil) {
        guard let destination = directory ?? path else { return }
        transfers.upload(urls, to: destination)
    }

    /// Runs one operation with a line in the activity strip; says whether it worked.
    @discardableResult
    private func perform(_ title: String, isTransfer: Bool = false, expectedSize: Int64? = nil, growing: URL? = nil,
                         result: URL? = nil, _ work: @escaping () async throws -> Void) async -> Bool {
        let id = addActivity(title, state: .running(progress: expectedSize == nil ? nil : 0), isTransfer: isTransfer)
        // `sftp` only draws a progress bar on a terminal, so a download's
        // progress is read off the file growing on disk instead.
        var watcher: Task<Void, Never>?
        if let expectedSize, expectedSize > 0, let growing {
            watcher = Task { [weak self] in
                var shown = -1
                while !Task.isCancelled {
                    let size = (try? FileManager.default.attributesOfItem(atPath: growing.path)[.size] as? Int64) ?? 0
                    let progress = min(1, Double(size) / Double(expectedSize))
                    // Written only when the whole percent moves: each write
                    // re-renders the panel, and a stalled transfer used to do
                    // it five times a second for nothing.
                    let percent = Int(progress * 100)
                    if percent != shown {
                        shown = percent
                        self?.updateActivity(id) { $0.state = .running(progress: progress) }
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
        do {
            try await work()
            watcher?.cancel()
            completeActivity(id, state: .done, result: result)
            return true
        } catch {
            watcher?.cancel()
            let message = (error as? SFTPError)?.description ?? error.localizedDescription
            updateActivity(id) { $0.state = .failed(message) }
            return false
        }
    }

    func addActivity(_ title: String, state: Activity.State, isTransfer: Bool = false) -> UUID {
        let activity = Activity(title: title, state: state, isTransfer: isTransfer)
        activities.append(activity)
        return activity.id
    }

    func completeActivity(_ id: UUID, state: Activity.State, result: URL?) {
        updateActivity(id) { $0.state = state; $0.localURL = result }
        if state == .done || state == .skipped {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(result == nil ? 3 : 8))
                // Keep recent results alongside the SFTP reconnect controls.
                guard let self, connection?.kind != .sftp || connection?.isLoggedIn == true else { return }
                dismiss(id)
            }
        }
    }

    func updateActivity(_ id: UUID, _ change: (inout Activity) -> Void) {
        guard let index = activities.firstIndex(where: { $0.id == id }) else { return }
        change(&activities[index])
    }

    func dismiss(_ id: UUID) {
        transfers.forget(id)
        activities.removeAll { $0.id == id }
    }

    static func freeName(_ name: String, in directory: URL) -> String {
        freeName(name) { candidate in
            let path = directory.appendingPathComponent(candidate).path
            return FileManager.default.fileExists(atPath: path)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
        }
    }

    static func freeName(_ name: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for index in 2... {
            let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            if !isTaken(candidate) { return candidate }
        }
        return name
    }

    // MARK: - Open and edit

    /// Downloads to a private folder, opens it in the Mac app for its type,
    /// and uploads it again each time that app saves it.
    private func edit(_ file: RemoteFile) async {
        guard let client else { return }
        let revision = sourceRevision
        if client.isLocal {
            // Already on this Mac: opened where it is, nothing to send back.
            RemoteEdit.open(URL(fileURLWithPath: file.path))
            return
        }
        if let existing = edits[file.path] {
            existing.open()
            return
        }
        // One folder per remote file, so two `config`s from different
        // directories do not collide.
        let folder = editDirectory.appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            activities.append(Activity(title: "Open “\(file.name)”", state: .failed(error.localizedDescription)))
            return
        }
        let succeeded = await perform("Open “\(file.name)”", expectedSize: file.size,
                                      growing: folder.appendingPathComponent(file.name)) {
            try await client.download(file.path, recursive: false, to: folder, as: file.name)
        }
        guard succeeded, !stopped, revision == sourceRevision else {
            try? FileManager.default.removeItem(at: folder)
            return
        }
        let local = folder.appendingPathComponent(file.name)
        let edit = RemoteEdit(local: local, remote: file.path) { [weak self] in
            guard let self, self.sourceRevision == revision else { return }
            self.saveBack(file.name, local: local, remote: file.path)
        }
        edits[file.path] = edit
        edit.open()
    }

    func saveBack(_ name: String, local: URL, remote: String) {
        guard !stopped, let client else { return }
        let previous = pendingSaves[remote]?.task
        let id = UUID()
        let revision = sourceRevision
        let task = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, !stopped, revision == sourceRevision else { return }
            defer { if pendingSaves[remote]?.id == id { pendingSaves[remote] = nil } }
            let snapshot = local.deletingLastPathComponent().appendingPathComponent(".upload-\(id)")
            await perform("Save “\(name)” to the server") {
                // Editors can replace the local file while sftp is reading it.
                // Each upload gets an immutable copy, and the next upload waits
                // for this one before reading the latest saved contents.
                defer { try? FileManager.default.removeItem(at: snapshot) }
                try Task.checkCancellation()
                try await BlockingWork.run { try FileManager.default.copyItem(at: local, to: snapshot) }
                try Task.checkCancellation()
                try await client.replace(remote, with: snapshot)
            }
        }
        pendingSaves[remote] = (id, task)
    }

    /// The tab is closing: stop watching and throw away the local copies.
    func stop() {
        transfers.stop()
        remoteDrag = nil
        stopped = true
        loadRequest = UUID()
        isLoading = false
        retry?.cancel()
        follow?.cancel()
        stopEditing()
        try? FileManager.default.removeItem(at: editDirectory)
    }

    private func stopEditing() {
        for save in pendingSaves.values { save.task.cancel() }
        pendingSaves.removeAll()
        edits.values.forEach { $0.stop() }
        edits.removeAll()
    }
}

/// A remote file open in a Mac app, watched so each save goes back up.
@MainActor
final class RemoteEdit {
    let local: URL
    let remote: String
    private let onSave: () -> Void
    private var source: (any DispatchSourceFileSystemObject)?
    private var lastModified: Date?
    private var pending: Task<Void, Never>?

    init(local: URL, remote: String, onSave: @escaping () -> Void) {
        self.local = local
        self.remote = remote
        self.onSave = onSave
        lastModified = Self.modified(local)
        watch()
    }

    func open() { Self.open(local) }

    static func open(_ local: URL) {
        // A file with no app of its own — `nginx.conf`, `.bashrc` — opens as
        // text rather than in the "choose an application" dialog.
        let workspace = NSWorkspace.shared
        if workspace.urlForApplication(toOpen: local) != nil {
            workspace.open(local)
        } else if let textEdit = workspace.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            workspace.open([local], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// The folder is watched, not the file: most editors save by writing a new
    /// file and renaming it over the old one, which a watch on the file itself
    /// would lose track of after the first save.
    private func watch() {
        let descriptor = Darwin.open(local.deletingLastPathComponent().path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .rename, .extend],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.changed() }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        self.source = source
        source.resume()
    }

    /// Saves arrive as several events (a temporary file, a rename, attributes);
    /// uploading once they settle sends the finished file once.
    private func changed() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            let modified = Self.modified(self.local)
            guard let modified, modified != self.lastModified else { return }
            self.lastModified = modified
            self.onSave()
        }
    }

    func stop() {
        pending?.cancel()
        source?.cancel()
        source = nil
    }

    /// Read from the file system each time: `URL.resourceValues` caches, and
    /// would keep answering with the date of the first read.
    private static func modified(_ url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}
