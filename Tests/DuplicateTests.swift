import Foundation
import Testing
@testable import Termstead

/// "Duplicate" in a session's context menu.
@MainActor
struct DuplicateTests {
    private func store() -> SessionStore {
        let store = SessionStore.sample()
        var web = store.session("prod-web-02")!
        web.forwards = [PortForward(listenPort: 8080, destinationHost: "localhost", destinationPort: 80)]
        store.applySessionEdits(originalID: web.id, updated: web, parentID: nil)
        return store
    }

    @Test func theCopySitsRightAfterTheOriginalAndIsSelected() throws {
        let store = store()
        let group = try #require(store.currentGroupID(ofSession: "db-primary"))
        let before = try #require(store.position(of: SidebarDragItem(kind: .session, id: "db-primary")))
        let copy = try #require(store.duplicateSession("db-primary"))

        #expect(copy.id == "db-primary copy")
        #expect(store.currentGroupID(ofSession: copy.id) == group)
        let after = try #require(store.position(of: SidebarDragItem(kind: .session, id: copy.id)))
        #expect(after.parent == before.parent)
        #expect(after.index == before.index + 1)
        #expect(store.selection == .session(copy.id, inPinned: false))
        // The original is pinned in the sample; its copy is not.
        #expect(store.isPinned("db-primary"))
        #expect(!store.isPinned(copy.id))
    }

    /// Everything carries over but the ids that name Keychain entries and
    /// tunnels: deleting one session must not take the other's passwords.
    @Test func hopsAndTunnelsGetIDsOfTheirOwn() throws {
        let store = store()
        let original = try #require(store.session("prod-web-02"))
        let copy = try #require(store.duplicateSession("prod-web-02"))

        #expect(copy.host == original.host && copy.user == original.user && copy.port == original.port)
        #expect(copy.icon == original.icon && copy.auth == original.auth && copy.keyPath == original.keyPath)
        #expect(copy.jumps.map(\.host) == original.jumps.map(\.host))
        #expect(copy.jumps.map(\.keyPath) == original.jumps.map(\.keyPath))
        #expect(Set(copy.jumps.map(\.id)).isDisjoint(with: original.jumps.map(\.id)))
        #expect(copy.forwards.map(\.summary) == original.forwards.map(\.summary))
        #expect(Set(copy.forwards.map(\.id)).isDisjoint(with: original.forwards.map(\.id)))
        #expect(store.session(copy.id) == copy)
    }

    @Test func copiesAreNumbered() {
        #expect(SessionStore.copyName(of: "web", taken: ["web"]) == "web copy")
        #expect(SessionStore.copyName(of: "web", taken: ["web", "web copy"]) == "web copy 2")
        #expect(SessionStore.copyName(of: "web", taken: ["web", "web copy", "web copy 2"]) == "web copy 3")

        let store = store()
        store.duplicateSession("nas")
        #expect(store.duplicateSession("nas")?.id == "nas copy 2")
    }

    /// The copy connects as the original does: its password and each hop's
    /// are carried over, paired by position in the chain.
    @Test func savedPasswordsComeAlong() throws {
        let keychain = KeychainStore(service: "com.pavelkhorenyan.termstead.tests.\(UUID().uuidString)")
        let original = Session(id: "a", user: "u", host: "h", port: 22, icon: .server, auth: .password,
                               jumps: [JumpHost(host: "b1", auth: .password), JumpHost(host: "b2")])
        var copy = original
        copy.id = "a copy"
        copy.jumps = original.jumps.map { var hop = $0; hop.id = UUID(); return hop }
        let accounts = [SSHLaunch.sessionPasswordAccount(original.id), SSHLaunch.sessionPasswordAccount(copy.id)]
            + (original.jumps + copy.jumps).map { SSHLaunch.hopPasswordAccount($0.id) }
        defer { accounts.forEach(keychain.delete) }

        keychain.set("session-secret", for: SSHLaunch.sessionPasswordAccount(original.id))
        keychain.set("hop-secret", for: SSHLaunch.hopPasswordAccount(original.jumps[0].id))
        keychain.copySecrets(of: original, to: copy)

        #expect(keychain.secret(for: SSHLaunch.sessionPasswordAccount(copy.id)) == "session-secret")
        #expect(keychain.secret(for: SSHLaunch.hopPasswordAccount(copy.jumps[0].id)) == "hop-secret")
        #expect(!keychain.contains(SSHLaunch.hopPasswordAccount(copy.jumps[1].id)))
        // The original keeps its own.
        #expect(keychain.secret(for: SSHLaunch.hopPasswordAccount(original.jumps[0].id)) == "hop-secret")
    }

    /// The mark beside a forwarding session's name reads its tunnels' states.
    @Test func theTunnelMarkSummarisesTheStates() {
        let tabs = ConnectionStore()
        #expect(tabs.forwardingSummary(of: "web") == nil)
        let forwards = (0..<3).map { _ in PortForward(listenPort: 1, destinationPort: 1) }
        let session = Session(id: "web", user: "u", host: "h", port: 22, icon: .server)
        var plan = SSHLaunchPlan(hops: [], target: SSHEndpoint(alias: "h", host: "h", auth: .automatic), config: "")
        plan.forwards = forwards.map { SSHLaunchPlan.Forward(forward: $0, arguments: []) }
        tabs.tunnelLaunches["web"] = TunnelLaunch(session: session, plan: plan, keychain: .shared)
        tabs.forwardStates["web"] = [forwards[0].id: .running, forwards[1].id: .stopped, forwards[2].id: .running]
        #expect(tabs.forwardingSummary(of: "web") == ForwardingSummary(running: 2, total: 3, failed: false))
        tabs.forwardStates["web"]?[forwards[1].id] = .failed("Port 1 is already in use on this Mac.")
        #expect(tabs.forwardingSummary(of: "web")?.failed == true)
        #expect(tabs.forwardingSummary(of: "web")?.description == "Port forwarding: 2 of 3 tunnels running, one failed")
    }
}
