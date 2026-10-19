import Foundation

/// Where one of a session's tunnels stands on its live connection.
enum ForwardState: Equatable, Sendable {
    /// Asked of ssh, no answer yet.
    case opening
    case running
    /// Stopped by hand. Stays down when another tab takes the tunnels over,
    /// until the session's last connection closes.
    case stopped
    /// ssh refused it; the reason, in the user's terms.
    case failed(String)
}

/// A session's tunnels belong to one of its connections at a time, the
/// holder: a tab, or a tunnel-only connection with no shell. The holder opens
/// them over its connection master once it is logged in, one `ssh -O forward`
/// each, so every tunnel gets its own answer — a port already taken is a
/// state here, not a warning scrolled past in the terminal.
extension ConnectionStore {
    /// Tabs and tunnel-only connections alike.
    var everyConnection: [Connection] { connections + tunnels }

    /// The callbacks every connection gets, tab or not.
    func wire(_ connection: Connection) {
        connection.onLogin = { [weak self, weak connection] in
            guard let self, let connection else { return }
            onLogin?(connection)
            if connection.holdsForwards || connection.claimForwards() {
                openForwards(on: connection)
            } else if connection.isTunnelOnly {
                takeForwards(to: connection)
            }
        }
        connection.mayForward = { [weak self] asking in
            guard let self, let session = asking.sessionID else { return true }
            return !everyConnection.contains { $0 !== asking && $0.sessionID == session && $0.holdsForwards }
        }
        connection.onForwardsReleased = { [weak self, weak connection] in
            guard let self, let connection, let session = connection.sessionID else { return }
            handOverForwards(of: session, from: connection)
        }
    }

    /// The connection whose ssh has the session's tunnels, once logged in:
    /// only then can they be stopped and started.
    func forwardHolder(of sessionID: String) -> Connection? {
        everyConnection.first { $0.sessionID == sessionID && $0.holdsForwards && $0.isLoggedIn }
    }

    /// `nil` while nothing holds the tunnel — the session is not connected,
    /// or the tunnel was added after it connected.
    func forwardState(_ id: UUID, of sessionID: String) -> ForwardState? {
        guard let holder = forwardHolder(of: sessionID), holder.carriesForward(id) else { return nil }
        return forwardStates[sessionID]?[id]
    }

