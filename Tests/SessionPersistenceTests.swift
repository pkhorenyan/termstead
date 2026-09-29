import Foundation
import Testing
@testable import Termstead

@MainActor
struct SessionPersistenceTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("termstead-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("sessions.json")
    }

    @Test func roundTripKeepsEverythingThatIsSaved() throws {
        let store = SessionStore.sample()
        let url = temporaryURL()
        try SessionPersistence.save(store.snapshot, to: url)

        guard case .loaded(let loaded) = SessionPersistence.load(from: url) else {
            Issue.record("expected the file to load")
            return
        }
        #expect(loaded == store.snapshot)

        let restored = SessionStore(snapshot: loaded)
        #expect(restored.sessions == store.sessions)
        #expect(restored.tree == store.tree)
        #expect(restored.pinnedIDs == store.pinnedIDs)
        #expect(restored.collapsedGroupIDs == store.collapsedGroupIDs)
    }

    @Test func authKeyPathAndHopsSurvive() throws {
        var session = Session(id: "edge", user: "ops", host: "edge.example", port: 2200, icon: .shield)
        session.auth = .password
        session.keyPath = "~/.ssh/edge_key"
        let hop = JumpHost(host: "bastion", user: "jump", port: 2222, auth: .key, keyPath: "~/.ssh/bastion")
        session.jumps = [hop]

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        #expect(decoded.auth == .password)
        #expect(decoded.keyPath == "~/.ssh/edge_key")
        #expect(decoded.jumps == [hop])
        #expect(decoded.jumps.first?.id == hop.id)
    }

    @Test func missingFileIsReportedAsMissing() {
        #expect(SessionPersistence.load(from: temporaryURL()) == .missing)
    }

    @Test func corruptFileIsMovedAsideNotOverwritten() throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)

        guard case .corrupt(let movedTo?) = SessionPersistence.load(from: url) else {
            Issue.record("expected the file to be moved aside")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try String(contentsOf: movedTo, encoding: .utf8) == "{ not json")
    }

    @Test func pinsToMissingSessionsAreDropped() {
        var snapshot = SessionStore.sample().snapshot
        snapshot.pinnedIDs.append("gone")
        #expect(!SessionStore(snapshot: snapshot).pinnedIDs.contains("gone"))
    }

    @Test func testRunsNeverTouchTheRealFile() {
        let storage = SessionStorage.forThisLaunch(
            defaults: UserDefaults(suiteName: "termstead-tests-\(UUID().uuidString)")!,
            environment: ["XCTestConfigurationFilePath": "/dev/null"]
        )
        #expect(storage.url == nil)
    }
}

@MainActor
struct DropArithmeticTests {
    private func children(_ store: SessionStore, of groupID: String) -> [String] {
        func find(_ nodes: [TreeNode]) -> [TreeNode]? {
            for node in nodes {
                if case .group(let group) = node {
                    if group.id == groupID { return group.children }
                    if let found = find(group.children) { return found }
                }
            }
            return nil
        }
        return find(store.tree.map { .group($0) })?.map(\.id) ?? []
    }

    @Test func reorderWithinAGroupAccountsForTheClosedGap() {
        let store = SessionStore.sample()
        let before = children(store, of: "home")
        #expect(before == ["group:lab", "session:nas"])

        // Dropping the lab group after nas: index 2 before detaching, 1 after.
        #expect(store.drop(SidebarDragItem(kind: .group, id: "lab"), to: DropTarget(parentGroupID: "home", index: 2)))
        #expect(children(store, of: "home") == ["session:nas", "group:lab"])
    }

    @Test func droppingNextToYourOwnSlotIsRefused() {
        let store = SessionStore.sample()
        let item = SidebarDragItem(kind: .session, id: "nas")
        #expect(!store.canDrop(item, to: DropTarget(parentGroupID: "home", index: 1)))
        #expect(!store.canDrop(item, to: DropTarget(parentGroupID: "home", index: 2)))
        #expect(store.canDrop(item, to: DropTarget(parentGroupID: "home", index: 0)))
    }

    @Test func sessionsCannotLiveAtTheTopLevel() {
        let store = SessionStore.sample()
        #expect(!store.canDrop(SidebarDragItem(kind: .session, id: "nas"), to: .into(nil)))
    }

    @Test func aGroupCannotMoveIntoItsOwnSubtree() {
        let store = SessionStore.sample()
        #expect(!store.canDrop(SidebarDragItem(kind: .group, id: "web"), to: .into("canary")))
    }

    @Test func movingIntoAGroupExpandsIt() {
        let store = SessionStore.sample()
        #expect(store.collapsedGroupIDs.contains("lab"))
        #expect(store.drop(SidebarDragItem(kind: .session, id: "nas"), to: .into("lab")))
        #expect(!store.collapsedGroupIDs.contains("lab"))
        #expect(children(store, of: "lab") == ["session:raspberry-pi", "session:nas"])
    }
}
