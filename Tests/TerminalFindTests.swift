import AppKit
import Testing
@testable import Termstead

@MainActor
struct TerminalFindTests {
    private func terminal() -> (SSHTerminalView, NSPasteboard) {
        let view = SSHTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("termstead-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        view.copyPasteboard = pasteboard
        view.copyOnSelect = true
        view.feed(text: "boot ok\r\nnginx: ERROR upstream timed out\r\ndisk ok\r\n")
        return (view, pasteboard)
    }

    private func settle() async throws {
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func findSelectsTheMatch() {
        let (view, pasteboard) = terminal()
        defer { pasteboard.releaseGlobally() }
        #expect(view.find("upstream", upward: true, caseSensitive: false))
        #expect(view.getSelection() == "upstream")
    }

    @Test func caseSensitivityIsHonoured() {
        let (view, pasteboard) = terminal()
        defer { pasteboard.releaseGlobally() }
        #expect(!view.find("error", upward: true, caseSensitive: true))
        #expect(view.find("error", upward: true, caseSensitive: false))
    }

    @Test func missingTermReportsNotFound() {
        let (view, pasteboard) = terminal()
        defer { pasteboard.releaseGlobally() }
        #expect(!view.find("kernel panic", upward: true, caseSensitive: false))
        #expect(!view.find("", upward: true, caseSensitive: false))
    }

    /// A match is a selection; copy-on-select must not put it on the clipboard.
    @Test func findingLeavesTheClipboardAlone() async throws {
        let (view, pasteboard) = terminal()
        defer { pasteboard.releaseGlobally() }
        view.find("upstream", upward: true, caseSensitive: false)
        view.find("ok", upward: true, caseSensitive: false)
        try await settle()
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test func endFindClearsTheSelection() {
        let (view, pasteboard) = terminal()
        defer { pasteboard.releaseGlobally() }
        view.find("disk", upward: true, caseSensitive: false)
        view.endFind()
        #expect(!view.selectionActive)
    }

    @Test func appStateTracksStatusAndClearsTheOldTab() {
        let (first, firstBoard) = terminal()
        let (second, secondBoard) = terminal()
        defer { firstBoard.releaseGlobally(); secondBoard.releaseGlobally() }
        let state = AppState()
        state.findQuery = "nginx"
        state.find(in: first, upward: true)
        #expect(state.findStatus == .found)
        #expect(first.selectionActive)

        state.find(in: second, upward: true)
        #expect(!first.selectionActive)
        #expect(second.selectionActive)

        state.findQuery = "absent"
        state.find(in: second, upward: true)
        #expect(state.findStatus == .notFound)

        state.closeFind()
        #expect(!state.isFindOpen)
        #expect(state.findStatus == .idle)
    }

    @Test func scrollbackSizeIsApplied() {
        let view = SSHTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        view.scrollbackLines = 50_000
        #expect(view.scrollbackLines == 50_000)
        #expect(view.getTerminal().options.scrollback == 50_000)

        // Keeps more than SwiftTerm's default of 500 lines.
        view.scrollbackLines = 10_000
        for index in 0..<2_000 { view.feed(text: "line \(index)\r\n") }
        #expect(view.find("line 3", upward: false, caseSensitive: false))
        #expect(view.getSelection() == "line 3")
    }
}
