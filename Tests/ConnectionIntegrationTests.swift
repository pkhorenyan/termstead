import Foundation
import Testing
@testable import Termstead

/// A real connection end to end: the app's own `SSHLaunch` plan, written to a
/// config file, run by `/usr/bin/ssh` in SwiftTerm's pseudo-terminal, against
/// an sshd this test starts on 127.0.0.1 as the current user.
///
/// A non-root sshd cannot check system passwords, so this covers key
/// authentication only. It goes through a jump host — the same server again,
/// which also exercises the alias given to a host that appears twice.
@MainActor
@Suite(.serialized)
final class ConnectionIntegrationTests {
    private let directory: URL
    private var sshd: Process?
    private var port = 0
    /// A Keychain service of this test's own, emptied afterwards.
    private let keychain = KeychainStore(service: "com.pavelkhorenyan.termstead.tests.\(UUID().uuidString)")
    private var keychainAccounts: [String] = []

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("termstead-sshd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    deinit {
        sshd?.terminate()
        for account in keychainAccounts { keychain.delete(account) }
        try? FileManager.default.removeItem(at: directory)
    }

    private func path(_ name: String) -> String { directory.appendingPathComponent(name).path }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func startServer(passphrase: String = "", sftp: Bool = true) async throws {
        try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", path("hostkey")])
        try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", passphrase, "-C", "termstead-test", "-f", path("clientkey")])
        try FileManager.default.copyItem(atPath: path("clientkey.pub"), toPath: path("authorized_keys"))

        // Ports are tried until sshd stays up: another process may hold one.
        for candidate in (0..<20).map({ _ in Int.random(in: 30000...60000) }) {
            let config = """
            ListenAddress 127.0.0.1
            Port \(candidate)
            HostKey \(path("hostkey"))
            PidFile \(path("sshd.pid"))
            AuthorizedKeysFile \(path("authorized_keys"))
            UsePAM no
            StrictModes no
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            \(sftp ? "Subsystem sftp /usr/libexec/sftp-server" : "")
            """
            try config.write(toFile: path("sshd_config"), atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
            process.arguments = ["-D", "-f", path("sshd_config"), "-E", path("sshd.log")]
            try process.run()
            try? await Task.sleep(for: .seconds(1))
            if process.isRunning {
                sshd = process
                port = candidate
                return
            }
        }
        throw CocoaError(.featureUnsupported)
    }

    /// Waits by suspending, not by spinning the run loop: SwiftTerm delivers
    /// on the main queue, and a main-actor test that spins inside its own job
    /// never lets those blocks run.
    private func awaitCondition(timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// The test's trust settings, on top of the app's config. First values
    /// win, so these go first. The target runs a plain `/bin/sh`: the "remote"
    /// is this Mac's own account, and the user's interactive shell setup (a
    /// heavy zsh prompt, here) made typed commands depend on timing.
    private func testConfig(_ plan: SSHLaunchPlan, batch: Bool) -> SSHLaunchPlan {
        var plan = plan
        plan.config = """
        Host \(plan.target.alias)
          RemoteCommand /bin/sh -i
          RequestTTY yes

        Host *
          StrictHostKeyChecking accept-new
          UserKnownHostsFile \(path("known_hosts"))
          IdentityAgent none
          BatchMode \(batch ? "yes" : "no")

        """ + plan.config
        return plan
    }

    private func directSession() -> Session {
        Session(id: "itest", user: NSUserName(), host: "127.0.0.1", port: port, icon: .server,
                auth: .key, keyPath: path("clientkey"))
    }

    private func store(_ secret: String, for account: String) {
        keychain.set(secret, for: account)
        keychainAccounts.append(account)
    }

    /// Waits for `text` on screen and records the screen if it never comes.
    private func expectScreen(_ connection: Connection, contains text: String,
                              timeout: TimeInterval = 20,
                              sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        do {
            try await awaitCondition(timeout: timeout) { screen(connection).contains(text) }
            return true
        } catch {
            Issue.record("“\(text)” never appeared. state=\(connection.state)\n\(screen(connection))",
                         sourceLocation: sourceLocation)
            return false
        }
    }

    /// Types `command` every couple of seconds until `marker` shows up. Input
    /// typed while ssh is still authenticating can be discarded — reading a
    /// passphrase flushes type-ahead, as ssh's own prompt does — so a single
    /// send would make the test depend on timing.
    private func run(_ command: String, in connection: Connection, until marker: String,
                     sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            connection.terminalView.send(txt: command + "\r")
            if (try? await awaitCondition(timeout: 2, { screen(connection).contains(marker) })) != nil {
                return true
            }
        }
        Issue.record("“\(marker)” never appeared. state=\(connection.state)\n\(screen(connection))",
                     sourceLocation: sourceLocation)
        return false
    }

    private func screen(_ connection: Connection) -> String {
        String(decoding: connection.terminalView.getTerminal().getBufferAsData(), as: UTF8.self)
    }

    @Test func keySessionThroughAJumpHost() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd"))
        try await startServer()

        let user = NSUserName()
        let hop = JumpHost(host: "\(user)@127.0.0.1:\(port)", auth: .key, keyPath: path("clientkey"))
        let session = Session(id: "itest", user: user, host: "127.0.0.1", port: port, icon: .server,
                              auth: .key, keyPath: path("clientkey"), jumps: [hop])
        let plan = try testConfig(SSHLaunch.plan(for: session, sessions: [:]), batch: true)
        #expect(plan.target.alias == "termstead-target")

        let connection = Connection(sessionID: session.id, title: session.id,
                                    address: session.statusAddress, keyDescription: "clientkey",
                                    keychain: keychain)
        connection.start(plan)
        defer { connection.close() }

        // The marker is computed remotely, so the echo of the typed command
        // cannot satisfy the check by itself.
        guard await run("echo TERMSTEAD_$((6*7))_OK", in: connection, until: "TERMSTEAD_42_OK") else { return }
        #expect(connection.state == .running)

        connection.terminalView.send(txt: "exit\r")
        guard await expectScreen(connection, contains: "Press Return to reconnect", timeout: 10) else { return }
        #expect(connection.state == .exited(code: 0))

        // Return on the closed tab starts it again.
        connection.terminalView.send(txt: "\r")
        #expect(connection.state.isRunning)
        _ = await run("echo TERMSTEAD_$((7*8))_AGAIN", in: connection, until: "TERMSTEAD_56_AGAIN")
    }

