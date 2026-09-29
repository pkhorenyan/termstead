import Testing
@testable import Termstead

@MainActor
struct DeleteTests {
    private func s(_ id: String) -> SidebarDragItem { SidebarDragItem(kind: .session, id: id) }
    private func g(_ id: String) -> SidebarDragItem { SidebarDragItem(kind: .group, id: id) }

    private func allSessionIDs(_ store: SessionStore) -> Set<String> {
        func walk(_ nodes: [TreeNode]) -> [String] {
            nodes.flatMap { node -> [String] in
                switch node {
                case .session(let id): [id]
                case .group(let group): walk(group.children)
                }
            }
        }
        return Set(store.tree.flatMap { walk($0.children) })
    }

    @Test func deletingASessionRemovesItEverywhere() {
        let store = SessionStore.sample()
        #expect(store.isPinned("prod-web-01"))
        let removed = store.delete([s("prod-web-01")])
        #expect(removed.map(\.id) == ["prod-web-01"])
        #expect(store.session("prod-web-01") == nil)
        #expect(!allSessionIDs(store).contains("prod-web-01"))
        #expect(!store.isPinned("prod-web-01"))
    }

    @Test func deletingAGroupTakesEverythingInside() {
        let store = SessionStore.sample()
        #expect(store.sessionCount(in: [g("web")]) == 2)
        let removed = Set(store.delete([g("web")]).map(\.id))
        #expect(removed == ["prod-web-01", "prod-web-02"])
        #expect(store.groupOptions().allSatisfy { $0.id != "web" && $0.id != "canary" })
        #expect(store.session("prod-web-02") == nil)
    }

    @Test func deletingATopLevelGroup() {
        let store = SessionStore.sample()
        let removed = Set(store.delete([g("staging")]).map(\.id))
        #expect(removed == ["staging-app"])
        #expect(!store.tree.contains { $0.id == "staging" })
    }

    @Test func aSessionInsideADeletedGroupCountsOnce() {
        let store = SessionStore.sample()
        let items = [g("web"), s("prod-web-02"), s("nas")]
        #expect(store.sessionCount(in: items) == 3)
        #expect(store.delete(items).count == 3)
    }

    @Test func theSelectionForgetsWhatWasDeleted() {
        let store = SessionStore.sample()
        let shown = store.flattened.rows.map { row -> SidebarDragItem in
            switch row {
            case .topGroup(let d): g(d.id)
            case .group(let d): g(d.id)
            case .session(let d): s(d.id)
            }
        }
        store.click(s("nas"), .single, shown: shown)
        store.click(s("staging-app"), .toggle, shown: shown)
        store.delete([s("staging-app")])
        #expect(store.selectedItems == [s("nas")])
        #expect(store.selectedID == nil)
    }
}
