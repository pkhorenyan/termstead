import Testing
@testable import Termstead

@MainActor
struct GroupColorTests {
    @Test func noColorStopsTheParentsColor() {
        let store = SessionStore.sample()
        // canary sits in the red "web" group and has its own orange.
        store.setColor("none", forGroup: "canary")
        #expect(store.color(forSession: "prod-web-02") == nil)
        #expect(GroupColor.rgb(for: store.effectiveColorID(ofGroup: "canary")) == nil)
        // The parent keeps its color.
        #expect(store.color(forSession: "prod-web-01") != nil)
    }

    @Test func inheritingTakesTheParentsColor() {
        let store = SessionStore.sample()
        store.setColor(nil, forGroup: "canary")
        #expect(store.colorID(forSession: "prod-web-02") == "red")
    }

    @Test func noColorIsSavedAsSuch() throws {
        let store = SessionStore.sample()
        store.setColor("none", forGroup: "canary")
        let restored = SessionStore(snapshot: store.snapshot)
        #expect(restored.colorID(ofGroup: "canary") == "none")
        #expect(restored.color(forSession: "prod-web-02") == nil)
    }
}