    @Test func passphraseComesFromTheKeychain() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd"))
        try await startServer(passphrase: "correct horse")
        store("correct horse", for: SSHLaunch.passphraseAccount(forKey: path("clientkey")))

        let session = directSession()
        let plan = try testConfig(SSHLaunch.plan(for: session, sessions: [:]), batch: false)
        let connection = Connection(sessionID: session.id, title: session.id, address: "",
                                    keyDescription: "", keychain: keychain)
        connection.start(plan)
        defer { connection.close() }

        guard await run("echo TERMSTEAD_$((3*3))_KEYCHAIN", in: connection, until: "TERMSTEAD_9_KEYCHAIN") else { return }
        // Nothing was asked on the terminal.
        #expect(!screen(connection).contains("Enter passphrase"))
    }

    @Test func aRefusedStoredPassphraseFallsBackToTheTerminal() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd"))
        try await startServer(passphrase: "correct horse")
        store("wrong horse", for: SSHLaunch.passphraseAccount(forKey: path("clientkey")))

        let session = directSession()
        let plan = try testConfig(SSHLaunch.plan(for: session, sessions: [:]), batch: false)
        let connection = Connection(sessionID: session.id, title: session.id, address: "",
                                    keyDescription: "", keychain: keychain)
        connection.start(plan)
        defer { connection.close() }

        // The stored value is tried once; the retry is asked on the terminal.
        guard await expectScreen(connection, contains: "Enter passphrase for key") else { return }
        connection.terminalView.send(txt: "correct horse\r")
        guard await run("echo TERMSTEAD_$((4*4))_TYPED", in: connection, until: "TERMSTEAD_16_TYPED") else { return }
        // Typed input is not echoed while a secret is asked for.
        #expect(!screen(connection).contains("correct horse"))
    }

    /// A tab in a store whose logins are reported, the way `MainView` wires
    /// them to the sidebar.
    private func loggingIn(_ session: Session) throws
        -> (Connection, AppState, ConnectionStore, LoginLog) {
        let plan = try testConfig(SSHLaunch.plan(for: session, sessions: [:]), batch: false)
        let connection = Connection(sessionID: session.id, title: session.id, address: "",
                                    keyDescription: "", keychain: keychain)
        let store = ConnectionStore()
        let appState = AppState()
        let log = LoginLog()
        store.onLogin = { connection in
            log.logins += 1
            Task {
                await appState.showFiles(afterLoginOf: connection, in: store)
                log.handled += 1
            }
        }
        store.add(connection)
        connection.start(plan)
        return (connection, appState, store, log)
    }

    @MainActor final class LoginLog {
        var logins = 0
        var handled = 0
    }

    /// The sidebar turns to SFTP once ssh is in — not while it is still
    /// asking for a passphrase — and opens on a folder already loaded.
    @Test func theSidebarTurnsToFilesOnceLoggedIn() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd"))
        try await startServer(passphrase: "correct horse")
        let (connection, appState, store, log) = try loggingIn(directSession())
        defer { connection.close() }
        _ = store

        guard await expectScreen(connection, contains: "Enter passphrase for key") else { return }
        try await Task.sleep(for: .seconds(1))
        #expect(log.logins == 0, "a passphrase prompt is not a login")
        #expect(appState.sidebarTab == .sessions)

        connection.terminalView.send(txt: "correct horse\r")
        try await awaitCondition(timeout: 20) { log.handled == 1 }
        #expect(log.logins == 1)
        #expect(appState.sidebarTab == .files)
        #expect(connection.fileBrowser.path != nil)
        #expect(connection.fileBrowser.problem == nil)
    }

    /// A server without SFTP — a switch, a router — keeps the session tree in
    /// the sidebar rather than turning to an error.
    @Test func aServerWithoutSFTPLeavesTheSidebarAlone() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd"))
        try await startServer(sftp: false)
        let (connection, appState, store, log) = try loggingIn(directSession())
        defer { connection.close() }
        _ = store

        try await awaitCondition(timeout: 20) { log.handled == 1 }
        #expect(log.logins == 1)
        #expect(appState.sidebarTab == .sessions)
        #expect(connection.fileBrowser.problem != nil)
    }

    /// The Files panel rides on the terminal's connection. The key has a
    /// passphrase that only the terminal is given (from the Keychain), and
    /// `sftp` runs with `BatchMode=yes`, so each operation below can only work
    /// through the terminal's connection master — through a jump host, too.
    @Test func filesGoOverTheTerminalsConnection() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd"))
        try await startServer(passphrase: "correct horse")
        store("correct horse", for: SSHLaunch.passphraseAccount(forKey: path("clientkey")))

        let user = NSUserName()
        let hop = JumpHost(host: "\(user)@127.0.0.1:\(port)", auth: .key, keyPath: path("clientkey"))
        let session = Session(id: "itest", user: user, host: "127.0.0.1", port: port, icon: .server,
                              auth: .key, keyPath: path("clientkey"), jumps: [hop])
        let plan = try testConfig(SSHLaunch.plan(for: session, sessions: [:]), batch: false)
        let connection = Connection(sessionID: session.id, title: session.id, address: "",
                                    keyDescription: "", keychain: keychain)
        connection.start(plan)
        defer { connection.close() }
        guard await run("echo TERMSTEAD_$((5*5))_FILES", in: connection, until: "TERMSTEAD_25_FILES") else { return }
        let client = try #require(connection.sftp)

        // The remote side is this Mac, so the "server" folder is a local one.
        let remote = directory.appendingPathComponent("remote folder", isDirectory: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        let odd = "q\"uote [1] *.txt"
        try "hello".write(to: remote.appendingPathComponent(odd), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: remote.appendingPathComponent("sub/inner"),
                                                withIntermediateDirectories: true)
        try "x".write(to: remote.appendingPathComponent("sub/inner/f"), atomically: true, encoding: .utf8)

        let listing = try await client.list(remote.path)
        #expect(listing.path.hasSuffix("/remote folder"))
        #expect(Set(listing.files.map(\.name)) == [odd, "sub"])
        #expect(listing.files.first { $0.name == "sub" }?.kind == .directory)
        #expect(listing.files.first { $0.name == odd }?.size == 5)

        // Download, upload, rename, make and delete — names with quotes,
        // brackets and a star included.
        let local = directory.appendingPathComponent("local", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try await client.download(RemotePath.join(listing.path, odd), recursive: false, to: local, as: odd)
        #expect(try String(contentsOf: local.appendingPathComponent(odd), encoding: .utf8) == "hello")

        let upload = local.appendingPathComponent("up load.txt")
        try "up".write(to: upload, atomically: true, encoding: .utf8)
        try await client.upload(upload, to: listing.path)
        #expect(FileManager.default.fileExists(atPath: remote.appendingPathComponent("up load.txt").path))

        try await client.rename(RemotePath.join(listing.path, "up load.txt"),
                                to: RemotePath.join(listing.path, "renamed.txt"))
        try await client.makeDirectory(RemotePath.join(listing.path, "new dir"))
        try await client.removeFile(RemotePath.join(listing.path, "renamed.txt"))
        try await client.removeDirectory(RemotePath.join(listing.path, "sub"))
        let after = try await client.list(listing.path)
        #expect(Set(after.files.map(\.name)) == [odd, "new dir"])

        // Editing writes the local copy back over the remote file.
        try "edited".write(to: local.appendingPathComponent(odd), atomically: true, encoding: .utf8)
        try await client.replace(RemotePath.join(listing.path, odd), with: local.appendingPathComponent(odd))
        #expect(try String(contentsOf: remote.appendingPathComponent(odd), encoding: .utf8) == "edited")

        // Once the terminal's ssh ends, sftp has nothing to ride on and does
        // not try to log in by itself.
        let stale = client
        connection.terminalView.send(txt: "exit\r")
        guard await expectScreen(connection, contains: "Press Return to reconnect", timeout: 10) else { return }
        #expect(connection.sftp == nil)
        await #expect(throws: SFTPError.self) { try await stale.list(remote.path) }
    }
}
