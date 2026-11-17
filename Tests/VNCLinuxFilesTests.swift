import AppKit
import Foundation
import Darwin
import IOSurface
import Testing
@testable import Termstead

@MainActor
struct VNCLinuxFileValidationTests {
    @Test func rejectsLinksAndNamesThatCouldBecomeSFTPCommands() throws {
        let root = URL.temporaryDirectory.appendingPathComponent("linux-validation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("test_rdp")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data([0, 1, 255]).write(to: folder.appendingPathComponent("Файл % ' [a].bin"))
        try VNCLinuxFiles.validate([folder])
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        #expect(throws: (any Error).self) { try VNCLinuxFiles.validate([folder]) }
        try FileManager.default.removeItem(at: link)
        try Data().write(to: folder.appendingPathComponent("unsafe\nname"))
        #expect(throws: (any Error).self) { try VNCLinuxFiles.validate([folder]) }
        #expect(!VNCLinuxFiles.validPath("/"))
        #expect(!VNCLinuxFiles.validPath("relative/file"))
        #expect(!VNCLinuxFiles.validPath("/file\rput evil"))
    }
}

@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TERMSTEAD_LINUX_SSH_CONFIG"] != nil,
                                       "Run TestLab/vnc/test.py with the Linux VNC lab"))
struct VNCLinuxFilesTests {
    private func wait(seconds: Double = 20, _ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }
    private func client() throws -> SFTPClient {
        let env = ProcessInfo.processInfo.environment
        return SFTPClient(configPath: try #require(env["TERMSTEAD_LINUX_SSH_CONFIG"]),
                          controlPath: try #require(env["TERMSTEAD_LINUX_SSH_CONTROL"]), alias: "linux-vnc-test")
    }
    private func plan() throws -> SSHLaunchPlan {
        let settings = try client()
        return SSHLaunchPlan(hops: [], target: .init(alias: "linux-vnc-test", host: "127.0.0.1", user: "lab", port: 2203,
                                                    auth: .automatic, passwordAccount: nil),
                             config: try String(contentsOfFile: settings.configPath, encoding: .utf8))
    }

    @Test func vncFilesPanelCopiesBetweenFinderAndSFTPWithoutAnSSHTab() async throws {
        let access = Connection(sessionID: nil, title: "VNC files", address: "127.0.0.1:5901",
                                keyDescription: "VNC", kind: .vnc)
        defer { access.close() }
        var reportedFileLogin = false
        access.onLogin = { reportedFileLogin = true }
        access.configureFileAccess(try plan(), title: "lab-vnc-ssh")
        let launch = VNCLaunch(session: try #require(SessionStore.sample().session("lab-vnc")), password: "lab")
        access.start(launch)
        await wait { access.vnc?.phase == .showing }
        try #require(access.vnc?.phase == .showing)
        await wait { reportedFileLogin }
        #expect(reportedFileLogin)

        let browser = access.fileBrowser
        let board = NSPasteboard(name: .init("vnc-sftp-files-\(UUID())"))
        browser.pasteboard = board
        defer { board.releaseGlobally() }
        browser.isShown = true
        let remote = "/home/lab/termstead-sftp-\(UUID())"
        try await client().makeDirectory(remote)
        defer { _ = TestLabVNC.command(["rm", "-rf", "--", remote]) }
        await browser.load(remote)
        await wait { browser.path == remote && browser.problem == nil }
        try #require(browser.path == remote)

        let local = URL.temporaryDirectory.appendingPathComponent("vnc-sftp-copy-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: local) }
        let file = local.appendingPathComponent("test_rdp.bin")
        let contents = Data([0, 255, 42, 0, 10, 13])
        try contents.write(to: file)
        board.clearContents()
        #expect(board.writeObjects([file as NSURL]))
        browser.paste()
        await wait { browser.files.contains(where: { $0.name == file.lastPathComponent }) }
        let entry = try #require(browser.files.first { $0.name == file.lastPathComponent })

        // A second Paste must not silently overwrite an existing remote file.
        browser.paste()
        await wait { browser.activities.contains { activity in
            if case .failed(let message) = activity.state { return message.contains("already exists") }
            return false
        } }
        #expect(browser.activities.contains { activity in
            if case .failed(let message) = activity.state { return message.contains("already exists") }
            return false
        })

        board.clearContents()
        await browser.copyToClipboard(entry)
        let copied = try #require((board.readObjects(forClasses: [NSURL.self],
                            options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first)
        #expect(copied.lastPathComponent == "test_rdp.bin")
        #expect(try Data(contentsOf: copied) == contents)

        let localFolder = local.appendingPathComponent("test_rdp", isDirectory: true)
        try FileManager.default.createDirectory(at: localFolder, withIntermediateDirectories: false)
        try contents.write(to: localFolder.appendingPathComponent("nested.bin"))
        board.clearContents()
        #expect(board.writeObjects([localFolder as NSURL]))
        browser.paste()
        await wait { browser.files.contains(where: { $0.name == "test_rdp" }) }
        let folderEntry = try #require(browser.files.first { $0.name == "test_rdp" })
        board.clearContents()
        await browser.copyToClipboard(folderEntry)
        let copiedFolder = try #require((board.readObjects(forClasses: [NSURL.self],
                                    options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first)
        #expect(copiedFolder.lastPathComponent == "test_rdp")
        #expect(try Data(contentsOf: copiedFolder.appendingPathComponent("nested.bin")) == contents)

