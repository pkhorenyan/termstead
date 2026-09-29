import AppKit
import Testing
@testable import Termstead

/// A right-click (or ⌃-click) on a sidebar row selects it before SwiftUI's
/// context menu opens, and still leaves the click to that menu.
@MainActor
struct ContextClickTests {
    private func layer(onContextClick: @escaping () -> Void) -> (NSView, RowInteractionView) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        let row = RowInteractionView(frame: container.bounds)
        row.onContextClick = onContextClick
        container.addSubview(row)
        return (container, row)
    }

    private func event(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: 10, y: 10), modifierFlags: flags,
                           timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                           clickCount: 1, pressure: 1)
    }

    @Test func rightClickSelectsAndPassesTheClickOn() {
        var selected = 0
        let (container, row) = layer { selected += 1 }
        row.currentEvent = { event(.rightMouseDown) }
        #expect(container.hitTest(NSPoint(x: 10, y: 10)) !== row, "the menu is SwiftUI's")
        #expect(selected == 1)

        // The release does not select again.
        row.currentEvent = { event(.rightMouseUp) }
        _ = container.hitTest(NSPoint(x: 10, y: 10))
        #expect(selected == 1)
    }

    @Test func controlClickSelectsToo() {
        var selected = 0
        let (container, row) = layer { selected += 1 }
        row.currentEvent = { event(.leftMouseDown, flags: .control) }
        #expect(container.hitTest(NSPoint(x: 10, y: 10)) !== row)
        #expect(selected == 1)
    }

    @Test func aPlainClickIsTheLayersOwn() {
        var selected = 0
        let (container, row) = layer { selected += 1 }
        row.currentEvent = { event(.leftMouseDown) }
        #expect(container.hitTest(NSPoint(x: 10, y: 10)) === row)
        #expect(selected == 0, "a plain click selects through onClick, on mouseDown")
    }

    /// A click outside the row is not this row's.
    @Test func elsewhereNothingHappens() {
        var selected = 0
        let (container, row) = layer { selected += 1 }
        row.currentEvent = { event(.rightMouseDown) }
        _ = container.hitTest(NSPoint(x: 10, y: 100))
        #expect(selected == 0)
    }

    // MARK: - ContextClickDetector (the SFTP file rows)

    private func detector(_ onContextClick: @escaping () -> Void)
        -> (NSView, ContextClickDetector.DetectorView) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        let view = ContextClickDetector.DetectorView(frame: container.bounds)
        view.onContextClick = onContextClick
        container.addSubview(view)
        return (container, view)
    }

    /// It hears right- and ⌃-clicks and is transparent to every click.
    @Test func detectorSelectsOnContextClickAndStaysTransparent() {
        var selected = 0
        let (container, view) = detector { selected += 1 }
        for (type, flags, expected) in [(NSEvent.EventType.rightMouseDown, NSEvent.ModifierFlags(), 1),
                                        (.leftMouseDown, .control, 2),
                                        (.leftMouseDown, [], 2),
                                        (.rightMouseUp, [], 2)] {
            view.currentEvent = { event(type, flags: flags) }
            #expect(container.hitTest(NSPoint(x: 10, y: 10)) !== view)
            #expect(selected == expected, "\(type) \(flags)")
        }
        view.currentEvent = { event(.rightMouseDown) }
        _ = container.hitTest(NSPoint(x: 10, y: 100))
        #expect(selected == 2, "a click outside the row")
    }
}
