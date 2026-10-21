import AppKit
import Foundation
import Testing
@testable import Termstead

struct RDPClipboardTextTests {
    @Test func lineEndingsChangeOnTheWay() {
        #expect(RDPDesktop.serverText("one\ntwo\r\nthree") == "one\r\ntwo\r\nthree")
        #expect(RDPDesktop.macText("one\r\ntwo") == "one\ntwo")
    }
}

/// Text copied on either side reaches the other, against the lab's xrdp —
/// its clipboard read and set with xclip in the container. The Mac's side
/// is a private pasteboard, never the user's.
@MainActor
@Suite(.serialized, .enabled(if: TestLabRDP.isUp && TestLabRDP.docker != nil,
                             "the lab's RDP server is not running (TestLab/lab.sh up)"))
struct RDPClipboardTests {
    private func wait(upTo seconds: Double, until done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// The X display of the session xrdp started for this connection: the
    /// newest, as every connection gets one of its own.
    private func display() throws -> String {
        let sockets = TestLabRDP.inContainer(["ls", "-t", "/tmp/.X11-unix"]).output
        let number = try #require(sockets.split(whereSeparator: \.isNewline).first?.dropFirst())
        return ":\(number)"
    }

    /// `xclip` as the lab user, in their session.
    private func xclip(_ arguments: String) throws -> (status: Int32, output: String) {
        TestLabRDP.inContainer(["su", "lab", "-c",
                                "DISPLAY=\(try display()) timeout 5 xclip -selection clipboard \(arguments)"])
    }

    private func open(pasteboard: NSPasteboard) async throws -> RDPDesktop {
        let desktop = RDPDesktop()
        desktop.knownHosts = TestLabRDP.knownHosts
        desktop.pasteboard = pasteboard
        desktop.availableSize = { (CGSize(width: 800, height: 600), 1) }
        var launch = RDPLaunch(session: SessionStore.sample().session("lab-rdp")!, password: "lab")
        launch.options.sound = false
        desktop.start(launch) { try await RDPSocket.connect(host: "127.0.0.1", port: 3390) }
        await TestLabRDP.waitUntilShowing(desktop)
        try #require(desktop.phase == .showing)
        return desktop
    }

    @Test func textCopiedHereCanBePastedThere() async throws {
        let pasteboard = NSPasteboard(name: .init("termstead-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let text = "from the Mac \(Int.random(in: 1000...9999)) — ✓"
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let desktop = try await open(pasteboard: pasteboard)
        var pasted = ""
        for _ in 0..<20 where pasted != text {
            try await Task.sleep(for: .milliseconds(500))
            pasted = try xclip("-o").output
        }
        #expect(pasted == text)
        desktop.stop()
    }

    @Test func textCopiedThereComesHere() async throws {
        let pasteboard = NSPasteboard(name: .init("termstead-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let desktop = try await open(pasteboard: pasteboard)
        try await Task.sleep(for: .seconds(1))

        let text = "from xrdp \(Int.random(in: 1000...9999))"
        // xclip serves the selection in the background; one paste, then it goes.
        _ = TestLabRDP.inContainer(["su", "lab", "-c",
                                    "printf '%s' '\(text)' | DISPLAY=\(try display()) xclip -selection clipboard -l 1 &"])
        await wait(upTo: 10) { pasteboard.string(forType: .string) == text }
        #expect(pasteboard.string(forType: .string) == text)
        desktop.stop()
    }
}
