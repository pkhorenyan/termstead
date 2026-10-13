import AppKit
import SwiftUI
import Testing
@testable import Termstead

private func s(_ id: String) -> SidebarDragItem { SidebarDragItem(kind: .session, id: id) }
private func g(_ id: String) -> SidebarDragItem { SidebarDragItem(kind: .group, id: id) }

/// A key as the keyboard sends it: SwiftUI's `onKeyPress` goes by the
/// character, the tree by the key code.
@MainActor
private func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], window: NSWindow? = nil) -> NSEvent {
    let characters = [125: "\u{F701}", 126: "\u{F700}", 123: "\u{F702}", 124: "\u{F703}",
                      36: "\r", 76: "\u{3}", 53: "\u{1B}", 51: "\u{7F}"][Int(code)] ?? "a"
    return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                            windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
                            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
}

/// The arrow keys, Return and Escape over the session tree.
///
/// The sample tree, with Lab closed, lists the Pinned strip (prod-web-01,
/// db-primary), then: Production, Web, prod-web-01, Canary, prod-web-02,
/// Databases, db-primary, Staging, staging-app, Home, Lab, nas — and the
/// Test lab group last.
@MainActor
struct TreeKeyboardTests {
    private let pinned = ["prod-web-01", "db-primary"]

    private func step(_ store: SessionStore, _ step: SessionStore.TreeStep, extending: Bool = false,
                      search: String = "") {
        store.step(step, extending: extending, pinned: pinned,
                   rows: store.flattened(matching: search).rows, canFold: search.isEmpty)
    }

    @Test func theKeysTheTreeTakes() {
        #expect(TreeKey.from(key(125)) == .step(.down, extending: false))
        #expect(TreeKey.from(key(126, .shift)) == .step(.up, extending: true))
        #expect(TreeKey.from(key(123)) == .step(.left, extending: false))
        #expect(TreeKey.from(key(124)) == .step(.right, extending: false))
        // A real arrow key also carries these.
        #expect(TreeKey.from(key(125, [.numericPad, .function])) == .step(.down, extending: false))
        #expect(TreeKey.from(key(36)) == .open)
        #expect(TreeKey.from(key(76)) == .open)
        #expect(TreeKey.from(key(53)) == .leave)
        // Shortcuts that belong to someone else.
        #expect(TreeKey.from(key(125, .command)) == nil)
        #expect(TreeKey.from(key(123, .shift)) == nil)
        #expect(TreeKey.from(key(124, .option)) == nil)
        #expect(TreeKey.from(key(36, .command)) == nil)
        #expect(TreeKey.from(key(0)) == nil)
    }

    @Test func upAndDownRunThroughThePinnedStripIntoTheTree() throws {
        let store = SessionStore.sample()
        store.selectedID = nil
        step(store, .down)
        #expect(store.selection == .session("prod-web-01", inPinned: true))
        #expect(store.selectedItems.isEmpty, "a Pinned row is not a place in the tree")
        step(store, .down)
        step(store, .down)
        #expect(store.selection == .group("production"))
        #expect(store.selectedItems == [g("production")])
        step(store, .up)
        #expect(store.selection == .session("db-primary", inPinned: true))

        // The ends hold.
        let last = try #require(store.flattened.rows.last?.item)
        store.click(last, .single, shown: [])
        step(store, .down)
        #expect(store.selectedItems == [last])
        store.select(session: "prod-web-01", inPinned: true)
        step(store, .up)
        #expect(store.selection == .session("prod-web-01", inPinned: true))
    }

    @Test func nothingSelectedUpStartsAtTheBottom() throws {
        let store = SessionStore.sample()
        store.selectedID = nil
        step(store, .up)
        #expect(store.selectedItems == [try #require(store.flattened.rows.last?.item)])
    }

    @Test func rightOpensAGroupThenGoesIntoIt() {
        let store = SessionStore.sample()
        store.select(group: "lab")
        step(store, .right)
        #expect(!store.collapsedGroupIDs.contains("lab"))
        #expect(store.selection == .group("lab"))
        step(store, .right)
        #expect(store.selection == .session("raspberry-pi", inPinned: false))
        step(store, .right)
        #expect(store.selection == .session("raspberry-pi", inPinned: false), "a session has no inside")
    }

    @Test func leftClosesAGroupThenGoesUp() {
        let store = SessionStore.sample()
        store.select(session: "prod-web-02")
        step(store, .left)
        #expect(store.selection == .group("canary"))
        step(store, .left)
        #expect(store.collapsedGroupIDs.contains("canary"))
        #expect(store.selection == .group("canary"))
        step(store, .left)
        #expect(store.selection == .group("web"))
        step(store, .left)
        step(store, .left)
        #expect(store.selection == .group("production"))
        step(store, .left)
        #expect(store.collapsedGroupIDs.isSuperset(of: ["canary", "web", "production"]))
        step(store, .left)
        #expect(store.selection == .group("production"), "the top level has nowhere further out")
    }

    /// A search holds every group open, so folding one would change nothing
    /// on screen and only surprise later, once the search is cleared.
    @Test func whileSearchingLeftAndRightOnlyMove() {
        let store = SessionStore.sample()
        let folded = store.collapsedGroupIDs
        store.select(session: "prod-web-02")
        step(store, .left, search: "prod")
        #expect(store.selection == .group("canary"))
        step(store, .left, search: "prod")
        #expect(store.selection == .group("web"))
        step(store, .right, search: "prod")
        #expect(store.selection == .session("prod-web-01", inPinned: false))
        #expect(store.collapsedGroupIDs == folded)
    }

