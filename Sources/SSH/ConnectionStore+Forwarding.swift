import Foundation

/// Where one of a session's tunnels stands on its tunnel connection.
enum ForwardState: Equatable, Sendable {
    /// Asked of ssh, no answer yet.
    case opening
    case running
    /// Stopped by hand. Stays down across a reconnect of the tunnel
    /// connection, until port forwarding is stopped for the session.
    case stopped
    /// ssh refused it; the reason, in the user's terms.
    case failed(String)
}

/// Port forwarding is an option of its own, as in MobaXterm: connecting to
/// a session opens a shell and nothing else. "Start Port Forwarding" runs
/// the session's tunnels on a connection of their own — ssh `-N`, no shell,
/// no tab — and asks its master for each tunnel once logged in, one
/// `ssh -O forward` each, so every tunnel gets its own answer: a port already
/// taken is a state here, not a warning scrolled past in a terminal.
extension ConnectionStore {
    /// Tabs and tunnel connections alike.
    var everyConnection: [Connection] { connections + tunnels }

    /// The callbacks every connection gets, tab or not.
    func wire(_ connection: Connection) {
        connection.onLogin = { [weak self, weak connection] in
            guard let self, let connection else { return }
            onLogin?(connection)
            if connection.isTunnelOnly { openForwards(on: connection) }
        }
    }

    /// The session's tunnel connection, running or not.
    func tunnelConnection(of sessionID: String) -> Connection? {
        everyConnection.first { $0.sessionID == sessionID && $0.isTunnelOnly }
    }

    /// The tunnel connection, once logged in: only then can tunnels be
    /// stopped and started on it.
    func forwardHolder(of sessionID: String) -> Connection? {
        tunnelConnection(of: sessionID).flatMap { $0.isLoggedIn ? $0 : nil }
    }

    /// Port forwarding is on for the session: its tunnel connection is up or
    /// on its way up.
    func isForwarding(_ sessionID: String) -> Bool {
        tunnelConnection(of: sessionID)?.state.isRunning ?? false
    }

    /// `nil` while nothing holds the tunnel — port forwarding is off, or the
    /// tunnel was added after it started.
    func forwardState(_ id: UUID, of sessionID: String) -> ForwardState? {
        guard let holder = forwardHolder(of: sessionID), holder.carriesForward(id) else { return nil }
        return forwardStates[sessionID]?[id]
    }

    /// Sessions with a tunnel connection, for the status bar.
    var sessionsWithTunnels: [String] {
        Array(Set(everyConnection.filter(\.isTunnelOnly).compactMap(\.sessionID)))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - Starting and stopping

    /// Starts port forwarding for the session. If ssh needs the user — a host
    /// key, a password not in the Keychain — or ends before logging in, the
    /// connection becomes a tab so the question or the error can be seen.
    func startTunnels(sessionID: String, in store: SessionStore) {
        guard let session = store.session(sessionID) else { return }
        let plan: SSHLaunchPlan
        do { plan = try Self.launchPlan(for: session, in: store) } catch {
            let failed = Connection(sessionID: sessionID, title: "\(session.id) — tunnels",
                                    address: session.statusAddress,
                                    keyDescription: Self.keyDescription(for: session), isTunnelOnly: true)
            add(failed)
            failed.fail(String(describing: error))
            return
        }
        startTunnels(for: session, plan: plan)
    }

    /// `plan` and `keychain` apart, for the tests: a known_hosts of their own.
    @discardableResult
    func startTunnels(for session: Session, plan: SSHLaunchPlan,
                      keychain: KeychainStore = .shared) -> Connection? {
        guard !session.forwards.isEmpty, !isForwarding(session.id) else { return nil }
        // One that ended is replaced, not reconnected: the settings may have
        // changed since.
        if let ended = tunnelConnection(of: session.id) { remove(ended, forgettingStops: false) }

        let connection = Connection(sessionID: session.id, title: "\(session.id) — tunnels",
                                    address: session.statusAddress,
                                    keyDescription: Self.keyDescription(for: session),
                                    keychain: keychain, isTunnelOnly: true)
        wire(connection)
        connection.onEnded = { [weak self, weak connection] in
            guard let self, let connection else { return }
            // Only the stops outlive the connection.
            if let session = connection.sessionID {
                forwardStates[session] = forwardStates[session]?.filter { $0.value == .stopped }
            }
            if !connection.didLogIn { showTunnelConnection(connection) }
        }
        tunnels.append(connection)
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

    /// Stops port forwarding for the session: its tunnel connection ends,
    /// tab or not, and every tunnel with it.
    func stopTunnels(sessionID: String) {
        guard let connection = tunnelConnection(of: sessionID) else { return }
        remove(connection, forgettingStops: true)
    }

    private func remove(_ connection: Connection, forgettingStops: Bool) {
        if connections.contains(where: { $0 === connection }) {
            close(connection.id)
        } else {
            connection.close()
            tunnels.removeAll { $0 === connection }
        }
        if forgettingStops, let session = connection.sessionID { forwardStates[session] = nil }
    }

    /// Moves a tunnel connection into the tab strip.
    func showTunnelConnection(_ connection: Connection) {
        guard tunnels.contains(where: { $0 === connection }) else { return }
        tunnels.removeAll { $0 === connection }
        add(connection)
    }

    /// A tab closed by hand may be the tunnel connection, shown because it
    /// needed the user: port forwarding stops with it.
    func forgetForwards(ofClosed closed: Connection) {
        guard closed.isTunnelOnly, let session = closed.sessionID else { return }
        forwardStates[session] = nil
    }

    // MARK: - Single tunnels

    func openForwards(on holder: Connection) {
        guard let session = holder.sessionID, let plan = holder.plan else { return }
        for forward in plan.forwards where forwardStates[session]?[forward.id] != .stopped {
            open(forward, on: holder, of: session)
        }
    }

    private func open(_ forward: SSHLaunchPlan.Forward, on holder: Connection, of session: String) {
        forwardStates[session, default: [:]][forward.id] = .opening
        holder.multiplex("forward", forward.arguments) { [weak self, weak holder] problem in
            // The answer is for this connection only; a newer one may hold
            // the tunnels by now.
            guard let self, let holder, holder === forwardHolder(of: session),
                  forwardStates[session]?[forward.id] == .opening else { return }
            forwardStates[session]?[forward.id] = problem.map { .failed(Self.explain($0, for: forward.forward)) } ?? .running
        }
    }

    /// Stops or starts one tunnel on the running tunnel connection. A failed
    /// tunnel "starts" by being asked for again.
    func setForward(_ id: UUID, of sessionID: String, running: Bool) {
        guard let holder = forwardHolder(of: sessionID),
              let forward = holder.plan?.forwards.first(where: { $0.id == id }) else { return }
        if running {
            open(forward, on: holder, of: sessionID)
            return
        }
        let state = forwardStates[sessionID]?[id]
        guard state != .stopped else { return }
        forwardStates[sessionID, default: [:]][id] = .stopped
        // A failed tunnel has nothing to cancel.
        guard state == .running || state == .opening else { return }
        holder.multiplex("cancel", forward.arguments) { [weak self] problem in
            guard let self, let problem else { return }
            forwardStates[sessionID]?[id] = .failed("Could not stop it: \(Self.lastLine(problem))")
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
