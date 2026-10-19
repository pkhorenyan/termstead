import Foundation

/// Where one of a session's tunnels stands while port forwarding is on.
enum ForwardState: Equatable, Sendable {
    /// Its connection is logging in, or ssh has been asked for the tunnel.
    case opening
    case running
    /// Stopped by hand: its connection, and every connection through it, is gone.
    case stopped
    /// ssh refused it, or its connection ended; the reason, in the user's terms.
    case failed(String)
}

/// A session's port forwarding at a glance, for the mark on its sidebar row.
struct ForwardingSummary: Equatable, Sendable {
    var running: Int
    var total: Int
    var failed: Bool

    var description: String {
        let count = "\(running) of \(total) tunnel\(total == 1 ? "" : "s") running"
        return failed ? "Port forwarding: \(count), one failed" : "Port forwarding: \(count)"
    }
}

/// What a session's port forwarding was started with. Kept so that one
/// stopped tunnel can be started again on the same terms.
struct TunnelLaunch {
    var session: Session
    var plan: SSHLaunchPlan
    var keychain: KeychainStore
}

/// Port forwarding is an option of its own, as in MobaXterm: connecting to
/// a session opens a shell and nothing else. "Start Port Forwarding" gives
/// each of the session's tunnels a connection of its own — ssh `-N`, no
/// shell, no tab.
///
/// One connection per tunnel, not one for all: `ssh -O cancel` closes only a
/// tunnel's listener, and every connection already open through it — a
/// browser's keep-alive, a psql session — lived on in the shared ssh after
/// Stop. Ending the tunnel's own ssh ends all of them. The price is a login
/// per tunnel.
///
/// Each connection asks its master for its tunnel once logged in
/// (`ssh -O forward`) rather than taking it on the command line, so a port
/// already taken is a state with a reason here, not a warning scrolled past
/// in a terminal nobody sees.
extension ConnectionStore {
    /// Tabs and tunnel connections alike.
    var everyConnection: [Connection] { connections + tunnels }

    /// The callbacks every connection gets, tab or not.
    func wire(_ connection: Connection) {
        connection.onLogin = { [weak self, weak connection] in
            guard let self, let connection else { return }
            onLogin?(connection)
            if connection.isTunnelOnly { openForward(on: connection) }
        }
    }

    // MARK: - Reading

    /// Port forwarding is on for the session: started and not stopped as a
    /// whole, even if each of its tunnels has been stopped or has failed.
    func isForwarding(_ sessionID: String) -> Bool {
        forwardStates[sessionID] != nil
    }

    /// `nil` while port forwarding is off for the session, or for a tunnel
    /// added after it started.
    func forwardState(_ id: UUID, of sessionID: String) -> ForwardState? {
        forwardStates[sessionID]?[id]
    }

    /// The tunnel as port forwarding started it, to tell an edit since.
    func launchedForward(_ id: UUID, of sessionID: String) -> PortForward? {
        tunnelLaunches[sessionID]?.plan.forwards.first { $0.id == id }?.forward
    }

    /// The tunnels port forwarding started for the session, in order.
    func launchedForwards(of sessionID: String) -> [PortForward] {
        tunnelLaunches[sessionID]?.plan.forwards.map(\.forward) ?? []
    }

    /// The connection carrying one tunnel, tab or not.
    func tunnelConnection(of sessionID: String, forward id: UUID) -> Connection? {
        everyConnection.first {
            $0.isTunnelOnly && $0.sessionID == sessionID && $0.plan?.forwards.first?.id == id
        }
    }

    /// `nil` while port forwarding is off for the session.
    func forwardingSummary(of sessionID: String) -> ForwardingSummary? {
        guard let states = forwardStates[sessionID] else { return nil }
        let failed = states.values.contains { if case .failed = $0 { true } else { false } }
        return ForwardingSummary(running: states.values.filter { $0 == .running }.count,
                                 total: launchedForwards(of: sessionID).count, failed: failed)
    }

