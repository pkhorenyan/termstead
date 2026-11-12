import AppKit
import Foundation
import Testing
@testable import Termstead

/// Opt-in verification against an isolated macOS VM with Screen Sharing and
/// SSH enabled. Uses a named pasteboard; never reads the user's clipboard.
@MainActor @Suite(.serialized)
struct VNCMacOSTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERMSTEAD_MACOS_VNC_HOST"] != nil))
    func nativeUnicodeClipboardAndFocus() async throws {
        let env = ProcessInfo.processInfo.environment
        let host = try #require(env["TERMSTEAD_MACOS_VNC_HOST"])
        let port = Int(env["TERMSTEAD_MACOS_VNC_PORT"] ?? "5900") ?? 5900
        let config = try #require(env["TERMSTEAD_MACOS_VNC_SSH_CONFIG"])
        func guest(_ command: String) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            // pbcopy/pbpaste transcode through the locale, unlike Cocoa apps.
            process.arguments = ["-F", config, "macos-vnc-vm", "export LC_CTYPE=UTF-8; " + command]
            let output = Pipe()
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
            return String(decoding: data, as: UTF8.self)
        }
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
