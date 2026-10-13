import AppKit
import SwiftUI
import Testing
@testable import Termstead

@MainActor
struct PaneTests {
    private func tab(_ name: String) -> Connection {
        Connection(sessionID: nil, title: name, address: name, keyDescription: "")
    }

    private func titles(_ store: ConnectionStore, _ pane: Int) -> [String] {
        store.tabs(in: pane).map(\.title)
    }

    @Test func aRemovedPaneHandsItsTabsToTheSameCorner() {
        typealias L = PaneLayout
        // Four panes: 0 top left, 1 top right, 2 bottom left, 3 bottom right.
        #expect((0..<4).map { L.pane($0, from: .grid, to: .sideBySide) } == [0, 1, 0, 1])
        #expect((0..<4).map { L.pane($0, from: .grid, to: .stacked) } == [0, 0, 1, 1])
        #expect((0..<4).map { L.pane($0, from: .grid, to: .single) } == [0, 0, 0, 0])
        #expect((0..<2).map { L.pane($0, from: .stacked, to: .grid) } == [0, 2])
        #expect((0..<2).map { L.pane($0, from: .sideBySide, to: .grid) } == [0, 1])
        #expect((0..<2).map { L.pane($0, from: .sideBySide, to: .stacked) } == [0, 0])
        #expect(L.pane(0, from: .single, to: .grid) == 0)
    }

    @Test func aSplitOpensAnEmptyPaneThatTakesTheNextTab() {
        let store = ConnectionStore()
        store.add(tab("a"))
        store.add(tab("b"))
        store.setLayout(.sideBySide)
        #expect(titles(store, 0) == ["a", "b"])
        #expect(store.focusedPane == 1, "the new pane is where the next session goes")
        #expect(store.active == nil)

        store.add(tab("c"))
        #expect(titles(store, 1) == ["c"])
        #expect(store.active?.title == "c")
        #expect(store.active(in: 0)?.title == "b", "the other pane keeps its tab in front")
    }

    @Test func choosingATabFocusesItsPane() {
        let store = ConnectionStore()
        store.add(tab("a"))
        store.setLayout(.sideBySide)
        store.add(tab("b"))
        let a = store.tabs(in: 0)[0].id
        store.activeID = a
        #expect(store.focusedPane == 0)
        #expect(store.active?.title == "a")
        store.focusPane(offset: 1)
        #expect(store.active?.title == "b")
        store.focusPane(offset: 1)
        #expect(store.focusedPane == 0, "round the end")
    }

    @Test func closingBringsForwardANeighbourInTheSamePane() {
        let store = ConnectionStore()
        store.setLayout(.sideBySide)
        store.focus(pane: 0)
        store.add(tab("l1"))
        store.focus(pane: 1)
        store.add(tab("r1"))
        store.focus(pane: 0)
        store.add(tab("l2"))
        store.add(tab("l3"))
        store.activeID = store.tabs(in: 0)[1].id // l2
        store.close(store.active!.id)
        #expect(store.active?.title == "l3", "the right-hand neighbour, as browsers do")
        store.close(store.active!.id)
        #expect(store.active?.title == "l1")
        #expect(store.active(in: 1)?.title == "r1", "the other pane is untouched")
    }

    @Test func draggingAlongAStripCountsOnlyItsOwnTabs() {
        let store = ConnectionStore()
        store.setLayout(.sideBySide)
        store.focus(pane: 0)
        store.add(tab("a"))
        store.focus(pane: 1)
        store.add(tab("x"))
        store.focus(pane: 0)
        store.add(tab("b"))
        store.add(tab("c"))
        let a = store.tabs(in: 0)[0].id
        store.move(a, to: 2)
        #expect(titles(store, 0) == ["b", "c", "a"])
        store.move(a, to: 0)
        #expect(titles(store, 0) == ["a", "b", "c"])
        #expect(titles(store, 1) == ["x"])
    }

    @Test func aTabMovedToAnotherPaneComesForwardThere() {
        let store = ConnectionStore()
        store.setLayout(.sideBySide)
        store.focus(pane: 0)
        store.add(tab("a"))
        store.add(tab("b"))
        store.focus(pane: 1)
        store.add(tab("x"))
        let b = store.tabs(in: 0)[1].id
        store.move(b, toPane: 1, at: 0)
        #expect(titles(store, 0) == ["a"])
        #expect(titles(store, 1) == ["b", "x"])
        #expect(store.focusedPane == 1 && store.active?.title == "b")
        #expect(store.active(in: 0)?.title == "a", "the pane it left has a tab in front")

        store.move(b, toPane: 0)
        #expect(titles(store, 0) == ["a", "b"], "no index: last")
        store.move(b, toPane: 7)
        #expect(titles(store, 0) == ["a", "b"], "no such pane")
    }

