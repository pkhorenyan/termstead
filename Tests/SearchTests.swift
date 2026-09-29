import Testing
@testable import Termstead

@MainActor
struct SearchTests {
    private func rows(_ store: SessionStore, _ query: String) -> [String] {
        store.flattened(matching: query).rows.map(\.id)
    }

    private func sessions(_ store: SessionStore, _ query: String) -> [String] {
        rows(store, query).filter { $0.hasPrefix("session:") }
    }

    @Test func emptyQueryIsTheWholeTree() {
        let store = SessionStore.sample()
        #expect(rows(store, "") == store.flattened.rows.map(\.id))
        #expect(rows(store, "   ") == store.flattened.rows.map(\.id))
        #expect(store.matchingSessionIDs("  ") == nil)
    }

    @Test func matchesByNameHostUserAndJumpHost() {
        let store = SessionStore.sample()
        #expect(sessions(store, "staging-app") == ["session:staging-app"])
        #expect(sessions(store, "10.0.2.5") == ["session:db-primary"])
        #expect(sessions(store, "postgres") == ["session:db-primary"])
        #expect(Set(sessions(store, "nat-gw")) == ["session:prod-web-02"])
    }

    @Test func isCaseInsensitive() {
        let store = SessionStore.sample()
        #expect(sessions(store, "STAGING-APP") == ["session:staging-app"])
    }

    @Test func aGroupNameShowsEverythingInIt() {
        let store = SessionStore.sample()
        #expect(Set(sessions(store, "production"))
                == ["session:prod-web-01", "session:prod-web-02", "session:db-primary"])
    }

    @Test func everyWordHasToMatch() {
        let store = SessionStore.sample()
        #expect(sessions(store, "production postgres") == ["session:db-primary"])
        #expect(sessions(store, "staging postgres").isEmpty)
    }

    @Test func showsTheWayDownToAMatchAndNothingElse() {
        let store = SessionStore.sample()
        #expect(rows(store, "prod-web-02")
                == ["top:production", "group:web", "group:canary", "session:prod-web-02"])
    }

    @Test func collapsedGroupsOpenForASearchAndStayCollapsedAfter() {
        let store = SessionStore.sample()
        #expect(store.collapsedGroupIDs.contains("lab"))
        #expect(sessions(store, "raspberry") == ["session:raspberry-pi"])
        #expect(store.collapsedGroupIDs.contains("lab"))
        #expect(!rows(store, "").contains("session:raspberry-pi"))
    }

    @Test func noMatchIsAnEmptyTreeNotTheWholeOne() {
        let store = SessionStore.sample()
        #expect(store.matchingSessionIDs("zzz-no-such-host") == [])
        #expect(rows(store, "zzz-no-such-host").isEmpty)
    }

    @Test func searchRowsKeepTheirRealPositionForDrops() {
        let store = SessionStore.sample()
        let searched = store.flattened(matching: "nas").rows
        let full = store.flattened.rows
        for row in searched {
            if case .session(let hit) = row, case .session(let original)? = full.first(where: { $0.id == row.id }) {
                #expect(hit.childIndex == original.childIndex)
            }
        }
    }

    @Test func theIndexStillCoversHiddenSessions() {
        let store = SessionStore.sample()
        let index = store.flattened(matching: "nas").index
        #expect(index.path["prod-web-01"] == "Production / Web")
    }
}
