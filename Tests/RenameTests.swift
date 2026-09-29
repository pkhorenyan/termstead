import Testing
@testable import Termstead

@MainActor
struct RenameTests {
    @Test func aSessionTakesItsNewNameEverywhere() {
        let store = SessionStore.sample()
        store.select(session: "prod-web-01")
        #expect(store.renameSession("prod-web-01", to: "  web-front  "))
        #expect(store.session("prod-web-01") == nil)
        #expect(store.session("web-front")?.host == "10.0.1.12")
        #expect(store.isPinned("web-front"))
        #expect(store.selectedID == "web-front")
        #expect(store.currentGroupID(ofSession: "web-front") == "web")
    }

    @Test func aTakenNameIsRefused() {
        let store = SessionStore.sample()
        #expect(!store.renameSession("prod-web-01", to: "nas"))
        #expect(store.session("prod-web-01") != nil)
    }

    @Test func anEmptyNameIsRefused() {
        let store = SessionStore.sample()
        #expect(!store.renameSession("nas", to: "   "))
        #expect(store.session("nas") != nil)
    }

    @Test func aGroupRenameKeepsItsID() {
        let store = SessionStore.sample()
        store.rename(group: "web", to: "Frontends")
        #expect(store.groupOptions().first { $0.id == "web" }?.name == "Frontends")
        #expect(store.currentGroupID(ofSession: "prod-web-01") == "web")
    }
}
