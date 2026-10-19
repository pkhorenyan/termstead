import Foundation
import Testing
@testable import Termstead

/// The Docker test lab (`TestLab/lab.sh up`), connected to with the app's own
/// code and its own sample sessions. Skipped when the lab is not running.
///
/// This is where password authentication is covered: the local-sshd tests run
/// as the current user, who cannot check system passwords, while the lab's
/// user really has the password `lab`.
enum TestLab {
    static let isUp: Bool = {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(2202).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }()
}

@MainActor
@Suite(.serialized, .enabled(if: TestLab.isUp, "the Docker test lab is not running (TestLab/lab.sh up)"))
final class TestLabTests {
    private let directory: URL
    private let keychain = KeychainStore(service: "com.pavelkhorenyan.termstead.tests.\(UUID().uuidString)")
    private var accounts: [String] = []
    private let lab = SessionStore.testLab()

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("termstead-lab-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        for account in accounts { keychain.delete(account) }
        try? FileManager.default.removeItem(at: directory)
    }

    private var sessions: [String: Session] { Dictionary(uniqueKeysWithValues: lab.sessions.map { ($0.id, $0) }) }

    private func store(_ secret: String, for account: String) {
        keychain.set(secret, for: account)
        accounts.append(account)
    }

    /// The app's plan, with the test's own known_hosts on top so the real one
    /// is never touched. The agent is left out so only the chosen key is used.
    private func plan(_ id: String) throws -> SSHLaunchPlan {
        // Tunnels 20000 ports up, so a tab of the same session left open in
        // a running Termstead cannot hold the ports the test reads.
        var session = sessions[id]!
        session.forwards = session.forwards.map { forward in
            var moved = forward
            moved.listenPort = forward.listenPort.map { $0 + 20000 }
            return moved
        }
        var plan = try SSHLaunch.plan(for: session, sessions: sessions)
        plan.config = """
        Host *
          StrictHostKeyChecking accept-new
          UserKnownHostsFile \(directory.appendingPathComponent("known_hosts").path)
          IdentityAgent none

        """ + plan.config
        return plan
    }

    private func screen(_ connection: Connection) -> String {
        String(decoding: connection.terminalView.getTerminal().getBufferAsData(), as: UTF8.self)
    }

