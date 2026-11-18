import AppKit
import Foundation
import Testing
@testable import Termstead

/// Opt-in verification against an isolated macOS VM with Screen Sharing and
/// SSH enabled. Uses a named pasteboard; never reads the user's clipboard.
@MainActor @Suite(.serialized)
struct VNCMacOSTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERMSTEAD_MACOS_VNC_HOST"] != nil))
    func sftpBesideMacVNCTransfersFilesWithoutAnSSHTab() async throws {
        let env = ProcessInfo.processInfo.environment
        let config = try #require(env["TERMSTEAD_MACOS_VNC_SSH_CONFIG"])
        let lines = try String(contentsOfFile: config, encoding: .utf8).components(separatedBy: .newlines)
        let address = try #require(lines.first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("HostName ") }?
            .trimmingCharacters(in: .whitespaces).dropFirst("HostName ".count))
        let lab = URL(fileURLWithPath: config).deletingLastPathComponent()
        var session = Session(id: "macos-sftp-test", user: "admin", host: "127.0.0.1",
                              port: Int(env["TERMSTEAD_MACOS_VNC_PORT"] ?? "15900") ?? 15900,
                              icon: .monitor, auth: .password)
        session.kind = .vnc
        session.persistentID = UUID()
        session.vnc.autoReconnect = false
        var access = VNCFileAccess()
        access.host = String(address)
        access.user = "admin"
        access.keyPath = lab.appendingPathComponent("id_ed25519").path
        session.vnc.fileAccess = access
        var plan = try ConnectionStore.vncFileAccessPlan(for: session, in: SessionStore.sample())
        plan.config = plan.config.replacingOccurrences(of: "\nHost *\n", with:
            "\n  HostKeyAlias termstead-macos-lab\n  UserKnownHostsFile \"\(lab.appendingPathComponent("known_hosts").path)\"\n  StrictHostKeyChecking yes\n\nHost *\n")

        let connection = Connection(sessionID: nil, title: "macOS SFTP", address: session.host,
                                    keyDescription: "VNC", kind: .vnc)
        defer { connection.close() }
        var fileLoggedIn = false
        connection.onLogin = { fileLoggedIn = true }
        connection.configureFileAccess(plan, title: "admin@macOS")
        connection.start(VNCLaunch(session: session, password: env["TERMSTEAD_MACOS_VNC_PASSWORD"] ?? "admin"))
        let deadline = Date().addingTimeInterval(35)
        while !fileLoggedIn && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(connection.vnc?.phase == .showing)
        try #require(fileLoggedIn && connection.fileAccess?.sftp != nil,
                     "SFTP login: \(connection.fileAccessProblem ?? "no connection")")

        let browser = connection.fileBrowser
        let board = NSPasteboard(name: .init("termstead-macos-sftp-\(UUID())"))
        browser.pasteboard = board
        defer { board.releaseGlobally() }
        browser.isShown = true
        let remote = "/Users/admin/Desktop/termstead-sftp-\(UUID())"
        _ = try guest("mkdir -p " + SFTPClient.shellQuote(remote))
        defer { _ = try? guest("rm -rf " + SFTPClient.shellQuote(remote)) }
        await browser.load(remote)
        try #require(browser.path == remote && browser.problem == nil,
                     "SFTP listing: \(browser.path ?? "no path"), \(browser.problem ?? "no error")")

        let local = URL.temporaryDirectory.appendingPathComponent("macos-sftp-\(UUID())")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: local) }
        let file = local.appendingPathComponent("данные.bin")
        let bytes = Data([0, 255, 42, 10, 13])
        try bytes.write(to: file)
        board.clearContents()
        #expect(board.writeObjects([file as NSURL]))
        browser.paste()
        let transferDeadline = Date().addingTimeInterval(20)
        while !browser.files.contains(where: { $0.name == file.lastPathComponent }) && Date() < transferDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let entry = try #require(browser.files.first { $0.name == file.lastPathComponent })
        #expect(try guest("base64 -i " + SFTPClient.shellQuote(remote + "/" + file.lastPathComponent))
            .trimmingCharacters(in: .whitespacesAndNewlines) == bytes.base64EncodedString())
        board.clearContents()
        await browser.copyToClipboard(entry)
        let copied = try #require((board.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first)
        #expect(copied.lastPathComponent == file.lastPathComponent)
        #expect(try Data(contentsOf: copied) == bytes)

        let folder = local.appendingPathComponent("test_rdp")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try bytes.write(to: folder.appendingPathComponent("nested.bin"))
        board.clearContents()
        #expect(board.writeObjects([folder as NSURL]))
        browser.paste()
        let folderDeadline = Date().addingTimeInterval(20)
        while !browser.files.contains(where: { $0.name == folder.lastPathComponent }) && Date() < folderDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let folderEntry = try #require(browser.files.first { $0.name == folder.lastPathComponent })
        #expect(try guest("base64 -i " + SFTPClient.shellQuote(remote + "/test_rdp/nested.bin"))
            .trimmingCharacters(in: .whitespacesAndNewlines) == bytes.base64EncodedString())
        board.clearContents()
        await browser.copyToClipboard(folderEntry)
        let copiedFolder = try #require((board.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first)
        #expect(copiedFolder.lastPathComponent == "test_rdp")
        #expect(try Data(contentsOf: copiedFolder.appendingPathComponent("nested.bin")) == bytes)
    }

    private func guest(_ command: String) throws -> String {
        let config = try #require(ProcessInfo.processInfo.environment["TERMSTEAD_MACOS_VNC_SSH_CONFIG"])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-F", config, "macos-vnc-vm", "export LC_CTYPE=UTF-8; " + command]
        let output = Pipe()
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERMSTEAD_MACOS_VNC_HOST"] != nil))
    func nativeUnicodeClipboardAndFocus() async throws {
        let env = ProcessInfo.processInfo.environment
        let host = try #require(env["TERMSTEAD_MACOS_VNC_HOST"])
        let port = Int(env["TERMSTEAD_MACOS_VNC_PORT"] ?? "5900") ?? 5900
        _ = try guest("sw_vers -productVersion")
        let board = NSPasteboard(name: .init("termstead-native-mac-\(UUID())"))
        defer { board.releaseGlobally() }
        let desktop = VNCDesktop(); defer { desktop.stop() }
        var focused = true
        desktop.pasteboard = board; desktop.hasKeyboard = { focused }
        var session = Session(id: "native-mac-test", user: env["TERMSTEAD_MACOS_VNC_USER"] ?? "admin",
                              host: host, port: port, icon: .monitor, auth: .password)
        session.kind = .vnc; session.vnc.autoReconnect = false
        let launch = VNCLaunch(session: session, password: env["TERMSTEAD_MACOS_VNC_PASSWORD"] ?? "admin")
        desktop.start(launch) { try await RDPSocket.connect(host: host, port: port) }
        func wait(_ condition: () -> Bool) async {
            let until = Date().addingTimeInterval(12)
            while !condition(), Date() < until { try? await Task.sleep(for: .milliseconds(50)) }
        }
        await wait { desktop.phase == .showing }
        try #require(desktop.phase == .showing && desktop.size != nil, "Native VNC phase: \(desktop.phase)")
        let local = "Termstead → macOS: привет 日本語 🙂"
        board.clearContents(); board.setString(local, forType: .string)
        desktop.offerClipboard(onPaste: true)
        var remote = ""
        for _ in 0..<40 where remote != local {
            try await Task.sleep(for: .milliseconds(100))
            remote = try guest("pbpaste")
        }
        try #require(remote == local)
        let incoming = "macOS → Termstead: привет 日本語 ✓"
        _ = try guest("printf '%s' '\(incoming)' | pbcopy")
        await wait { board.string(forType: .string) == incoming }
        try #require(board.string(forType: .string) == incoming)
        let settled = board.changeCount
        try await Task.sleep(for: .milliseconds(800))
        #expect(board.changeCount == settled, "clipboard echoes must settle")
        focused = false; desktop.keyboardLeft()
        let inactive = "macOS inactive: новый текст ✓"
        _ = try guest("printf '%s' '\(inactive)' | pbcopy")
        try await Task.sleep(for: .milliseconds(700))
        #expect(board.string(forType: .string) == incoming)
        focused = true; desktop.keyboardArrived()
        await wait { board.string(forType: .string) == inactive }
        #expect(board.string(forType: .string) == inactive)
    }
}
