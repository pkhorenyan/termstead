import AppKit
import SwiftUI
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

    @Test func aDraggedTabStopsAtTheEndsOfTheStrip() {
        let widths: [CGFloat] = [100, 160, 80]
        // The first tab cannot go left of the strip, the last not past it.
        #expect(TabReorder.clamped(-50, at: 0, widths: widths) == 0)
        #expect(TabReorder.clamped(500, at: 2, widths: widths) == 0)
        // The middle one has 100 to its left and 80 to its right.
        #expect(TabReorder.clamped(-300, at: 1, widths: widths) == -100)
        #expect(TabReorder.clamped(300, at: 1, widths: widths) == 80)
        #expect(TabReorder.clamped(30, at: 1, widths: widths) == 30)
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

/// The strip itself, with more tabs than fit.
@MainActor
@Suite(.serialized)
struct TabStripScrollTests {
    private func strip(tabs: Int) async throws -> (NSWindow, ConnectionStore) {
        let connectionStore = ConnectionStore()
        for n in 1...tabs {
            connectionStore.add(Connection(sessionID: nil, title: "server-\(n)", address: "h\(n)", keyDescription: ""))
        }
        connectionStore.activeID = connectionStore.connections[0].id
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 700, height: Metrics.tabBarHeight),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        let themeStore = ThemeStore()
        window.contentView = NSHostingView(rootView: TabBarView()
            .environment(themeStore)
            .environment(SessionStore.sample())
            .environment(connectionStore)
            .environment(AppState())
            .environment(\.theme, themeStore.current))
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        return (window, connectionStore)
    }

    private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    @Test func theWheelScrollsTheStripAndStopsAtItsEnds() async throws {
        let (window, _) = try await strip(tabs: 16)
        defer { window.close() }
        let helper = try #require(views(TabStripScrollingView.self, in: window.contentView!).first)
        let scrollView = try #require(helper.enclosingScrollView, "the strip did not scroll")
        let clip = scrollView.contentView
        #expect(clip.bounds.minX == 0)

        helper.wheel(-1, precise: true, in: scrollView)
        helper.wheel(-30, precise: true, in: scrollView)
        #expect(clip.bounds.minX == 31)

        // Three notches of a mouse wheel, gliding into place.
        for _ in 1...3 { helper.wheel(-1, precise: false, in: scrollView) }
        try await Task.sleep(for: .milliseconds(400))
        #expect(clip.bounds.minX == 31 + 3 * TabStripScrollingView.wheelStep)

        helper.wheel(-100_000, precise: true, in: scrollView)
        let end = scrollView.documentView!.frame.width - clip.bounds.width
        #expect(clip.bounds.minX == end)
        helper.wheel(100_000, precise: true, in: scrollView)
        #expect(clip.bounds.minX == 0)
    }

    @Test func aTabHeldAtTheEdgeScrollsTheStripAndMovesAlong() async throws {
        let (window, store) = try await strip(tabs: 16)
        defer { window.close() }
        let first = store.connections[0].id
        let tabs = views(TabInteractionView.self, in: window.contentView!)
        let tab = try #require(tabs.min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX })
        let scrollView = try #require(tab.enclosingScrollView)
        let start = tab.convert(NSPoint(x: tab.bounds.midX, y: tab.bounds.midY), to: nil)
        let edge = scrollView.convert(NSPoint(x: scrollView.bounds.maxX - 4, y: 0), to: nil).x

        func mouse(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: start.y), modifierFlags: [],
                               timestamp: 0, windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        tab.mouseDown(with: mouse(.leftMouseDown, x: start.x))
        tab.mouseDragged(with: mouse(.leftMouseDragged, x: (start.x + edge) / 2))
        tab.mouseDragged(with: mouse(.leftMouseDragged, x: edge))
        // The pointer stays put at the edge; the strip keeps going.
        try await Task.sleep(for: .milliseconds(800))
        let scrolled = scrollView.contentView.bounds.minX
        let slot = store.connections.firstIndex { $0.id == first } ?? 0
        tab.mouseUp(with: mouse(.leftMouseUp, x: edge))
        try await Task.sleep(for: .milliseconds(100))
        let afterRelease = scrollView.contentView.bounds.minX

        #expect(scrolled > 300, "the strip did not follow the tab")
        #expect(slot > 5, "the tab did not pass the tabs scrolling under it")
        #expect(afterRelease == scrolled, "scrolling went on after the drag ended")
    }
}
