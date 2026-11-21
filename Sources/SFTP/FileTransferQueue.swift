import AppKit
import Observation

/// Direct uploads and downloads share a serial queue per file browser.
@MainActor
@Observable
final class FileTransferQueue {
    enum Choice {
        case skip, replace, keepBoth
    }

    struct Conflict: Identifiable {
        let id: UUID
        let name: String
        let folder: String
        let canReplace: Bool
    }

    private enum Operation {
        case upload(URL, to: String)
        case download(RemoteFile, to: URL, refresh: FileBrowser?)

        var name: String {
            switch self {
            case .upload(let url, _): url.lastPathComponent
            case .download(let file, _, _): file.name
            }
        }

        var title: String {
            switch self {
            case .upload: "Upload “\(name)”"
            case .download: "Download “\(name)”"
            }
        }
    }

    private struct Job {
        let operation: Operation
        let batch: UUID
        var choice: Choice?
    }

    private(set) var conflict: Conflict?
    private(set) var finishing: UUID?
    private weak var browser: FileBrowser?
    @ObservationIgnored private var jobs: [UUID: Job] = [:]
    @ObservationIgnored private var pending: [UUID] = []
    @ObservationIgnored private var choices: [UUID: Choice] = [:]
    @ObservationIgnored private var active: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var remoteStages: Set<String> = []
    @ObservationIgnored private var sourceRevision = UUID()
    @ObservationIgnored private var stopped = false

    init(browser: FileBrowser) { self.browser = browser }

    func upload(_ urls: [URL], to path: String) {
        enqueue(urls.map { .upload($0, to: path) })
    }

    func download(_ files: [RemoteFile], to folder: URL, refresh: FileBrowser? = nil) {
        enqueue(files.map { .download($0, to: folder, refresh: refresh) })
    }

    private func enqueue(_ operations: [Operation]) {
        guard let browser, !stopped else { return }
        let batch = UUID()
        for operation in operations {
            let id = browser.addActivity(operation.title, state: .queued, isTransfer: true)
            jobs[id] = Job(operation: operation, batch: batch)
            pending.append(id)
        }
        startNext()
    }

    func canRetry(_ activity: FileBrowser.Activity) -> Bool {
        guard case .failed = activity.state else { return false }
        return jobs[activity.id] != nil
    }

    func canCancel(_ activity: FileBrowser.Activity) -> Bool {
        guard jobs[activity.id] != nil else { return false }
        switch activity.state {
        case .queued, .waitingForChoice, .running: return true
        default: return false
        }
    }

    func retry(_ ids: [UUID]) {
        guard let browser, !stopped else { return }
        let wanted = Set(ids)
        for activity in browser.activities where wanted.contains(activity.id) && canRetry(activity) {
            jobs[activity.id]?.choice = nil
            browser.updateActivity(activity.id) { $0.state = .queued }
            pending.append(activity.id)
        }
        startNext()
    }

    func resolve(_ id: UUID, with choice: Choice, forBatch: Bool) {
        guard let conflict, conflict.id == id, let job = jobs[id] else { return }
        guard choice != .replace || conflict.canReplace else { return }
        if forBatch { choices[job.batch] = choice }
        jobs[id]?.choice = choice
        self.conflict = nil
        browser?.updateActivity(id) { $0.state = .queued }
        pending.insert(id, at: 0)
        startNext()
    }

    func cancel(_ id: UUID) {
        guard finishing != id else { return }
        if active?.id == id {
            active?.task.cancel()
        } else if pending.contains(id) || conflict?.id == id {
            pending.removeAll { $0 == id }
            if conflict?.id == id { conflict = nil }
            finish(id, state: .cancelled)
            startNext()
        }
    }

