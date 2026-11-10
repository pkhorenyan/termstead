import AppKit
import Testing
@testable import Termstead

@MainActor
@Suite(.serialized)
struct SelectionAutoscrollTests {
    private func terminal() -> (NSWindow, SSHTerminalView) {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        let view = SSHTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        view.copyOnSelect = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.feed(text: (1...200).map { "line \($0)" }.joined(separator: "\r\n"))
        return (window, view)
    }

    private func mouse(_ type: NSEvent.EventType, in view: SSHTerminalView, y: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(NSPoint(x: 20, y: y), to: nil),
                           modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: view.window?.windowNumber ?? 0, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func drag(_ view: SSHTerminalView, to y: CGFloat) {
        view.mouseDown(with: mouse(.leftMouseDown, in: view, y: view.bounds.midY))
        view.mouseDragged(with: mouse(.leftMouseDragged, in: view, y: y))
    }

    @Test func aStationaryPointerAboveScrollsAndExtendsFromThePress() async throws {
        let (window, view) = terminal()
        defer { window.close() }
        let top = view.getTerminal().getTopVisibleRow()
        drag(view, to: view.bounds.maxY + 8)
        let initial = try #require(view.getSelection())
        #expect(initial.contains("line"), "The first drag must retain the press as its anchor")
        try await Task.sleep(for: .milliseconds(180))
        #expect(view.getTerminal().getTopVisibleRow() < top)
        let extended = try #require(view.getSelection())
        #expect(extended.count > initial.count)
        #expect(extended.hasSuffix(initial), "The anchor must stay on the originally pressed row")
        view.mouseUp(with: mouse(.leftMouseUp, in: view, y: view.bounds.maxY + 8))
    }

    @Test func aStationaryPointerBelowScrollsDownAndExtendsTheSelection() async throws {
        let (window, view) = terminal()
        defer { window.close() }
        view.scrollUp(lines: 30)
        let top = view.getTerminal().getTopVisibleRow()
        drag(view, to: -8)
        let initial = try #require(view.getSelection())
        try await Task.sleep(for: .milliseconds(180))
        #expect(view.getTerminal().getTopVisibleRow() > top)
        let extended = try #require(view.getSelection())
        #expect(extended.count > initial.count)
        #expect(extended.hasPrefix(initial))
        view.mouseUp(with: mouse(.leftMouseUp, in: view, y: -8))
    }

    @Test func returningInsideAndReleasingStopAutoscroll() async throws {
        let (window, view) = terminal()
        defer { window.close() }
        drag(view, to: view.bounds.maxY + 8)
        try await Task.sleep(for: .milliseconds(120))
        view.mouseDragged(with: mouse(.leftMouseDragged, in: view, y: view.bounds.maxY - 20))
        let inside = view.getTerminal().getTopVisibleRow()
        try await Task.sleep(for: .milliseconds(140))
        #expect(view.getTerminal().getTopVisibleRow() == inside)

        view.mouseDragged(with: mouse(.leftMouseDragged, in: view, y: view.bounds.maxY + 8))
        try await Task.sleep(for: .milliseconds(120))
        #expect(view.getTerminal().getTopVisibleRow() < inside)
        view.mouseUp(with: mouse(.leftMouseUp, in: view, y: view.bounds.maxY + 8))
        let released = view.getTerminal().getTopVisibleRow()
        let selected = view.getSelection()
        try await Task.sleep(for: .milliseconds(140))
        #expect(view.getTerminal().getTopVisibleRow() == released)
        #expect(view.getSelection() == selected)
    }

    @Test func autoscrollRunsWhileAppKitTracksTheDrag() {
        let (window, view) = terminal()
        defer { window.close() }
        let top = view.getTerminal().getTopVisibleRow()
        drag(view, to: view.bounds.maxY + 8)
        let deadline = Date().addingTimeInterval(0.3)
        while view.getTerminal().getTopVisibleRow() == top, Date() < deadline {
            RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.02))
        }
        #expect(view.getTerminal().getTopVisibleRow() < top)
        view.mouseUp(with: mouse(.leftMouseUp, in: view, y: view.bounds.maxY + 8))
    }

    @Test func removingTheTerminalStopsAutoscroll() async throws {
        let (window, view) = terminal()
        defer { window.close() }
        drag(view, to: view.bounds.maxY + 8)
        try await Task.sleep(for: .milliseconds(120))
        view.removeFromSuperview()
        #expect(view.window == nil)
        let top = view.getTerminal().getTopVisibleRow()
        try await Task.sleep(for: .milliseconds(140))
        #expect(view.getTerminal().getTopVisibleRow() == top)
    }

    @Test func mouseReportingLeavesScrollingToTheRemoteApplication() async throws {
        let (window, view) = terminal()
        defer { window.close() }
        view.feed(text: "\u{1b}[?1002h")
        let top = view.getTerminal().getTopVisibleRow()
        drag(view, to: view.bounds.maxY + 8)
        try await Task.sleep(for: .milliseconds(140))
        #expect(view.getTerminal().getTopVisibleRow() == top)
        #expect(!view.selectionActive)
        view.mouseUp(with: mouse(.leftMouseUp, in: view, y: view.bounds.maxY + 8))
    }

    @Test func autoscrollStopsAtTheBufferBoundary() async throws {
        let (window, view) = terminal()
        defer { window.close() }
        view.scrollUp(lines: view.getTerminal().getTopVisibleRow() - 2)
        drag(view, to: view.bounds.maxY + 400)
        try await Task.sleep(for: .milliseconds(140))
        #expect(view.getTerminal().getTopVisibleRow() == 0)
        let selected = view.getSelection()
        try await Task.sleep(for: .milliseconds(140))
        #expect(view.getSelection() == selected)
        view.mouseUp(with: mouse(.leftMouseUp, in: view, y: view.bounds.maxY + 400))
    }
}
