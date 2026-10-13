import Foundation

/// The tabs open when Termstead quit, for Settings ▸ Terminal ▸ Window ▸
/// "Reopen tabs at launch".
///
/// Kept only for the real session file: a development launch or a test run
/// works on a tree of its own, and its tabs would replace the user's list.
struct TabMemory: Codable, Equatable, Sendable {
    struct Tab: Codable, Equatable, Sendable {
        /// A saved session, by name.
        var sessionID: String?
        /// A quick connection's address, as it was typed.
        var address: String?
    }

    var tabs: [Tab]
    /// Which of them was in front.
    var active: Int?

    static let key = "window.openTabs"

    init(tabs: [Tab], active: Int?) {
        self.tabs = tabs
        self.active = active
    }

    @MainActor
    init(_ store: ConnectionStore) {
        tabs = store.connections.map { connection in
            connection.sessionID.map { Tab(sessionID: $0) } ?? Tab(address: connection.address)
        }
        active = store.active.flatMap { front in store.connections.firstIndex { $0.id == front.id } }
    }

    func save(to defaults: UserDefaults) {
        guard !tabs.isEmpty, let data = try? JSONEncoder().encode(self) else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        defaults.set(data, forKey: Self.key)
    }

    static func load(from defaults: UserDefaults) -> TabMemory? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(TabMemory.self, from: $0) }
    }

    /// The tabs that can still be opened: a session deleted since is skipped,
    /// and the tab in front is counted among what is left.
    @MainActor
    func reopenable(in sessions: SessionStore) -> TabMemory {
        var kept: [Tab] = []
        var front: Int?
        for (index, tab) in tabs.enumerated() {
            if let id = tab.sessionID, sessions.session(id) == nil { continue }
            if tab.sessionID == nil, (tab.address ?? "").isEmpty { continue }
            if index == active { front = kept.count }
            kept.append(tab)
        }
        return TabMemory(tabs: kept, active: front)
    }

    /// Opens the tabs again, in their order, with the same one in front.
    @MainActor
    func reopen(in connections: ConnectionStore, sessions: SessionStore) {
        let plan = reopenable(in: sessions)
        var opened: [UUID] = []
        for tab in plan.tabs {
            if let id = tab.sessionID {
                // A new tab each time: two tabs on one session stay two.
                connections.connect(sessionID: id, in: sessions, newTab: true)
            } else if let address = tab.address {
                connections.connect(address: address)
            }
            if let last = connections.connections.last { opened.append(last.id) }
        }
        if let front = plan.active, opened.indices.contains(front) {
            connections.activeID = opened[front]
        }
    }
}
