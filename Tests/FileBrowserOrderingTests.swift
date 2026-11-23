import Foundation
import Testing
@testable import Termstead

/// Requests finish only when the test releases them. This reproduces network
/// reordering without depending on connection speed or a running server.
private actor ControlledFiles: FileSource {
    nonisolated var isLocal: Bool { false }
    typealias Listing = (path: String, files: [RemoteFile])
    private var listings: [String: CheckedContinuation<Listing, any Error>] = [:]
    private var homeRequest: CheckedContinuation<String, any Error>?
    private var waitsForHome = false
    private var saves: [Int: CheckedContinuation<Void, any Error>] = [:]
    private(set) var saveContents: [Data] = []
    private(set) var savedContents: Data?
    private(set) var activeSaves = 0
    private(set) var maximumActiveSaves = 0
    private var interruptedDownloads = 0
    private var downloadDelay: Duration?
    private(set) var stagedDownload: URL?

    func failNextDownload() { interruptedDownloads += 1 }
    func holdNextDownload(for delay: Duration = .seconds(30)) { downloadDelay = delay }

    func holdHome() { waitsForHome = true }
    func hasHomeRequest() -> Bool { homeRequest != nil }
    func home() async throws -> String {
        if !waitsForHome { return "/" }
        return try await withCheckedThrowingContinuation { homeRequest = $0 }
    }
    func finishHome() { homeRequest?.resume(returning: "/"); homeRequest = nil }

    func list(_ path: String) async throws -> Listing {
        try await withCheckedThrowingContinuation { listings[path] = $0 }
    }
    func hasListing(_ path: String) -> Bool { listings[path] != nil }
    func finishListing(_ path: String, error: SFTPError? = nil, files: [RemoteFile] = []) {
        let reply = listings.removeValue(forKey: path)
        if let error { reply?.resume(throwing: error) } else { reply?.resume(returning: (path, files)) }
    }

    func replace(_ remote: String, with local: URL) async throws {
        let data = try Data(contentsOf: local)
        let index = saveContents.count
        saveContents.append(data)
        activeSaves += 1
        maximumActiveSaves = max(maximumActiveSaves, activeSaves)
        defer { activeSaves -= 1 }
        try await withCheckedThrowingContinuation { saves[index] = $0 }
        savedContents = data
    }
    func finishSave(_ index: Int, error: SFTPError? = nil) {
        let reply = saves.removeValue(forKey: index)
        if let error { reply?.resume(throwing: error) } else { reply?.resume() }
    }

    func isDirectory(_ path: String) async -> Bool { false }
    func download(_ remote: String, recursive: Bool, to localDirectory: URL, as name: String) async throws {
        let target = localDirectory.appendingPathComponent(name)
        stagedDownload = target
        if let downloadDelay {
            self.downloadDelay = nil
            try Data("half".utf8).write(to: target)
            try await Task.sleep(for: downloadDelay)
        }
        if interruptedDownloads > 0 {
            interruptedDownloads -= 1
            try Data("half".utf8).write(to: target)
            throw SFTPError.failed("Connection lost")
        }
        try Data("complete".utf8).write(to: target)
    }
    func upload(_ local: URL, to remoteDirectory: String) async throws {}
    func makeDirectory(_ path: String) async throws {}
    func rename(_ path: String, to newPath: String) async throws {}
    func removeFile(_ path: String) async throws {}
    func removeDirectory(_ path: String) async throws {}
    func terminalDirectory() async -> String? { nil }
}