    /// Types the command every couple of seconds until its output shows up —
    /// input typed while ssh is still authenticating can be discarded.
    /// `then` runs on the live connection before it is closed.
    private func expectShell(on id: String, reaching host: String,
                             then: ((Connection) async throws -> Void)? = nil) async throws {
        let connection = Connection(sessionID: id, title: id, address: "", keyDescription: "",
                                    keychain: keychain)
        connection.start(try plan(id))
        defer { connection.close() }

        let marker = "SB_\(host)_OK"
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            connection.terminalView.send(txt: "echo SB_$(hostname)_OK\r")
            for _ in 0..<40 where !screen(connection).contains(marker) {
                try await Task.sleep(for: .milliseconds(50))
            }
            if screen(connection).contains(marker) { break }
        }
        #expect(screen(connection).contains(marker),
                "\(id) did not reach \(host). state=\(connection.state)\n\(screen(connection))")
        #expect(!screen(connection).contains("password:"), "\(id) asked for something on the terminal")
        if screen(connection).contains(marker), let then { try await then(connection) }
    }

    @Test func directWithAKey() async throws {
        try await expectShell(on: "lab-direct", reaching: "direct")
    }

    @Test func oneJumpNamedAfterASavedSession() async throws {
        try await expectShell(on: "lab-app-1-jump", reaching: "app")
    }

    @Test func twoJumps() async throws {
        try await expectShell(on: "lab-db-2-jumps", reaching: "db")
    }

    @Test func twoJumpsTypedOut() async throws {
        try await expectShell(on: "lab-db-2-jumps-typed", reaching: "db")
    }

    @Test func passwordFromTheKeychain() async throws {
        store("lab", for: SSHLaunch.sessionPasswordAccount("lab-direct-password"))
        try await expectShell(on: "lab-direct-password", reaching: "direct")
    }

    @Test func passwordsOnTheJumpHostAndTheTarget() async throws {
        let session = sessions["lab-app-password"]!
        store("lab", for: SSHLaunch.hopPasswordAccount(session.jumps[0].id))
        store("lab", for: SSHLaunch.sessionPasswordAccount(session.id))
        try await expectShell(on: "lab-app-password", reaching: "app")
    }

    @Test func passphraseFromTheKeychain() async throws {
        store("lab", for: SSHLaunch.passphraseAccount(forKey: "~/.ssh/termstead-lab-passphrase"))
        try await expectShell(on: "lab-direct-passphrase", reaching: "direct")
    }

    /// Local forwards through a jump host reach app's page and, resolved
    /// from app, middle's; the Files tab still joins the connection, its
    /// config untouched by the tunnels.
    @Test func localForwardThroughAJump() async throws {
        let store = ConnectionStore()
        let connection = try tab(in: store, tunnelsSession())
        defer { store.close(connection.id) }
        // Opened just after login, over the master.
        try await waitFor { await Self.get(28081).contains("Hello from middle") }
        #expect(await Self.get(28080).contains("Hello from app"))
        #expect(await Self.get(28081).contains("Hello from middle"))
        let client = try #require(connection.sftp)
        #expect(try await client.home() == "/home/lab")
    }

    /// A second tab of the session leaves the tunnels to the first, without
    /// "Address already in use", and takes them over when the first closes.
    @Test func aSecondTabLeavesTheTunnelsToTheFirst() async throws {
        let store = ConnectionStore()
        func open() throws -> Connection {
            let connection = Connection(sessionID: "lab-app-tunnels", title: "", address: "",
                                        keyDescription: "", keychain: keychain)
            store.add(connection)
            connection.start(try plan("lab-app-tunnels"))
            return connection
        }
        func page() async -> String {
            (try? await Self.exchange(port: 28080, sending: "GET / HTTP/1.0\r\n\r\n")) ?? ""
        }
        func waitFor(_ condition: () async -> Bool) async throws {
            for _ in 0..<200 where !(await condition()) { try await Task.sleep(for: .milliseconds(50)) }
        }

        let first = try open()
        defer { store.close(first.id) }
        try await waitFor { await page().contains("Hello from app") }
        #expect(first.holdsForwards)

        let second = try open()
        defer { store.close(second.id) }
        try await waitFor { screen(second).contains("lab@app") }
        #expect(screen(second).contains("lab@app"), "\(screen(second))")
        #expect(!second.holdsForwards)
        #expect(!screen(second).contains("Address already in use"), "\(screen(second))")

        store.close(first.id)
        try await waitFor {
            guard second.holdsForwards else { return false }
            return await page().contains("Hello from app")
        }
        #expect(second.holdsForwards, "\(screen(second))")
        let moved = await page()
        #expect(moved.contains("Hello from app"), "the tunnel did not move to the second tab")
    }

    // MARK: - Tunnels on a live connection

    private func tunnelsSession(_ change: (inout Session) -> Void = { _ in }) -> Session {
        var session = sessions["lab-app-tunnels"]!
        change(&session)
        return session
    }

    private static func get(_ port: UInt16) async -> String {
        (try? await exchange(port: port, sending: "GET / HTTP/1.0\r\n\r\n")) ?? ""
    }

    private func waitFor(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 where !(await condition()) { try await Task.sleep(for: .milliseconds(50)) }
    }

    private func tab(in store: ConnectionStore, _ session: Session) throws -> Connection {
        let connection = Connection(sessionID: session.id, title: "", address: "",
                                    keyDescription: "", keychain: keychain)
        store.add(connection)
        connection.start(try plan(session.id))
        return connection
    }

    /// A tunnel stops and starts on the live connection, the others untouched,
    /// and a stopped one stays down when another tab takes the tunnels over.
    @Test func aTunnelStopsAndStartsAgain() async throws {
        let store = ConnectionStore()
        let session = tunnelsSession()
        let web = session.forwards[0].id
        let first = try tab(in: store, session)
        defer { store.close(first.id) }
        try await waitFor { store.forwardState(web, of: session.id) == .running }
        #expect(await Self.get(28080).contains("Hello from app"))

        store.setForward(web, of: session.id, running: false)
        #expect(store.forwardState(web, of: session.id) == .stopped)
        try await waitFor { await Self.get(28080).isEmpty }
        #expect(await Self.get(28080).isEmpty, "the stopped tunnel still answers")
        #expect(await Self.get(28081).contains("Hello from middle"), "the other tunnels must stay up")

        store.setForward(web, of: session.id, running: true)
        try await waitFor { store.forwardState(web, of: session.id) == .running }
        #expect(await Self.get(28080).contains("Hello from app"))

        // Stopped again, then handed to a second tab: it stays stopped there.
        store.setForward(web, of: session.id, running: false)
        let second = try tab(in: store, session)
        defer { store.close(second.id) }
        try await waitFor { screen(second).contains("lab@app") }
        store.close(first.id)
        try await waitFor { store.forwardHolder(of: session.id) === second }
        try await waitFor { await Self.get(28081).contains("Hello from middle") }
        #expect(await Self.get(28081).contains("Hello from middle"))
        #expect(await Self.get(28080).isEmpty)
        #expect(store.forwardState(web, of: session.id) == .stopped)
    }

    /// Listens on 127.0.0.1 and ::1, as ssh does for "localhost". Retries
    /// while the previous test's ssh lets go of the port.
    private static func takePort(_ port: UInt16) async throws -> [Int32] {
        var sockets: [Int32] = []
        for family in [AF_INET, AF_INET6] {
            let fd = socket(family, SOCK_STREAM, 0)
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            if family == AF_INET6 {
                setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size))
            }
            var bound: Int32 = -1
            for _ in 0..<100 {
                if family == AF_INET {
                    var address = sockaddr_in()
                    address.sin_family = sa_family_t(AF_INET)
                    address.sin_port = port.bigEndian
                    address.sin_addr.s_addr = inet_addr("127.0.0.1")
                    bound = withUnsafePointer(to: &address) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                } else {
                    var address = sockaddr_in6()
                    address.sin6_family = sa_family_t(AF_INET6)
                    address.sin6_port = port.bigEndian
                    address.sin6_addr = in6addr_loopback
                    bound = withUnsafePointer(to: &address) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                        }
                    }
                }
                if bound == 0 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try #require(bound == 0 && listen(fd, 1) == 0, "could not take port \(port) for the test")
            sockets.append(fd)
        }
        return sockets
    }

    /// A port something else has is a failed tunnel with the reason, and the
    /// rest open regardless.
    @Test func aTakenPortIsReported() async throws {
        let blockers = try await Self.takePort(28080)
        defer { blockers.forEach { close($0) } }

        let store = ConnectionStore()
        let session = tunnelsSession()
        let connection = try tab(in: store, session)
        defer { store.close(connection.id) }
        let web = session.forwards[0].id, middle = session.forwards[1].id
        try await waitFor {
            if case .failed = store.forwardState(web, of: session.id) { return true }
            return false
        }
        #expect(store.forwardState(web, of: session.id) == .failed("Port 28080 is already in use on this Mac."))
        try await waitFor { store.forwardState(middle, of: session.id) == .running }
        #expect(await Self.get(28081).contains("Hello from middle"))
    }

    /// "Start Tunnels Only": the tunnels on a connection with no shell and no tab.
    @Test func tunnelsWithoutATab() async throws {
        let store = ConnectionStore()
        let session = tunnelsSession()
        let connection = try #require(store.startTunnels(for: session, plan: try plan(session.id),
                                                         keychain: keychain))
        defer { store.stopTunnels(sessionID: session.id) }
        try await waitFor { await Self.get(28080).contains("Hello from app") }
        #expect(await Self.get(28080).contains("Hello from app"))
        #expect(store.connections.isEmpty, "a tunnel-only connection became a tab")
        #expect(store.tunnels.first === connection)
        #expect(store.sessionsWithTunnels == [session.id])

        // A tab of the session now leaves the tunnels where they are.
        let terminal = try tab(in: store, session)
        defer { store.close(terminal.id) }
        try await waitFor { screen(terminal).contains("lab@app") }
        #expect(!terminal.holdsForwards)

        store.stopTunnels(sessionID: session.id)
        // ...and takes them over once the tunnel-only connection is gone.
        try await waitFor { store.forwardHolder(of: session.id) === terminal }
        try await waitFor { await Self.get(28080).contains("Hello from app") }
        #expect(await Self.get(28080).contains("Hello from app"))
    }

    /// "Start Tunnels Only" while a tab has the tunnels moves them over:
    /// the tab can then close and the tunnels stay.
    @Test func tunnelsMoveOutOfATab() async throws {
        let store = ConnectionStore()
        let session = tunnelsSession()
        let terminal = try tab(in: store, session)
        defer { store.close(terminal.id) }
        try await waitFor { store.forwardState(session.forwards[0].id, of: session.id) == .running }

        let background = try #require(store.startTunnels(for: session, plan: try plan(session.id),
                                                         keychain: keychain))
        defer { store.stopTunnels(sessionID: session.id) }
        try await waitFor { store.forwardHolder(of: session.id) === background }
        #expect(store.forwardHolder(of: session.id) === background)
        #expect(!terminal.holdsForwards)
        try await waitFor { store.forwardState(session.forwards[0].id, of: session.id) == .running }

        store.close(terminal.id)
        try await waitFor { await Self.get(28080).contains("Hello from app") }
        #expect(await Self.get(28080).contains("Hello from app"))
        #expect(store.connections.isEmpty)
    }

    /// The remote tunnel: a port on app that leads back through this Mac to
    /// direct's page (published on 127.0.0.1:2280).
    @Test func aRemoteTunnelLeadsBackHere() async throws {
        let store = ConnectionStore()
        let session = tunnelsSession()
        let connection = try tab(in: store, session)
        defer { store.close(connection.id) }
        try await waitFor { store.forwardState(session.forwards[3].id, of: session.id) == .running }
        #expect(store.forwardState(session.forwards[3].id, of: session.id) == .running)
        for _ in 0..<5 where !screen(connection).contains("Hello from direct") {
            connection.terminalView.send(txt: "wget -qO- localhost:29000 | grep h1\r")
            try await waitFor { screen(connection).contains("Hello from direct") }
        }
        #expect(screen(connection).contains("Hello from direct"), "\(screen(connection))")
    }

    /// A tunnel named in the user's own config is not opened behind
    /// Termstead's back: it could neither show it nor stop it.
    @Test func theConfigsOwnTunnelsAreCleared() async throws {
        let store = ConnectionStore()
        let connection = Connection(sessionID: "lab-direct", title: "", address: "",
                                    keyDescription: "", keychain: keychain)
        store.add(connection)
        defer { store.close(connection.id) }
        var withTunnel = try plan("lab-direct")
        withTunnel.config = "Host *\n  LocalForward 28090 localhost:80\n\n" + withTunnel.config
        connection.start(withTunnel)
        try await waitFor { connection.isLoggedIn }
        #expect(connection.isLoggedIn)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await Self.get(28090).isEmpty, "the config's LocalForward was opened")
    }

    /// Sends `request` to 127.0.0.1:`port` and reads the reply until the
    /// server closes the connection.
    private static func exchange(port: UInt16, sending request: String) async throws -> String {
        try await Task.detached {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(fd) }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
            _ = request.utf8CString.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count - 1) }
            var reply: [UInt8] = []
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(fd, &buffer, buffer.count)
                guard count > 0 else { break }
                reply += buffer.prefix(count)
            }
            return String(decoding: reply, as: UTF8.self)
        }.value
    }

    // MARK: - Files (the lab seeds each home folder; see TestLab/entrypoint.sh)

    /// The Files tab two jumps deep, over the terminal's connection.
    @Test func filesThroughTwoJumps() async throws {
        try await expectShell(on: "lab-db-2-jumps", reaching: "db") { connection in
            let client = try #require(connection.sftp)
            let home = try await client.list(try await client.home())
            #expect(home.path == "/home/lab")
            let names = Set(home.files.map(\.name))
            for expected in ["whoami.txt", "logs", "file with spaces.txt", "кириллица.txt",
                             "q\"uote [1] *.txt", "link-to-logs", "read-only.txt", "locked"] {
                #expect(names.contains(expected), "missing \(expected)")
            }

            // It really is db: the seeded file says so.
            let local = self.directory.appendingPathComponent("dl", isDirectory: true)
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            try await client.download("/home/lab/whoami.txt", recursive: false, to: local, as: "whoami.txt")
            #expect(try String(contentsOf: local.appendingPathComponent("whoami.txt"), encoding: .utf8)
                        .contains("on db"))

            // Symlinks: one to a folder, one to a file.
            #expect(await client.isDirectory("/home/lab/link-to-logs"))
            #expect(!(await client.isDirectory("/home/lab/link-to-nginx.conf")))

            // Refusals come back as readable messages.
            await #expect(throws: SFTPError.self) { try await client.list("/home/lab/locked") }
            let upload = local.appendingPathComponent("read-only.txt")
            try "overwrite".write(to: upload, atomically: true, encoding: .utf8)
            await #expect(throws: SFTPError.self) {
                try await client.replace("/home/lab/read-only.txt", with: upload)
            }

            // A round trip that leaves the home folder as it was.
            let note = local.appendingPathComponent("from termstead.txt")
            try "hello db".write(to: note, atomically: true, encoding: .utf8)
            try await client.upload(note, to: "/home/lab")
            #expect(try await client.list("/home/lab").files.contains { $0.name == "from termstead.txt" })
            try await client.removeFile("/home/lab/from termstead.txt")
        }
    }

    /// Passwords on the jump host and on the target: sftp needs neither again.
    @Test func filesWithPasswordsOnTheJumpHostAndTheTarget() async throws {
        let session = sessions["lab-app-password"]!
        store("lab", for: SSHLaunch.hopPasswordAccount(session.jumps[0].id))
        store("lab", for: SSHLaunch.sessionPasswordAccount(session.id))
        try await expectShell(on: "lab-app-password", reaching: "app") { connection in
            let client = try #require(connection.sftp)
            let listing = try await client.list("/home/lab/logs")
            let big = try #require(listing.files.first { $0.name == "big-20MB.bin" })
            #expect(big.size == Int64(20_971_520))
        }
    }

    /// `cd` in the terminal moves the SFTP panel along, two jumps deep.
    @Test func filesFollowTheTerminal() async throws {
        try await expectShell(on: "lab-db-2-jumps", reaching: "db") { connection in
            let client = try #require(connection.sftp)
            #expect(await client.terminalDirectory() == "/home/lab")

            let browser = connection.fileBrowser
            browser.followsTerminal = true
            browser.isShown = true
            browser.start()
            try await self.wait { browser.path == "/home/lab" }

            // Typed as the user would; the panel follows on Return.
            connection.terminalView.send(txt: "cd 'etc/nginx'\r")
            try await self.wait { browser.path == "/home/lab/etc/nginx" }
            #expect(browser.files.contains { $0.name == "nginx.conf" })

            // Switched off, it stays where it is.
            browser.followsTerminal = false
            connection.terminalView.send(txt: "cd /tmp\r")
            try await Task.sleep(for: .seconds(2))
            #expect(browser.path == "/home/lab/etc/nginx")
            #expect(await client.terminalDirectory() == "/tmp")
            browser.followsTerminal = true
            try await self.wait { browser.path == "/tmp" }
        }
    }

    /// The status bar's figures from a real Linux server, two jumps deep,
    /// over the terminal's own connection.
    @Test func serverLoadThroughTwoJumps() async throws {
        try await expectShell(on: "lab-db-2-jumps", reaching: "db") { connection in
            connection.watchesLoad = true
            try await self.wait { connection.serverLoad != nil }
            let load = try #require(connection.serverLoad)
            #expect(load.memoryTotal > 0 && load.memoryUsed <= load.memoryTotal)
            #expect(load.diskPercent != nil)
            #expect(load.loadAverage.count == 3)
            #expect(load.uptime > 0)
            // The share and the rates need the second block, one interval on.
            try await self.wait(timeout: TimeInterval(ServerLoadScript.interval) * 3) {
                connection.serverLoad?.cpu != nil
            }
            #expect(connection.serverLoad?.receiveRate != nil)
            #expect(!connection.loadIsUnsupported)

            connection.watchesLoad = false
            let stopped = connection.serverLoad
            try await Task.sleep(for: .seconds(ServerLoadScript.interval + 1))
            #expect(connection.serverLoad == stopped, "the watch went on after it was stopped")
        }
    }

    private func wait(timeout: TimeInterval = 10, _ condition: () -> Bool,
                      sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("condition not met in \(timeout) s", sourceLocation: sourceLocation)
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
