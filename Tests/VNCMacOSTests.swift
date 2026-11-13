import AppKit
import CryptoKit
import Foundation
import Testing
@testable import Termstead

/// Opt-in verification against an isolated macOS VM with Screen Sharing and
/// SSH enabled. Uses a named pasteboard; never reads the user's clipboard.
@MainActor @Suite(.serialized)
struct VNCMacOSTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERMSTEAD_MACOS_VNC_HOST"] != nil), arguments: [false, true])
    func nativeMultipleSelectionsPasteIntoFinder(_ receive: Bool) async throws {
        try await Task.sleep(for: .seconds(5))
        let env = ProcessInfo.processInfo.environment
        let host = try #require(env["TERMSTEAD_MACOS_VNC_HOST"])
        let port = Int(env["TERMSTEAD_MACOS_VNC_PORT"] ?? "5900") ?? 5900
        let root = URL.temporaryDirectory.appendingPathComponent("termstead-native-multiple-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("test_rdp")
        let empty = root.appendingPathComponent("Пустая папка 🙂")
        let file = root.appendingPathComponent("данные %.bin")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        let bytes = Data((0..<131_103).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: file)
        try Data("nested proof".utf8).write(to: folder.appendingPathComponent("proof.txt"))
        let destination = "/Users/admin/Desktop/Termstead Multiple Check \(UUID())"
        let quote = SFTPClient.shellQuote
        _ = try guest("mkdir -p " + quote(destination) + "; open " + quote(destination))
        defer { _ = try? guest("rm -rf " + quote(destination)) }
        let board = NSPasteboard(name: .init("termstead-native-multiple-\(UUID())"))
        defer { board.releaseGlobally() }
        let desktop = VNCDesktop(); defer { desktop.stop() }
        desktop.pasteboard = board; desktop.hasKeyboard = { true }
        var session = Session(id: "native-multiple", user: env["TERMSTEAD_MACOS_VNC_USER"] ?? "admin",
                              host: host, port: port, icon: .monitor, auth: .password)
        session.kind = .vnc; session.vnc.autoReconnect = false
        session.vnc.receiveClipboard = receive
        desktop.start(VNCLaunch(session: session, password: env["TERMSTEAD_MACOS_VNC_PASSWORD"] ?? "admin")) {
            try await RDPSocket.connect(host: host, port: port)
        }
        let connectedDeadline = Date().addingTimeInterval(15)
        while desktop.phase != .showing, Date() < connectedDeadline { try await Task.sleep(for: .milliseconds(50)) }
        try #require(desktop.phase == .showing)
        desktop.pointer(x: 1000, y: 800, buttons: 1)
        desktop.pointer(x: 1000, y: 800, buttons: 0)
        try await Task.sleep(for: .seconds(3))
        board.clearContents(); board.writeObjects([folder, empty, file] as [NSURL])
        desktop.view.paste(nil)
        var pasted = false
        let deadline = Date().addingTimeInterval(25)
        while !pasted, Date() < deadline {
            pasted = try guest("test -f " + quote(destination + "/test_rdp/proof.txt") +
                " && test -d " + quote(destination + "/Пустая папка 🙂") +
                " && test -f " + quote(destination + "/данные %.bin") + " && printf yes || true") == "yes"
            if !pasted { try await Task.sleep(for: .milliseconds(100)) }
        }
        try #require(pasted, "Actual Finder multi-selection Paste, receive=\(receive): \(String(describing: desktop.fileCopy))")
        let actual = try guest("base64 -i " + quote(destination + "/данные %.bin"))
        #expect(Data(base64Encoded: actual, options: .ignoreUnknownCharacters) == bytes)
        #expect(try guest("cat " + quote(destination + "/test_rdp/proof.txt")) == "nested proof")
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

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERMSTEAD_MACOS_VNC_HOST"] != nil))
    func nativeFileTransportInBothDirections() async throws {
        // The native agent tears down the previous viewer asynchronously.
        // Let its input/clipboard ownership settle between live tests.
        try await Task.sleep(for: .seconds(5))
        let env = ProcessInfo.processInfo.environment
        let host = try #require(env["TERMSTEAD_MACOS_VNC_HOST"])
        let port = Int(env["TERMSTEAD_MACOS_VNC_PORT"] ?? "5900") ?? 5900
        let board = NSPasteboard(name: .init("termstead-native-files-\(UUID())"))
        defer { board.releaseGlobally() }
        let desktop = VNCDesktop(); defer { desktop.stop() }
        var focused = true
        desktop.pasteboard = board; desktop.hasKeyboard = { focused }
        var session = Session(id: "native-mac-files", user: env["TERMSTEAD_MACOS_VNC_USER"] ?? "admin",
                              host: host, port: port, icon: .monitor, auth: .password)
        // Deliberately retain the default Linux keyboard profile: native
        // file paste must still use Finder's Command-V, not Control-V.
        session.kind = .vnc; session.vnc.autoReconnect = false
        desktop.start(VNCLaunch(session: session, password: env["TERMSTEAD_MACOS_VNC_PASSWORD"] ?? "admin")) {
            try await RDPSocket.connect(host: host, port: port)
        }
        func wait(_ condition: () -> Bool) async {
            let until = Date().addingTimeInterval(30)
            while !condition(), Date() < until { try? await Task.sleep(for: .milliseconds(50)) }
        }
        await wait { desktop.phase == .showing }
        try #require(desktop.phase == .showing && desktop.supportsFiles, "Native VNC phase: \(desktop.phase)")
        let root = URL.temporaryDirectory.appendingPathComponent("termstead-live-files-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("test_rdp")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let bytes = Data((0..<131_103).map { UInt8(truncatingIfNeeded: $0) })
        let text = "Termstead — привет 日本語 🙂\n"
        try bytes.write(to: source.appendingPathComponent("binary.bin"))
        try Data().write(to: source.appendingPathComponent("empty"))
        try Data(text.utf8).write(to: source.appendingPathComponent("nested/данные.txt"))
        let quote = SFTPClient.shellQuote
        let destination = "/Users/admin/Desktop/Termstead Paste Check \(UUID())"
        _ = try guest("mkdir -p " + quote(destination) + "; open " + quote(destination))
        defer { _ = try? guest("rm -rf " + quote(destination)) }
        try await Task.sleep(for: .seconds(1))
        // Activate Finder through the VNC viewer, as a user does before
        // pasting. Opening a window over SSH alone does not hand it input.
        desktop.pointer(x: 1000, y: 900, buttons: 1)
        desktop.pointer(x: 1000, y: 900, buttons: 0)
        // Let the native server's input handoff guard settle after opening
        // and activating a window outside the viewer.
        try await Task.sleep(for: .seconds(3))
        focused = false; desktop.keyboardLeft()
        board.clearContents(); board.writeObjects([source as NSURL])
        focused = true; desktop.keyboardArrived()
        try await Task.sleep(for: .milliseconds(350))
        // An old remote selection arriving after focus settled must not
        // replace the new local folder before the user's Command-V.
        _ = try guest("/tmp/termstead-file-clipboard text 'Termstead Files'")
        try await Task.sleep(for: .milliseconds(350))
        try #require((board.readObjects(forClasses: [NSURL.self]) as? [URL]) == [source])
        desktop.edit(0x76)
        await wait { desktop.fileCopy?.done == true || desktop.fileCopy?.error != nil }
        try #require(desktop.fileCopy?.done == true, "Upload: \(String(describing: desktop.fileCopy))")
        let paths = try JSONDecoder().decode([String].self, from: Data(try guest("/tmp/termstead-file-clipboard inspect").utf8))
        let remote = try #require(paths.first)
        try #require(paths.count == 1 && remote.hasPrefix("/private/tmp/Termstead-"))
        // The SSH channel only inspects guest results; all file contents were
        // transferred by the production VNC engine over its existing socket.
        let uploaded = try guest("base64 -i " + quote(remote + "/binary.bin"))
        #expect(Data(base64Encoded: uploaded, options: .ignoreUnknownCharacters) == bytes)
        #expect(try guest("cat " + quote(remote + "/nested/данные.txt")) == text)
        #expect(try guest("wc -c < " + quote(remote + "/empty")).trimmingCharacters(in: .whitespacesAndNewlines) == "0")
        var pasted = false
        let pasteDeadline = Date().addingTimeInterval(12)
        while !pasted, Date() < pasteDeadline {
            pasted = try guest("test -f " + quote(destination + "/test_rdp/nested/данные.txt") + " && printf yes || true") == "yes"
            if !pasted { try await Task.sleep(for: .milliseconds(100)) }
        }
        try #require(pasted, "Finder must paste the new folder using its original test_rdp name")
        let pastedBytes = try guest("base64 -i " + quote(destination + "/test_rdp/binary.bin"))
        #expect(Data(base64Encoded: pastedBytes, options: .ignoreUnknownCharacters) == bytes)

        let incoming = "/Users/admin/Desktop/Termstead Files"
        let expected = try guest("shasum -a 256 " + quote(incoming + "/binary.bin")).split(separator: " ").first
        // Native clipboard fetches filter ordinary Finder public.file-url
        // entries. Exercise the file transport with an explicit node fixture;
        // this does not claim end-to-end Finder Command-C integration.
        desktop.edit(0x63)
        _ = try guest("/tmp/termstead-file-clipboard transport-files " + quote(incoming))
        await wait { desktop.fileCopy?.sending == false && (desktop.fileCopy?.done == true || desktop.fileCopy?.error != nil) }
        try #require(desktop.fileCopy?.sending == false && desktop.fileCopy?.done == true,
                     "Download: \(String(describing: desktop.fileCopy))")
        let local = try #require((board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first)
        let binary = try Data(contentsOf: local.appendingPathComponent("binary.bin"))
        #expect(SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined() == expected.map(String.init))
        #expect(try Data(contentsOf: local.appendingPathComponent("empty")).isEmpty)
        #expect(try String(contentsOf: local.appendingPathComponent("nested/данные.txt"), encoding: .utf8) == text)
    }
}
