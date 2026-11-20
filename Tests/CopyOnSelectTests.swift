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

    @Test func emptySelectionPreservesTheClipboard() {
        let (view, pasteboard) = terminal(copyOnSelect: false)
        defer { pasteboard.releaseGlobally() }
        let empty = SSHTerminalView(frame: view.frame)
        empty.copyOnSelect = false
        empty.copyPasteboard = pasteboard
        pasteboard.setString("existing clipboard", forType: .string)
        empty.selectAll(nil)
        empty.copy(empty)
        #expect(pasteboard.string(forType: .string) == "existing clipboard")
    }

    @Test func doubleClickOnEitherCellOfAnEmojiCopiesIt() throws {
        let (view, pasteboard) = terminal(copyOnSelect: false)
        defer { pasteboard.releaseGlobally() }
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.feed(text: "\u{1b}[H🙂!")
        let pixels = try #require(view.cellSizeInPixels(source: view.getTerminal()))
        let width = CGFloat(pixels.width) / window.backingScaleFactor
        for column in 0...1 {
            let point = NSPoint(x: (CGFloat(column) + 0.5) * width, y: view.bounds.maxY - 6)
            let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
                location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 2, pressure: 1))
            view.mouseDown(with: click)
            #expect(view.getSelection() == "🙂")
            view.copy(view)
            #expect(pasteboard.string(forType: .string) == "🙂")
        }
    }
}