@MainActor
struct FileBrowserOrderingTests {
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()) {
            guard Date() < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func browser() -> (FileBrowser, ControlledFiles) {
        let client = ControlledFiles()
        let browser = FileBrowser(connection: nil)
        browser.clientOverride = client
        return (browser, client)
    }

    @Test func commandAndShiftClicksSelectSeveralFilesForOneCopy() async throws {
        let (browser, client) = browser()
        defer { browser.stop() }
        let names = ["alpha", "bravo", "charlie", "delta"]
        let files = names.map { name in
            RemoteFile(name: name, path: "/folder/\(name)", kind: .file, size: 1,
                       modified: nil, permissions: "-rw-r--r--", owner: "lab", group: "lab")
        }
        let load = Task { await browser.load("/folder") }
        try await wait { await client.hasListing("/folder") }
        await client.finishListing("/folder", files: files)
        await load.value
        browser.select(files[0])
        browser.select(files[2], modifiers: .command)
        #expect(Set(browser.selectedFiles.map(\.name)) == ["alpha", "charlie"])
        #expect(browser.filesForAction(on: files[1]).map(\.name) == ["bravo"])
        #expect(browser.filesForAction(on: files[2]).map(\.name) == ["alpha", "charlie"])
        browser.select(files[3], modifiers: .shift)
        #expect(Set(browser.selectedFiles.map(\.name)) == ["charlie", "delta"])
        browser.select(files[2], modifiers: .command)
        #expect(browser.selectedFiles.map(\.name) == ["delta"])
        browser.clearSelection()
        #expect(browser.selectedFile == nil)
        #expect(browser.selectedFiles.isEmpty)
        browser.select(files[0], modifiers: .shift)
        #expect(browser.selectedFiles.map(\.name) == ["alpha"])
    }

    @Test func localMetadataAloneLooksEmptyButHiddenUserFilesCanBeRevealed() async throws {
        let directory = try localFile().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("config"))
        try Data().write(to: directory.appendingPathComponent(".DS_Store"))
        let browser = FileBrowser(localFiles: LocalFiles())
        await browser.load(directory.path)
        #expect(browser.visibleFiles.isEmpty)
        #expect(!browser.hasHiddenContents)
        try Data().write(to: directory.appendingPathComponent(".env"))
        await browser.load(directory.path)
        #expect(browser.hasHiddenContents)
        browser.showHidden = true
        #expect(browser.visibleFiles.contains { $0.name == ".env" })
    }

    @Test func anOldListingCannotReplaceTheNewDirectory() async throws {
        let (browser, client) = browser()
        defer { browser.stop() }
        let old = Task { await browser.load("/old") }
        try await wait { await client.hasListing("/old") }
        let new = Task { await browser.load("/new") }
        try await wait { await client.hasListing("/new") }
        await client.finishListing("/new")
        await new.value
        #expect(browser.path == "/new" && !browser.isLoading)
        await client.finishListing("/old")
        await old.value
        #expect(browser.path == "/new" && browser.problem == nil)
    }

    @Test func anOldErrorCannotClearTheNewLoadingStateOrBecomeItsProblem() async throws {
        let (browser, client) = browser()
        defer { browser.stop() }
        let old = Task { await browser.load("/old") }
        try await wait { await client.hasListing("/old") }
        let new = Task { await browser.load("/new") }
        try await wait { await client.hasListing("/new") }
        await client.finishListing("/old", error: .failed("old failure"))
        await old.value
        #expect(browser.isLoading && browser.problem == nil)
        await client.finishListing("/new")
        await new.value
        #expect(browser.path == "/new" && !browser.isLoading)
    }

    @Test func aSlowHomeRequestCannotStartAnObsoleteListing() async throws {
        let (browser, client) = browser()
        defer { browser.stop() }
        await client.holdHome()
        let old = Task { await browser.load(nil) }
        try await wait { await client.hasHomeRequest() }
        let new = Task { await browser.load("/new") }
        try await wait { await client.hasListing("/new") }
        await client.finishListing("/new")
        await new.value
        await client.finishHome()
        await old.value
        #expect(browser.path == "/new")
        #expect(await !client.hasListing("/"))
    }

    @Test func aClosedBrowserIgnoresAListingStillInFlight() async throws {
        let (browser, client) = browser()
        let load = Task { await browser.load("/old") }
        try await wait { await client.hasListing("/old") }
        browser.stop()
        await client.finishListing("/old")
        await load.value
        #expect(browser.path == nil && browser.files.isEmpty && !browser.isLoading)
    }

    @Test func aWaitingConnectionCanRetryWithoutCancellingItsOwnRequest() async throws {
        let (browser, client) = browser()
        defer { browser.stop() }
        browser.isShown = true
        let first = Task { await browser.load("/ready") }
        try await wait { await client.hasListing("/ready") }
        await client.finishListing("/ready", error: .notReady)
        await first.value
        try await wait { await client.hasListing("/ready") }
        await client.finishListing("/ready")
        try await wait { browser.path == "/ready" && !browser.isLoading }
        #expect(browser.problem == nil)
    }

    private func localFile() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sb-edit-order-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("config")
        try Data("first".utf8).write(to: file)
        return file
    }

    @Test func interruptedAndCancelledDownloadsNeverPublishPartialFiles() async throws {
        let (browser, client) = browser()
        let folder = try localFile().deletingLastPathComponent()
        defer { browser.stop(); try? FileManager.default.removeItem(at: folder) }
        browser.downloadsDirectory = folder
        let file = RemoteFile(name: "report", path: "/remote/report", kind: .file, size: 8,
                              modified: nil, permissions: "rw-r--r--", owner: "lab", group: "lab")
        await client.failNextDownload()
        browser.download(file)
        try await wait { browser.activities.first?.state == .failed("Connection lost") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["config"])
        let failed = try #require(browser.activities.first)
        browser.transfers.retry([failed.id])
        try await wait { browser.activities.first?.state == .done }
        let result = folder.appendingPathComponent(file.name)
        #expect(try String(contentsOf: result, encoding: .utf8) == "complete")

        let another = RemoteFile(name: "cancelled", path: "/remote/cancelled", kind: .file, size: 8,
                                 modified: nil, permissions: "rw-r--r--", owner: "lab", group: "lab")
        await client.holdNextDownload()
        browser.download(another)
        try await wait { await client.stagedDownload?.lastPathComponent == another.name }
        let pending = try #require(browser.activities.last)
        #expect(pending.state != .done)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(another.name).path))
        browser.transfers.cancel(pending.id)
        try await wait { browser.activities.last?.state == .cancelled }
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == ["config", "report"])
    }

    @Test func savesOfOneFileAreSerializedAndUseImmutableCopies() async throws {
        let (browser, client) = browser()
        let local = try localFile()
        defer { browser.stop(); try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) }
        browser.saveBack("config", local: local, remote: "/config")
        try await wait { await client.saveContents.count == 1 }
        try Data("second".utf8).write(to: local, options: .atomic)
        browser.saveBack("config", local: local, remote: "/config")
        try await Task.sleep(for: .milliseconds(30))
        #expect(await client.saveContents.count == 1)
        await client.finishSave(0)
        try await wait { await client.saveContents.count == 2 }
        #expect(await client.saveContents == [Data("first".utf8), Data("second".utf8)])
        #expect(await client.maximumActiveSaves == 1)
        await client.finishSave(1)
        try await wait { await client.activeSaves == 0 }
        #expect(await client.savedContents == Data("second".utf8))
        try await wait { browser.activities.allSatisfy { $0.state == .done } }
        #expect(try FileManager.default.contentsOfDirectory(atPath: local.deletingLastPathComponent().path) == ["config"])
    }

    @Test func aChangedDestinationNeedsAnotherChoiceEvenWithBatchReplace() async throws {
        let (browser, client) = browser()
        let destination = try localFile()
        defer { browser.stop(); try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        browser.downloadsDirectory = destination.deletingLastPathComponent()
        let file = RemoteFile(name: "config", path: "/remote/config", kind: .file, size: 8,
                              modified: nil, permissions: "rw-r--r--", owner: "lab", group: "lab")
        await client.holdNextDownload(for: .milliseconds(500))
        browser.download(file)
        try await wait { browser.transfers.conflict != nil }
        let firstConflict = try #require(browser.transfers.conflict)
        browser.transfers.resolve(firstConflict.id, with: .replace, forBatch: true)
        try await wait { await client.stagedDownload != nil }
        let external = Data("changed elsewhere".utf8)
        try external.write(to: destination, options: .atomic)
        try await wait { browser.activities.first.map(browser.transfers.canRetry) == true }
        browser.transfers.retry([firstConflict.id])
        try await wait { browser.transfers.conflict != nil }
        #expect(browser.transfers.conflict?.id == firstConflict.id)
        #expect(try Data(contentsOf: destination) == external)
        browser.transfers.resolve(firstConflict.id, with: .skip, forBatch: false)
        try await wait { browser.activities.first?.state == .skipped }
    }

    @Test func changingHostsDropsPendingEditorSaves() async throws {
        let (browser, previous) = browser()
        let replacement = ControlledFiles()
        let local = try localFile()
        defer { browser.stop(); try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) }
        browser.saveBack("config", local: local, remote: "/config")
        try await wait { await previous.saveContents.count == 1 }
        browser.saveBack("config", local: local, remote: "/config")
        browser.sourceChanged()
        browser.clientOverride = replacement
        await previous.finishSave(0)
        try await wait { await previous.activeSaves == 0 }
        browser.saveBack("config", local: local, remote: "/config")
        try await wait { await replacement.saveContents.count == 1 }
        #expect(await previous.saveContents.count == 1)
        await replacement.finishSave(0)
        try await wait { await replacement.activeSaves == 0 }
    }

    @Test func aFailedSaveDoesNotPreventTheNextVersionFromBeingUploaded() async throws {
        let (browser, client) = browser()
        let local = try localFile()
        defer { browser.stop(); try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) }
        browser.saveBack("config", local: local, remote: "/config")
        try await wait { await client.saveContents.count == 1 }
        try Data("second".utf8).write(to: local)
        browser.saveBack("config", local: local, remote: "/config")
        await client.finishSave(0, error: .failed("upload failed"))
        try await wait { await client.saveContents.count == 2 }
        await client.finishSave(1)
        try await wait { await client.activeSaves == 0 }
        #expect(await client.savedContents == Data("second".utf8))
        #expect(browser.activities.contains { $0.state == .failed("upload failed") })
    }

    @Test func closingTheTabCancelsQueuedSaves() async throws {
        let (browser, client) = browser()
        let local = try localFile()
        defer { try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) }
        browser.saveBack("config", local: local, remote: "/config")
        try await wait { await client.saveContents.count == 1 }
        browser.saveBack("config", local: local, remote: "/config")
        browser.stop()
        await client.finishSave(0)
        try await wait { await client.activeSaves == 0 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await client.saveContents.count == 1)
    }
}