    func forget(_ id: UUID) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        if !jobs.values.contains(where: { $0.batch == job.batch }) { choices[job.batch] = nil }
    }

    func stop() {
        stopped = true
        active?.task.cancel()
        pending.removeAll()
        conflict = nil
        jobs.removeAll()
        choices.removeAll()
    }

    /// A VNC session can be reconfigured to browse a different SSH host.
    func sourceChanged() {
        sourceRevision = UUID()
        remoteStages.removeAll()
        pending.removeAll()
        conflict = nil
        active?.task.cancel()
        for id in Array(jobs.keys) { browser?.dismiss(id) }
    }

    func sourceReady() {
        if let client = browser?.transferClient, !remoteStages.isEmpty { cleanRemoteStages(using: client) }
        startNext()
    }

    private func startNext() {
        guard !stopped, active == nil, conflict == nil, let client = browser?.transferClient else { return }
        guard let id = pending.first, let job = jobs[id] else {
            if !remoteStages.isEmpty { cleanRemoteStages(using: client) }
            return
        }
        pending.removeFirst()
        browser?.updateActivity(id) { $0.state = .running(progress: nil) }
        let revision = sourceRevision
        active = (id, Task {
            do {
                try await self.run(id, job: job, client: client, revision: revision)
            } catch {
                if revision == self.sourceRevision {
                    let message = (error as? SFTPError)?.description ?? error.localizedDescription
                    if Task.isCancelled { self.finish(id, state: .cancelled) }
                    else { self.browser?.updateActivity(id) { $0.state = .failed(message) } }
                }
            }
            self.finishing = nil
            self.active = nil
            // Failed cleanup is retried on login or when the user submits more work.
            if !self.pending.isEmpty { self.startNext() }
        })
    }

    private func finish(_ id: UUID, state: FileBrowser.Activity.State, result: URL? = nil) {
        forget(id)
        browser?.completeActivity(id, state: state, result: result)
    }

    private func run(_ id: UUID, job: Job, client: any FileSource, revision: UUID) async throws {
        let operation = job.operation
        let name = operation.name
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else {
            throw SFTPError.failed("Invalid file name.")
        }

        let target: any FileSource
        let folder: String
        let kind: RemoteFile.Kind
        let size: Int64?
        switch operation {
        case .upload(let url, let destination):
            target = client
            folder = destination
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            kind = values.isSymbolicLink == true ? .symlink : values.isDirectory == true ? .directory : .file
            size = values.fileSize.map(Int64.init)
        case .download(let file, let destination, _):
            target = LocalFiles()
            folder = destination.path
            kind = file.kind
            size = file.size
        }
        let destination = try await target.list(folder)
        try Task.checkCancellation()
        let ignoresCase = target.isLocal && (try? URL(fileURLWithPath: destination.path)
            .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) == false
        func sameName(_ lhs: String, _ rhs: String) -> Bool {
            ignoresCase ? lhs.compare(rhs, options: .caseInsensitive) == .orderedSame : lhs == rhs
        }
        let existing = destination.files.first { sameName($0.name, name) }
        let canReplace = kind == .file && existing?.kind == .file
        var finalName = name
        var replacing = false
        if let existing {
            let choice = job.choice ?? choices[job.batch]
            switch choice {
            case .skip:
                finish(id, state: .skipped)
                return
            case .keepBoth:
                finalName = FileBrowser.freeName(name) { candidate in
                    destination.files.contains { sameName($0.name, candidate) }
                }
            case .replace where canReplace:
                finalName = existing.name
                replacing = true
            default:
                conflict = Conflict(id: id, name: name, folder: destination.path, canReplace: canReplace)
                browser?.updateActivity(id) { $0.state = .waitingForChoice }
                return
            }
        }
        let stage = RemotePath.join(destination.path, ".termstead-transfer-\(UUID().uuidString.lowercased())")
        let stagedFile = RemotePath.join(stage, name)
        let finalPath = RemotePath.join(destination.path, finalName)
        if target.isLocal, case .upload(let url, _) = operation, kind == .directory,
           let original = LocalFiles.realPath(url.path), stage.hasPrefix(original + "/") {
            throw SFTPError.failed("A folder cannot be copied into itself.")
        }
        let browser = self.browser
        do {
            try await target.makeTransferStage(stage)
            try await withProgress(id, size: kind == .file ? size : nil, target: target, stage: stage, name: name) {
                switch operation {
                case .upload(let url, _): try await client.upload(url, to: stage)
                case .download(let file, _, _):
                    var recursive = file.kind == .directory
                    if file.kind == .symlink { recursive = await client.isDirectory(file.path) }
                    try await client.download(file.path, recursive: recursive, to: URL(fileURLWithPath: stage), as: name)
                }
            }
            try Task.checkCancellation()
            if replacing {
                let current = try await target.list(destination.path).files.first { sameName($0.name, finalName) }
                guard current == existing else {
                    throw SFTPError.failed("The destination changed during the transfer. Retry to choose again.")
                }
            }
            try Task.checkCancellation()
            finishing = id
            let shouldReplace = replacing
            // Once this starts, finish the rename even if the user closes the view.
            try await Task { try await target.finishTransfer(stagedFile, at: finalPath, replacing: shouldReplace) }.value
        } catch {
            await discard(stage, using: target, revision: revision)
            throw error
        }
        await discard(stage, using: target, revision: revision)
        guard revision == sourceRevision else { return }
        finish(id, state: .done, result: target.isLocal ? URL(fileURLWithPath: finalPath) : nil)
        switch operation {
        case .upload: if browser?.path == folder, browser?.isLoading == false { await browser?.load(folder) }
        case .download(_, _, let local): if local?.path == folder, local?.isLoading == false { await local?.load(folder) }
        }
    }

    private func withProgress(_ id: UUID, size: Int64?, target: any FileSource, stage: String, name: String,
                              work: () async throws -> Void) async throws {
        guard let size, size > 0 else { try await work(); return }
        let browser = self.browser
        let monitor = Task {
            var previous = -1
            while !Task.isCancelled {
                let bytes: Int64
                if target.isLocal {
                    let file = RemotePath.join(stage, name)
                    bytes = (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? Int64) ?? 0
                } else {
                    bytes = (try? await target.list(stage).files.first { $0.name == name }?.size) ?? 0
                }
                guard !Task.isCancelled else { break }
                let percent = Int(min(100, 100 * Double(bytes) / Double(size)))
                if percent != previous {
                    previous = percent
                    browser?.updateActivity(id) { $0.state = .running(progress: Double(percent) / 100) }
                }
                try? await Task.sleep(for: target.isLocal ? .milliseconds(250) : .seconds(1))
            }
        }
        defer { monitor.cancel() }
        try await work()
    }

    private func discard(_ stage: String, using target: any FileSource, revision: UUID) async {
        do {
            // Cleanup still runs when the transfer task was cancelled.
            try await Task { try await target.discardTransferStage(stage) }.value
            remoteStages.remove(stage)
        } catch where !target.isLocal && revision == sourceRevision {
            remoteStages.insert(stage)
            if let previous = target as? SFTPClient,
               let current = browser?.transferClient as? SFTPClient, current != previous {
                cleanRemoteStages(using: current)
            }
        } catch {}
    }

    private func cleanRemoteStages(using client: any FileSource) {
        let paths = remoteStages
        let revision = sourceRevision
        remoteStages.removeAll()
        Task { [weak self] in
            for stage in paths {
                guard let self, self.sourceRevision == revision, !self.stopped else { return }
                let parent = RemotePath.parent(of: stage)
                if let listing = try? await client.list(parent), !listing.files.contains(where: { $0.path == stage }) {
                    continue
                }
                await self.discard(stage, using: client, revision: revision)
            }
        }
    }
}