    /// Sessions with port forwarding on, for the status bar.
    var sessionsWithTunnels: [String] {
        forwardStates.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - The session's port forwarding

    /// Starts port forwarding for the session: a connection for each tunnel
    /// not already running.
    func startTunnels(sessionID: String, in store: SessionStore) {
        guard let session = store.session(sessionID) else { return }
        do {
            startTunnels(for: session, plan: try Self.launchPlan(for: session, in: store))
        } catch {
            // An address or a tunnel that cannot be used: said in a tab, as
            // a connection that fails to start is.
            let failed = Connection(sessionID: sessionID, title: "\(session.id) — tunnels",
                                    address: session.statusAddress,
                                    keyDescription: Self.keyDescription(for: session))
            add(failed)
            failed.fail(String(describing: error))
        }
    }

    /// `plan` and `keychain` apart, for the tests: a known_hosts of their own.
    @discardableResult
    func startTunnels(for session: Session, plan: SSHLaunchPlan,
                      keychain: KeychainStore = .shared) -> [Connection] {
        guard !plan.forwards.isEmpty else { return [] }
        let launch = TunnelLaunch(session: session, plan: plan, keychain: keychain)
        tunnelLaunches[session.id] = launch
        if forwardStates[session.id] == nil { forwardStates[session.id] = [:] }
        return plan.forwards.compactMap { forward in
            switch forwardStates[session.id]?[forward.id] {
            case .opening?, .running?: nil
            default: startTunnel(forward, of: launch)
            }
        }
    }

    /// Stops port forwarding for the session: every tunnel's connection
    /// ends, tab or not, and every connection through them.
    func stopTunnels(sessionID: String) {
        forwardStates[sessionID] = nil
        tunnelLaunches[sessionID] = nil
        for connection in everyConnection where connection.isTunnelOnly && connection.sessionID == sessionID {
            drop(connection)
        }
    }

    // MARK: - Single tunnels

    /// Starts or stops one tunnel. Stopping ends its connection, so the
    /// connections already open through it close too; starting makes a new one.
    func setForward(_ id: UUID, of sessionID: String, running: Bool) {
        guard let launch = tunnelLaunches[sessionID],
              let forward = launch.plan.forwards.first(where: { $0.id == id }) else { return }
        if running {
            if let old = tunnelConnection(of: sessionID, forward: id) { drop(old) }
            startTunnel(forward, of: launch)
        } else {
            forwardStates[sessionID]?[id] = .stopped
            if let connection = tunnelConnection(of: sessionID, forward: id) { drop(connection) }
        }
    }

    @discardableResult
    private func startTunnel(_ forward: SSHLaunchPlan.Forward, of launch: TunnelLaunch) -> Connection {
        let sessionID = launch.session.id
        var plan = launch.plan
        plan.forwards = [forward]
        let connection = Connection(sessionID: sessionID,
                                    title: Self.tunnelTitle(sessionID, forward.forward),
                                    address: launch.session.statusAddress,
                                    keyDescription: Self.keyDescription(for: launch.session),
                                    keychain: launch.keychain, isTunnelOnly: true)
        wire(connection)
        // The session's name at the time, not now: it may be renamed meanwhile.
        connection.onEnded = { [weak self, weak connection] in
            guard let self, let connection, let sessionID = connection.sessionID else { return }
            ended(connection, forward: forward.id, of: sessionID)
        }
        tunnels.append(connection)
        forwardStates[sessionID]?[forward.id] = .opening
        connection.start(plan)
        // Long enough for a key or a stored password through two jump hosts;
        // anything slower is most likely a question on the terminal.
        Task { [weak self, weak connection] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, let connection, !connection.isLoggedIn, connection.state.isRunning else { return }
            showTunnelConnection(connection)
        }
        return connection
    }

    /// Logged in: ask the master for the tunnel. A refusal ends the
    /// connection — there is no use keeping a login for a tunnel that is not.
    private func openForward(on connection: Connection) {
        guard let sessionID = connection.sessionID, let forward = connection.plan?.forwards.first else { return }
        connection.multiplex("forward", forward.arguments) { [weak self, weak connection] problem in
            guard let self, let connection, everyConnection.contains(where: { $0 === connection }),
                  forwardStates[sessionID]?[forward.id] == .opening else { return }
            if let problem {
                forwardStates[sessionID]?[forward.id] = .failed(Self.explain(problem, for: forward.forward))
                drop(connection)
            } else {
                forwardStates[sessionID]?[forward.id] = .running
            }
        }
    }

    /// ssh ended by itself. Before login the connection becomes a tab, so the
    /// error or the question it stopped at can be read there.
    private func ended(_ connection: Connection, forward id: UUID, of sessionID: String) {
        // Closed by Termstead: whoever closed it has set the state already.
        guard everyConnection.contains(where: { $0 === connection }) else { return }
        guard connection.didLogIn else {
            forwardStates[sessionID]?[id] = .failed("Could not log in: its tab says why.")
            showTunnelConnection(connection)
            return
        }
        forwardStates[sessionID]?[id] = .failed("The connection closed.")
        tunnels.removeAll { $0 === connection }
    }

    /// Ends a tunnel connection, in the tab strip or not.
    private func drop(_ connection: Connection) {
        if connections.contains(where: { $0 === connection }) {
            close(connection.id)
        } else {
            tunnels.removeAll { $0 === connection }
            connection.close()
        }
    }

    /// A session renamed while forwarding: its tunnels, their states and
    /// what they started with follow the new name, or the menu would offer
    /// to start them again over the running ones.
    func renameTunnels(from oldID: String, to newID: String) {
        for connection in everyConnection where connection.isTunnelOnly && connection.sessionID == oldID {
            connection.sessionID = newID
            if let forward = connection.plan?.forwards.first {
                connection.title = Self.tunnelTitle(newID, forward.forward)
            }
        }
        if let states = forwardStates.removeValue(forKey: oldID) { forwardStates[newID] = states }
        if var launch = tunnelLaunches.removeValue(forKey: oldID) {
            launch.session.id = newID
            tunnelLaunches[newID] = launch
        }
    }

    static func tunnelTitle(_ sessionID: String, _ forward: PortForward) -> String {
        "\(sessionID) — \(forward.summary)"
    }

    /// Moves a tunnel connection into the tab strip.
    func showTunnelConnection(_ connection: Connection) {
        guard tunnels.contains(where: { $0 === connection }) else { return }
        tunnels.removeAll { $0 === connection }
        add(connection)
    }

    /// A tunnel connection shown as a tab and closed by hand: that tunnel
    /// stops. A state set before the close (a refusal, a stop) stays.
    func forgetForwards(ofClosed closed: Connection) {
        guard closed.isTunnelOnly, let sessionID = closed.sessionID,
              let id = closed.plan?.forwards.first?.id else { return }
        switch forwardStates[sessionID]?[id] {
        case .opening?, .running?: forwardStates[sessionID]?[id] = .stopped
        default: break
        }
    }

    // MARK: - Menus

    /// "Start Port Forwarding" or "Stop Port Forwarding" for a session's
    /// context menu; nothing for a session with no tunnels.
    func forwardingMenuItems(for session: Session, in store: SessionStore) -> [(title: String, run: () -> Void)] {
        guard !session.forwards.isEmpty else { return [] }
        if isForwarding(session.id) {
            return [("Stop Port Forwarding", { [weak self] in self?.stopTunnels(sessionID: session.id) })]
        }
        return [("Start Port Forwarding", { [weak self, weak store] in
            guard let self, let store else { return }
            startTunnels(sessionID: session.id, in: store)
        })]
    }

    // MARK: - Messages

    /// ssh's refusal says only that forwarding failed. For a port on this
    /// Mac the reason is almost always that something else has it.
    nonisolated static func explain(_ stderr: String, for forward: PortForward) -> String {
        guard stderr.contains("forwarding request failed") || stderr.contains("forwarding failed") else {
            return lastLine(stderr)
        }
        let port = forward.listenPort.map(String.init) ?? "?"
        switch forward.kind {
        case .local, .dynamic:
            return "Port \(port) is already in use on this Mac."
        case .remote:
            return "The server would not listen on port \(port): it is taken there, or not allowed."
        }
    }

    nonisolated static func lastLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).last.map(String.init) ?? "ssh refused."
    }
}
