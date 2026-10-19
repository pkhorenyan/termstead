import Foundation
import Observation

/// How the terminal area is divided. Panes are numbered along the rows:
/// left then right, top then bottom.
enum PaneLayout: String, Codable, CaseIterable, Sendable {
    case single, sideBySide, stacked, grid

    var paneCount: Int {
        switch self {
        case .single: 1
        case .sideBySide, .stacked: 2
        case .grid: 4
        }
    }

    /// For "Move to Pane", in this layout's terms.
    func name(ofPane pane: Int) -> String {
        switch self {
        case .single: "Main"
        case .sideBySide: pane == 0 ? "Left" : "Right"
        case .stacked: pane == 0 ? "Top" : "Bottom"
        case .grid: ["Top Left", "Top Right", "Bottom Left", "Bottom Right"][min(pane, 3)]
        }
    }

    private var columns: Int { self == .sideBySide || self == .grid ? 2 : 1 }
    private var rows: Int { self == .stacked || self == .grid ? 2 : 1 }

    /// Where a tab in `pane` goes when `source` becomes `target`: to the pane
    /// that covers the same corner of the window, so nothing is closed and
    /// the left column stays on the left.
    static func pane(_ pane: Int, from source: PaneLayout, to target: PaneLayout) -> Int {
        let column = min(pane % source.columns, target.columns - 1)
        let row = min(pane / source.columns, target.rows - 1)
        return row * target.columns + column
    }
}

/// The open tabs, the panes they are in, and which is in front. Runtime only:
/// nothing here is saved — see `TabMemory`.
///
/// One store for every pane, each tab carrying its pane's number. Whatever
/// acts on "the tab in front" — the menus, the status bar, the SFTP panel,
/// the sidebar — means the focused pane's, so `active` and `activeID` are
/// that pane's and none of it needed to know there are panes.
@MainActor
@Observable
final class ConnectionStore {
    private(set) var connections: [Connection] = []
    private(set) var layout: PaneLayout = .single
    private(set) var focusedPane = 0
    /// The tab chosen last in each pane.
    private var activeByPane: [Int: UUID] = [:]

    /// The focused pane's tab in front. Setting it brings that tab forward in
    /// its own pane and focuses the pane.
    var activeID: UUID? {
        get { activeByPane[focusedPane] }
        set {
            if let id = newValue, let tab = connections.first(where: { $0.id == id }) {
                if tab.pane != focusedPane {
                    paneLog.debug("focus pane \(self.focusedPane, privacy: .public) → \(tab.pane, privacy: .public) with tab \(tab.title, privacy: .public)")
                }
                activeByPane[tab.pane] = id
                focusedPane = tab.pane
            } else {
                activeByPane[focusedPane] = nil
            }
            updateLoadWatches()
        }
    }
    /// Settings ▸ "Show server load". Only the tab in front is watched: the
    /// status bar shows no other, and each watch is a process here and a
    /// shell loop on the server.
    var watchesServerLoad = false {
        didSet { updateLoadWatches() }
    }

    private func updateLoadWatches() {
        let front = active?.id
        for connection in connections {
            connection.watchesLoad = watchesServerLoad && connection.id == front
        }
    }

    var active: Connection? { active(in: focusedPane) }

    /// A pane's tabs, in the order its strip shows them.
    func tabs(in pane: Int) -> [Connection] {
        connections.filter { $0.pane == pane }
    }

    /// The pane's tab in front: the one chosen there last, else its first.
    func active(in pane: Int) -> Connection? {
        let tabs = tabs(in: pane)
        return tabs.first { $0.id == activeByPane[pane] } ?? tabs.first
    }

    /// A click in the pane, its terminal taking the keyboard, or ⌘] / ⌘[.
    func focus(pane: Int) {
        guard (0..<layout.paneCount).contains(pane), pane != focusedPane else { return }
        paneLog.debug("focus pane \(self.focusedPane, privacy: .public) → \(pane, privacy: .public)")
        focusedPane = pane
        updateLoadWatches()
    }

    /// ⌘] and ⌘[: the next or previous pane, round the ends.
    func focusPane(offset: Int) {
        let count = layout.paneCount
        focus(pane: ((focusedPane + offset) % count + count) % count)
    }

    // MARK: - Broadcast input

    /// Typing goes to every visible pane's tab in front, not only the focused
    /// one (⌥⌘I, the button beside the layouts). Split layouts only.
    private(set) var isBroadcasting = false
    /// Panes left out of it: they keep their own input.
    private(set) var broadcastExcluded: Set<Int> = []

    var canBroadcast: Bool { layout.paneCount > 1 }

    func toggleBroadcast() {
        isBroadcasting = canBroadcast && !isBroadcasting
        paneLog.debug("broadcast input \(self.isBroadcasting ? "on" : "off", privacy: .public)")
    }

    func toggleBroadcast(pane: Int) {
        if broadcastExcluded.contains(pane) {
            broadcastExcluded.remove(pane)
        } else {
            broadcastExcluded.insert(pane)
        }
    }