    @Test func goingBackToOnePaneClosesNothing() {
        let store = ConnectionStore()
        store.setLayout(.grid)
        for pane in 0..<4 {
            store.focus(pane: pane)
            store.add(tab("p\(pane)"))
        }
        store.focus(pane: 3)
        store.setLayout(.stacked)
        #expect(titles(store, 0) == ["p0", "p1"])
        #expect(titles(store, 1) == ["p2", "p3"])
        #expect(store.focusedPane == 1 && store.active?.title == "p3", "the focused tab stays in front")

        store.setLayout(.single)
        #expect(titles(store, 0) == ["p0", "p1", "p2", "p3"])
        #expect(store.active?.title == "p3")
    }

    @Test func nextTabStaysInThePane() {
        let store = ConnectionStore()
        store.setLayout(.sideBySide)
        store.focus(pane: 0)
        store.add(tab("a"))
        store.add(tab("b"))
        store.focus(pane: 1)
        store.add(tab("x"))
        store.focus(pane: 0)
        store.showTab(offset: 1)
        #expect(store.active?.title == "a", "round the end of its own pane, not into the next")
        store.focus(pane: 1)
        store.showTab(offset: 1)
        #expect(store.active?.title == "x", "a pane with one tab stays put")
    }

    @Test func onlyTheFocusedPanesTabHasItsLoadWatched() {
        let store = ConnectionStore()
        store.watchesServerLoad = true
        store.add(tab("a"))
        store.setLayout(.sideBySide)
        store.add(tab("b"))
        #expect(store.connections.map(\.watchesLoad) == [false, true])
        store.focus(pane: 0)
        #expect(store.connections.map(\.watchesLoad) == [true, false])
    }

    // MARK: - Broadcast input

    @Test func broadcastReachesTheOtherVisiblePanesFrontTabs() {
        let store = ConnectionStore()
        store.toggleBroadcast()
        #expect(!store.isBroadcasting, "one pane has nothing to broadcast to")
        store.setLayout(.grid)
        for pane in 0..<4 {
            store.focus(pane: pane)
            store.add(tab("p\(pane)a"))
            store.add(tab("p\(pane)b"))
        }
        // Each pane's first tab in front, except pane 3's second.
        for pane in 0..<3 { store.activeID = store.tabs(in: pane)[0].id }
        let source = store.tabs(in: 0)[0]
        #expect(store.broadcastTargets(from: source).isEmpty, "off until asked for")

        store.toggleBroadcast()
        #expect(store.broadcastTargets(from: source).map(\.title) == ["p1a", "p2a", "p3b"])
        #expect(store.broadcastTargets(from: store.tabs(in: 0)[1]).isEmpty, "a tab not in front sends nowhere")

        store.toggleBroadcast(pane: 2)
        #expect(store.broadcastTargets(from: source).map(\.title) == ["p1a", "p3b"])
        #expect(store.broadcastTargets(from: store.tabs(in: 2)[0]).isEmpty, "a pane left out keeps its own input")

        store.tabs(in: 1)[0].fail("gone")
        #expect(store.broadcastTargets(from: source).map(\.title) == ["p3b"], "a closed tab is skipped")
    }

    @Test func oneLayoutOrAnotherEndsOrResetsBroadcast() {
        let store = ConnectionStore()
        store.setLayout(.sideBySide)
        store.toggleBroadcast()
        store.toggleBroadcast(pane: 1)
        store.setLayout(.grid)
        #expect(store.isBroadcasting)
        #expect(store.broadcastExcluded.isEmpty, "pane numbers mean other panes now")
        store.setLayout(.single)
        #expect(!store.isBroadcasting)
    }

    // MARK: - Reopening

    @Test func theTabListRemembersPanesAndWhatIsInFront() throws {
        let store = ConnectionStore()
        store.setLayout(.sideBySide)
        store.focus(pane: 0)
        store.add(tab("a"))
        store.add(tab("b"))
        store.focus(pane: 1)
        store.add(tab("c"))
        store.activeID = store.tabs(in: 0)[0].id
        let memory = TabMemory(store)
        #expect(memory.layout == .sideBySide)
        #expect(memory.tabs.map(\.pane) == [nil, nil, 1])
        #expect(memory.active == 0)
        #expect(memory.fronts == [0, 2])
        let decoded = try JSONDecoder().decode(TabMemory.self, from: JSONEncoder().encode(memory))
        #expect(decoded == memory)
    }

