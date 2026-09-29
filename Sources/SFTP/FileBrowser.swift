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
            /// `progress` is nil when it cannot be measured (uploads, folders).
            case running(progress: Double?)
            case done
            case failed(String)
        }

        let id = UUID()
        var title: String
        var state: State
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

    /// What the list shows. Stored, not computed: sorting a big folder with
    /// `localizedStandardCompare` on every read cost two full sorts per
    /// render — each click, each progress tick.
    private(set) var visibleFiles: [RemoteFile] = []

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
    @ObservationIgnored private var retry: Task<Void, Never>?
    /// Waits between tries while the terminal is still logging in: 1, 2, 4,
    /// then 5 s. It sat at 1 s forever, a `sftp` launch a second for as long
    /// as a password prompt went unanswered.
    @ObservationIgnored private var retryDelay: Duration = .seconds(1)
    @ObservationIgnored private var edits: [String: RemoteEdit] = [:]
    @ObservationIgnored private lazy var editDirectory: URL = {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-edit-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
    }()

    /// Overridable for tests; the real one belongs to the tab.
    @ObservationIgnored var clientOverride: SFTPClient?
    var client: SFTPClient? { clientOverride ?? connection?.sftp }

    /// Where downloads go.
    @ObservationIgnored var downloadsDirectory = FileManager.default.urls(for: .downloadsDirectory,
                                                                          in: .userDomainMask)[0]

    init(connection: Connection?) {
        self.connection = connection
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
        guard !isLoading else { return }
        retryDelay = .seconds(1)
        if path == nil {
            Task { await loadFirstFolder() }
        } else {
            Task { await followTerminal() }
        }
    }

    private func loadFirstFolder() async {
        if followsTerminal, let directory = await client?.terminalDirectory() {
            await load(directory)
        } else {
            await load(nil)
        }
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
        guard followsTerminal, let client, let directory = await client.terminalDirectory(),
              directory != path else { return }
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
        retry?.cancel()
        guard let client else {
            problem = "Not connected."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let directory: String
            if let target { directory = target } else { directory = try await client.home() }
            let listing = try await client.list(directory)
            path = listing.path
            files = listing.files
            problem = nil
            retryDelay = .seconds(1)
            if let selection, !files.contains(where: { $0.path == selection }) { self.selection = nil }
        } catch SFTPError.notReady {
            // The terminal is still logging in — a password prompt, say.
            // Check again shortly rather than making the user press Refresh.
            problem = SFTPError.notReady.description
            // Only while someone is looking; showing the panel starts over.
            guard isShown else { return }
            let delay = retryDelay
            retryDelay = min(retryDelay * 2, .seconds(5))
            retry = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, self?.isShown == true else { return }
                await self?.load(target)
            }
        } catch {
            problem = (error as? SFTPError)?.description ?? error.localizedDescription
        }
    }

    /// Double-click: a folder opens in the panel, a file in its Mac app.
    /// A symlink is whichever it turns out to point at.
    func open(_ file: RemoteFile) {
        Task {
            switch file.kind {
            case .directory:
                await load(file.path)
            case .symlink:
                if let client, await client.isDirectory(file.path) {
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

    func delete(_ file: RemoteFile) {
        guard let client else { return }
        Task {
            await perform("Delete “\(file.name)”") {
                if file.kind == .directory {
                    try await client.removeDirectory(file.path)
                } else {
                    try await client.removeFile(file.path)
                }
            }
            await load(path)
        }
    }

    /// A slash would make it a path, and `.`/`..` are not names at all.
    static func validName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), trimmed != ".", trimmed != ".." else { return nil }
        return trimmed
    }

    // MARK: - Transfers

    /// Into ~/Downloads, under a name that does not overwrite anything there.
    func download(_ file: RemoteFile) {
        guard let client else { return }
        Task {
            var isFolder = file.kind == .directory
            if file.kind == .symlink { isFolder = await client.isDirectory(file.path) }
            let name = Self.freeName(file.name, in: downloadsDirectory)
            let target = downloadsDirectory.appendingPathComponent(name)
            await perform("Download “\(file.name)”", expectedSize: isFolder ? nil : file.size,
                          growing: isFolder ? nil : target, result: target) {
                try await client.download(file.path, recursive: isFolder, to: self.downloadsDirectory, as: name)
            }
        }
    }

    /// Files and folders dropped from Finder or picked with Upload.
    func upload(_ urls: [URL], into directory: String? = nil) {
        guard let client, let destination = directory ?? path else { return }
        Task {
            for url in urls {
                await perform("Upload “\(url.lastPathComponent)”") {
                    try await client.upload(url, to: destination)
                }
            }
            if destination == path { await load(path) }
        }
    }

    /// Runs one operation with a line in the activity strip; says whether it worked.
    @discardableResult
    private func perform(_ title: String, expectedSize: Int64? = nil, growing: URL? = nil,
                         result: URL? = nil, _ work: @escaping () async throws -> Void) async -> Bool {
        let activity = Activity(title: title, state: .running(progress: expectedSize == nil ? nil : 0))
        activities.append(activity)
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
                        self?.update(activity.id) { $0.state = .running(progress: progress) }
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
        do {
            try await work()
            watcher?.cancel()
            update(activity.id) { $0.state = .done; $0.localURL = result }
            // A finished line clears itself; a failure stays until dismissed.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(result == nil ? 3 : 8))
                self?.dismiss(activity.id)
            }
            return true
        } catch {
            watcher?.cancel()
            let message = (error as? SFTPError)?.description ?? error.localizedDescription
            update(activity.id) { $0.state = .failed(message) }
            return false
        }
    }

    private func update(_ id: UUID, _ change: (inout Activity) -> Void) {
        guard let index = activities.firstIndex(where: { $0.id == id }) else { return }
        change(&activities[index])
    }

    func dismiss(_ id: UUID) {
        activities.removeAll { $0.id == id }
    }

    static func freeName(_ name: String, in directory: URL) -> String {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.appendingPathComponent(name).path) else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for index in 2... {
            let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            if !manager.fileExists(atPath: directory.appendingPathComponent(candidate).path) { return candidate }
        }
        return name
    }

    // MARK: - Open and edit

    /// Downloads to a private folder, opens it in the Mac app for its type,
    /// and uploads it again each time that app saves it.
    private func edit(_ file: RemoteFile) async {
        guard let client else { return }
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
        guard succeeded else { return }
        let local = folder.appendingPathComponent(file.name)
        let edit = RemoteEdit(local: local, remote: file.path) { [weak self] in
            self?.saveBack(file.name, local: local, remote: file.path)
        }
        edits[file.path] = edit
        edit.open()
    }

    private func saveBack(_ name: String, local: URL, remote: String) {
        guard let client else { return }
        Task { await perform("Save “\(name)” to the server") { try await client.replace(remote, with: local) } }
    }

    /// The tab is closing: stop watching and throw away the local copies.
    func stop() {
        retry?.cancel()
        edits.values.forEach { $0.stop() }
        edits.removeAll()
        try? FileManager.default.removeItem(at: editDirectory)
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

    func open() {
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
