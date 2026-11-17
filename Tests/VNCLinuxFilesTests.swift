import AppKit
import Foundation
import Darwin
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
    private func open(_ desktop: VNCDesktop, fileClient: SFTPClient? = nil) async throws {
        // TigerVNC desktop and the selected SSH connection are the same user
        // and machine. Named pasteboards never touch Pavel's clipboard.
        desktop.hasKeyboard = { true }
        desktop.start(VNCLaunch(session: SessionStore.sample().session("lab-vnc")!, password: "lab")) {
            try await RDPSocket.connect(host: "127.0.0.1", port: 5901)
        }
        await wait { desktop.phase != .connecting }
        try #require(desktop.phase == .showing)
        #expect(!desktop.supportsFiles) // no Apple file-transfer extension
        desktop.connectLinuxFiles(client: try fileClient ?? client(), title: "Linux test SSH")
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
        try await open(desktop, fileClient: #require(ssh.sftp))
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
}
