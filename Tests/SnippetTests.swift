import Foundation
import Testing
@testable import Termstead

@MainActor
struct SnippetTests {
    @Test func linesAreTypedWithReturn() {
        #expect(Snippet(name: "a", text: "df -h").keystrokes == "df -h\r")
        #expect(Snippet(name: "a", text: "one\ntwo\n\n").keystrokes == "one\rtwo\r")
        #expect(Snippet(name: "a", text: "one\r\ntwo").keystrokes == "one\rtwo\r")
        // Left on the prompt to finish by hand.
        #expect(Snippet(name: "a", text: "grep -r ", pressReturn: false).keystrokes == "grep -r ")
    }

    @Test func theyAreKeptInTheirFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-snippets-\(UUID().uuidString.prefix(8)).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SnippetStore(url: url)
        #expect(store.snippets.isEmpty)
        store.save(Snippet(name: "one", text: "echo 1"))
        store.save(Snippet(name: "two", text: "echo 2"))
        var edited = store.snippets[0]
        edited.text = "echo one"
        store.save(edited)
        let copy = try #require(store.duplicate(store.snippets[1].id))
        #expect(copy.name == "two copy")
        store.move(copy.id, to: 0)
        #expect(store.snippets.map(\.name) == ["two copy", "one", "two"])
        store.delete(store.snippets[2].id)

        let again = SnippetStore(url: url)
        #expect(again.snippets.map(\.name) == ["two copy", "one"])
        #expect(again.snippets[1].text == "echo one")
    }

    @Test func movingDownLandsBeforeTheTarget() {
        let store = SnippetStore(url: nil, snippets: ["a", "b", "c"].map { Snippet(name: $0, text: $0) })
        store.move(store.snippets[0].id, to: 2)
        #expect(store.snippets.map(\.name) == ["b", "a", "c"])
        store.move(store.snippets[0].id, to: 3)
        #expect(store.snippets.map(\.name) == ["a", "c", "b"])
    }

    /// A test run keeps them in memory, like the tree: the user's file is
    /// never touched.
    @Test func aTestRunNeverWritesTheUsersFile() {
        let storage = SessionStorage.forThisLaunch()
        #expect(!storage.isTheUsersOwn)
        let before = FileManager.default.contents(atPath: SnippetStore.defaultURL.path)
        let store = SnippetStore.forThisLaunch(storage)
        store.save(Snippet(name: "x", text: "x"))
        #expect(FileManager.default.contents(atPath: SnippetStore.defaultURL.path) == before)
    }

    /// Nothing to type into: no tab, a closed one, or a remote desktop.
    @Test func onlyARunningShellTakesOne() {
        let tabs = ConnectionStore()
        defer { tabs.closeAll() }
        #expect(tabs.snippetTarget == nil)
        tabs.openLocalTerminal()
        #expect(tabs.snippetTarget != nil)
    }
}
