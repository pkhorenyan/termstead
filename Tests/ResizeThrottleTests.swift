import AppKit
import Testing
@testable import Termstead

/// During a drag the terminal's size follows at most every
/// `Container.resizeInterval` and then lands on the final one: each change of
/// width reflows SwiftTerm's whole scrollback.
@MainActor
struct ResizeThrottleTests {
    private func container() -> (TerminalPane.Container, SSHTerminalView) {
        let container = TerminalPane.Container(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let terminal = SSHTerminalView(frame: .zero)
        container.mount(terminal)
        container.layoutSubtreeIfNeeded()
        return (container, terminal)
    }

    @Test func aDragResizesAtMostOncePerInterval() async throws {
        let (container, terminal) = container()
        let settled = terminal.frame.width
        container.interactiveResize = { _ in true }
        // Mounting was itself a resize; start the drag after it.
        try await Task.sleep(for: .milliseconds(150))

        container.setFrameSize(NSSize(width: 700, height: 400))
        container.layoutSubtreeIfNeeded()
        let first = terminal.frame.width
        #expect(first != settled, "the first change of a drag applies at once")

        // More movement within the interval waits.
        for width in stride(from: 690, through: 600, by: -10) {
            container.setFrameSize(NSSize(width: CGFloat(width), height: 400))
            container.layoutSubtreeIfNeeded()
        }
        #expect(terminal.frame.width == first)

        // …and then lands on where the drag is.
        try await Task.sleep(for: .milliseconds(250))
        container.layoutSubtreeIfNeeded()
        #expect(terminal.frame.width == 600)
    }

    @Test func withoutADragEveryChangeApplies() {
        let (container, terminal) = container()
        container.interactiveResize = { _ in false }
        for width in [700, 650, 600] {
            container.setFrameSize(NSSize(width: CGFloat(width), height: 400))
            container.layoutSubtreeIfNeeded()
            #expect(terminal.frame.width == CGFloat(width))
        }
    }
}