    /// The pane takes broadcast input: on, split, not left out, and with a
    /// tab in front.
    func receivesBroadcast(pane: Int) -> Bool {
        isBroadcasting && canBroadcast && !broadcastExcluded.contains(pane) && active(in: pane) != nil
    }

    /// Where input typed into `source` goes besides `source` itself: the
    /// other included panes' tabs in front, still connected. Nothing when the
    /// source's own pane is left out, or the source is not in front there.
    func broadcastTargets(from source: Connection) -> [Connection] {
        guard receivesBroadcast(pane: source.pane), active(in: source.pane) === source else { return [] }
        return (0..<layout.paneCount).compactMap { pane in
            guard pane != source.pane, receivesBroadcast(pane: pane),
                  let front = active(in: pane), front.state.isRunning else { return nil }
            return front
        }
    }

    func broadcast(_ data: ArraySlice<UInt8>, from source: Connection) {
        for target in broadcastTargets(from: source) {
            target.terminalView.receiveBroadcast(data)
        }
    }

    /// Switches the layout. Nothing is closed: tabs of a pane that goes move
    /// to the pane covering the same corner (`PaneLayout.pane`). A new pane
    /// starts empty and takes the focus, so the next session opens there.
    func setLayout(_ new: PaneLayout) {
        guard new != layout else { return }
        let old = layout
        let wasFocused = focusedPane
        var fronts: [Int: UUID] = [:]
        // The focused pane's tab last, so it wins where panes merge.
        for pane in (0..<old.paneCount).filter({ $0 != wasFocused }) + [wasFocused] {
            if let front = active(in: pane) { fronts[PaneLayout.pane(pane, from: old, to: new)] = front.id }
        }
        for connection in connections {
            connection.pane = PaneLayout.pane(connection.pane, from: old, to: new)
        }
        layout = new
        activeByPane = fronts
        // Pane numbers mean other panes now; one pane has nothing to broadcast to.
        broadcastExcluded = []
        if new.paneCount < 2 { isBroadcasting = false }
        let mapped = PaneLayout.pane(wasFocused, from: old, to: new)
        if new.paneCount > old.paneCount {
            focusedPane = (0..<new.paneCount).first { tabs(in: $0).isEmpty } ?? mapped
        } else {
            focusedPane = mapped
        }
        updateLoadWatches()
    }

    func isLive(_ sessionID: String) -> Bool {
        connections.contains { $0.sessionID == sessionID && $0.state.isRunning }
    }

    /// Double-click, Return, "Connect": brings the session's running tab to the
    /// front if there is one, and only otherwise opens another. `newTab` always
    /// opens another — a second shell on the same server is a normal thing to want.
    func connect(sessionID: String, in store: SessionStore, newTab: Bool = false) {
        // Not the tunnel connection, even shown as a tab: it has no shell.
        if !newTab, let existing = connections.first(where: {
            $0.sessionID == sessionID && $0.state.isRunning && !$0.isTunnelOnly
        }) {
            activeID = existing.id
            return
        }
        guard let session = store.session(sessionID) else { return }

        let connection = Connection(sessionID: sessionID, title: session.id,
                                    address: session.statusAddress,
                                    keyDescription: Self.keyDescription(for: session))
        add(connection)
        do {
            connection.start(try Self.launchPlan(for: session, in: store))
        } catch {
            connection.fail(String(describing: error))
        }
    }

    static func launchPlan(for session: Session, in store: SessionStore) throws -> SSHLaunchPlan {
        var plan = try SSHLaunch.plan(for: session, sessions: store.sessions)
        // Development hook: `-sb-ssh-prefix <file>` puts that file's ssh
        // options first — trust settings for a throwaway test server, so
        // a launched copy can connect to one without a host-key prompt.
        // Launch arguments only; they never persist.
        if let path = UserDefaults.standard.string(forKey: "sb-ssh-prefix"),
           let prefix = try? String(contentsOfFile: path, encoding: .utf8) {
            plan.config = prefix + "\n" + plan.config
        }
        return plan
    }

    /// "Save & reconnect": the session's tabs are closed and one fresh tab takes
    /// the first one's place — in its pane — running with the settings just saved.
    func reconnect(sessionID: String, in store: SessionStore) {
        let old = connections.filter { $0.sessionID == sessionID }
        let first = old.first
        let position = first.flatMap { first in tabs(in: first.pane).firstIndex { $0.id == first.id } }
        for connection in old { close(connection.id) }
        if let first { focusedPane = first.pane }
        connect(sessionID: sessionID, in: store, newTab: true)
        if let position, let fresh = connections.last {
            move(fresh.id, to: position)
        }
    }

    /// A session's name is its id, so a rename has to follow it into the tabs:
    /// otherwise they lose their group colour and stop counting as the
    /// session's live connection.
    func renameSession(from oldID: String, to newID: String) {
        guard oldID != newID else { return }
        for connection in connections where connection.sessionID == oldID {
            connection.sessionID = newID
            connection.title = newID
        }
    }

