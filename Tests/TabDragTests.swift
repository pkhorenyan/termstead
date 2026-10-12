import AppKit
import Testing
@testable import Termstead

@MainActor
struct TabDragTests {
    @Test func aTabTakesItsNeighboursSlotPastHalfItsWidth() {
        let widths: [CGFloat] = [100, 160, 80, 120]
        // Not yet half of the 160 on its right.
        #expect(TabReorder.slot(from: 0, offset: 79, widths: widths).index == 0)
        let one = TabReorder.slot(from: 0, offset: 81, widths: widths)
        #expect(one.index == 1 && one.shift == 160)
        // Far enough to pass two neighbours in one move.
        let two = TabReorder.slot(from: 0, offset: 210, widths: widths)
        #expect(two.index == 2 && two.shift == 240)
        // To the left, against the left neighbour's width.
        let back = TabReorder.slot(from: 2, offset: -81, widths: widths)
        #expect(back.index == 1 && back.shift == -160)
        #expect(TabReorder.slot(from: 2, offset: -79, widths: widths).index == 2)
    }

    @Test func theEndsOfTheStripHoldTheTab() {
        let widths: [CGFloat] = [100, 100]
        #expect(TabReorder.slot(from: 1, offset: 900, widths: widths).index == 1)
        #expect(TabReorder.slot(from: 0, offset: -900, widths: widths).index == 0)
    }

    @Test func movingKeepsEveryTabAndTheOneInFront() {
        let store = ConnectionStore()
        for name in ["a", "b", "c"] {
            store.add(Connection(sessionID: nil, title: name, address: name, keyDescription: ""))
        }
        let a = store.connections[0].id
        store.activeID = a
        store.move(a, to: 2)
        #expect(store.connections.map(\.title) == ["b", "c", "a"])
        #expect(store.active?.id == a)
        store.move(a, to: 7)
        #expect(store.connections.map(\.title) == ["b", "c", "a"])
    }

    private func mouse(_ type: NSEvent.EventType, x: CGFloat, button: Int = 0) -> NSEvent {
        let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 10), modifierFlags: [],
                                       timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                       clickCount: 1, pressure: 1)!
        guard button != 0, let cg = event.cgEvent else { return event }
        cg.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        return NSEvent(cgEvent: cg)!
    }

    @Test func aPressSelectsAndOnlyTravelBeyondTheThresholdDrags() {
        let view = TabInteractionView()
        var selected = 0, travels: [CGFloat] = [], ended = 0
        view.onSelect = { selected += 1 }
        view.onDrag = { travels.append($0) }
        view.onDragEnd = { ended += 1 }

        view.mouseDown(with: mouse(.leftMouseDown, x: 50))
        #expect(selected == 1, "selected on the press, not on release")
        view.mouseDragged(with: mouse(.leftMouseDragged, x: 52))
        view.mouseUp(with: mouse(.leftMouseUp, x: 52))
        #expect(travels.isEmpty && ended == 0, "a wobble is still a click")

        view.mouseDown(with: mouse(.leftMouseDown, x: 50))
        view.mouseDragged(with: mouse(.leftMouseDragged, x: 70))
        view.mouseDragged(with: mouse(.leftMouseDragged, x: 20))
        view.mouseUp(with: mouse(.leftMouseUp, x: 20))
        #expect(travels == [20, -30])
        #expect(ended == 1)
    }

    @Test func theMiddleButtonCloses() {
        let view = TabInteractionView()
        var closed = 0
        view.onMiddleClick = { closed += 1 }
        view.otherMouseDown(with: mouse(.otherMouseDown, x: 10, button: 2))
        #expect(closed == 1)
    }
}