    @Test func aListFromBeforePanesIsOnePane() throws {
        let old = Data(#"{"tabs":[{"sessionID":"a"},{"address":"me@host"}],"active":1}"#.utf8)
        let memory = try JSONDecoder().decode(TabMemory.self, from: old)
        #expect(memory.layout == nil && memory.fronts == nil)
        #expect(memory.tabs.allSatisfy { $0.pane == nil })
    }

    /// The sessions' hosts cannot be used, so no ssh is started: each tab
    /// opens, fails at once and stays where it was put.
    @Test func reopeningPutsEachTabBackInItsPane() {
        func session(_ id: String) -> Session {
            Session(id: id, user: "u", host: "no such host", port: 22, icon: .server)
        }
        let sessions = SessionStore(
            tree: [SessionGroup(id: "g", name: "G", colorID: nil,
                                children: [.session("s1"), .session("s2"), .session("s3")])],
            sessions: ["s1": session("s1"), "s2": session("s2"), "s3": session("s3")],
            selectedID: nil, pinnedIDs: [])
        let memory = TabMemory(tabs: [TabMemory.Tab(sessionID: "s1"), TabMemory.Tab(sessionID: "s2"),
                                      TabMemory.Tab(sessionID: "s3", pane: 1)],
                               active: 2, layout: .sideBySide, fronts: [0, 2])
        let store = ConnectionStore()
        memory.reopen(in: store, sessions: sessions)
        defer { store.closeAll() }
        #expect(store.layout == .sideBySide)
        #expect(titles(store, 0) == ["s1", "s2"])
        #expect(titles(store, 1) == ["s3"])
        #expect(store.active(in: 0)?.title == "s1")
        #expect(store.focusedPane == 1)
    }
}

/// Panes in a real window: dragging a tab across, and who has the keyboard.
@MainActor
@Suite(.serialized)
struct PaneWindowTests {
    private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    private func settle() async throws {
        for _ in 0..<8 { try await Task.sleep(for: .milliseconds(25)) }
    }

    private func window(_ layout: PaneLayout, tabs: [[String]]) async throws
        -> (NSWindow, ConnectionStore, AppState) {
        let store = ConnectionStore()
        store.setLayout(layout)
        for (pane, names) in tabs.enumerated() {
            store.focus(pane: pane)
            for name in names {
                store.add(Connection(sessionID: nil, title: name, address: name, keyDescription: ""))
            }
        }
        store.focus(pane: 0)
        let appState = AppState()
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 900, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        let themeStore = ThemeStore()
        window.contentView = NSHostingView(rootView: PaneLayoutView()
            .environment(themeStore)
            .environment(SessionStore.sample())
            .environment(store)
            .environment(appState)
            .environment(\.theme, themeStore.current))
        window.orderFront(nil)
        try await settle()
        return (window, store, appState)
    }

    /// A point of SwiftUI's global space as an event's window location.
    private func windowPoint(_ point: CGPoint, in window: NSWindow) -> NSPoint {
        let content = window.contentView!
        let y = content.isFlipped ? point.y : content.bounds.height - point.y
        return content.convert(NSPoint(x: point.x, y: y), to: nil)
    }

