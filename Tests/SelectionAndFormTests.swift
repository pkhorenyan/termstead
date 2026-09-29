import AppKit
import SwiftUI
import Testing
@testable import Termstead

@MainActor
struct SidebarSelectionTests {
    @Test func aGroupAndASessionAreNeverSelectedTogether() {
        let store = SessionStore.sample()
        store.select(session: "nas")
        store.select(group: "web")
        #expect(store.selectedID == nil)
        #expect(store.selectedGroupID == "web")

        store.select(session: "nas")
        #expect(store.selectedGroupID == nil)
        #expect(store.selectedID == "nas")
    }

    @Test func aPinnedRowAndItsTreeRowAreSeparatePlaces() {
        let store = SessionStore.sample()
        store.select(session: "prod-web-01", inPinned: true)
        #expect(store.selection == .session("prod-web-01", inPinned: true))
        #expect(store.selection != .session("prod-web-01", inPinned: false))
        // Commands still know which session it is.
        #expect(store.selectedID == "prod-web-01")
    }

    @Test func renamingKeepsTheSelectionWhereItWas() {
        let store = SessionStore.sample()
        store.select(session: "nas", inPinned: true)
        var edited = store.session("nas")!
        edited.id = "nas-2"
        store.applySessionEdits(originalID: "nas", updated: edited, parentID: nil)
        #expect(store.selection == .session("nas-2", inPinned: true))
    }
}

/// The form runs app-modal without starving the main queue: terminal output
/// and SwiftUI updates both arrive through it.
@MainActor
@Suite(.serialized)
struct FormModalityTests {
    /// A plain window for a test. Created from Swift, an NSWindow is released
    /// on close by default on top of ARC's own release, and its close animation
    /// then touches freed memory — a crash that looks like the code under test.
    private func testWindow(_ rect: NSRect, _ style: NSWindow.StyleMask) -> NSWindow {
        let window = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        return window
    }

    private func settle(until condition: () -> Bool) async throws {
        for _ in 0..<60 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func formIsModalAndTheMainQueueKeepsRunning() async throws {
        let parent = testWindow(NSRect(x: 200, y: 200, width: 900, height: 600), [.titled])
        parent.orderFront(nil)
        defer { parent.close() }

        let host = FormWindowHost()
        host.parent = parent
        var closedByForm = false
        host.onClose = { closedByForm = true }
        host.present(route: .newGroup(parentGroupID: nil), theme: .graphite, themeStore: ThemeStore(),
                     sessionStore: .sample(), connectionStore: ConnectionStore())

        try await settle { NSApp.modalWindow != nil }
        #expect(NSApp.modalWindow?.title == "New group")
        #expect(parent.childWindows?.contains { $0 === NSApp.modalWindow } == true)
        #expect(!parent.isMovable, "the window under a form must not be draggable")

        var delivered = false
        DispatchQueue.main.async { delivered = true }
        try await settle { delivered }
        #expect(delivered, "the main queue stalled while the form was modal")

        host.dismiss()
        try await settle { NSApp.modalWindow == nil && parent.isMovable }
        #expect(NSApp.modalWindow == nil)
        #expect(parent.isMovable)
        #expect(!closedByForm, "an outside dismissal must not report itself as the user closing")
    }

    @Test func escapeEndsTheModalLoopAndClearsTheRoute() async throws {
        let parent = testWindow(NSRect(x: 200, y: 200, width: 900, height: 600), [.titled])
        parent.orderFront(nil)
        defer { parent.close() }

        let host = FormWindowHost()
        host.parent = parent
        var closedByForm = false
        host.onClose = { closedByForm = true }
        host.present(route: .newGroup(parentGroupID: nil), theme: .graphite, themeStore: ThemeStore(),
                     sessionStore: .sample(), connectionStore: ConnectionStore())
        try await settle { NSApp.modalWindow != nil }

        // What Escape does. Nothing here updates SwiftUI, so this also shows the
        // loop ends without waiting for the route change to be applied.
        NSApp.modalWindow?.cancelOperation(nil)
        try await settle { NSApp.modalWindow == nil }
        #expect(NSApp.modalWindow == nil)
        #expect(closedByForm)
        #expect(parent.childWindows?.isEmpty ?? true)
    }

    /// How the Appearance window is made modal: SwiftUI creates that window, so
    /// the view inside it does the work.
    @Test func aSwiftUIWindowWithModalWhileOpenBlocksTheAppUntilItCloses() async throws {
        let main = testWindow(NSRect(x: 200, y: 200, width: 900, height: 600), [.titled])
        main.orderFront(nil)
        defer { main.close() }

        var states: [Bool] = []
        let panel = testWindow(NSRect(x: 300, y: 300, width: 400, height: 300), [.titled, .closable])
        panel.contentView = NSHostingView(rootView: Color.clear.background(ModalWhileOpen { states.append($0) }))
        panel.makeKeyAndOrderFront(nil)

        try await settle { NSApp.modalWindow === panel }
        #expect(NSApp.modalWindow === panel)
        #expect(!main.isMovable)
        #expect(states == [true])

        panel.performClose(nil)
        try await settle { NSApp.modalWindow == nil && main.isMovable }
        #expect(NSApp.modalWindow == nil)
        #expect(main.isMovable)
        #expect(states == [true, false])
    }
}

@MainActor
struct WindowDraggingTests {
    /// Only the titlebar moves a window; the window's name in it must not get
    /// in the way of that.
    @Test func windowsMoveByTheirTitlebarOnly() async throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = NSHostingView(rootView: Color.clear.background(
            WindowConfigurator(theme: .graphite, toolbarHeight: 28, minSize: .zero, titlebarTitle: "Test")))
        window.orderFront(nil)
        defer { window.close() }

        for _ in 0..<40 where window.titlebarAccessoryViewControllers.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!window.isMovableByWindowBackground)
        let name = try #require(window.titlebarAccessoryViewControllers.first?.view)
        #expect(name.mouseDownCanMoveWindow)
    }
}
