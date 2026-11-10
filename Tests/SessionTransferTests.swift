import Foundation
import Security
import Testing
@testable import Termstead

@MainActor
struct SessionTransferTests {
    private func chain() -> SessionSnapshot {
        let store = SessionStore(tree: [], sessions: [:], selectedID: nil, pinnedIDs: [])
        let bastions = store.createGroup(name: "Bastions", parentID: nil, colorID: nil)
        let servers = store.createGroup(name: "Servers", parentID: nil, colorID: nil)
        let bastion = Session(id: "bastion", user: "jump", host: "jump.example", port: 2222,
                              icon: .server, auth: .password)
        store.createSession(bastion, parentID: bastions)
        var app = Session(id: "app", user: "ops", host: "app.internal", port: 22, icon: .server, auth: .password)
        app.jumps = [JumpHost(host: "bastion"), JumpHost(host: "literal.example", auth: .password)]
        store.createSession(app, parentID: servers)
        store.pinnedIDs = ["app"]
        return store.snapshot
    }
    private func contents(_ snapshot: SessionSnapshot) throws -> SessionArchive.Contents {
        try SessionArchive.contents(SessionArchive.document(snapshot))
    }

    private func addServer(to source: SessionStore) -> Session {
        var session = Session(id: "app-2", user: "ops", host: "app2.internal", port: 22, icon: .server, auth: .password)
        session.jumps = [JumpHost(host: "bastion")]
        source.createSession(session, parentID: nil)
        return source.session(session.id)!
    }

    @Test(arguments: SessionTransfer.Conflict.allCases)
    func firstImportPreservesSessionIdentities(_ conflict: SessionTransfer.Conflict) throws {
        let original = chain()
        let imported = try SessionTransfer.plan(contents(original), into: .empty, conflict: conflict)
        #expect(imported.added.map(\.persistentID) == original.sessions.map(\.persistentID))
    }

