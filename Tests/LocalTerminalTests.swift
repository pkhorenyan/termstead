import Foundation
import Testing
@testable import Termstead

/// A tab with the Mac's own shell instead of ssh.
@MainActor
@Suite(.serialized)
struct LocalTerminalTests {
    private func screen(_ connection: Connection) -> String {
        String(decoding: connection.terminalView.getTerminal().getBufferAsData(), as: UTF8.self)
    }

    /// Suspends while it waits, so the terminal's output can arrive.
    private func wait(upTo seconds: Double, until done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// The marker is computed by the shell, so the echo of what was typed
    /// cannot pass for it. Typing is repeated: a login shell may still be
    /// reading its profile when the first line arrives.
    private func run(_ command: String, in tab: Connection, until marker: String) async -> Bool {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            tab.terminalView.send(txt: command + "\r")
            await wait(upTo: 2) { screen(tab).contains(marker) }
            if screen(tab).contains(marker) { return true }
        }
        return false
    }

    @Test func aLocalTabRunsTheUsersShellAtHome() async throws {
        let tabs = ConnectionStore()
        defer { tabs.closeAll() }
        tabs.openLocalTerminal()
        let tab = try #require(tabs.active)
        #expect(tab.isLocalShell)
        #expect(tab.sessionID == nil)
        #expect(tab.title == "Local")
        #expect(tab.state.isRunning)

        #expect(await run("echo TERMSTEAD_$((6*7))_$PWD", in: tab, until: "TERMSTEAD_42_\(NSHomeDirectory())"))
    }

    /// `exit` ends it like a closed connection, and Return starts it again.
    @Test func returnStartsTheShellAgain() async throws {
        let tabs = ConnectionStore()
        defer { tabs.closeAll() }
        tabs.openLocalTerminal()
        let tab = try #require(tabs.active)
        #expect(await run("echo TERMSTEAD_$((2*3))_READY", in: tab, until: "TERMSTEAD_6_READY"))

        tab.terminalView.send(txt: "exit\r")
        await wait(upTo: 10) { !tab.state.isRunning }
        #expect(!tab.state.isRunning)
        #expect(screen(tab).contains("The shell exited"))
        #expect(screen(tab).contains("Press Return to start it again"))

        tab.terminalView.send(txt: "\r")
        #expect(tab.state.isRunning)
        #expect(await run("echo TERMSTEAD_$((7*8))_AGAIN", in: tab, until: "TERMSTEAD_56_AGAIN"))
    }

    /// The Files panel browses this Mac for a local tab, and follows its `cd`.
    @Test func theFilesPanelFollowsALocalShell() async throws {
        let made = FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-local-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: made.appendingPathComponent("inner"), withIntermediateDirectories: true)
        // As the kernel names it: /private/var, not /var.
        let folder = URL(fileURLWithPath: try #require(LocalFiles.realPath(made.path)))
        try Data("hello".utf8).write(to: folder.appendingPathComponent("note.txt"))
        defer { try? FileManager.default.removeItem(at: folder) }

        let tabs = ConnectionStore()
        defer { tabs.closeAll() }
        tabs.openLocalTerminal()
        let tab = try #require(tabs.active)
        let source = try #require(tab.files)
        #expect(source.isLocal)
        #expect(try await source.home() == NSHomeDirectory())

        #expect(await run("cd '\(folder.path)' && echo TERMSTEAD_$((3*5))_IN", in: tab, until: "TERMSTEAD_15_IN"))
        #expect(await source.terminalDirectory() == folder.path)

        let browser = tab.fileBrowser
        browser.isShown = true
        browser.start()
        await wait(upTo: 5) { browser.path == folder.path }
        #expect(browser.problem == nil)
        #expect(browser.visibleFiles.map(\.name) == ["inner", "note.txt"])
        #expect(browser.visibleFiles.last?.size == 5)
        #expect(browser.visibleFiles.last?.permissions.count == 9)

        browser.makeDirectory(named: "made")
        await wait(upTo: 5) { browser.files.contains { $0.name == "made" } }
        let newFolder = try #require(browser.files.first { $0.name == "made" })
        browser.rename(newFolder, to: "renamed")
        await wait(upTo: 5) { browser.files.contains { $0.name == "renamed" } }
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("renamed").path))

        browser.upload([folder.appendingPathComponent("note.txt")], into: folder.appendingPathComponent("inner").path)
        await wait(upTo: 5) { FileManager.default.fileExists(atPath: folder.appendingPathComponent("inner/note.txt").path) }
        #expect(FileManager.default.contents(atPath: folder.appendingPathComponent("inner/note.txt").path) == Data("hello".utf8))
    }

    /// Opening one turns the sidebar to its files, as a server's login does.
    @Test func openingALocalTabShowsItsFiles() async throws {
        let tabs = ConnectionStore()
        defer { tabs.closeAll() }
        let app = AppState(defaults: UserDefaults(suiteName: "local-files-\(UUID())")!)
        tabs.onLogin = { connection in Task { await app.showFiles(afterLoginOf: connection, in: tabs) } }
        #expect(app.sidebarTab == .sessions)
        tabs.openLocalTerminal()
        await wait(upTo: 5) { app.sidebarTab == .files }
        #expect(app.sidebarTab == .files)
        #expect(tabs.active?.fileBrowser.path == NSHomeDirectory())
    }

    @Test func aLocalTabIsRememberedAndReopened() {
        let tabs = ConnectionStore()
        defer { tabs.closeAll() }
        tabs.openLocalTerminal()
        let memory = TabMemory(tabs)
        #expect(memory.tabs == [TabMemory.Tab(local: true)])

        let again = ConnectionStore()
        defer { again.closeAll() }
        memory.reopen(in: again, sessions: SessionStore.sample())
        #expect(again.connections.count == 1)
        #expect(again.connections.first?.isLocalShell == true)
    }
}
