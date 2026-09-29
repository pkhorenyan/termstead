import Testing
@testable import Termstead

@MainActor
struct CloseConfirmationTests {
    /// A connection that was never started still counts as running — which is
    /// the state a live ssh tab is in.
    private func storeWithOneTab() -> (ConnectionStore, Connection) {
        let store = ConnectionStore()
        let tab = Connection(sessionID: "nas", title: "nas", address: "", keyDescription: "")
        store.add(tab)
        return (store, tab)
    }

    @Test func aLiveTabAsksFirst() {
        let (store, tab) = storeWithOneTab()
        let state = AppState()
        state.requestClose(tab.id, in: store, confirm: true)
        #expect(state.pendingClose == tab.id)
        #expect(store.connections.count == 1, "nothing closes before the answer")
    }

    @Test func withTheSettingOffItClosesAtOnce() {
        let (store, tab) = storeWithOneTab()
        let state = AppState()
        state.requestClose(tab.id, in: store, confirm: false)
        #expect(state.pendingClose == nil)
        #expect(store.connections.isEmpty)
    }

    @Test func liveTabsAreCountedForQuitting() {
        let (store, _) = storeWithOneTab()
        #expect(store.liveCount == 1)
        store.closeAll()
        #expect(store.liveCount == 0)
    }
}
