import Foundation
import Testing
@testable import Termstead

/// SSH and RDP sessions side by side: what is saved, and what an RDP session
/// is kept out of.
@MainActor
struct SessionKindTests {
    private func rdpSession(display: RDPOptions.Display = .fitTab) -> Session {
        var session = Session(id: "win", user: "admin", host: "10.0.0.5", port: 3389,
                              icon: .monitor, auth: .password)
        session.kind = .rdp
        var options = RDPOptions()
        options.domain = "CORP"
        options.display = display
        options.sound = false
        session.rdp = options
        return session
    }

    /// Every file written before there was RDP: no kind, no options.
    @Test func aSessionSavedBeforeRDPReadsAsSSH() throws {
        let json = #"{"id":"web","user":"deploy","host":"10.0.1.4","port":22,"icon":"server","auth":"key","keyPath":"~/.ssh/id_ed25519","jumps":[]}"#
        let session = try JSONDecoder().decode(Session.self, from: Data(json.utf8))
        #expect(session.kind == .ssh)
        #expect(session.rdp == RDPOptions())
    }

    /// An ssh session writes exactly what it wrote before.
    @Test func anSSHSessionWritesNoKind() throws {
        let session = Session(id: "web", user: "deploy", host: "10.0.1.4", port: 22, icon: .server)
        let json = try #require(String(data: JSONEncoder().encode(session), encoding: .utf8))
        #expect(!json.contains("sessionKind"))
        #expect(!json.contains("rdpOptions"))
    }

    @Test func anRDPSessionSurvivesARoundTrip() throws {
        for display in [RDPOptions.Display.fitTab, .fixed(width: 1600, height: 900)] {
            let session = rdpSession(display: display)
            let read = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
            #expect(read == session)
            #expect(read.kind == .rdp)
            #expect(read.rdp.display == display)
            #expect(read.rdp.domain == "CORP")
            #expect(!read.rdp.sound)
        }
    }

    /// Options added in a later version must not make older files unreadable.
    @Test func missingOptionsTakeTheirDefaults() throws {
        let options = try JSONDecoder().decode(RDPOptions.self, from: Data(#"{"domain":"LAB"}"#.utf8))
        #expect(options.domain == "LAB")
        #expect(options.display == .fitTab)
        #expect(options.sharpOnRetina && options.clipboard && options.sound)
    }

    @Test func aDuplicateIsAnRDPSessionToo() throws {
        let store = SessionStore.sample()
        let group = try #require(store.groupOptions().first?.id)
        let name = try #require(store.createSession(rdpSession(), parentID: group))
        let copy = try #require(store.duplicateSession(name))
        #expect(copy.kind == .rdp)
        #expect(copy.rdp == rdpSession().rdp)
    }

    @Test func anRDPSessionCannotBeAJumpHost() {
        let desktop = rdpSession()
        let target = Session(id: "behind", user: "deploy", host: "10.0.0.9", port: 22, icon: .server,
                             jumps: [JumpHost(host: desktop.id)])
        #expect(throws: SSHLaunchError.notSSH(desktop.id)) {
            try SSHLaunch.plan(for: target, sessions: [desktop.id: desktop, target.id: target],
                               keyExists: { _ in true })
        }
    }

    /// No tunnels behind a desktop: no menu item offers to start them.
    @Test func anRDPSessionOffersNoPortForwarding() {
        var session = rdpSession()
        session.forwards = [PortForward(listenPort: 8080, destinationHost: "localhost", destinationPort: 80)]
        #expect(ConnectionStore().forwardingMenuItems(for: session, in: SessionStore.sample()).isEmpty)
    }

    /// Until the RDP engine is in, opening one never runs ssh against the
    /// desktop's port.
    @Test func openingAnRDPSessionStartsNoSSH() throws {
        let store = SessionStore.sample()
        let group = try #require(store.groupOptions().first?.id)
        let name = try #require(store.createSession(rdpSession(), parentID: group))
        let connections = ConnectionStore()
        connections.connect(sessionID: name, in: store)
        let tab = try #require(connections.active)
        #expect(tab.plan == nil)
        #expect(!tab.state.isRunning)
        connections.closeAll()
    }
}
