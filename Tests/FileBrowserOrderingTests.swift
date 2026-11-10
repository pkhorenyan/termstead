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
    func finishListing(_ path: String, error: SFTPError? = nil) {
        let reply = listings.removeValue(forKey: path)
        if let error { reply?.resume(throwing: error) } else { reply?.resume(returning: (path, [])) }
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
    func download(_ remote: String, recursive: Bool, to localDirectory: URL, as name: String) async throws {}
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
