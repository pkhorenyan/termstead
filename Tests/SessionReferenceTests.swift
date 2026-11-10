import Foundation
import Testing
@testable import Termstead

@MainActor
struct SessionReferenceTests {
    private func store() -> SessionStore {
        let gateway = Session(id: "gateway", user: "jump", host: "192.0.2.10", port: 2222,
                              icon: .server, auth: .key, keyPath: "~/.ssh/gateway")
        let target = Session(id: "target", user: "user", host: "192.0.2.20", port: 22,
                             icon: .server, jumps: [JumpHost(host: "gateway")])
        return SessionStore(tree: [SessionGroup(id: "g", name: "g", colorID: nil,
                                                children: [.session(gateway.id), .session(target.id)])],
                            sessions: [gateway.id: gateway, target.id: target], selectedID: nil, pinnedIDs: [])
    }

    @Test func renamingABastionKeepsItsEndpointAndIdentity() throws {
        let store = store()
        let id = try #require(store.sessions["gateway"]?.persistentID)
        let before = try SSHLaunch.plan(for: #require(store.session("target")), sessions: store.sessions)
        #expect(store.renameSession("gateway", to: "new gateway"))
        let target = try #require(store.session("target"))
        #expect(target.jumps[0].host == "new gateway")
        #expect(target.jumps[0].sessionIdentity == id)
        let after = try SSHLaunch.plan(for: target, sessions: store.sessions)
        #expect(after.hops[0].host == before.hops[0].host)
        #expect(after.hops[0].user == "jump")
        #expect(after.hops[0].port == 2222)
        #expect(after.hops[0].auth == .key("~/.ssh/gateway"))
        #expect(after.hops[0].passwordAccount == SSHLaunch.sessionPasswordAccount("new gateway"))
    }

    @Test func savingAFormWithAFreshSessionValuePreservesItsIdentity() throws {
        let store = store()
        let id = try #require(store.session("gateway")?.persistentID)
        let edited = Session(id: "renamed", user: "changed", host: "192.0.2.11", port: 2200, icon: .server)
        store.applySessionEdits(originalID: "gateway", updated: edited, parentID: nil)
        #expect(store.session("renamed")?.persistentID == id)
        let plan = try SSHLaunch.plan(for: #require(store.session("target")), sessions: store.sessions)
        #expect(plan.hops[0].host == "192.0.2.11")
        #expect(plan.hops[0].user == "changed")
        #expect(plan.hops[0].port == 2200)
    }

    @Test func staleLabelsStillResolveByIdentityAndExplicitOverridesSurvive() throws {
        let store = store()
        var target = try #require(store.session("target"))
        target.jumps[0].user = "override"
        target.jumps[0].port = 2022
        target.jumps[0].auth = .password
        let account = SSHLaunch.hopPasswordAccount(target.jumps[0].id)
        #expect(store.renameSession("gateway", to: "renamed"))
        let plan = try SSHLaunch.plan(for: target, sessions: store.sessions)
        #expect(plan.hops[0].host == "192.0.2.10")
        #expect(plan.hops[0].user == "override")
        #expect(plan.hops[0].port == 2022)
        #expect(plan.hops[0].auth == .password)
        #expect(plan.hops[0].passwordAccount == account)
    }

    @Test func reusingANameDoesNotRedirectAnExistingReference() throws {
        let store = store()
        #expect(store.renameSession("gateway", to: "renamed"))
        _ = store.createSession(Session(id: "gateway", user: "other", host: "203.0.113.99", port: 22,
                                        icon: .server), parentID: "g")
        let plan = try SSHLaunch.plan(for: #require(store.session("target")), sessions: store.sessions)
        #expect(plan.hops[0].host == "192.0.2.10")
        store.delete([SidebarDragItem(kind: .session, id: "renamed")])
        #expect(throws: SSHLaunchError.missingSavedSession("renamed")) {
            try SSHLaunch.plan(for: #require(store.session("target")), sessions: store.sessions)
        }
    }

    @Test func typingAnotherHostReplacesTheReference() throws {
        let store = store()
        var target = try #require(store.session("target"))
        target.jumps[0].host = "operator@203.0.113.30:2200"
        #expect(target.jumps[0].sessionIdentity == nil)
        let plan = try SSHLaunch.plan(for: target, sessions: store.sessions)
        #expect(plan.hops[0].host == "203.0.113.30")
        #expect(plan.hops[0].user == "operator")
        #expect(plan.hops[0].port == 2200)
    }

    @Test func aDuplicateHasItsOwnIdentityAndKeepsItsJumpReferences() throws {
        let store = store()
        let original = try #require(store.session("target"))
        let copy = try #require(store.duplicateSession("target"))
        #expect(copy.persistentID != original.persistentID)
        #expect(copy.jumps[0].sessionIdentity == original.jumps[0].sessionIdentity)
        #expect(store.session(copy.id) == copy)
    }

    @Test func insertingACopyCannotTakeTheOriginalIdentity() throws {
        let store = store()
        var copy = try #require(store.session("gateway"))
        let original = copy.persistentID
        copy.id = "a copy sorted before gateway"
        _ = store.createSession(copy, parentID: "g")
        #expect(store.session("gateway")?.persistentID == original)
        #expect(store.session(copy.id)?.persistentID != original)
        let plan = try SSHLaunch.plan(for: #require(store.session("target")), sessions: store.sessions)
        #expect(plan.hops[0].host == "192.0.2.10")
    }

    @Test func identitiesSurviveSavingAndReferencesAlsoWorkForDesktopTunnels() throws {
        let original = store()
        let data = try JSONEncoder().encode(original.snapshot)
        let restored = SessionStore(snapshot: try JSONDecoder().decode(SessionSnapshot.self, from: data))
        #expect(restored.snapshot == original.snapshot)
        #expect(restored.renameSession("gateway", to: "renamed"))
        var desktop = try #require(restored.session("target"))
        desktop.kind = .rdp
        let plan = try SSHLaunch.plan(tunnelFor: desktop, sessions: restored.sessions)
        #expect(plan.target.host == "192.0.2.10")
        #expect(plan.target.port == 2222)
    }

    @Test func anOldFileIsMigratedAndBackedUpBeforeReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sb-migrate-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sessions.json")
        var legacy = store().snapshot
        legacy.version = 1
        for index in legacy.sessions.indices {
            legacy.sessions[index].persistentID = nil
            for hop in legacy.sessions[index].jumps.indices { legacy.sessions[index].jumps[hop].sessionIdentity = nil }
        }
        let original = try JSONEncoder().encode(legacy)
        try original.write(to: url)
        let migrated = SessionStore(snapshot: legacy)
        #expect(migrated.session("target")?.jumps[0].sessionIdentity == migrated.session("gateway")?.persistentID)
        try SessionPersistence.save(migrated.snapshot, to: url)
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("sessions.json.before-v2-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: #require(backups.first)) == original)
        guard case .loaded(let saved) = SessionPersistence.load(from: url) else {
            Issue.record("The migrated file did not load"); return
        }
        #expect(saved == migrated.snapshot)
        try SessionPersistence.save(migrated.snapshot, to: url)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
    }

    @Test func tunnelRestartPlansFollowMovedKeychainAccounts() throws {
        let sessions = store()
        let target = try #require(sessions.session("target"))
        let plan = try SSHLaunch.plan(for: target, sessions: sessions.sessions)
        let tabs = ConnectionStore()
        tabs.tunnelLaunches[target.id] = TunnelLaunch(session: target, plan: plan, keychain: .shared)
        tabs.renameSession(from: "gateway", to: "renamed")
        #expect(tabs.tunnelLaunches[target.id]?.plan.hops[0].passwordAccount
                == SSHLaunch.sessionPasswordAccount("renamed"))
        #expect(tabs.tunnelLaunches[target.id]?.plan.target.passwordAccount == plan.target.passwordAccount)
    }
}
