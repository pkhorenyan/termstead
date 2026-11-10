import Foundation
import Testing
@testable import Termstead

@MainActor
struct PersistenceRecoveryTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sb-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func corruptSnippetsArePreservedBeforeAnotherSnippetIsSaved() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("snippets.json")
        let original = Data("{ damaged snippets".utf8)
        try original.write(to: url)
        let store = SnippetStore(url: url)
        #expect(store.loadProblem != nil)
        #expect(store.snippets.isEmpty)
        let recovery = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("snippets.json.corrupt-") }
        #expect(recovery.count == 1)
        let backup = try #require(recovery.first)
        #expect(try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int == 0o600)
        store.save(Snippet(name: "new", text: "pwd"))
        #expect(try Data(contentsOf: backup) == original)
        #expect(SnippetStore(url: url).snippets.map(\.name) == ["new"])
        #expect(!store.hasUnsavedChanges && store.saveProblem == nil)
    }

    @Test func aFailedRecoveryCopyBlocksReplacementUntilRetryCanPreserveIt() throws {
        let root = try directory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let url = root.appendingPathComponent("snippets.json")
        let original = Data("{ still recoverable".utf8)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        let store = SnippetStore(url: url)
        #expect(store.loadProblem != nil)
        store.save(Snippet(name: "new", text: "pwd"))
        #expect(store.saveProblem != nil && store.hasUnsavedChanges)
        #expect(try Data(contentsOf: url) == original)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        store.retrySave()
        #expect(store.saveProblem == nil && !store.hasUnsavedChanges)
        #expect(SnippetStore(url: url).snippets.map(\.name) == ["new"])
        let copies = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("snippets.json.recovery-") }
        #expect(copies.count == 1)
        #expect(try Data(contentsOf: #require(copies.first)) == original)
    }

    @Test func anUnreadableSnippetPathIsNotReplacedByAnEmptyList() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("snippets.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let important = url.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: important)
        let store = SnippetStore(url: url)
        #expect(store.loadProblem != nil)
        store.save(Snippet(name: "new", text: "pwd"))
        #expect(store.saveProblem != nil)
        #expect(try String(contentsOf: important, encoding: .utf8) == "keep")
    }

    @Test func sessionSaveErrorsAreVisibleAndRetryKeepsTheLatestSnapshot() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("blocked")
        let url = blocked.appendingPathComponent("sessions.json")
        let defaults = UserDefaults(suiteName: "sb-storage-\(UUID())")!
        defaults.set(url.path, forKey: "sb-store")
        let storage = SessionStorage.forThisLaunch(defaults: defaults, environment: [:])
        try Data("occupied".utf8).write(to: blocked)
        let store = SessionStore.sample()
        storage.save(store.snapshot)
        #expect(storage.saveProblem != nil && storage.hasUnsavedChanges)
        _ = store.renameSession("nas", to: "latest")
        storage.save(store.snapshot)
        try FileManager.default.removeItem(at: blocked)
        storage.retrySave()
        #expect(storage.saveProblem == nil && !storage.hasUnsavedChanges)
        guard case .loaded(let saved) = SessionPersistence.load(from: url) else {
            Issue.record("Retry did not save sessions"); return
        }
        #expect(saved == store.snapshot)
    }

    @Test func snippetSaveErrorsCanBeRetriedWithoutLosingInMemoryEdits() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("blocked")
        let store = SnippetStore(url: blocked.appendingPathComponent("snippets.json"))
        #expect(store.loadProblem == nil, "A missing file is normal on first launch")
        try Data("occupied".utf8).write(to: blocked)
        store.save(Snippet(name: "one", text: "pwd"))
        store.save(Snippet(name: "two", text: "ls"))
        #expect(store.saveProblem != nil && store.hasUnsavedChanges)
        #expect(store.snippets.map(\.name) == ["one", "two"])
        try FileManager.default.removeItem(at: blocked)
        store.retrySave()
        #expect(store.saveProblem == nil && !store.hasUnsavedChanges)
        #expect(SnippetStore(url: blocked.appendingPathComponent("snippets.json")).snippets == store.snippets)
    }
}
