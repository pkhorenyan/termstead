import AppKit
import SwiftUI
import Testing
@testable import Termstead

/// The sidebar scrolls when the list is longer than the window — including
/// when the wheel turns over a row, where the AppKit mouse layer sits on top.
/// The scroll event is sent to the test's own window, never through the
/// system, so nothing moves on the user's screen.
@MainActor
struct SidebarScrollTests {
    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView != nil { return scroll }
        for sub in view.subviews { if let found = findScrollView(in: sub) { return found } }
        return nil
    }

    private func findRowLayer(in view: NSView) -> RowInteractionView? {
        if let row = view as? RowInteractionView, row.bounds.height > 20 { return row }
        for sub in view.subviews { if let found = findRowLayer(in: sub) { return found } }
        return nil
    }

    @Test func theWheelScrollsTheTreeOverARow() async throws {
        let store = SessionStore.sample()
        store.collapsedGroupIDs = []
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = NSHostingView(rootView:
            SidebarView()
                .frame(width: 248, height: 360)
                .environment(store)
                .environment(AppState())
                .environment(ConnectionStore())
                .environment(\.theme, .graphite))
        window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)) }

        let scroll = try #require(findScrollView(in: window.contentView!), "no scroll view in the sidebar")
        let row = try #require(findRowLayer(in: window.contentView!), "no row")
        #expect(scroll.documentView!.frame.height > scroll.contentView.bounds.height,
                "the sample tree should not fit in 360pt")
        let before = scroll.contentView.bounds.origin.y

        // The row's mouse layer is what the pointer is over, so it is what
        // receives the wheel. It must pass it on to the scroll view.
        let center = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        let hit = window.contentView!.hitTest(window.contentView!.convert(center, from: nil))
        #expect(hit is RowInteractionView)
        let cgEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                           wheelCount: 1, wheel1: -120, wheel2: 0, wheel3: 0))
        let event = try #require(NSEvent(cgEvent: cgEvent))
        row.scrollWheel(with: event)
        for _ in 0..<15 { try await Task.sleep(for: .milliseconds(20)) }

        #expect(scroll.contentView.bounds.origin.y != before, "the tree did not scroll")
    }

    /// The same inside the whole main window, with its clipped content row,
    /// titlebar configuration and status bar.
    @Test func theWheelScrollsTheSidebarInTheMainWindow() async throws {
        let store = SessionStore.sample()
        store.collapsedGroupIDs = []
        let themeStore = ThemeStore()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = NSHostingView(rootView:
            MainView()
                .environment(themeStore)
                .environment(store)
                .environment(SessionStorage.forThisLaunch())
                .environment(ConnectionStore())
                .environment(AppState())
                .environment(\.theme, .graphite))
        window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<15 { try await Task.sleep(for: .milliseconds(20)) }

        let scroll = try #require(findScrollView(in: window.contentView!))
        let row = try #require(findRowLayer(in: window.contentView!))
        let before = scroll.contentView.bounds.origin.y
        let cgEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                           wheelCount: 1, wheel1: -120, wheel2: 0, wheel3: 0))
        row.scrollWheel(with: try #require(NSEvent(cgEvent: cgEvent)))
        for _ in 0..<15 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(scroll.contentView.bounds.origin.y != before, "the sidebar did not scroll in the main window")
        #expect(scroll.hasVerticalScroller, "no scroller to show where the list is")
        // Pavel wants to see at a glance that the list goes on: the style that
        // does not fade, shown only while the tree is longer than the sidebar.
        #expect(scroll.scrollerStyle == .legacy)
        #expect(scroll.autohidesScrollers)
        #expect(scroll.verticalScroller is SlimScroller, "the system scroller came back")
    }

    @Test func theKnobStaysSlimHoweverWideTheScrollerGets() {
        let slot = NSRect(x: 0, y: 40, width: 7, height: 120)
        let resting = SlimScroller.knobRect(slot: slot, in: NSRect(x: 0, y: 0, width: 7, height: 400))
        let hovered = SlimScroller.knobRect(slot: slot, in: NSRect(x: 0, y: 0, width: 15, height: 400))
        #expect(resting.width == SlimScroller.knobWidth)
        #expect(hovered.width == SlimScroller.knobWidth)
        #expect(hovered.maxX == 15 - SlimScroller.edgeInset)
    }
}

@MainActor
struct ThinScrollerStyleTests {
    private func scrollView(alwaysVisible: Bool) -> (NSScrollView, ThinScroller.Probe) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        scroll.hasVerticalScroller = true
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
        scroll.documentView = document
        let probe = ThinScroller.Probe()
        probe.alwaysVisible = alwaysVisible
        document.addSubview(probe)
        probe.apply()
        return (scroll, probe)
    }

    @Test func theGroupPickerKeepsItsKnobShowing() {
        let (scroll, _) = scrollView(alwaysVisible: true)
        #expect(scroll.scrollerStyle == .legacy, "legacy is the style that does not fade")
        #expect(scroll.verticalScroller is SlimScroller)
        #expect(NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) > SlimScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy))
    }

    @Test func theSidebarStaysQuiet() {
        let (scroll, _) = scrollView(alwaysVisible: false)
        #expect(scroll.scrollerStyle == .overlay)
        #expect(scroll.verticalScroller is SlimScroller)
    }
}
