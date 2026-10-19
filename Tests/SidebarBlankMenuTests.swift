import AppKit
import SwiftUI
import Testing
@testable import Termstead

/// A right-click on the sidebar's empty space offers what can be made
/// there; a right-click on a row keeps that row's own menu. The menus are
/// read with `menu(for:)`, so nothing opens on screen.
@MainActor
struct SidebarBlankMenuTests {
    private func menuTitles(in window: NSWindow, at point: NSPoint) throws -> [String] {
        let content = try #require(window.contentView)
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: content.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        var view = content.hitTest(point)
        while let current = view {
            if let menu = current.menu(for: event) { return menu.items.map(\.title) }
            view = current.superview
        }
        return []
    }

    private func sidebar(_ store: SessionStore) throws -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = NSHostingView(rootView:
            SidebarView()
                .frame(width: 248, height: 900)
                .environment(store)
                .environment(AppState(defaults: try #require(UserDefaults(suiteName: "termstead-blank-\(UUID().uuidString)"))))
                .environment(ConnectionStore())
                .environment(\.theme, .graphite))
        window.orderFront(nil)
        return window
    }

    @Test func emptySpaceUnderTheTreeHasAMenu() async throws {
        let store = SessionStore.sample()
        store.collapsedGroupIDs = Set(store.tree.map(\.id))
        let window = try sidebar(store)
        defer { window.close() }
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)) }

        let content = try #require(window.contentView)
        // Well below the collapsed tree, above the footer (non-flipped: y up).
        let below = NSPoint(x: 140, y: content.isFlipped ? 700 : 200)
        let titles = try menuTitles(in: window, at: below)
        #expect(titles.contains("New Session…"), "got \(titles)")
        #expect(titles.contains("Import from ~/.ssh/config"))
    }

    @Test func anEmptyTreeHasTheMenuToo() async throws {
        let store = SessionStore(tree: [], sessions: [:], selectedID: nil, pinnedIDs: [])
        let window = try sidebar(store)
        defer { window.close() }
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)) }
        let titles = try menuTitles(in: window, at: NSPoint(x: 140, y: 450))
        #expect(titles.contains("New Group…"), "got \(titles)")
    }

    @Test func aRowKeepsItsOwnMenu() async throws {
        let store = SessionStore.sample()
        let window = try sidebar(store)
        defer { window.close() }
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)) }

        func rows(_ view: NSView) -> [RowInteractionView] {
            ((view as? RowInteractionView).map { [$0] } ?? []) + view.subviews.flatMap(rows)
        }
        let content = try #require(window.contentView)
        let row = try #require(rows(content).first { $0.bounds.height > 30 }, "no session row")
        let point = content.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), from: row)
        let titles = try menuTitles(in: window, at: point)
        #expect(titles.contains("Connect"), "got \(titles)")
        #expect(!titles.contains("New Session…"))
    }
}