    /// Sessions with tunnels on a live connection, for the status bar.
    var sessionsWithTunnels: [String] {
        let ids = everyConnection.compactMap { connection -> String? in
            guard let id = connection.sessionID, connection.holdsForwards else { return nil }
            return id
        } + tunnels.compactMap(\.sessionID)
        return Array(Set(ids)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - Opening and closing

    func openForwards(on holder: Connection) {
        guard let session = holder.sessionID, let plan = holder.plan else { return }
        for forward in plan.forwards where forwardStates[session]?[forward.id] != .stopped {
            open(forward, on: holder, of: session)
        }
    }

    private func open(_ forward: SSHLaunchPlan.Forward, on holder: Connection, of session: String) {
        forwardStates[session, default: [:]][forward.id] = .opening
        holder.multiplex("forward", forward.arguments) { [weak self, weak holder] problem in
            // The answer is for this holder only; another may have the
            // tunnels by now.
            guard let self, let holder, holder.holdsForwards,
                  forwardStates[session]?[forward.id] == .opening else { return }
            forwardStates[session]?[forward.id] = problem.map { .failed(Self.explain($0, for: forward.forward)) } ?? .running
        }
    }

    /// Stops or starts one tunnel on the connection that holds it. A failed
    /// tunnel "starts" by being asked for again.
    func setForward(_ id: UUID, of sessionID: String, running: Bool) {
        guard let holder = forwardHolder(of: sessionID),
              let forward = holder.plan?.forwards.first(where: { $0.id == id }) else { return }
        if running {
            open(forward, on: holder, of: sessionID)
            return
        }
        // A failed tunnel has nothing to cancel.
        guard forwardStates[sessionID]?[id] != .stopped else { return }
        let wasOpen = forwardStates[sessionID]?[id] == .running || forwardStates[sessionID]?[id] == .opening
        forwardStates[sessionID, default: [:]][id] = .stopped
        guard wasOpen else { return }
        holder.multiplex("cancel", forward.arguments) { [weak self] problem in
            guard let self, let problem else { return }
            forwardStates[sessionID]?[id] = .failed("Could not stop it: \(Self.lastLine(problem))")
        }
    }

    /// Every tunnel of the session at once, for the menus.
    func setAllForwards(of sessionID: String, running: Bool) {
        guard let holder = forwardHolder(of: sessionID) else { return }
        for forward in holder.plan?.forwards ?? [] where (forwardStates[sessionID]?[forward.id] == .running) != running {
            setForward(forward.id, of: sessionID, running: running)
        }
    }

    /// "Start Tunnels Only" while a tab has the tunnels: the tab closes its
    /// own, and once ssh has let go of the ports the tunnel-only connection
    /// opens them, so the tab can be closed without taking them along.
    private func takeForwards(to taker: Connection) {
        guard let session = taker.sessionID,
              let old = everyConnection.first(where: { $0 !== taker && $0.sessionID == session && $0.holdsForwards })
        else { return }
        old.giveUpForwards()
        let open = (old.plan?.forwards ?? []).filter {
            let state = forwardStates[session]?[$0.id]
            return state == .running || state == .opening
        }
        var pending = open.count
        let finish = { [weak self, weak taker] in
            guard let self, let taker, taker.claimForwards() else { return }
            openForwards(on: taker)
        }
        guard pending > 0 else { return finish() }
        for forward in open {
            old.multiplex("cancel", forward.arguments) { _ in
                pending -= 1
                if pending == 0 { finish() }
            }
        }
    }

    /// The holder is gone: its tunnels close with its ssh. Another of the
    /// session's connections, already logged in, takes them over; one still
    /// logging in takes them when it is in (`wire`).
    private func handOverForwards(of session: String, from old: Connection) {
        // Only the stops outlive the holder.
        forwardStates[session] = forwardStates[session]?.filter { $0.value == .stopped }
        for other in everyConnection where other !== old && other.sessionID == session {
            if other.claimForwards() {
                openForwards(on: other)
                return
            }
        }
    }

    /// A stop lasts while the session has a connection; the next one opens
    /// every tunnel again.
    func forgetForwards(ofClosed closed: Connection) {
        guard let session = closed.sessionID,
              !everyConnection.contains(where: { $0 !== closed && $0.sessionID == session }) else { return }
        forwardStates[session] = nil
    }

    // MARK: - Tunnels without a shell

    /// The session's tunnels on a connection of their own, ssh `-N`, with no
    /// tab. If ssh needs the user — a host key, a password not in the
    /// Keychain — or ends before logging in, the connection becomes a tab so
    /// the question or the error can be seen.
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
        let sessionID = session.id
        guard !session.forwards.isEmpty, !tunnels.contains(where: { $0.sessionID == sessionID }) else { return nil }
        let connection = Connection(sessionID: sessionID, title: "\(session.id) — tunnels",
                                    address: session.statusAddress,
                                    keyDescription: Self.keyDescription(for: session),
                                    keychain: keychain, isTunnelOnly: true)
        wire(connection)
        connection.onEnded = { [weak self, weak connection] in
            guard let self, let connection, !connection.didLogIn else { return }
            showTunnelConnection(connection)
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

    /// Moves a tunnel-only connection into the tab strip.
    func showTunnelConnection(_ connection: Connection) {
        guard tunnels.contains(where: { $0 === connection }) else { return }
        tunnels.removeAll { $0 === connection }
        add(connection)
    }

    /// Ends the session's tunnel-only connections.
    func stopTunnels(sessionID: String) {
        for connection in tunnels where connection.sessionID == sessionID {
            connection.close()
            tunnels.removeAll { $0 === connection }
            forgetForwards(ofClosed: connection)
        }
    }

    // MARK: - Menus

    /// The session's tunnel commands for a context menu: stop or start them
    /// on the live connection, run them with no shell, or end that.
    func forwardingMenuItems(for session: Session, in store: SessionStore) -> [(title: String, run: () -> Void)] {
        guard !session.forwards.isEmpty else { return [] }
        var items: [(title: String, run: () -> Void)] = []
        if forwardHolder(of: session.id) != nil {
            let states = session.forwards.compactMap { forwardState($0.id, of: session.id) }
            if !states.isEmpty {
                let anyRunning = states.contains { $0 == .running || $0 == .opening }
                items.append((anyRunning ? "Stop Port Forwarding" : "Start Port Forwarding",
                              { self.setAllForwards(of: session.id, running: !anyRunning) }))
            }
        }
        // Also while a tab has them: they move over, and the tab can close.
        if !tunnels.contains(where: { $0.sessionID == session.id }) {
            items.append(("Start Tunnels Only", { [weak self, weak store] in
                guard let self, let store else { return }
                startTunnels(sessionID: session.id, in: store)
            }))
        }
        if tunnels.contains(where: { $0.sessionID == session.id }) {
            items.append(("Disconnect Tunnels", { self.stopTunnels(sessionID: session.id) }))
        }
        return items
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