    @Test func shiftExtendsFromTheAnchor() {
        let store = SessionStore.sample()
        store.select(session: "prod-web-01")
        step(store, .down, extending: true)
        step(store, .down, extending: true)
        #expect(store.selectedItems == [s("prod-web-01"), g("canary"), s("prod-web-02")])
        #expect(store.selection == .session("prod-web-01", inPinned: false), "the anchor stays put")

        // Back past the anchor: the range turns round it.
        for _ in 0..<3 { step(store, .up, extending: true) }
        #expect(store.selectedItems == [g("web"), s("prod-web-01")])

        // A ⇧-click moves the same loose end.
        store.click(s("db-primary"), .extend, shown: store.flattened.rows.map(\.item))
        step(store, .up, extending: true)
        #expect(store.selectedItems == [s("prod-web-01"), g("canary"), s("prod-web-02"), g("db")])

        // A plain arrow leaves the range from its loose end.
        step(store, .down)
        #expect(store.selection == .session("db-primary", inPinned: false))
        #expect(store.selectedItems == [s("db-primary")])
    }

    @Test func returnOpensTheSelectedSessionsInListOrder() {
        let store = SessionStore.sample()
        let shown = store.flattened.rows.map(\.item)
        store.click(s("nas"), .single, shown: shown)
        store.click(s("prod-web-02"), .toggle, shown: shown)
        store.click(g("db"), .toggle, shown: shown)
        store.click(s("staging-app"), .toggle, shown: shown)
        #expect(store.sessionsToOpen(along: store.flattened.rows) == ["prod-web-02", "staging-app", "nas"])

        store.select(session: "db-primary", inPinned: true)
        #expect(store.sessionsToOpen(along: store.flattened.rows) == ["db-primary"])
        store.select(group: "web")
        #expect(store.sessionsToOpen(along: store.flattened.rows).isEmpty)
    }
}

/// The same in a real sidebar: the keys go to the window, as typing does.
@MainActor
@Suite(.serialized)
struct TreeKeyboardWindowTests {
    private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    private func sidebar(height: CGFloat = 760) async throws -> (NSWindow, SessionStore) {
        let store = SessionStore.sample()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = NSHostingView(rootView:
            SidebarView()
                .frame(width: 248, height: height)
                .environment(store)
                .environment(AppState())
                .environment(ConnectionStore())
                .environment(\.theme, .graphite))
        window.orderFront(nil)
        try await settle()
        return (window, store)
    }

    private func settle() async throws {
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(20)) }
    }

    private func press(_ code: UInt16, in window: NSWindow) async throws {
        window.sendEvent(key(code, window: window))
        try await settle()
    }

    @Test func aClickedRowHandsTheKeyboardToTheTree() async throws {
        let (window, store) = try await sidebar()
        defer { window.close() }
        let nas = try #require(views(RowInteractionView.self, in: window.contentView!).first { $0.item == s("nas") })
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: nas.convert(NSPoint(x: 40, y: 10), to: nil),
                                       modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        nas.mouseDown(with: click)
        #expect(store.selection == .session("nas", inPinned: false))
        #expect(window.firstResponder is TreeKeyView)

        try await press(126, in: window)
        #expect(store.selection == .group("lab"))
        try await press(124, in: window)
        #expect(!store.collapsedGroupIDs.contains("lab"))
        try await press(124, in: window)
        #expect(store.selection == .session("raspberry-pi", inPinned: false))

        // Closing Lab takes the row that had the keyboard's attention away.
        try await press(123, in: window)
        try await press(123, in: window)
        #expect(store.collapsedGroupIDs.contains("lab"))
        #expect(window.firstResponder is TreeKeyView, "the keyboard went with the row")

        // Return on a group opens it.
        try await press(36, in: window)
        #expect(!store.collapsedGroupIDs.contains("lab"))
    }

    @Test func downFromTheSearchFieldGoesToTheFirstSession() async throws {
        let (window, store) = try await sidebar()
        defer { window.close() }
        store.select(session: "nas")
        let field = try #require(views(NSTextField.self, in: window.contentView!).first { $0.isEditable })
        #expect(window.makeFirstResponder(field))
        try await settle()
        try await press(125, in: window)
        #expect(store.selection == .session("prod-web-01", inPinned: true))
        #expect(window.firstResponder is TreeKeyView)
    }

    @Test func theRowTheKeyboardIsOnIsScrolledIntoSight() async throws {
        let (window, store) = try await sidebar(height: 320)
        defer { window.close() }
        let tree = try #require(views(TreeKeyView.self, in: window.contentView!).first)
        #expect(window.makeFirstResponder(tree))
        store.select(session: "prod-web-01", inPinned: true)
        for _ in 0..<15 { try await press(125, in: window) }

        let item = try #require(store.selectedItems.first)
        let row = try #require(views(RowInteractionView.self, in: window.contentView!).first { $0.item == item },
                               "the row is not even laid out")
        let scroll = try #require(row.enclosingScrollView)
        let frame = row.convert(row.bounds, to: scroll.contentView)
        #expect(scroll.contentView.bounds.insetBy(dx: 0, dy: -1).contains(frame),
                "\(item.id) at \(frame) is outside \(scroll.contentView.bounds)")
        #expect(scroll.contentView.bounds.minY > 0, "the list never moved")
    }
}
