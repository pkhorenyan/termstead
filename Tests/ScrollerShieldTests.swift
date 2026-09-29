import AppKit
import SwiftTerm
import Testing
@testable import Termstead

@MainActor
struct ScrollerShieldTests {
    private func mounted() -> (TerminalPane.Container, SSHTerminalView) {
        let container = TerminalPane.Container(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        let terminal = SSHTerminalView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        container.mount(terminal)
        container.layout()
        return (container, terminal)
    }

    @Test func theShieldCoversTheScrollBar() throws {
        let (container, terminal) = mounted()
        let shield = container.scrollerShield
        let scroller = try #require(shield.scroller, "SwiftTerm's scroll bar was not found")
        #expect(shield.frame == terminal.convert(scroller.frame, to: container))
        #expect(shield.frame.width > 0 && shield.frame.height > 0)
        let center = NSPoint(x: shield.frame.midX, y: shield.frame.midY)
        #expect(container.hitTest(center) === shield)
    }

    @Test func theWheelStillScrollsTheTerminal() throws {
        let (container, terminal) = mounted()
        terminal.feed(text: (1...200).map { "line \($0)" }.joined(separator: "\r\n"))
        let before = terminal.getTerminal().buffer.yDisp
        let cgEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                           wheelCount: 1, wheel1: 5, wheel2: 0, wheel3: 0))
        let event = try #require(NSEvent(cgEvent: cgEvent))
        container.scrollerShield.scrollWheel(with: event)
        #expect(terminal.getTerminal().buffer.yDisp != before, "the wheel over the scroll bar did not scroll")
    }
}
