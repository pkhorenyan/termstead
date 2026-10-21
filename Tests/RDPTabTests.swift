import Foundation
import Testing
@testable import Termstead

/// An RDP session opened as a tab, against the lab's xrdp.
@MainActor
@Suite(.serialized, .enabled(if: TestLabRDP.isUp, "the lab's RDP server is not running (TestLab/lab.sh up)"))
struct RDPTabTests {
    private func wait(upTo seconds: Double, until done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func open(in connections: ConnectionStore) async throws -> Connection {
        connections.connect(sessionID: "lab-rdp", in: SessionStore.sample())
        let tab = try #require(connections.active)
        await wait(upTo: 20) { tab.desktop?.phase == .showing }
        return tab
    }

    @Test func theTabShowsTheDesktop() async throws {
        let connections = ConnectionStore()
        let tab = try await open(in: connections)
        let desktop = try #require(tab.desktop)
        #expect(tab.kind == .rdp)
        #expect(desktop.phase == .showing)
        #expect(tab.state.isRunning)
        #expect(connections.isLive("lab-rdp"))
        #expect((desktop.size?.width ?? 0) > 0)
        connections.closeAll()
    }

    /// The engine's process going away ends the desktop, says so in the tab,
    /// and Return brings it back, as with an ssh tab.
    @Test func anEngineCrashEndsTheDesktopAndReturnReconnects() async throws {
        let connections = ConnectionStore()
        let tab = try await open(in: connections)
        let desktop = try #require(tab.desktop)
        try #require(desktop.phase == .showing)

        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        // A crash, not a request to quit: libxpc holds SIGTERM back while
        // the service has work in hand. Only this build's engine: a copy of
        // Termstead in use keeps its desktops.
        let engine = Bundle.main.bundleURL
            .appendingPathComponent("Contents/XPCServices/TermsteadRDP.xpc/Contents/MacOS/TermsteadRDP").path
        kill.arguments = ["-9", "-f", engine]
        try kill.run()
        kill.waitUntilExit()
        await wait(upTo: 10) { !tab.state.isRunning }

        #expect(!tab.state.isRunning)
        #expect(desktop.phase == .ended("The RDP engine stopped."))
        let screen = String(decoding: tab.terminalView.getTerminal().getBufferAsData(), as: UTF8.self)
        #expect(screen.contains("The RDP engine stopped."))

        // Noticed within a few tens of milliseconds; the restart takes about
        // ten seconds, launchd's pause before it starts a crashed service again.
        tab.restart()
        await wait(upTo: 20) { desktop.phase == .showing }
        #expect(desktop.phase == .showing)
        #expect(tab.state.isRunning)
        connections.closeAll()
    }

    /// Closing the tab ends the session; nothing reports it as a failure.
    @Test func closingTheTabEndsTheSession() async throws {
        let connections = ConnectionStore()
        let tab = try await open(in: connections)
        let desktop = try #require(tab.desktop)
        connections.close(tab.id)
        #expect(desktop.phase == .ended(""))
        #expect(connections.connections.isEmpty)
    }

    /// Broadcast input is text for terminals; a remote desktop is left out
    /// as a source and as a target.
    @Test func aDesktopTakesNoBroadcastInput() async throws {
        let connections = ConnectionStore()
        connections.setLayout(.sideBySide)
        connections.focus(pane: 0)
        let desktop = try await open(in: connections)
        connections.focus(pane: 1)
        let shell = Connection(sessionID: nil, title: "shell", address: "shell", keyDescription: "")
        connections.add(shell)
        connections.toggleBroadcast()

        #expect(!connections.receivesBroadcast(pane: desktop.pane))
        #expect(connections.broadcastTargets(from: shell).isEmpty)
        #expect(connections.broadcastTargets(from: desktop).isEmpty)
        connections.closeAll()
    }
}