        board.clearContents()
        await browser.copyToClipboard([entry, folderEntry])
        let selection = try #require(board.readObjects(forClasses: [NSURL.self],
                                        options: [.urlReadingFileURLsOnly: true]) as? [URL])
        #expect(Set(selection.map(\.lastPathComponent)) == ["test_rdp.bin", "test_rdp"])
        let selectedFile = try #require(selection.first { $0.lastPathComponent == "test_rdp.bin" })
        #expect(try Data(contentsOf: selectedFile) == contents)

        let previousSSH = access.fileAccess?.id
        access.reconnectFileAccess()
        await wait { access.fileAccess?.id != previousSSH && access.fileAccess?.isLoggedIn == true }
        #expect(access.fileAccess?.isLoggedIn == true)
    }
    private func open(_ desktop: VNCDesktop, fileClient: SFTPClient? = nil, background: Bool = false, receive: Bool = true) async throws {
        // TigerVNC desktop and the selected SSH connection are the same user
        // and machine. Named pasteboards never touch Pavel's clipboard.
        desktop.hasKeyboard = { true }
        var launch = VNCLaunch(session: SessionStore.sample().session("lab-vnc")!, password: "lab")
        launch.options.receiveClipboard = receive
        desktop.start(launch) {
            try await RDPSocket.connect(host: "127.0.0.1", port: 5901)
        }
        await wait { desktop.phase != .connecting }
        try #require(desktop.phase == .showing)
        #expect(!desktop.supportsFiles) // no Apple file-transfer extension
        if background {
            desktop.connectLinuxFiles(plan: try plan(), title: "Linux test SSH", keychain: KeychainStore(service: "linux-background-\(UUID())"))
        } else { desktop.connectLinuxFiles(client: try fileClient ?? client(), title: "Linux test SSH") }
        await wait { desktop.linuxFilesReady || desktop.fileCopy?.error != nil }
        try #require(desktop.linuxFilesReady, "\(desktop.fileCopy?.error ?? "helper did not start")")
    }
    private func show(_ path: String) async throws {
        _ = TestLabVNC.command(["sh", "-c", "thunar '\(path)' >/dev/null 2>&1 &"])
        try await Task.sleep(for: .seconds(1))
        let name = URL(fileURLWithPath: path).lastPathComponent
        let result = TestLabVNC.command(["sh", "-c", "command -v xdotool >/dev/null || exit 1; w=$(xdotool search --onlyvisible --name '^\(name)' | tail -1); test -n \"$w\" && xdotool windowactivate --sync \"$w\""])
        try #require(result.status == 0)
        try await Task.sleep(for: .milliseconds(250))
    }
    private func prepare() throws -> String {
        let path = "/tmp/termstead-linux-\(UUID())"
        let result = TestLabVNC.command(["mkdir", "-p", path])
        try #require(result.status == 0)
        _ = TestLabVNC.command(["sh", "-c", "printf '' | xclip -selection clipboard >/dev/null 2>&1"])
        return path
    }
    @Test func finderFilesPasteOnceIntoThunarWithOriginalNamesAndContents() async throws {
        let remote = try prepare()
        defer { _ = TestLabVNC.command(["rm", "-rf", "--", remote]) }
        let root = URL.temporaryDirectory.appendingPathComponent("linux-upload-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("test_rdp")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Пустая 🙂"), withIntermediateDirectories: true)
        let payload = Data((0..<131073).map { UInt8($0 % 251) })
        try payload.write(to: folder.appendingPathComponent("данные % ' [a].bin"))
        let empty = root.appendingPathComponent("пустой %.txt")
        try Data().write(to: empty)
        let board = NSPasteboard(name: .init("linux-upload-\(UUID())"))
        defer { board.releaseGlobally() }
        let desktop = VNCDesktop(); desktop.pasteboard = board
        defer { desktop.stop() }
        try await open(desktop)
        try await show(remote)
        board.clearContents(); board.writeObjects([folder, empty] as [NSURL])
        desktop.view.paste(nil) // exactly one ordinary Paste
        await wait { desktop.fileCopy?.done == true || desktop.fileCopy?.error != nil }
        try #require(desktop.fileCopy?.error == nil, "\(desktop.fileCopy?.error ?? "")")
        #expect(desktop.fileCopy?.paste == .sent)
        var present = false
        for _ in 0..<100 where !present {
            present = TestLabVNC.command(["test", "-f", remote + "/test_rdp/данные % ' [a].bin"]).status == 0
            if !present { try await Task.sleep(for: .milliseconds(50)) }
        }
        try #require(present, "The first Ctrl+V must actually create test_rdp in Thunar")
        #expect(TestLabVNC.command(["test", "-d", remote + "/test_rdp/Пустая 🙂"]).status == 0)
        #expect(TestLabVNC.command(["stat", "-c", "%s", remote + "/пустой %.txt"]).output.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
        let copy = root.appendingPathComponent("verification")
        try await client().download(remote + "/test_rdp/данные % ' [a].bin", recursive: false, to: root, as: copy.lastPathComponent)
        #expect(try Data(contentsOf: copy) == payload)
        // The helper's own file announcement must not turn the Mac's file
        // clipboard into a text list of remote paths.
        let local = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(local == [folder, empty])
    }
    @Test func thunarCopyDownloadsFoldersAndFilesWithoutMovingTheOriginals() async throws {
        let remote = try prepare()
        defer { _ = TestLabVNC.command(["rm", "-rf", "--", remote]) }
        let fixture = "import os,pathlib; p=pathlib.Path(" + String(reflecting: remote) + "); (p/'test_rdp'/'Пустая 🙂').mkdir(parents=True); (p/'test_rdp'/'данные %.bin').write_bytes(bytes(range(256))*1025); (p/'пустой.txt').touch()"
        try #require(TestLabVNC.command(["python3", "-c", fixture]).status == 0)
        let board = NSPasteboard(name: .init("linux-download-\(UUID())"))
        defer { board.releaseGlobally() }
        let desktop = VNCDesktop(); desktop.pasteboard = board
        defer { desktop.stop() }
        try await open(desktop)
        try await show(remote)
        desktop.press([0xffe3, 0x61]) // Ctrl+A
        try await Task.sleep(for: .milliseconds(150))
        desktop.view.copy(nil) // genuine file-manager Copy, no URL test injection
        desktop.hasKeyboard = { false }; desktop.keyboardLeft() // immediately return to Finder
        await wait { desktop.fileCopy?.done == true || desktop.fileCopy?.error != nil }
        try #require(desktop.fileCopy?.done == true, "\(desktop.fileCopy?.error ?? "No copied files arrived")")
        let urls = try #require(board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])
        #expect(Set(urls.map(\.lastPathComponent)) == ["test_rdp", "пустой.txt"])
        let folder = try #require(urls.first { $0.lastPathComponent == "test_rdp" })
        let expected = Data((0..<256 * 1025).map { UInt8($0 % 256) })
        #expect(try Data(contentsOf: folder.appendingPathComponent("данные %.bin")) == expected)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Пустая 🙂").path))
        #expect(TestLabVNC.command(["test", "-f", remote + "/test_rdp/данные %.bin"]).status == 0)
        // Files remain usable after the bridge closes, as Finder requires.
        desktop.stop()
        #expect(try Data(contentsOf: folder.appendingPathComponent("данные %.bin")) == expected)
        for url in urls { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
    }
    @Test func unicodeTextStillSynchronizesAndLosingFocusProtectsTheLocalClipboard() async throws {
        let remote = try prepare()
        defer { _ = TestLabVNC.command(["rm", "-rf", "--", remote]) }
        let board = NSPasteboard(name: .init("linux-text-\(UUID())"))
        defer { board.releaseGlobally() }
        let desktop = VNCDesktop(); desktop.pasteboard = board
        defer { desktop.stop() }
        try await open(desktop)
        let text = "Linux → Mac — привет 🙂 \(UUID())"
        _ = TestLabVNC.command(["sh", "-c", "printf '%s' '\(text)' | xclip -selection clipboard >/dev/null 2>&1"])
        await wait { board.string(forType: .string) == text }
        #expect(board.string(forType: .string) == text)
        desktop.hasKeyboard = { false }; desktop.keyboardLeft()
        try await Task.sleep(for: .milliseconds(150))
        _ = TestLabVNC.command(["sh", "-c", "printf '%s' 'background copy' | xclip -selection clipboard >/dev/null 2>&1"])
        try await Task.sleep(for: .milliseconds(300))
        #expect(board.string(forType: .string) == text)
        desktop.hasKeyboard = { true }; desktop.keyboardArrived()
        await wait { board.string(forType: .string) == "background copy" }
        #expect(board.string(forType: .string) == "background copy")
        let local = "Mac → Linux — привет 🙂 \(UUID())"
        board.clearContents(); board.setString(local, forType: .string)
        desktop.offerClipboard(onPaste: true)
        var remoteText = ""
        for _ in 0..<20 where remoteText != local {
            try await Task.sleep(for: .milliseconds(50))
            remoteText = TestLabVNC.command(["timeout", "2", "xclip", "-selection", "clipboard", "-o"]).output
        }
        #expect(remoteText == local)
        let urlText = "file:///tmp/this-is-text-\(UUID())"
        _ = TestLabVNC.command(["sh", "-c", "printf '%s' '\(urlText)' | xclip -selection clipboard >/dev/null 2>&1"])
        await wait { board.string(forType: .string) == urlText }
        #expect(board.string(forType: .string) == urlText)
        #expect(desktop.fileCopy?.error == nil)
    }
    @Test func cancellingAnUploadRemovesItsStageAndKeepsTheSharedSSHConnection() async throws {
        let sftp = try client()
        let bridge = VNCLinuxFiles(client: sftp, title: "Cancellation test")
        defer { bridge.close() }
        try bridge.start()
        await wait { bridge.isReady }
        try #require(bridge.isReady)
        func stages() -> String {
            TestLabVNC.command(["python3", "-c", "import pathlib,json;print(json.dumps(sorted(str(p) for p in pathlib.Path.home().glob('.termstead-vnc-*'))))"]).output
        }
        let before = stages()
        let folder = URL.temporaryDirectory.appendingPathComponent("linux-cancel-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("large.bin")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 128 * 1024 * 1024)
        try handle.close()
        let transfer = Task { try await bridge.upload([file]) }
        try await Task.sleep(for: .milliseconds(30))
        transfer.cancel()
        do { try await transfer.value; Issue.record("The upload unexpectedly completed before cancellation") }
        catch { #expect(error is CancellationError) }
        var after = stages()
        for _ in 0..<30 where after != before {
            try await Task.sleep(for: .milliseconds(50)); after = stages()
        }
        #expect(after == before)
        #expect(try await sftp.home() == "/home/lab")
    }
    @Test func closingTheLinkedSSHTabDisconnectsFileClipboardAndKeepsVNCAlive() async throws {
        // XCTest can inherit SIGPIPE ignored from its launcher. Match a
        // normally launched app so a broken control pipe cannot hide here.
        let previous = signal(SIGPIPE, SIG_DFL)
        defer { signal(SIGPIPE, previous) }
        let settings = try client()
        let config = try String(contentsOfFile: settings.configPath, encoding: .utf8)
        let keychain = KeychainStore(service: "termstead-linux-close-\(UUID())")
        let ssh = Connection(sessionID: nil, title: "SSH close regression", address: "lab", keyDescription: "test", keychain: keychain)
        let tabs = ConnectionStore()
        tabs.add(ssh)
        defer { tabs.closeAll() }
        let plan = SSHLaunchPlan(hops: [], target: .init(alias: "linux-vnc-test", host: "127.0.0.1", user: "lab", port: 2203,
                                                         auth: .automatic, passwordAccount: nil), config: config)
        ssh.start(plan)
        await wait { ssh.isLoggedIn || !ssh.state.isRunning }
        try #require(ssh.isLoggedIn)
        let board = NSPasteboard(name: .init("linux-close-\(UUID())"))
        defer { board.releaseGlobally() }
        let desktop = VNCDesktop(); desktop.pasteboard = board
        defer { desktop.stop() }
        let linked = try #require(ssh.sftp)
        try await open(desktop, fileClient: linked)
        for _ in 0..<500 {
            desktop.hasKeyboard = { false }; desktop.keyboardLeft()
            desktop.hasKeyboard = { true }; desktop.keyboardArrived()
        }
        tabs.close(ssh.id) // the same close operation as the user's tab menu
        for _ in 0..<200 {
            desktop.hasKeyboard = { false }; desktop.keyboardLeft()
            desktop.hasKeyboard = { true }; desktop.keyboardArrived()
            try await Task.sleep(for: .milliseconds(1))
        }
        await wait { desktop.linuxFileConnection == nil }
        #expect(desktop.linuxFileConnection == nil)
        #expect(desktop.phase == .showing)
        #expect(tabs.connections.isEmpty)
        desktop.connectLinuxFiles(client: settings, title: "Reconnected SSH")
        await wait { desktop.linuxFilesReady || desktop.fileCopy?.error != nil }
        #expect(desktop.linuxFilesReady)
        #expect(desktop.phase == .showing)
        desktop.stop(); desktop.stop() // repeated teardown is harmless
    }
    @Test func backgroundSSHNeedsNoTabAndStopsWithTheVNCConnection() async throws {
        let tabs = ConnectionStore()
        let vnc = Connection(sessionID: nil, title: "VNC with background files", address: "lab", keyDescription: "test", kind: .vnc)
        tabs.add(vnc)
        defer { tabs.closeAll() }
        let desktop = try #require(vnc.vnc)
        let board = NSPasteboard(name: .init("linux-background-\(UUID())"))
        desktop.pasteboard = board
        defer { board.releaseGlobally() }
        try await open(desktop, background: true)
        #expect(tabs.connections.count == 1 && tabs.connections[0] === vnc)
        let ssh = try #require(desktop.filesSSH)
        #expect(ssh.isLoggedIn)
        let pid = ssh.terminalView.process.shellPid
        try #require(pid > 0)
        #expect(desktop.linuxFilesReady)
        tabs.close(vnc.id)
        await wait { kill(pid, 0) != 0 && errno == ESRCH }
        #expect(kill(pid, 0) != 0 && errno == ESRCH)
        #expect(desktop.filesSSH == nil && !desktop.linuxFilesReady)
    }
    @Test func configuredSSHStartsWithVNCAndSurvivesDesktopRestart() async throws {
        let board = NSPasteboard(name: .init("linux-configured-\(UUID())"))
        defer { board.releaseGlobally() }
        let desktop = VNCDesktop(); desktop.pasteboard = board
        defer { desktop.stop() }
        desktop.hasKeyboard = { true }
        desktop.connectLinuxFiles(plan: try plan(), title: "Saved file SSH",
                                  keychain: KeychainStore(service: "linux-configured-\(UUID())"))
        let launch = VNCLaunch(session: SessionStore.sample().session("lab-vnc")!, password: "lab")
        func start() {
            desktop.start(launch) { try await RDPSocket.connect(host: "127.0.0.1", port: 5901) }
        }
        start()
        await wait { desktop.linuxFilesReady || desktop.fileCopy?.error != nil }
        try #require(desktop.linuxFilesReady, "\(desktop.fileCopy?.error ?? "clipboard did not start")")
        #expect(desktop.linuxFileConnection == "Saved file SSH")
        start()
        await wait { desktop.linuxFilesReady || desktop.fileCopy?.error != nil }
        #expect(desktop.linuxFilesReady, "\(desktop.fileCopy?.error ?? "clipboard did not restart")")
        #expect(desktop.phase == .showing)
    }
    @Test(arguments: [false, true])
    func rightClickPublishesFilesAndThunarsPasteMenuCopiesThem(_ receive: Bool) async throws {
        let remote = try prepare()
        defer { _ = TestLabVNC.command(["rm", "-rf", "--", remote]) }
        let root = URL.temporaryDirectory.appendingPathComponent("linux-menu-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("menu-proof.txt")
        let payload = Data("Pasted through the remote context menu — ✓".utf8)
        try payload.write(to: file)
        let desktop = VNCDesktop()
        defer { desktop.stop() }
        let board = NSPasteboard(name: .init("linux-menu-\(UUID())"))
        desktop.pasteboard = board
        defer { board.releaseGlobally() }
        try await open(desktop, background: true, receive: receive)
        try await show(remote)
        _ = TestLabVNC.command(["sh", "-c", "w=$(xdotool getactivewindow); xdotool windowmove \"$w\" 0 30 windowsize \"$w\" 1280 740"])
        let window = NSWindow(contentRect: NSRect(x: 20, y: 40, width: 1280, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = desktop.viewport
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        board.clearContents(); board.writeObjects([file] as [NSURL])
        let rect = desktop.view.shownRect
        let point = desktop.view.convert(NSPoint(x: rect.minX + rect.width * 1000 / 1280,
                                                 y: rect.minY + rect.height * 600 / 800), to: nil)
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        desktop.view.rightMouseDown(with: try mouse(.rightMouseDown))
        desktop.view.rightMouseUp(with: try mouse(.rightMouseUp))
        await wait { desktop.fileCopy?.done == true || desktop.fileCopy?.error != nil }
        try #require(desktop.fileCopy?.paste == .ready, "\(desktop.fileCopy?.error ?? "Context clipboard was not prepared")")
        // Preparing a menu must never paste on its own.
        #expect(TestLabVNC.command(["test", "-e", remote + "/menu-proof.txt"]).status != 0)
        try await Task.sleep(for: .milliseconds(300))
        captureMenu(desktop, name: "before")
        let targets = TestLabVNC.command(["timeout", "2", "xclip", "-selection", "clipboard", "-t", "TARGETS", "-o"]).output
        #expect(targets.contains("x-special/gnome-copied-files"), "Remote clipboard targets: \(targets)")
        // Click the actual Paste row in this fixed English Thunar fixture.
        // No keyboard shortcut and no reopening the menu can mask a grey row.
        desktop.pointer(x: 1040, y: 429, buttons: 1)
        desktop.pointer(x: 1040, y: 429, buttons: 0)
        var present = false
        for _ in 0..<100 where !present {
            present = TestLabVNC.command(["test", "-f", remote + "/menu-proof.txt"]).status == 0
            if !present { try await Task.sleep(for: .milliseconds(50)) }
        }
        if !present { captureMenu(desktop, name: "after") }
        try #require(present, "Paste must be enabled and work in the actual Thunar menu")
        try await client().download(remote + "/menu-proof.txt", recursive: false, to: root, as: "verify")
        #expect(try Data(contentsOf: root.appendingPathComponent("verify")) == payload)
        // A second menu can use the existing publication without reuploading.
        #expect(!desktop.prepareContextMenu(ready: { _ in Issue.record("Already-published files should open the menu immediately") }))
        if receive {
            // A remote file copy made with the mouse has no local Copy key
            // event. Its real URI clipboard must still replace files already
            // shared from the Mac, rather than being mistaken for an echo.
            _ = TestLabVNC.command(["sh", "-c", "printf '%s' 'file://\(remote)/menu-proof.txt' | xclip -selection clipboard -t text/uri-list >/dev/null 2>&1"])
            await wait { desktop.fileCopy?.sending == false && desktop.fileCopy?.done == true }
            let received = try #require((board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first)
            #expect(received != file)
            #expect(try Data(contentsOf: received) == payload)
            if received != file { try? FileManager.default.removeItem(at: received.deletingLastPathComponent().deletingLastPathComponent()) }
        } else {
            let revision = board.changeCount
            _ = TestLabVNC.command(["sh", "-c", "printf 'remote clipboard changed' | xclip -selection clipboard >/dev/null 2>&1"])
            try await Task.sleep(for: .milliseconds(300))
            #expect(board.changeCount == revision)
            var ready: Bool?
            #expect(desktop.prepareContextMenu { ready = $0 })
            await wait { ready != nil }
            #expect(ready == true) // send-only still invalidates stale metadata
        }
    }
    @Test func expiredRemoteFileClipboardIsIgnoredAndTheNextCopyWorks() async throws {
        let remote = "/tmp/termstead-linux-\(UUID())"
        defer { _ = TestLabVNC.command(["rm", "-rf", "--", remote]) }
        // Mimic reconnecting after a test removed its fixture directory but
        // xclip still owns its old file URI. No local pasteboard is touched.
        _ = TestLabVNC.command(["sh", "-c", "printf '%s' 'file://\(remote)/missing.txt' | xclip -selection clipboard -t text/uri-list >/dev/null 2>&1"])
        let bridge = VNCLinuxFiles(client: try client(), title: "Expired clipboard regression")
        defer { bridge.close() }
        var selections: [VNCLinuxFiles.Selection] = []
        var errors: [String] = [], texts: [String] = []
        bridge.onReady = { [weak bridge] in bridge?.setActive(true) }
        bridge.onSelection = { selections.append($0) }
        bridge.onError = { errors.append($0) }
        bridge.onText = { texts.append($0) }
        try bridge.start()
        await wait { !selections.isEmpty || !errors.isEmpty }
        #expect(errors.isEmpty, "A stale automatic inspection must not open the copy-error dialog")
        try #require(selections.last?.files.isEmpty == true)
        #expect(texts.isEmpty, "Expired file URLs must not become clipboard text")
        #expect(bridge.isReady)
        let live = remote + "/live.txt"
        try #require(TestLabVNC.command(["sh", "-c", "mkdir -p '\(remote)'; printf 'live after stale' > '\(live)'"]).status == 0)
        _ = TestLabVNC.command(["sh", "-c", "printf '%s' 'file://\(live)' | xclip -selection clipboard -t text/uri-list >/dev/null 2>&1"])
        await wait { selections.last?.files.first?.path == live }
        let selection = try #require(selections.last)
        try #require(selection.files.first?.path == live)
        let urls = try await bridge.download(selection)
        defer {
            for url in urls { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        }
        #expect(try Data(contentsOf: #require(urls.first)) == Data("live after stale".utf8))
        #expect(errors.isEmpty)
    }
    private func captureMenu(_ desktop: VNCDesktop, name: String) {
        guard let surface = desktop.view.layer?.sublayers?.first?.contents as? IOSurface else { return }
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        guard let context = CGContext(data: IOSurfaceGetBaseAddress(surface), width: surface.width, height: surface.height,
                                      bitsPerComponent: 8, bytesPerRow: IOSurfaceGetBytesPerRow(surface), space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
              let image = context.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: "/private/tmp/termstead-linux-menu-\(name).png"))
    }
}