    @Test func repeatedImportAddsNewServersThroughThePreviouslyImportedBastion() throws {
        let source = SessionStore(snapshot: chain())
        let first = try SessionTransfer.plan(contents(source.snapshot), into: .empty, conflict: .keepBoth)
        let second = addServer(to: source)
        var archive = try contents(source.snapshot)
        let bastion = try #require(source.session("bastion"))
        archive.credentials = [
            .init(sessionID: bastion.persistentID!, role: "password", value: "must-not-replace-local"),
            .init(sessionID: second.persistentID!, role: "password", value: "new-password")]
        let update = try SessionTransfer.plan(archive, into: first.snapshot, conflict: .skip)
        #expect(update.added.map(\.id) == ["app-2"])
        #expect(update.skipped == 2)
        #expect(update.added.first?.jumps[0].sessionIdentity == bastion.persistentID)
        #expect(update.snapshot.sessions.first { $0.id == "bastion" } == bastion)
        #expect(update.secrets.map(\.account) == [SSHLaunch.sessionPasswordAccount(second.id)])
        let imported = SessionStore(snapshot: update.snapshot)
        let launch = try SSHLaunch.plan(for: #require(imported.session(second.id)), sessions: imported.sessions)
        #expect(launch.hops.first?.host == "jump.example")
        #expect(launch.hops.first?.passwordAccount == SSHLaunch.sessionPasswordAccount("bastion"))
        let again = try SessionTransfer.plan(archive, into: update.snapshot, conflict: .skip)
        #expect(again.added.isEmpty)
        #expect(again.snapshot == update.snapshot)
        #expect(again.secrets.isEmpty)
    }

    @Test func repeatedImportRecognizesOlderImportsWithRegeneratedIdentities() throws {
        let source = SessionStore(snapshot: chain())
        var legacy = source.snapshot
        let identities = Dictionary(uniqueKeysWithValues: legacy.sessions.map { ($0.persistentID!, UUID()) })
        legacy.sessions = legacy.sessions.map { session in
            var copy = session
            copy.persistentID = identities[session.persistentID!]
            copy.jumps = session.jumps.map { hop in
                var copy = hop
                copy.id = UUID()
                copy.sessionIdentity = hop.sessionIdentity.flatMap { identities[$0] }
                return copy
            }
            return copy
        }
        let second = addServer(to: source)
        let update = try SessionTransfer.plan(contents(source.snapshot), into: legacy, conflict: .skip)
        let bastion = try #require(legacy.sessions.first { $0.id == "bastion" })
        #expect(update.added.map(\.id) == [second.id])
        #expect(update.added.first?.jumps[0].sessionIdentity == bastion.persistentID)
        #expect(update.snapshot.sessions.first { $0.id == "bastion" } == bastion)
        let imported = SessionStore(snapshot: update.snapshot)
        let launch = try SSHLaunch.plan(for: #require(imported.session(second.id)), sessions: imported.sessions)
        #expect(launch.hops.first?.host == bastion.host)
        #expect(launch.hops.first?.port == bastion.port)
    }

    @Test(arguments: ["host", "user", "port", "auth", "key"])
    func olderImportsMustMatchEverySSHJumpEndpointSetting(_ difference: String) throws {
        let original = chain()
        var bastion = try #require(original.sessions.first { $0.id == "bastion" })
        bastion.persistentID = UUID()
        var archive = try contents(original)
        switch difference {
        case "host": bastion.host = "unrelated.example"
        case "user": bastion.user = "another-user"
        case "port": bastion.port += 1
        case "auth": bastion.auth = .key
        default:
            let index = try #require(archive.snapshot.sessions.firstIndex { $0.id == bastion.id })
            archive.snapshot.sessions[index].auth = .key
            archive.snapshot.sessions[index].keyPath = "~/.ssh/source-key"
            bastion.auth = .key
            bastion.keyPath = "~/.ssh/different-key"
        }
        let local = SessionStore(tree: [], sessions: [:], selectedID: nil, pinnedIDs: [])
        local.createSession(bastion, parentID: nil)
        let update = try SessionTransfer.plan(archive, into: local.snapshot, conflict: .skip)
        #expect(update.added.isEmpty)
        #expect(update.skipped == 2)
        #expect(update.snapshot == local.snapshot)
    }

    @Test func exportingAFolderIncludesExternalJumpDependencies() throws {
        let original = chain()
        let folder = try #require(original.tree.first { $0.name == "Servers" })
        let exported = SessionTransfer.exportSnapshot(original, groupID: folder.id)
        #expect(Set(exported.sessions.map(\.id)) == ["app", "bastion"])
        #expect(exported.pinnedIDs == ["app"])
        let imported = try SessionTransfer.plan(contents(exported), into: .empty, conflict: .keepBoth)
        let app = try #require(imported.added.first { $0.id == "app" })
        let launch = try SSHLaunch.plan(for: app, sessions: Dictionary(uniqueKeysWithValues: imported.added.map { ($0.id, $0) }))
        #expect(launch.hops.first?.host == "jump.example")
        #expect(launch.hops.first?.user == "jump")
        #expect(launch.hops.first?.port == 2222)
    }

    @Test func keepingBothRenamesTheWholeImportedChainAndRemapsSecrets() throws {
        let original = chain()
        let source = try #require(original.sessions.first { $0.id == "app" })
        var archive = try contents(original)
        archive.credentials = [
            .init(sessionID: source.persistentID!, role: "password", value: "app-secret"),
            .init(sessionID: source.persistentID!, hopID: source.jumps[1].id, role: "hopPassword", value: "hop-secret")]
        let plan = try SessionTransfer.plan(archive, into: original, conflict: .keepBoth)
        #expect(plan.added.count == 2)
        #expect(plan.renamed.count == 2)
        let app = try #require(plan.added.first { $0.id == "app (2)" })
        let bastion = try #require(plan.added.first { $0.id == "bastion (2)" })
        #expect(app.persistentID != source.persistentID)
        #expect(app.jumps[0].host == bastion.id)
        #expect(app.jumps[0].sessionIdentity == bastion.persistentID)
        #expect(app.jumps[1].id != source.jumps[1].id)
        #expect(plan.secrets.contains { $0.account == SSHLaunch.sessionPasswordAccount(app.id) && $0.value == "app-secret" })
        #expect(plan.secrets.contains { $0.account == SSHLaunch.hopPasswordAccount(app.jumps[1].id) && $0.value == "hop-secret" })
        #expect(plan.snapshot.pinnedIDs == ["app", "app (2)"])
        let restored = SessionStore(snapshot: plan.snapshot)
        restored.sessions[bastion.id]?.host = "new.example"
        let launch = try SSHLaunch.plan(for: app, sessions: restored.sessions)
        #expect(launch.hops.first?.host == "new.example")
        #expect(plan.snapshot.tree.prefix(original.tree.count).elementsEqual(original.tree))
        #expect(Set(plan.snapshot.tree.map(\.id)).count == plan.snapshot.tree.count)
    }

    @Test func skipDoesNotRedirectDependenciesToUnrelatedSameNameHost() throws {
        let original = chain()
        let store = SessionStore(tree: [], sessions: [:], selectedID: nil, pinnedIDs: [])
        store.createSession(Session(id: "bastion", user: "other", host: "wrong.example", port: 22, icon: .server), parentID: nil)
        let before = store.snapshot
        let plan = try SessionTransfer.plan(contents(original), into: before, conflict: .skip)
        #expect(plan.added.isEmpty)
        #expect(plan.skipped == 2)
        #expect(plan.snapshot == before)
        #expect(plan.secrets.isEmpty)
    }

    @Test func skipCanReuseTheSamePermanentIdentityAfterLocalRename() throws {
        let original = chain()
        let imported = try SessionTransfer.plan(contents(original), into: .empty, conflict: .keepBoth)
        let store = SessionStore(snapshot: imported.snapshot)
        _ = store.delete([SidebarDragItem(kind: .session, id: "app")])
        var bastion = try #require(store.session("bastion"))
        bastion.id = "renamed-bastion"
        store.applySessionEdits(originalID: "bastion", updated: bastion, parentID: store.currentGroupID(ofSession: "bastion"))
        let plan = try SessionTransfer.plan(contents(original), into: store.snapshot, conflict: .skip)
        let app = try #require(plan.added.first)
        #expect(app.jumps[0].host == "renamed-bastion")
        #expect(app.jumps[0].sessionIdentity == bastion.persistentID)
        #expect(plan.skipped == 1)
    }

    @Test func missingReferencesNeverBindToLocalIdentitiesOrNames() throws {
        let original = chain()
        var archive = try contents(original)
        archive.snapshot.sessions.removeAll { $0.id == "bastion" }
        archive.snapshot.tree.removeAll { $0.name == "Bastions" }
        let plan = try SessionTransfer.plan(archive, into: original, conflict: .keepBoth)
        let app = try #require(plan.added.first)
        #expect(app.jumps[0].sessionIdentity != original.sessions.first { $0.id == "bastion" }?.persistentID)
        let restored = SessionStore(snapshot: plan.snapshot)
        #expect(throws: SSHLaunchError.self) { try SSHLaunch.plan(for: app, sessions: restored.sessions) }
    }

    @Test func suffixesDoNotStealAnotherImportedName() throws {
        let original = chain()
        let store = SessionStore(snapshot: original)
        store.createSession(Session(id: "app (2)", user: "u", host: "h", port: 22, icon: .server), parentID: nil)
        let plan = try SessionTransfer.plan(contents(store.snapshot), into: original, conflict: .keepBoth)
        #expect(Set(plan.added.map(\.id)) == ["app (3)", "bastion (2)", "app (2)"])
    }

    @Test func exportedPasswordsComeOnlyFromSelectedSessionsAndRoundTripKeychain() throws {
        let original = chain()
        let source = KeychainStore(service: "termstead-transfer-source-\(UUID())")
        let target = KeychainStore(service: "termstead-transfer-target-\(UUID())")
        let app = try #require(original.sessions.first { $0.id == "app" })
        let password = SSHLaunch.sessionPasswordAccount(app.id)
        let hop = SSHLaunch.hopPasswordAccount(app.jumps[1].id)
        source.set("pw", for: password); source.set("hop", for: hop); source.set("exclude", for: "unrelated")
        defer { source.delete(password); source.delete(hop); source.delete("unrelated") }
        let credentials = try SessionTransfer.credentials(for: original, using: source)
        #expect(credentials.filter { $0.role == "password" }.count == 1)
        #expect(!credentials.contains { $0.value == "exclude" })
        var archive = try contents(original)
        archive.credentials = credentials
        let plan = try SessionTransfer.plan(archive, into: .empty, conflict: .keepBoth)
        defer { plan.secrets.forEach { target.delete($0.account) } }
        #expect(try SessionTransfer.installSecrets(plan, using: target).count == 2)
        #expect(target.secret(for: password) == "pw")
        let copy = try #require(plan.added.first { $0.id == "app" })
        #expect(target.secret(for: SSHLaunch.hopPasswordAccount(copy.jumps[1].id)) == "hop")
        #expect(try SessionTransfer.installSecrets(plan, using: target).isEmpty)
    }

    @Test func existingPasswordsSurviveAnImport() throws {
        let target = KeychainStore(service: "termstead-transfer-existing-\(UUID())")
        defer { target.delete("shared") }
        target.set("local", for: "shared")
        let plan = SessionTransfer.Plan(snapshot: .empty, added: [], skipped: 0, renamed: [],
                                       secrets: [.init(account: "shared", value: "imported")])
        #expect(try SessionTransfer.installSecrets(plan, using: target).isEmpty)
        #expect(target.secret(for: "shared") == "local")
    }

    @Test func failedCredentialWriteRollsBackNewAccounts() throws {
        let keychain = KeychainStore(service: "termstead-transfer-rollback-\(UUID())")
        defer { keychain.delete("first") }
        struct FailingStore: SessionSecretStore {
            let keychain: KeychainStore
            func readSecret(_ account: String) throws -> String? { try keychain.readSecret(account) }
            func insertSecret(_ secret: String, account: String) throws {
                if account == "second" { throw KeychainStore.AccessError(status: errSecNotAvailable) }
                try keychain.insertSecret(secret, account: account)
            }
            func removeSecret(_ account: String) throws { try keychain.removeSecret(account) }
        }
        let plan = SessionTransfer.Plan(snapshot: .empty, added: [], skipped: 0, renamed: [], secrets: [
            .init(account: "first", value: "one"), .init(account: "second", value: "two")])
        #expect(throws: (any Error).self) { try SessionTransfer.installSecrets(plan, using: FailingStore(keychain: keychain)) }
        #expect(!keychain.contains("first"))
    }

    @Test func failedImportLeavesTheTreeAndExistingPasswordsUntouched() async throws {
        let original = chain()
        var archive = try contents(original)
        archive.credentials = [.init(sessionID: original.sessions[0].persistentID!, role: "password", value: "pw")]
        let store = SessionStore(snapshot: original)
        let before = store.snapshot
        struct Unavailable: SessionSecretStore {
            func readSecret(_ account: String) throws -> String? { throw KeychainStore.AccessError(status: errSecNotAvailable) }
            func insertSecret(_ secret: String, account: String) throws { Issue.record("Must not insert after a read failure") }
            func removeSecret(_ account: String) throws { Issue.record("Nothing was inserted") }
        }
        do {
            _ = try await SessionTransfer.importSessions(archive, into: store, conflict: .keepBoth, keychain: Unavailable())
            Issue.record("Expected Keychain failure")
        } catch { #expect(store.snapshot == before) }
    }

    @Test func sharedKeyPassphrasesRemainValidAcrossMultipleSessionRecords() throws {
        var original = chain()
        for index in original.sessions.indices { original.sessions[index].auth = .key }
        let keychain = KeychainStore(service: "termstead-transfer-key-\(UUID())")
        let account = SSHLaunch.passphraseAccount(forKey: Session.defaultKeyPath)
        keychain.set("shared-passphrase", for: account)
        defer { keychain.delete(account) }
        let credentials = try SessionTransfer.credentials(for: original, using: keychain)
        #expect(credentials.filter { $0.role == "keyPassphrase" }.count == 2)
        let document = try SessionArchive.document(original, credentials: credentials)
        let contents = try SessionArchive.decode(SessionArchive.encode(document, password: "password"), password: "password")
        let plan = try SessionTransfer.plan(contents, into: .empty, conflict: .keepBoth)
        #expect(plan.secrets.count == 1)
        #expect(plan.secrets.first?.value == "shared-passphrase")
    }

    @Test func desktopExportDoesNotReadAnUnrelatedSSHKeyPassphrase() throws {
        let store = SessionStore(tree: [], sessions: [:], selectedID: nil, pinnedIDs: [])
        var desktop = Session(id: "desktop", user: "u", host: "desktop.example", port: 3389, icon: .monitor)
        desktop.kind = .rdp
        store.createSession(desktop, parentID: nil)
        let keychain = KeychainStore(service: "termstead-transfer-desktop-\(UUID())")
        let account = SSHLaunch.passphraseAccount(forKey: Session.defaultKeyPath)
        let password = SSHLaunch.sessionPasswordAccount(desktop.id)
        keychain.set("unrelated-key", for: account); keychain.set("desktop-password", for: password)
        defer { keychain.delete(account); keychain.delete(password) }
        let credentials = try SessionTransfer.credentials(for: store.snapshot, using: keychain)
        #expect(credentials.map(\.role) == ["password"])
        #expect(credentials.first?.value == "desktop-password")
    }

    private func destination() -> SessionSnapshot {
        let store = SessionStore(tree: [], sessions: [:], selectedID: nil, pinnedIDs: [])
        let root = store.createGroup(name: "Existing", parentID: nil, colorID: nil)
        let nested = store.createGroup(name: "Destination", parentID: root, colorID: "blue")
        store.createGroup(name: "Other", parentID: root, colorID: nil)
        store.createSession(Session(id: "local", user: "u", host: "local.example", port: 22, icon: .server), parentID: nested)
        store.collapsedGroupIDs = Set(store.groupOptions().map(\.id))
        return store.snapshot
    }

    @Test func importCanPreserveFoldersInsideANestedExistingGroup() throws {
        let current = destination()
        let store = SessionStore(snapshot: current)
        let id = try #require(store.groupOptions().first { $0.name == "Destination" }?.id)
        let plan = try SessionTransfer.plan(contents(chain()), into: current, conflict: .keepBoth,
                                            destinationGroupID: id)
        let restored = SessionStore(snapshot: plan.snapshot)
        #expect(restored.tree.count == 1)
        #expect(restored.tree[0].id == current.tree[0].id)
        #expect(restored.currentGroupID(ofSession: "local") == id)
        let importedGroups = restored.groupOptions().filter { ["Bastions", "Servers"].contains($0.name) }
        #expect(importedGroups.count == 2)
        #expect(importedGroups.allSatisfy { $0.depth == 2 && restored.parentID(ofGroup: $0.id) == id })
        #expect(!restored.collapsedGroupIDs.contains(id))
        #expect(!restored.collapsedGroupIDs.contains(current.tree[0].id))
        let other = try #require(restored.groupOptions().first { $0.name == "Other" })
        #expect(restored.collapsedGroupIDs.contains(other.id))
        #expect(restored.pinnedIDs == ["app"])
    }

    @Test func importCanPlaceSessionsDirectlyInAnExistingGroupAndKeepJumps() throws {
        let current = destination()
        let store = SessionStore(snapshot: current)
        let id = try #require(store.groupOptions().first { $0.name == "Destination" }?.id)
        let plan = try SessionTransfer.plan(contents(chain()), into: current, conflict: .keepBoth,
                                            destinationGroupID: id, keepFolders: false)
        let restored = SessionStore(snapshot: plan.snapshot)
        #expect(restored.groupOptions().count == store.groupOptions().count)
        for name in ["local", "app", "bastion"] { #expect(restored.currentGroupID(ofSession: name) == id) }
        let app = try #require(restored.session("app"))
        let launch = try SSHLaunch.plan(for: app, sessions: restored.sessions)
        #expect(launch.hops.first?.host == "jump.example")
        #expect(launch.hops.first?.port == 2222)
    }

    @Test func conflictsCanBeRenamedWithinTheSelectedGroupWithoutExtraRootFolders() throws {
        let current = chain()
        let id = try #require(current.tree.first { $0.name == "Servers" }?.id)
        let plan = try SessionTransfer.plan(contents(current), into: current, conflict: .keepBoth,
                                            destinationGroupID: id, keepFolders: false)
        let restored = SessionStore(snapshot: plan.snapshot)
        #expect(restored.tree.count == current.tree.count)
        #expect(restored.currentGroupID(ofSession: "app") == id)
        #expect(restored.currentGroupID(ofSession: "app (2)") == id)
        #expect(restored.currentGroupID(ofSession: "bastion (2)") == id)
        #expect(restored.currentGroupID(ofSession: "bastion") != id)
        #expect(restored.session("app (2)")?.jumps[0].sessionIdentity == restored.session("bastion (2)")?.persistentID)
    }

    @Test func aMissingDestinationFailsBeforeAnyCredentialAccess() async throws {
        let store = SessionStore(snapshot: destination())
        let before = store.snapshot
        var archive = try contents(chain())
        archive.credentials = [.init(sessionID: archive.snapshot.sessions[0].persistentID!, role: "password", value: "pw")]
        struct NoAccess: SessionSecretStore {
            func readSecret(_ account: String) throws -> String? { Issue.record("Must validate the destination first"); return nil }
            func insertSecret(_ secret: String, account: String) throws { Issue.record("Must not write a password") }
            func removeSecret(_ account: String) throws { Issue.record("Must not delete a password") }
        }
        do {
            _ = try await SessionTransfer.importSessions(archive, into: store, conflict: .keepBoth,
                destinationGroupID: "deleted-group", keepFolders: false, keychain: NoAccess())
            Issue.record("Expected a missing destination error")
        } catch { #expect(store.snapshot == before) }
    }
}
