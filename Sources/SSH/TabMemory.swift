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
        /// The pane it was in; `nil` before there were panes, and for the first.
        var pane: Int?
    }

    var tabs: [Tab]
    /// Which of them was in front, in the focused pane.
    var active: Int?
    /// `nil` in lists saved before there were panes: one pane.
    var layout: PaneLayout?
    /// Every pane's tab in front, as indexes into `tabs`.
    var fronts: [Int]?

    static let key = "window.openTabs"

    init(tabs: [Tab], active: Int?, layout: PaneLayout? = nil, fronts: [Int]? = nil) {
        self.tabs = tabs
        self.active = active
        self.layout = layout
        self.fronts = fronts
    }

    @MainActor
    init(_ store: ConnectionStore) {
        // A tunnel connection shown as a tab is no shell to reopen: port
        // forwarding is started by hand, and would come back as a terminal.
        let all = store.connections.filter { !$0.isTunnelOnly }
        tabs = all.map { connection in
            var tab = connection.sessionID.map { Tab(sessionID: $0) } ?? Tab(address: connection.address)
            tab.pane = connection.pane == 0 ? nil : connection.pane
            return tab
        }
        active = store.active.flatMap { front in all.firstIndex { $0.id == front.id } }
        layout = store.layout == .single ? nil : store.layout
        let fronts = (0..<store.layout.paneCount).compactMap { pane in
            store.active(in: pane).flatMap { front in all.firstIndex { $0.id == front.id } }
        }
        self.fronts = store.layout == .single ? nil : fronts
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
        var renumbered: [Int: Int] = [:]
        for (index, tab) in tabs.enumerated() {
            if let id = tab.sessionID, sessions.session(id) == nil { continue }
            if tab.sessionID == nil, (tab.address ?? "").isEmpty { continue }
            renumbered[index] = kept.count
            kept.append(tab)
        }
        return TabMemory(tabs: kept, active: active.flatMap { renumbered[$0] }, layout: layout,
                         fronts: fronts?.compactMap { renumbered[$0] })
    }

    /// Opens the tabs again, in their panes and order, with the same ones in
    /// front and the same pane focused.
    @MainActor
    func reopen(in connections: ConnectionStore, sessions: SessionStore) {
        let plan = reopenable(in: sessions)
        let layout = plan.layout ?? .single
        connections.setLayout(layout)
        var opened: [UUID] = []
        for tab in plan.tabs {
            connections.focus(pane: min(tab.pane ?? 0, layout.paneCount - 1))
            if let id = tab.sessionID {
                // A new tab each time: two tabs on one session stay two.
                connections.connect(sessionID: id, in: sessions, newTab: true)
            } else if let address = tab.address {
                connections.connect(address: address)
            }
            if let last = connections.connections.last { opened.append(last.id) }
        }
        for front in plan.fronts ?? [] where opened.indices.contains(front) {
            connections.activeID = opened[front]
        }
        // The focused pane's last, so it ends up focused.
        if let front = plan.active, opened.indices.contains(front) {
            connections.activeID = opened[front]
        }
    }
}
