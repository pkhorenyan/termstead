import AppKit
import Testing
@testable import Termstead

@MainActor
struct CopyOnSelectTests {
    private func terminal(copyOnSelect: Bool) -> (SSHTerminalView, NSPasteboard) {
        let view = SSHTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("termstead-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        view.copyPasteboard = pasteboard
        view.copyOnSelect = copyOnSelect
        view.feed(text: "hello from the lab\r\n")
        return (view, pasteboard)
    }

    private func settle() async throws {
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func selectingCopies() async throws {
        let (view, pasteboard) = terminal(copyOnSelect: true)
        defer { pasteboard.releaseGlobally() }
        view.selectAll(nil)
        try await settle()
        #expect(pasteboard.string(forType: .string)?.contains("hello from the lab") == true)
    }

    @Test func offMeansOff() async throws {
        let (view, pasteboard) = terminal(copyOnSelect: false)
        defer { pasteboard.releaseGlobally() }
        view.selectAll(nil)
        try await settle()
        #expect(pasteboard.string(forType: .string) == nil)
    }
}