    @Test func aTabDraggedOntoAnotherPanesStripMovesThere() async throws {
        let (window, store, appState) = try await window(.sideBySide, tabs: [["a", "b"], ["x"]])
        defer { window.close() }
        let a = try #require(views(TabInteractionView.self, in: window.contentView!)
            .min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX })
        let start = a.convert(NSPoint(x: a.bounds.midX, y: a.bounds.midY), to: nil)
        let strip = try #require(appState.paneStrips[1])
        let drop = windowPoint(CGPoint(x: strip.maxX - 40, y: strip.midY), in: window)

        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                               clickCount: 1, pressure: 1)!
        }
        a.mouseDown(with: mouse(.leftMouseDown, start))
        a.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: start.x + 30, y: start.y)))
        a.mouseDragged(with: mouse(.leftMouseDragged, drop))
        try await settle()
        #expect(appState.dropPane == 1, "the strip under the pointer is not marked")
        a.mouseUp(with: mouse(.leftMouseUp, drop))
        try await settle()

        #expect(store.tabs(in: 0).map(\.title) == ["b"])
        #expect(store.tabs(in: 1).map(\.title) == ["x", "a"], "dropped right of x")
        #expect(store.focusedPane == 1 && store.active?.title == "a")
        #expect(appState.dropPane == nil)
    }

    @Test func onlyTheFocusedPaneTakesTheKeyboard() async throws {
        let (window, store, _) = try await window(.grid, tabs: [["a"], ["b"], ["c"], ["d"]])
        defer { window.close() }
        #expect(window.firstResponder === store.active(in: 0)?.terminalView)
        store.focus(pane: 2)
        try await settle()
        #expect(window.firstResponder === store.active(in: 2)?.terminalView)

        // Another pane's terminal taking the keyboard gives that pane the focus.
        let d = try #require(store.active(in: 3)?.terminalView)
        window.makeFirstResponder(d)
        try await settle()
        #expect(store.focusedPane == 3)
    }

    /// SwiftUI mounts the new panes' terminals and then updates the old
    /// panes once more before removing them. They used to take their
    /// terminals back then and carry them out of the window: two empty
    /// panes that no click could focus.
    @Test func fewerPanesKeepEveryTerminalShowing() async throws {
        let (window, store, _) = try await window(.grid, tabs: [["a"], ["b"], ["c"], ["d"]])
        defer { window.close() }
        store.setLayout(.sideBySide)
        try await settle()
        let shown = views(SSHTerminalView.self, in: window.contentView!)
        #expect(shown.count == 2)
        for pane in 0..<2 {
            let terminal = try #require(store.active(in: pane)?.terminalView)
            #expect(shown.contains { $0 === terminal }, "pane \(pane) shows nothing")
        }
        #expect(window.firstResponder === store.active?.terminalView)

        // Two switches in one go: grid's empty lower panes become the
        // bottom pane, so every tab ends up on top and the bottom is empty.
        store.setLayout(.grid)
        store.setLayout(.stacked)
        try await settle()
        let fronts = (0..<2).compactMap { store.active(in: $0)?.terminalView }
        let nowShown = views(SSHTerminalView.self, in: window.contentView!)
        #expect(fronts.count == 1 && store.tabs(in: 1).isEmpty)
        #expect(nowShown.count == fronts.count && fronts.allSatisfy { f in nowShown.contains { $0 === f } })
    }

    /// Through the application, as the mouse does it: SwiftTerm's mouseDown
    /// does not take the keyboard, so a click into another pane's terminal
    /// left both the focus and the keyboard where they were.
    @Test func aClickIntoAnotherPanesTerminalFocusesIt() async throws {
        let (window, store, _) = try await window(.sideBySide, tabs: [["a"], ["b"]])
        defer { window.close() }
        let b = try #require(store.active(in: 1)?.terminalView)
        let point = b.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil,
                                               eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        try await settle()
        #expect(store.focusedPane == 1)
        #expect(window.firstResponder === b)
    }

    /// Typed into the left pane, with `cat` running in both: the right
    /// pane's terminal shows it too. Not the left terminal's own reply to a
    /// cursor-position request, nor a mouse report, nor anything once the
    /// right pane is left out. (Typing is sent the way SwiftTerm sends a
    /// keystroke, with a key event in progress: a window in a test is never
    /// key, so a real key event would not reach it.)
    @Test func typingIsBroadcastButRepliesAndMouseReportsAreNot() async throws {
        let (window, store, _) = try await window(.sideBySide, tabs: [["left"], ["right"]])
        defer { store.closeAll(); window.close() }
        for pane in 0..<2 {
            store.active(in: pane)!.terminalView.startProcess(executable: "/bin/cat", args: [],
                                                              environment: nil, execName: "cat")
        }
        let left = try #require(store.active(in: 0)?.terminalView)
        let right = try #require(store.active(in: 1)?.terminalView)
        store.toggleBroadcast()
        try await settle()

        func screen(_ view: SSHTerminalView) -> String {
            String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self)
        }
        func type(_ text: String, during type: NSEvent.EventType) {
            let event = type == .keyDown
                ? NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, characters: "x",
                                   charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7)
                : NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                     clickCount: 1, pressure: 1)
            left.eventInProgress = { event }
            left.send(txt: text)
            left.eventInProgress = { nil }
        }

        type("hello", during: .keyDown)
        try await settle()
        #expect(screen(left).contains("hello"))
        #expect(screen(right).contains("hello"), "the right pane did not get the typing")

        // ESC [ 6 n asks the left terminal where its cursor is; it answers
        // ESC [ row ; col R, which cat echoes back as text there.
        left.feed(text: "\u{1b}[6n")
        try await settle()
        #expect(!screen(right).contains("R"), "the left terminal's reply reached the right pane")

        type("MOUSE", during: .leftMouseDown)
        try await settle()
        #expect(screen(left).contains("MOUSE") && !screen(right).contains("MOUSE"))

        store.toggleBroadcast(pane: 1)
        type("SOLO", during: .keyDown)
        try await settle()
        #expect(screen(left).contains("SOLO") && !screen(right).contains("SOLO"),
                "a pane left out still got the typing")
    }
}
