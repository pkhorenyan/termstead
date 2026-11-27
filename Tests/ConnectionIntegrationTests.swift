import AppKit
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

    private func startServer(passphrase: String = "", sftp: Bool = true, sftpOnly: Bool = false) async throws {
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
            \(sftpOnly ? "ForceCommand internal-sftp\nPermitTTY no" : "")
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
    private func testConfig(_ plan: SSHLaunchPlan, batch: Bool, confirmHostKey: Bool = false) -> SSHLaunchPlan {
        var plan = plan
        plan.config = """
        Host \(plan.target.alias)
          RemoteCommand /bin/sh -i
          RequestTTY yes

        Host *
          StrictHostKeyChecking \(confirmHostKey ? "ask" : "accept-new")
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

    /// A tab closed while ssh runs: its ssh is collected, not left a zombie
    /// until Termstead quits. A zombie still answers `kill(pid, 0)`.
    @Test func aClosedTabLeavesNoZombie() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd"))
        try await startServer()
        let session = directSession()
        let plan = try testConfig(SSHLaunch.plan(for: session, sessions: [:]), batch: true)
        let connection = Connection(sessionID: session.id, title: session.id, address: "",
                                    keyDescription: "", keychain: keychain)
        connection.start(plan)
        guard await run("echo TERMSTEAD_$((6*7))_OK", in: connection, until: "TERMSTEAD_42_OK") else {
            connection.close()
            return
        }
        let pid = connection.terminalView.process.shellPid
        try #require(pid > 0)

        connection.close()
        let collected = (try? await awaitCondition(timeout: 10) { kill(pid, 0) == -1 && errno == ESRCH }) != nil
        #expect(collected)
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

    @Test func standaloneSFTPWaitsForTheHostKeyToBeConfirmed() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd"))
        try await startServer(passphrase: "correct horse", sftpOnly: true)
        store("correct horse", for: SSHLaunch.passphraseAccount(forKey: path("clientkey")))
        var session = directSession()
        session.kind = .sftp
        let plan = try testConfig(SSHLaunch.plan(for: session, sessions: [:]), batch: false, confirmHostKey: true)
        let connection = Connection(sessionID: session.id, title: session.id, address: session.address,
                                    keyDescription: "", keychain: keychain, kind: session.kind)
        connection.start(plan)
        defer { connection.close() }

        guard await expectScreen(connection, contains: "Are you sure you want to continue connecting") else { return }
        #expect(!connection.isLoggedIn)
        connection.terminalView.send(txt: "yes\r")
        try await awaitCondition(timeout: 10) { connection.isLoggedIn }
        let client = try #require(connection.sftp)
        #expect(try await client.home().hasPrefix("/"))
        #expect(FileManager.default.fileExists(atPath: path("known_hosts")))
    }

    /// A tab in a store whose logins are reported, the way `MainView` wires
    /// them to the sidebar.
    private func loggingIn(_ session: Session, appState: AppState = AppState(), opensFilesAfterLogin: Bool = true) throws
        -> (Connection, AppState, ConnectionStore, LoginLog) {
        let plan = try testConfig(SSHLaunch.plan(for: session, sessions: [:]), batch: false)
        let connection = Connection(sessionID: session.id, title: session.id, address: "",
                                    keyDescription: "", keychain: keychain, kind: session.kind)
        let store = ConnectionStore()
        let log = LoginLog()
        store.onLogin = { connection in
            log.logins += 1
            Task {
                await appState.showFiles(afterLoginOf: connection, in: store, opensFilesAfterLogin: opensFilesAfterLogin)
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

    /// The load watch rides the terminal's connection. This server is the
    /// Mac itself, which has no /proc: the watch says so and stops, and
    /// the status bar shows nothing rather than zeros.
    @Test func serverLoadOnAServerWithoutProcStops() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd"))
        try await startServer()
        let (connection, _, store, log) = try loggingIn(directSession())
        defer { connection.close() }
        _ = store

        try await awaitCondition(timeout: 20) { log.logins == 1 }
        connection.watchesLoad = true
        try await awaitCondition(timeout: 10) { connection.loadIsUnsupported }
        #expect(connection.serverLoad == nil)
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

    @Test func standaloneSFTPSessionWorksWithShellAccessDisabled() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd"))
        try await startServer(sftpOnly: true)
        var session = directSession()
        session.kind = .sftp
        let domain = "termstead-sftp-sidebar-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let appState = AppState(defaults: defaults)
        appState.sidebarTab = .snippets
        appState.isSidebarHidden = true
        let (connection, _, store, log) = try loggingIn(session, appState: appState, opensFilesAfterLogin: false)
        defer { connection.close() }
        try await awaitCondition(timeout: 10) { log.handled == 1 }
        #expect(store.active === connection)
        #expect(appState.sidebarTab == .files)
        #expect(!appState.isSidebarHidden)
        let browser = connection.fileBrowser
        let local = appState.localFiles
        #expect(!browser.canFollowTerminal)
        #expect(!browser.isLocal)
        #expect(local.isLocal)
        #expect(!local.canFollowTerminal)

        let client = try #require(connection.sftp)
        let listing = try await client.list(directory.path)
        let remote = RemotePath.join(listing.path, "sftp folder")
        let source = directory.appendingPathComponent("report.txt")
        try "hello".write(to: source, atomically: true, encoding: .utf8)
        try await client.makeDirectory(remote)
        let nested = RemotePath.join(remote, "nested")
        try await client.makeDirectory(nested)
        await browser.load(nested)
        await local.load(directory.path)
        let sourceFile = try #require(local.visibleFiles.first { $0.name == "report.txt" })
        browser.upload([URL(fileURLWithPath: sourceFile.path)])
        try await awaitCondition(timeout: 10) { browser.visibleFiles.contains { $0.name == "report.txt" } }
        let file = try #require(browser.visibleFiles.first { $0.name == "report.txt" })
        try "keep me".write(to: source, atomically: true, encoding: .utf8)
        browser.download([file], into: local)
        try await awaitCondition(timeout: 10) { browser.transfers.conflict != nil }
        let downloadConflict = try #require(browser.transfers.conflict)
        #expect(downloadConflict.canReplace)
        browser.transfers.resolve(downloadConflict.id, with: .keepBoth, forBatch: false)
        try await awaitCondition(timeout: 10) { local.visibleFiles.contains { $0.name == "report 2.txt" } }
        #expect(try String(contentsOf: directory.appendingPathComponent("report 2.txt"), encoding: .utf8) == "hello")
        #expect(try String(contentsOf: source, encoding: .utf8) == "keep me")

        let pasteboard = NSPasteboard.withUniqueName()
        browser.pasteboard = pasteboard
        defer { pasteboard.releaseGlobally() }
        await browser.copyToClipboard(file)
        let copied = try #require((pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first)
        defer { try? FileManager.default.removeItem(at: copied.deletingLastPathComponent()) }
        #expect(try String(contentsOf: copied, encoding: .utf8) == "hello")

        let another = directory.appendingPathComponent("other.txt")
        try "new other".write(to: another, atomically: true, encoding: .utf8)
        try "old other".write(toFile: RemotePath.join(nested, "other.txt"), atomically: true, encoding: .utf8)
        browser.upload([source, another])
        try await awaitCondition(timeout: 10) { browser.transfers.conflict != nil }
        let uploadConflict = try #require(browser.transfers.conflict)
        #expect(browser.activities.contains { $0.title.contains("other.txt") && $0.state == .queued })
        browser.transfers.resolve(uploadConflict.id, with: .replace, forBatch: true)
        try await awaitCondition(timeout: 10) {
            (try? String(contentsOfFile: RemotePath.join(nested, "other.txt"), encoding: .utf8)) == "new other"
        }
        #expect(try String(contentsOfFile: RemotePath.join(nested, "report.txt"), encoding: .utf8) == "keep me")

        let missing = ["missing-a.txt", "missing-b.txt"].map { directory.appendingPathComponent($0) }
        browser.upload(missing)
        try await awaitCondition(timeout: 10) { browser.activities.filter(browser.transfers.canRetry).count == 2 }
        for url in missing { try "retry".write(to: url, atomically: true, encoding: .utf8) }
        browser.transfers.retry(browser.activities.filter(browser.transfers.canRetry).map(\.id))
        try await awaitCondition(timeout: 10) { browser.visibleFiles.contains { $0.name == "missing-b.txt" } }
        #expect(try String(contentsOfFile: RemotePath.join(nested, "missing-a.txt"), encoding: .utf8) == "retry")

        browser.upload([source, another])
        try await awaitCondition(timeout: 10) { browser.transfers.conflict != nil }
        let skipConflict = try #require(browser.transfers.conflict)
        browser.transfers.resolve(skipConflict.id, with: .skip, forBatch: true)
        try await awaitCondition(timeout: 10) { browser.activities.filter { $0.state == .skipped }.count == 2 }

        let tree = directory.appendingPathComponent("documents", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
        try "inside".write(to: tree.appendingPathComponent("note"), atomically: true, encoding: .utf8)
        let secondTree = directory.appendingPathComponent("pictures", isDirectory: true)
        try FileManager.default.createDirectory(at: secondTree, withIntermediateDirectories: false)
        try "second folder".write(to: secondTree.appendingPathComponent("image"), atomically: true, encoding: .utf8)
        try "mixed drag".write(to: directory.appendingPathComponent("drag.txt"), atomically: true, encoding: .utf8)
        await local.load(directory.path)
        let folderRow = try #require(local.visibleFiles.first { $0.name == "documents" })
        let otherFolder = try #require(local.visibleFiles.first { $0.name == "pictures" })
        let fileRow = try #require(local.visibleFiles.first { $0.name == "drag.txt" })
        local.select(folderRow)
        local.select(otherFolder, modifiers: .command)
        local.select(fileRow, modifiers: .command)
        let dragView = FileDragView()
        dragView.file = otherFolder
        dragView.browser = local
        let press = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                                                   timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1,
                                                   clickCount: 1, pressure: 1))
        dragView.mouseDown(with: press)
        #expect(local.selectedFiles.count == 3)
        let dragItems = dragView.prepareDrag(at: .zero)
        let dragBoard = NSPasteboard.withUniqueName()
        defer { dragBoard.releaseGlobally() }
        let localWriters = try dragItems.map { item in try #require(item.item as? NSURL) }
        #expect(dragBoard.writeObjects(localWriters))
        let ofLocalFiles = FileDropTargetView()
        ofLocalFiles.browser = browser
        ofLocalFiles.onDrop = { payload in
            guard case .local(let dropped) = payload else { return false }
            #expect(dropped.map(\.lastPathComponent) == ["documents", "pictures", "drag.txt"])
            browser.upload(dropped)
            return true
        }
        let localDrop = TestFileDrop(pasteboard: dragBoard, source: dragView)
        // Dropping across panels onto blank space copies into the open folder.
        #expect(ofLocalFiles.draggingEntered(localDrop) == .copy)
        #expect(ofLocalFiles.performDragOperation(localDrop))
        dragView.mouseUp(with: press)
        #expect(local.selectedFiles.map(\.name) == ["pictures"])
        try await awaitCondition(timeout: 10) { browser.visibleFiles.contains { $0.name == "drag.txt" } }
        #expect(try String(contentsOfFile: RemotePath.join(nested, "drag.txt"), encoding: .utf8) == "mixed drag")
        #expect(try String(contentsOfFile: RemotePath.join(nested, "pictures/image"), encoding: .utf8) == "second folder")
        let uploadedFile = try #require(browser.visibleFiles.first { $0.name == "drag.txt" })
        let otherFile = try #require(browser.visibleFiles.first { $0.name == "other.txt" })
        browser.select(uploadedFile)
        browser.select(otherFile, modifiers: .command)
        browser.selectForContextMenu(uploadedFile)
        let toDelete = browser.filesForAction(on: uploadedFile)
        #expect(Set(toDelete.map(\.name)) == ["drag.txt", "other.txt"])
        browser.delete(toDelete)
        try await awaitCondition(timeout: 10) {
            !browser.visibleFiles.contains { $0.name == "drag.txt" || $0.name == "other.txt" }
        }
        let deletions = browser.activities.filter { $0.title.hasPrefix("Delete ") && $0.state == .done }
        #expect(deletions.count == 2)
        #expect(deletions.allSatisfy { !$0.isTransfer })
        #expect(!FileManager.default.fileExists(atPath: uploadedFile.path))
        #expect(!FileManager.default.fileExists(atPath: otherFile.path))
        #expect(FileManager.default.fileExists(atPath: RemotePath.join(nested, "report.txt")))
        let remoteTree = try #require(browser.visibleFiles.first { $0.name == "documents" })
        browser.download([remoteTree], into: local)
        try await awaitCondition(timeout: 10) { browser.transfers.conflict != nil }
        let folderConflict = try #require(browser.transfers.conflict)
        #expect(!folderConflict.canReplace)
        browser.transfers.resolve(folderConflict.id, with: .keepBoth, forBatch: false)
        try await awaitCondition(timeout: 10) { local.visibleFiles.contains { $0.name == "documents 2" } }
        #expect(try String(contentsOf: directory.appendingPathComponent("documents 2/note"), encoding: .utf8) == "inside")

        let remoteFile = try #require(browser.visibleFiles.first { $0.name == "report.txt" })
        browser.select(remoteTree)
        browser.select(remoteFile, modifiers: .command)
        dragView.file = remoteFile
        dragView.browser = browser
        dragView.mouseDown(with: press)
        let remoteItems = dragView.prepareDrag(at: .zero)
        #expect(remoteItems.count == 2)
        let writer = try #require(remoteItems.first?.item as? NSFilePromiseProvider)
        dragBoard.clearContents()
        #expect(dragBoard.writeObjects([writer]))
        #expect(FileDrop.read(dragBoard) == dragView.draggedFiles)
        // The destination still copies the whole selection when the drag board
        // lacks the custom type and contains only an unreadable file URL.
        dragBoard.clearContents()
        #expect(dragBoard.setString("not a file URL", forType: .fileURL))
        let incoming = directory.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: false)
        let ofRemoteFiles = FileDropTargetView()
        ofRemoteFiles.browser = local
        ofRemoteFiles.folder = incoming.path
        ofRemoteFiles.onDrop = { payload in
            guard case .remote(let reference) = payload else { return false }
            return FileDrop.download(reference, into: local, directory: incoming.path, in: store)
        }
        let remoteDrop = TestFileDrop(pasteboard: dragBoard, source: dragView)
        #expect(ofRemoteFiles.draggingEntered(remoteDrop) == .copy)
        #expect(ofRemoteFiles.performDragOperation(remoteDrop))
        #expect(!ofRemoteFiles.performDragOperation(remoteDrop))
        try await awaitCondition(timeout: 10) {
            FileManager.default.fileExists(atPath: incoming.appendingPathComponent("report.txt").path)
        }
        #expect(try String(contentsOf: incoming.appendingPathComponent("documents/note"), encoding: .utf8) == "inside")
        #expect(try String(contentsOf: incoming.appendingPathComponent("report.txt"), encoding: .utf8) == "keep me")
        let promise = try #require(writer.delegate)
        let promised = incoming.appendingPathComponent("promised documents", isDirectory: true)
        try await withCheckedThrowingContinuation { (finished: CheckedContinuation<Void, any Error>) in
            promise.filePromiseProvider(writer, writePromiseTo: promised) { error in
                if let error { finished.resume(throwing: error) }
                else { finished.resume() }
            }
        }
        #expect(try String(contentsOf: promised.appendingPathComponent("note"), encoding: .utf8) == "inside")
        let remaining = try await client.list(nested).files
        #expect(!remaining.contains { $0.name.hasPrefix(".termstead-transfer-") })
        try FileManager.default.createSymbolicLink(atPath: RemotePath.join(remote, "link"),
                                                    withDestinationPath: source.path)
        try await client.removeDirectory(remote)
        #expect(!FileManager.default.fileExists(atPath: remote))
        #expect(FileManager.default.fileExists(atPath: source.path))

        for (index, panel) in [local, browser].enumerated() {
            let root = directory.appendingPathComponent("move-\(index)", isDirectory: true)
            let folder = root.appendingPathComponent("target", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let names = ["first.txt", "second.txt"]
            for name in names { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
            await panel.load(root.path)
            let first = try #require(panel.visibleFiles.first { $0.name == names[0] })
            let second = try #require(panel.visibleFiles.first { $0.name == names[1] })
            let target = try #require(panel.visibleFiles.first { $0.name == "target" })
            panel.select(first)
            panel.select(second, modifiers: .command)
            dragView.browser = panel
            dragView.file = first
            dragView.mouseDown(with: press)
            #expect(dragView.prepareDrag(at: .zero).count == 2)
            let drop = TestFileDrop(pasteboard: dragBoard, source: dragView)
            let destination = FileDropTargetView()
            destination.browser = panel
            #expect(destination.draggingEntered(drop).isEmpty)
            #expect(!destination.performDragOperation(drop))
            #expect(!panel.canMove([target], into: target.path))
            #expect(!panel.canMove([target], into: RemotePath.join(target.path, "child")))
            destination.folder = target.path
            #expect(destination.draggingEntered(drop) == .move)
            #expect(destination.performDragOperation(drop))
            try await awaitCondition(timeout: 10) { panel.visibleFiles.map(\.name) == ["target"] }
            for name in names {
                #expect(try Data(contentsOf: folder.appendingPathComponent(name)) == Data(name.utf8))
                #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
            }
        }
    }

    @Test func sftpKeepsTheQueueAndRetriesOnTheSameTabAfterDisconnect() async throws {
        try await startServer(sftpOnly: true)
        var session = directSession()
        session.kind = .sftp
        let plan = try testConfig(SSHLaunch.plan(for: session, sessions: [:]), batch: true)
        let connection = Connection(sessionID: session.id, title: session.id, address: "",
                                    keyDescription: "", keychain: keychain, kind: .sftp)
        connection.start(plan)
        defer { connection.close() }
        try await awaitCondition(timeout: 10) { connection.isLoggedIn }
        let browser = connection.fileBrowser
        let folders = try ["source", "remote", "downloads"].map { name in
            let url = directory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        }
        let source = folders[0], remote = folders[1], downloads = folders[2]
        let fixtures = (1...50).map { index in
            ("file-\(index).bin", Data(repeating: UInt8(index), count: index * 1024))
        }
        let contents = Dictionary(uniqueKeysWithValues: fixtures)
        let files = try fixtures.map { name, data in
            let url = source.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }

        func hasActiveTransfer() -> Bool {
            browser.activities.contains { activity in
                if case .running = activity.state { return true }
                return false
            }
        }

        func disconnectAndRetry(destination: URL, keepRecentResults: Bool = false,
                                enqueueRemaining: () -> Void) async throws {
            try await awaitCondition(timeout: 15) { browser.activities.contains { $0.state == .done } }
            let completed = Set(browser.activities.filter { $0.state == .done }.map(\.id))
            let pid = connection.terminalView.process.shellPid
            try #require(pid > 0)
            // Hold this test's SSH master before submitting the remaining files.
            // This guarantees a transfer is interrupted even on a fast loopback.
            try #require(kill(pid, SIGSTOP) == 0)
            defer { if connection.state.isRunning, connection.terminalView.process.shellPid == pid { _ = kill(pid, SIGCONT) } }
            enqueueRemaining()
            try await awaitCondition(timeout: 10, hasActiveTransfer)
            try #require(kill(pid, SIGKILL) == 0)
            try await awaitCondition(timeout: 10) {
                !connection.state.isRunning && !hasActiveTransfer() &&
                    browser.activities.contains(where: browser.transfers.canRetry)
            }
            if keepRecentResults { try await Task.sleep(for: .milliseconds(3200)) }
            #expect(browser.activities.contains { completed.contains($0.id) && $0.state == .done })
            let failed = browser.activities.filter(browser.transfers.canRetry).map(\.id)
            browser.transfers.retry(failed)
            #expect(browser.activities.filter { failed.contains($0.id) }.allSatisfy { $0.state == .queued })
            let terminalWasRunning = connection.terminalView.process.running
            connection.terminalView.send(txt: "\r")
            try #require(connection.state.isRunning, "Return must restart SSH (PTY still running: \(terminalWasRunning))")
            try await awaitCondition(timeout: 10) { connection.isLoggedIn }
            try await awaitCondition(timeout: 60) {
                if let conflict = browser.transfers.conflict,
                   (try? Data(contentsOf: destination.appendingPathComponent(conflict.name))) == contents[conflict.name] {
                    // The final rename can succeed before the lost SSH reply reaches the sender.
                    browser.transfers.resolve(conflict.id, with: .skip, forBatch: false)
                }
                return browser.activities.allSatisfy { $0.state == .done || $0.state == .skipped }
            }
            let names = try FileManager.default.contentsOfDirectory(atPath: destination.path)
            #expect(Set(names) == Set(contents.keys))
            for (name, expected) in contents {
                #expect(try Data(contentsOf: destination.appendingPathComponent(name)) == expected)
            }
            for item in browser.activities { browser.dismiss(item.id) }
        }

        let client = try #require(connection.sftp)
        let remotePath = try await client.list(remote.path).path
        browser.upload([try #require(files.first)], into: remotePath)
        try await disconnectAndRetry(destination: remote, keepRecentResults: true) {
            browser.upload(Array(files.dropFirst()), into: remotePath)
        }

        let reconnected = try #require(connection.sftp)
        let listing = try await reconnected.list(remotePath)
        let local = FileBrowser(localFiles: LocalFiles())
        browser.download([try #require(listing.files.first)], into: local, directory: downloads.path)
        try await disconnectAndRetry(destination: downloads) {
            browser.download(Array(listing.files.dropFirst()), into: local, directory: downloads.path)
        }
    }

    @Test func sftpRejectsIncompleteFoldersAndCleansAbandonedUploadsAfterReconnect() async throws {
        try await startServer(sftpOnly: true)
        var session = directSession()
        session.kind = .sftp
        let plan = try testConfig(SSHLaunch.plan(for: session, sessions: [:]), batch: true)
        func connection() -> Connection {
            let connection = Connection(sessionID: session.id, title: session.id, address: "",
                                        keyDescription: "", keychain: keychain, kind: .sftp)
            connection.start(plan)
            return connection
        }

        let original = connection()
        var originalClosed = false
        defer { if !originalClosed { original.close() } }
        try await awaitCondition(timeout: 10) { original.isLoggedIn }
        let client = try #require(original.sftp)
        let listing = try await client.list(directory.path)
        let remote = RemotePath.join(listing.path, "remote")
        try await client.makeDirectory(remote)
        let tree = directory.appendingPathComponent("tree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
        try Data("file".utf8).write(to: tree.appendingPathComponent("data"))
        try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("link").path,
                                                   withDestinationPath: "data")
        let browser = original.fileBrowser
        browser.upload([tree], into: remote)
        try await awaitCondition(timeout: 10) { browser.activities.contains(where: browser.transfers.canRetry) }
        #expect(try await client.list(remote).files.isEmpty)

        let treeEntry = try #require(try await client.list(listing.path).files.first { $0.name == "tree" })
        let downloads = directory.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: false)
        browser.downloadsDirectory = downloads
        browser.download(treeEntry)
        try await awaitCondition(timeout: 10) { browser.activities.filter(browser.transfers.canRetry).count == 2 }
        #expect(try FileManager.default.contentsOfDirectory(atPath: downloads.path).isEmpty)

        let journal = try #require(client.stageJournal)
        let stage = RemotePath.join(remote, SFTPStageJournal.prefix + UUID().uuidString.lowercased())
        let record = try journal.register(stage)
        defer { record.close() }
        try await client.makeTransferStage(stage)
        try Data("unfinished".utf8).write(to: URL(fileURLWithPath: RemotePath.join(stage, "data")))
        await journal.recover(using: client)
        #expect(FileManager.default.fileExists(atPath: stage))
        original.close()
        originalClosed = true
        record.close()

        let reopened = connection()
        defer { reopened.close() }
        try await awaitCondition(timeout: 10) { reopened.isLoggedIn && !FileManager.default.fileExists(atPath: record.url.path) }
        #expect(!FileManager.default.fileExists(atPath: stage))
        #expect(FileManager.default.fileExists(atPath: remote))
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

        await #expect(throws: SFTPError.self) {
            try await client.rename(RemotePath.join(listing.path, "up load.txt"),
                                    to: RemotePath.join(listing.path, odd))
        }
        #expect(try String(contentsOf: remote.appendingPathComponent(odd), encoding: .utf8) == "hello")
        #expect(try String(contentsOf: remote.appendingPathComponent("up load.txt"), encoding: .utf8) == "up")
        try await client.rename(RemotePath.join(listing.path, "up load.txt"),
                                to: RemotePath.join(listing.path, "renamed.txt"))
        try await client.makeDirectory(RemotePath.join(listing.path, "new dir"))
        try await client.removeFile(RemotePath.join(listing.path, "renamed.txt"))
        try await client.removeDirectory(RemotePath.join(listing.path, "sub"))
        let after = try await client.list(listing.path)
        #expect(Set(after.files.map(\.name)) == [odd, "new dir"])

        // Editing writes the local copy back over the remote file.
        let originalFile = remote.appendingPathComponent(odd)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: originalFile.path)
        let localEdit = local.appendingPathComponent(odd)
        let openedContents = try await SFTPClient.contentDigest(of: localEdit)
        try "edited".write(to: localEdit, atomically: true, encoding: .utf8)
        // A same-sized update can be invisible in the server's ls metadata.
        try "other".write(to: originalFile, atomically: false, encoding: .utf8)
        let remoteFile = RemotePath.join(listing.path, odd)
        await #expect(throws: SFTPError.self) {
            try await client.replace(remoteFile, with: localEdit, matching: openedContents)
        }
        #expect(try String(contentsOf: originalFile, encoding: .utf8) == "other")
        #expect(try String(contentsOf: localEdit, encoding: .utf8) == "edited")
        try "hello".write(to: originalFile, atomically: false, encoding: .utf8)
        try await client.replace(remoteFile, with: localEdit, matching: openedContents)
        #expect(try String(contentsOf: originalFile, encoding: .utf8) == "edited")
        let attributes = try FileManager.default.attributesOfItem(atPath: originalFile.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        try FileManager.default.setAttributes([.posixPermissions: 0o440], ofItemAtPath: originalFile.path)
        try "another version".write(to: local.appendingPathComponent(odd), atomically: true, encoding: .utf8)
        await #expect(throws: SFTPError.self) {
            try await client.replace(RemotePath.join(listing.path, odd), with: local.appendingPathComponent(odd))
        }
        #expect(try String(contentsOf: originalFile, encoding: .utf8) == "edited")

        // Once the terminal's ssh ends, sftp has nothing to ride on and does
        // not try to log in by itself.
        let stale = client
        connection.terminalView.send(txt: "exit\r")
        guard await expectScreen(connection, contains: "Press Return to reconnect", timeout: 10) else { return }
        #expect(connection.sftp == nil)
        await #expect(throws: SFTPError.self) { try await stale.list(remote.path) }
    }
}

@MainActor
private final class TestFileDrop: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    let draggingDestinationWindow: NSWindow? = nil
    let draggingSourceOperationMask: NSDragOperation
    let draggingLocation: NSPoint = .zero
    let draggedImageLocation: NSPoint = .zero
    nonisolated var draggedImage: NSImage? { nil }
    let draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    let springLoadingHighlight: NSSpringLoadingHighlight = .none

    init(pasteboard: NSPasteboard, source: FileDragView? = nil) {
        draggingPasteboard = pasteboard
        draggingSource = source
        draggingSourceOperationMask = source == nil ? .copy : [.copy, .move]
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}

    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
