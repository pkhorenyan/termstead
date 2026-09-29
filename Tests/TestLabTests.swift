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
        var plan = try SSHLaunch.plan(for: sessions[id]!, sessions: sessions)
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
