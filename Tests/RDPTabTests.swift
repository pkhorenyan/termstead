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
        let desktop = try #require(tab.desktop)
        // Before the certificate arrives: connecting is asynchronous.
        desktop.knownHosts = TestLabRDP.knownHosts
        await TestLabRDP.waitUntilShowing(desktop)
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
        await TestLabRDP.waitUntilShowing(desktop)
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

    /// Two desktops as two users stay up together. (As one user, xrdp — and
    /// Windows, by default — hands the session to the second login.)
    @Test func twoUsersAtOnce() async throws {
        var user = "lab"
        func open() -> RDPDesktop {
            let desktop = RDPDesktop()
            var launch = RDPLaunch(session: SessionStore.sample().session("lab-rdp")!, password: "lab")
            launch.user = user
            launch.options.sound = false
            desktop.knownHosts = TestLabRDP.knownHosts
            desktop.availableSize = { (CGSize(width: 800, height: 600), 1) }
            desktop.start(launch) { try await RDPSocket.connect(host: "127.0.0.1", port: 3390) }
            return desktop
        }
        let first = open()
        await TestLabRDP.waitUntilShowing(first)
        user = "lab2"
        let second = open()
        await TestLabRDP.waitUntilShowing(second)
        try await Task.sleep(for: .seconds(3))
        #expect(first.phase == .showing)
        #expect(second.phase == .showing)
        first.stop()
        second.stop()
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

/// An RDP session through a jump host: ssh carries the desktop to a Unix
/// socket in the tab's private folder.
@MainActor
@Suite(.serialized, .enabled(if: TestLabRDP.isUp && TestLab.isUp, "the Docker test lab is not running (TestLab/lab.sh up)"))
final class RDPTunnelTests {
    private let directory: URL
    private let lab = SessionStore.testLab()

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("termstead-rdp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    private func wait(upTo seconds: Double, until done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// The tab as the app opens it, with the test's own known_hosts and no
    /// agent, as `TestLabTests` has it.
    private func open(_ id: String) throws -> Connection {
        let sessions = Dictionary(uniqueKeysWithValues: lab.sessions.map { ($0.id, $0) })
        return try open(try #require(sessions[id]))
    }

    private func open(_ session: Session) throws -> Connection {
        let id = session.id
        let sessions = Dictionary(uniqueKeysWithValues: lab.sessions.map { ($0.id, $0) })
        var plan = try SSHLaunch.plan(forDesktop: session, sessions: sessions)
        plan.config = """
        Host *
          StrictHostKeyChecking accept-new
          UserKnownHostsFile \(directory.appendingPathComponent("known_hosts").path)
          IdentityAgent none

        """ + plan.config
        let tab = Connection(sessionID: id, title: id, address: session.statusAddress,
                             keyDescription: "RDP", kind: .rdp)
        tab.desktop?.availableSize = { (CGSize(width: 800, height: 600), 1) }
        tab.desktop?.knownHosts = TestLabRDP.knownHosts
        var launch = RDPLaunch(session: session, password: "lab")
        launch.options.sound = false
        tab.start(launch, tunnel: plan)
        return tab
    }

    @Test func theDesktopComesThroughTheBastion() async throws {
        let tab = try open("lab-rdp-via-bastion")
        let desktop = try #require(tab.desktop)
        await TestLabRDP.waitUntilShowing(desktop)
        #expect(desktop.phase == .showing)
        #expect(desktop.size == CGSize(width: 800, height: 600))
        #expect(tab.isLoggedIn)
        // The tunnel's ssh is no shell: nothing for the Files tab.
        #expect(tab.plan?.target.host == "127.0.0.1")
        tab.close()
    }

    /// Two hops, the second typed out: ssh reaches `middle` through the
    /// bastion, and the desktop is forwarded from there.
    @Test func theDesktopComesThroughTwoJumpHosts() async throws {
        var session = try #require(lab.sessions.first { $0.id == "lab-rdp-via-bastion" })
        session.id = "lab-rdp-2-jumps"
        session.jumps = [JumpHost(host: "lab-bastion"),
                         JumpHost(host: "middle", user: "lab", port: 22, auth: .key, keyPath: "~/.ssh/termstead-lab")]
        let tab = try open(session)
        let desktop = try #require(tab.desktop)
        await TestLabRDP.waitUntilShowing(desktop, seconds: 45)
        #expect(desktop.phase == .showing)
        #expect(tab.plan?.target.host == "middle")
        tab.close()
    }

    /// The tunnel ending takes the desktop with it, and says so.
    /// The tunnel's ssh reaches the bastion; its load must not pass for the
    /// desktop's in the status bar.
    @Test func aDesktopThroughATunnelShowsNoServerLoad() async throws {
        let tab = try open("lab-rdp-via-bastion")
        let desktop = try #require(tab.desktop)
        await TestLabRDP.waitUntilShowing(desktop)
        try #require(desktop.phase == .showing)
        tab.watchesLoad = true
        try await Task.sleep(for: .seconds(4))
        #expect(tab.serverLoad == nil)
        tab.close()
    }

    @Test func theTunnelEndingEndsTheDesktop() async throws {
        let tab = try open("lab-rdp-via-bastion")
        let desktop = try #require(tab.desktop)
        await TestLabRDP.waitUntilShowing(desktop)
        try #require(desktop.phase == .showing)

        kill(tab.terminalView.process.shellPid, SIGTERM)
        await wait(upTo: 10) { !tab.state.isRunning }
        #expect(!tab.state.isRunning)
        #expect(desktop.phase == .ended(""))
        let screen = String(decoding: tab.terminalView.getTerminal().getBufferAsData(), as: UTF8.self)
        #expect(screen.contains("Press Return to reconnect."))

        tab.restart()
        await TestLabRDP.waitUntilShowing(desktop)
        #expect(desktop.phase == .showing)
        tab.close()
    }

    @Test func aDesktopSessionIsNoJumpHost() throws {
        let sessions = Dictionary(uniqueKeysWithValues: lab.sessions.map { ($0.id, $0) })
        let target = Session(id: "behind", user: "lab", host: "app", port: 22, icon: .server,
                             jumps: [JumpHost(host: "lab-rdp")])
        #expect(throws: SSHLaunchError.notSSH("lab-rdp")) {
            try SSHLaunch.plan(for: target, sessions: sessions.merging([target.id: target]) { a, _ in a })
        }
    }

    /// The forward goes to a socket path, the desktop's host as the last hop
    /// sees it; an IPv6 address in brackets.
    @Test func theForwardIsToASocket() throws {
        #expect(try SSHLaunch.rdpForwardArguments(socket: "/tmp/x/rdp", host: "rdp", port: 3389)
                == ["-L", "/tmp/x/rdp:rdp:3389"])
        #expect(try SSHLaunch.rdpForwardArguments(socket: "/tmp/x/rdp", host: "fe80::1", port: 3389)
                == ["-L", "/tmp/x/rdp:[fe80::1]:3389"])
    }
}