    /// A quick connection: an address and nothing else, not saved.
    func connect(address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let connection = Connection(sessionID: nil, title: trimmed, address: trimmed,
                                    keyDescription: "key: ssh default")
        add(connection)
        do {
            connection.start(try SSHLaunch.plan(forAddress: trimmed))
        } catch {
            connection.fail(String(describing: error))
        }
    }

    func close(_ id: UUID) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        let closing = connections[index]
        closing.close()
        detach(closing)
        updateLoadWatches()
        forgetForwards(ofClosed: closing)
    }

    // MARK: - Port forwarding (see ConnectionStore+Forwarding.swift)

    /// Each tunnel's state, per session, while port forwarding is on for it.
    var forwardStates: [String: [UUID: ForwardState]] = [:]
    /// What each session's port forwarding was started with, to start one
    /// of its tunnels again.
    var tunnelLaunches: [String: TunnelLaunch] = [:]
    /// One connection per running tunnel, ssh `-N` and no shell. Not tabs —
    /// until one needs the user, see `showTunnelConnection`.
    var tunnels: [Connection] = []

    /// Takes a tab out of the list. If it was in front in its pane, its
    /// neighbour there comes forward: the one on the right, as browsers do,
    /// else the one on the left.
    private func detach(_ tab: Connection) {
        let siblings = tabs(in: tab.pane)
        let position = siblings.firstIndex { $0.id == tab.id } ?? 0
        let wasInFront = active(in: tab.pane)?.id == tab.id
        connections.removeAll { $0.id == tab.id }
        guard wasInFront else { return }
        let rest = tabs(in: tab.pane)
        activeByPane[tab.pane] = rest.indices.contains(position) ? rest[position].id : rest.last?.id
    }

    /// Brings forward the tab `offset` places along from the one in front, in
    /// the focused pane, wrapping round at either end as Safari's tabs do.
    func showTab(offset: Int) {
        let tabs = tabs(in: focusedPane)
        guard tabs.count > 1, let front = active,
              let index = tabs.firstIndex(where: { $0.id == front.id }) else { return }
        let count = tabs.count
        activeID = tabs[((index + offset) % count + count) % count].id
    }

    /// Moves a tab along its pane's strip, to the slot it is dragged to.
    /// `index` counts that pane's tabs only.
    func move(_ id: UUID, to index: Int) {
        guard let moving = connections.first(where: { $0.id == id }) else { return }
        let siblings = tabs(in: moving.pane)
        guard let from = siblings.firstIndex(where: { $0.id == id }),
              siblings.indices.contains(index), from != index else { return }
        let target = siblings[index].id
        connections.removeAll { $0.id == id }
        guard let at = connections.firstIndex(where: { $0.id == target }) else { return }
        connections.insert(moving, at: from < index ? at + 1 : at)
    }

    /// Moves a tab into another pane, before that pane's tab at `index` or
    /// last, and brings it forward there: the pane takes the focus.
    func move(_ id: UUID, toPane pane: Int, at index: Int? = nil) {
        guard (0..<layout.paneCount).contains(pane),
              let moving = connections.first(where: { $0.id == id }) else { return }
        guard moving.pane != pane else {
            if let index { move(id, to: min(index, tabs(in: pane).count - 1)) }
            return
        }
        detach(moving)
        moving.pane = pane
        let target = tabs(in: pane)
        if let index, target.indices.contains(index),
           let at = connections.firstIndex(where: { $0.id == target[index].id }) {
            connections.insert(moving, at: at)
        } else {
            connections.append(moving)
        }
        activeID = id
    }

    /// A tab with ssh still running ends a session someone may be using; an
    /// exited one has nothing left to lose.
    func needsCloseConfirmation(_ id: UUID, setting: Bool) -> Bool {
        setting && connections.contains { $0.id == id && $0.state.isRunning }
    }

    var liveCount: Int { (connections + tunnels).filter(\.state.isRunning).count }

    func closeActive() {
        guard let id = active?.id else { return }
        close(id)
    }

    func closeAll() {
        for connection in connections + tunnels { connection.close() }
        connections.removeAll()
        tunnels.removeAll()
        forwardStates = [:]
        tunnelLaunches = [:]
        activeByPane = [:]
        updateLoadWatches()
    }

    /// Told when a tab's ssh has logged in to its server.
    @ObservationIgnored var onLogin: (@MainActor (Connection) -> Void)?

    func add(_ connection: Connection) {
        wire(connection)
        connection.onInput = { [weak self, weak connection] data in
            guard let self, let connection else { return }
            self.broadcast(data, from: connection)
        }
        connection.pane = focusedPane
        connections.append(connection)
        activeID = connection.id
    }

    /// How the tab logs in, for the status bar. The bare file name read as
    /// just another word ("termstead-lab" — a host? a user?), so it says "key".
    static func keyDescription(for session: Session) -> String {
        switch session.auth {
        case .password: "password"
        case .key:
            // An empty path leaves the choice to ssh: agent and default keys.
            session.keyPath.isEmpty ? "key: ssh default" : "key: " + (session.keyPath as NSString).lastPathComponent
        }
    }
}
