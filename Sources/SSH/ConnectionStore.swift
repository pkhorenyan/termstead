import Foundation
import Observation

/// The open tabs and which one is in front. Runtime only: nothing here is saved.
@MainActor
@Observable
final class ConnectionStore {
    private(set) var connections: [Connection] = []
    var activeID: UUID?

    var active: Connection? {
        connections.first { $0.id == activeID } ?? connections.first
    }

    func isLive(_ sessionID: String) -> Bool {
        connections.contains { $0.sessionID == sessionID && $0.state.isRunning }
    }

    /// Double-click, Return, "Connect": brings the session's running tab to the
    /// front if there is one, and only otherwise opens another. `newTab` always
    /// opens another — a second shell on the same server is a normal thing to want.
    func connect(sessionID: String, in store: SessionStore, newTab: Bool = false) {
        if !newTab, let existing = connections.first(where: { $0.sessionID == sessionID && $0.state.isRunning }) {
            activeID = existing.id
            return
        }
        guard let session = store.session(sessionID) else { return }

        let connection = Connection(sessionID: sessionID, title: session.id,
                                    address: session.statusAddress,
                                    keyDescription: Self.keyDescription(for: session))
        add(connection)
        do {
            var plan = try SSHLaunch.plan(for: session, sessions: store.sessions)
            // Development hook: `-sb-ssh-prefix <file>` puts that file's ssh
            // options first — trust settings for a throwaway test server, so
            // a launched copy can connect to one without a host-key prompt.
            // Launch arguments only; they never persist.
            if let path = UserDefaults.standard.string(forKey: "sb-ssh-prefix"),
               let prefix = try? String(contentsOfFile: path, encoding: .utf8) {
                plan.config = prefix + "\n" + plan.config
            }
            connection.start(plan)
        } catch {
            connection.fail(String(describing: error))
        }
    }

    /// "Save & reconnect": the session's tabs are closed and one fresh tab takes
    /// the first one's place, running with the settings just saved.
    func reconnect(sessionID: String, in store: SessionStore) {
        let old = connections.filter { $0.sessionID == sessionID }
        let position = old.first.flatMap { first in connections.firstIndex { $0.id == first.id } }
        for connection in old { close(connection.id) }
        connect(sessionID: sessionID, in: store, newTab: true)
        if let position, let fresh = connections.last, position < connections.count - 1 {
            connections.removeLast()
            connections.insert(fresh, at: position)
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
        connections[index].close()
        connections.remove(at: index)
        if activeID == id {
            // The neighbour on the right, as browsers do, else the one on the left.
            activeID = connections.indices.contains(index) ? connections[index].id : connections.last?.id
        }
    }

    /// A tab with ssh still running ends a session someone may be using; an
    /// exited one has nothing left to lose.
    func needsCloseConfirmation(_ id: UUID, setting: Bool) -> Bool {
        setting && connections.contains { $0.id == id && $0.state.isRunning }
    }

    var liveCount: Int { connections.filter(\.state.isRunning).count }

    func closeActive() {
        guard let id = active?.id else { return }
        close(id)
    }

    func closeAll() {
        for connection in connections { connection.close() }
        connections.removeAll()
        activeID = nil
    }

    /// Told when a tab's ssh has logged in to its server.
    @ObservationIgnored var onLogin: (@MainActor (Connection) -> Void)?

    func add(_ connection: Connection) {
        connection.onLogin = { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.onLogin?(connection)
        }
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
