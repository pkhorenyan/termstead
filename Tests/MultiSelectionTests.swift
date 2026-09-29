import AppKit
import Testing
@testable import Termstead

@MainActor
struct MultiSelectionTests {
    private func s(_ id: String) -> SidebarDragItem { SidebarDragItem(kind: .session, id: id) }
    private func g(_ id: String) -> SidebarDragItem { SidebarDragItem(kind: .group, id: id) }

    private func shown(_ store: SessionStore) -> [SidebarDragItem] {
        store.flattened.rows.map { row in
            switch row {
            case .topGroup(let data): g(data.id)
            case .group(let data): g(data.id)
            case .session(let data): s(data.id)
            }
        }
    }

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

    // MARK: - Selection

    @Test func aPlainClickSelectsOneRow() {
        let store = SessionStore.sample()
        store.click(s("nas"), .single, shown: shown(store))
        store.click(g("web"), .single, shown: shown(store))
        #expect(store.selectedItems == [g("web")])
        #expect(store.selectedGroupID == "web")
    }

    @Test func commandClickAddsAndRemoves() {
        let store = SessionStore.sample()
        let rows = shown(store)
        store.click(s("nas"), .single, shown: rows)
        store.click(s("staging-app"), .toggle, shown: rows)
        store.click(g("db"), .toggle, shown: rows)
        #expect(store.selectedItems == [s("nas"), s("staging-app"), g("db")])

        store.click(s("staging-app"), .toggle, shown: rows)
        #expect(store.selectedItems == [s("nas"), g("db")])
    }

    @Test func removingTheAnchorHandsItOn() {
        let store = SessionStore.sample()
        let rows = shown(store)
        store.click(s("nas"), .single, shown: rows)
        store.click(s("staging-app"), .toggle, shown: rows)
        #expect(store.selectedID == "staging-app")
        store.click(s("staging-app"), .toggle, shown: rows)
        #expect(store.selectedID == "nas")
    }

    @Test func shiftClickSelectsTheRangeShown() {
        let store = SessionStore.sample()
        let rows = shown(store)
        store.click(g("web"), .single, shown: rows)
        store.click(s("prod-web-02"), .extend, shown: rows)
        #expect(store.selectedItems == [g("web"), s("prod-web-01"), g("canary"), s("prod-web-02")])
        // The anchor stays: a second ⇧-click re-ranges from it.
        store.click(s("prod-web-01"), .extend, shown: rows)
        #expect(store.selectedItems == [g("web"), s("prod-web-01")])
    }

    @Test func aPinnedHighlightDoesNotJoinATreeSelection() {
        let store = SessionStore.sample()
        store.select(session: "prod-web-01", inPinned: true)
        #expect(store.selectedItems.isEmpty)
        store.click(s("nas"), .toggle, shown: shown(store))
        #expect(store.selectedItems == [s("nas")])
    }

    // MARK: - What moves

    @Test func draggingASelectedRowCarriesTheSelectionInTreeOrder() {
        let store = SessionStore.sample()
        let rows = shown(store)
        store.click(s("nas"), .single, shown: rows)
        store.click(s("prod-web-01"), .toggle, shown: rows)
        #expect(store.dragPayload(startingAt: s("nas")) == [s("prod-web-01"), s("nas")])
    }

    @Test func draggingAnUnselectedRowCarriesOnlyIt() {
        let store = SessionStore.sample()
        let rows = shown(store)
        store.click(s("nas"), .single, shown: rows)
        store.click(s("prod-web-01"), .toggle, shown: rows)
        #expect(store.dragPayload(startingAt: s("staging-app")) == [s("staging-app")])
    }

    @Test func rowsInsideAMovedGroupTravelWithIt() {
        let store = SessionStore.sample()
        #expect(store.normalized([s("prod-web-02"), g("web"), s("nas")]) == [g("web"), s("nas")])
    }

    // MARK: - Moving several

    @Test func severalSessionsLandTogetherInTreeOrder() {
        let store = SessionStore.sample()
        #expect(store.drop([s("nas"), s("raspberry-pi")], to: .into("db")))
        #expect(children(store, of: "db") == ["session:db-primary", "session:raspberry-pi", "session:nas"])
        #expect(!children(store, of: "home").contains("session:nas"))
    }

    @Test func insertingAtAPositionAccountsForRowsTakenFromAbove() {
        let store = SessionStore.sample()
        // web holds [prod-web-01, canary]; prod-web-01 sits above the target slot.
        #expect(store.drop([s("prod-web-01"), s("nas")], to: DropTarget(parentGroupID: "web", index: 2)))
        #expect(children(store, of: "web") == ["group:canary", "session:prod-web-01", "session:nas"])
    }

    @Test func insertingAtTheTop() {
        let store = SessionStore.sample()
        #expect(store.drop([s("prod-web-01"), s("db-primary")], to: DropTarget(parentGroupID: "staging", index: 0)))
        #expect(children(store, of: "staging") == ["session:prod-web-01", "session:db-primary", "session:staging-app"])
    }

    @Test func sessionsCannotGoToTheTopLevelEvenTogether() {
        let store = SessionStore.sample()
        #expect(!store.canDrop([g("web"), s("nas")], to: .into(nil)))
        #expect(store.canDrop([g("web"), g("lab")], to: .into(nil)))
    }

    @Test func noGroupMayMoveIntoItsOwnSubtree() {
        let store = SessionStore.sample()
        #expect(!store.canDrop([g("web"), s("nas")], to: .into("canary")))
    }

    @Test func movingGroupsKeepsTheirContents() {
        let store = SessionStore.sample()
        #expect(store.drop([g("canary"), g("lab")], to: .into("staging")))
        #expect(children(store, of: "staging") == ["session:staging-app", "group:canary", "group:lab"])
        #expect(children(store, of: "canary") == ["session:prod-web-02"])
        #expect(children(store, of: "lab") == ["session:raspberry-pi"])
    }

    // MARK: - Pasteboard

    @Test func theDragPasteboardCarriesEveryItem() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("termstead-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let items = [g("web"), s("nas")]
        pasteboard.setData(SidebarDragItem.pasteboardData(items), forType: .termsteadSidebarItemPasteboard)
        #expect(SidebarDragItem.items(from: pasteboard) == items)
    }
}
