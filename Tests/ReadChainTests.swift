import AppKit
import SwiftTerm
import Testing
@testable import Termstead

/// The vendored SwiftTerm's read loop (Vendor/SwiftTerm/PATCHES.md): one
/// DispatchIO read at a time. Before the patch every partial delivery started
/// another read chain, and a flood of output left tens of thousands of them —
/// and hundreds of MB of heap — behind.
@MainActor
struct ReadChainTests {
    private func screen(_ view: SSHTerminalView) -> String {
        String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self)
    }

    /// Suspends, so SwiftTerm's main-queue deliveries can run (see CLAUDE.md).
    private func wait(timeout: TimeInterval = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func aFloodLeavesOneReadOutstanding() async throws {
        let view = SSHTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.startProcess(executable: "/bin/sh", args: ["-c", "seq 1 200000; sleep 5"],
                          environment: nil, execName: "sh")
        defer { view.terminate() }
        try await wait { screen(view).contains("200000") }

        let process = try #require(view.process)
        // Many reads were needed; at every moment at most one was pending.
        #expect(process.readsCompleted > 10)
        #expect(process.readsArmed - process.readsCompleted <= 1,
                "armed \(process.readsArmed), completed \(process.readsCompleted)")
    }

    /// Reading only re-arms when a read completes, but a read delivers what
    /// it has as it arrives: a prompt must show at once, not after 128 KB.
    @Test func slowOutputStillArrivesAtOnce() async throws {
        let view = SSHTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.startProcess(executable: "/bin/sh", args: ["-c", "echo first; sleep 1; echo second; sleep 5"],
                          environment: nil, execName: "sh")
        defer { view.terminate() }
        try await wait(timeout: 3) { screen(view).contains("first") }
        try await wait(timeout: 4) { screen(view).contains("second") }
        #expect(view.process?.running == true, "both lines came while the process was still running")
    }
}
