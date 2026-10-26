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
