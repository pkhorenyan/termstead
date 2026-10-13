import Foundation
import Testing
@testable import Termstead

@MainActor
struct TabMemoryTests {
    private func store(_ tabs: [(session: String?, address: String)]) -> ConnectionStore {
        let store = ConnectionStore()
        for tab in tabs {
            store.add(Connection(sessionID: tab.session, title: tab.session ?? tab.address,
                                 address: tab.address, keyDescription: ""))
        }
        return store
    }

    @Test func remembersEachTabInOrderWithTheOneInFront() {
        let tabs = store([("prod-web-01", "deploy@10.0.1.12:22"), (nil, "me@example.org:2222"),
                          ("prod-web-01", "deploy@10.0.1.12:22")])
        tabs.activeID = tabs.connections[1].id
        let memory = TabMemory(tabs)
        #expect(memory.tabs == [TabMemory.Tab(sessionID: "prod-web-01"),
                                TabMemory.Tab(address: "me@example.org:2222"),
                                TabMemory.Tab(sessionID: "prod-web-01")])
        #expect(memory.active == 1)
    }

    /// With sudden or automatic termination declared, quitting ended the app
    /// right after `applicationShouldTerminate`: `applicationWillTerminate`,
    /// which saves the tabs, never ran, and nothing was reopened.
    @Test func theAppIsNotKilledWithoutBeingToldItIsQuitting() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "NSSupportsSuddenTermination") == nil)
        #expect(Bundle.main.object(forInfoDictionaryKey: "NSSupportsAutomaticTermination") == nil)
    }

    @Test func survivesARoundTripAndForgetsAnEmptyStrip() throws {
        let suite = "termstead-tabs-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let memory = TabMemory(tabs: [.init(sessionID: "nas"), .init(address: "pi@raspberry")], active: 1)
        memory.save(to: defaults)
        #expect(TabMemory.load(from: defaults) == memory)

        TabMemory(tabs: [], active: nil).save(to: defaults)
        #expect(TabMemory.load(from: defaults) == nil)
    }

    @Test func skipsSessionsDeletedSinceAndKeepsTheFrontTab() {
        let sessions = SessionStore.sample()
        let memory = TabMemory(tabs: [.init(sessionID: "gone"), .init(sessionID: "nas"),
                                      .init(address: ""), .init(sessionID: "db-primary")],
                               active: 3)
        let plan = memory.reopenable(in: sessions)
        #expect(plan.tabs == [.init(sessionID: "nas"), .init(sessionID: "db-primary")])
        #expect(plan.active == 1)

        // The front tab itself gone: nothing in particular comes to the front.
        let lost = TabMemory(tabs: [.init(sessionID: "nas"), .init(sessionID: "gone")], active: 1)
        #expect(lost.reopenable(in: sessions).active == nil)
    }

    @Test func closingSeveralTabsAsksOnceWhileAnyIsLive() {
        let tabs = store([(nil, "a"), (nil, "b"), (nil, "c")])
        let ids = tabs.connections.prefix(2).map(\.id)
        let state = AppState()

        // A tab that was never started counts as live, as one still connecting does.
        state.requestClose(Array(ids), in: tabs, confirm: true)
        #expect(state.pendingCloseGroup == Array(ids))
        #expect(tabs.connections.count == 3)

        state.pendingCloseGroup = nil
        state.requestClose(Array(ids), in: tabs, confirm: false)
        #expect(state.pendingCloseGroup == nil)
        #expect(tabs.connections.map(\.title) == ["c"])
    }
}
