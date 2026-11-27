import AppKit
import SwiftTerm
import Testing
@testable import Termstead

@MainActor
struct TerminalBehaviourTests {
    @Test func scrollingDownMovesEntireRowsInTheAlternateScreen() {
        let view = SSHTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        let terminal = view.getTerminal()
        view.feed(text: "\u{1b}[?1049h\u{1b}[1;1HHeader\r\nOriginal line\r\nAnother line\r\nDiscarded line\r\nFooter")
        view.feed(text: "\u{1b}[2;4r\u{1b}[2;1H\u{1b}[T\u{1b}[r")
        let rows = (0..<5).map { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
        #expect(rows == ["Header", "", "Original line", "Another line", "Footer"])
    }

    /// A loop rather than test arguments: SwiftTerm's `CursorStyle` is not
    /// `Sendable`, which parameterised tests require.
    @Test func cursorShapeAndBlinkMapToSwiftTerm() {
        let expected: [(ThemeStore.CursorShape, Bool, CursorStyle)] = [
            (.block, true, .blinkBlock), (.block, false, .steadyBlock),
            (.underline, true, .blinkUnderline), (.underline, false, .steadyUnderline),
            (.bar, true, .blinkBar), (.bar, false, .steadyBar),
        ]
        for (shape, blinks, style) in expected {
            #expect(SSHTerminalView.cursorStyle(shape: shape, blinks: blinks) == style)
        }
    }

    @Test func oneLineIsPastedWithoutAsking() {
        #expect(!SSHTerminalView.needsPasteConfirmation(for: "ls -la"))
        #expect(!SSHTerminalView.needsPasteConfirmation(for: "ls -la\n"))
        #expect(!SSHTerminalView.needsPasteConfirmation(for: "ls -la\r\n"))
    }

    @Test func severalLinesAsk() {
        #expect(SSHTerminalView.needsPasteConfirmation(for: "cd /tmp\nrm -rf build"))
        #expect(SSHTerminalView.needsPasteConfirmation(for: "a\r\nb\r\n"))
        #expect(SSHTerminalView.needsPasteConfirmation(for: "a\rb"))
    }

    private final class InputRecorder: LocalProcessTerminalView {
        var input: [String] = []

        override func send(source: TerminalView, data: ArraySlice<UInt8>) {
            input.append(String(decoding: data, as: UTF8.self))
        }
    }

    @Test func broadcastPasteNormalizesNewlinesAndUsesEachPanesMode() {
        let store = ConnectionStore()
        defer { store.closeAll() }
        store.setLayout(.sideBySide)
        let recorders = (0..<2).map { _ in InputRecorder(frame: .zero) }
        let views = recorders.enumerated().map { pane, recorder in
            store.focus(pane: pane)
            let tab = Connection(sessionID: nil, title: "Test", address: "", keyDescription: "")
            store.add(tab)
            let view = tab.terminalView
            view.startProcess(executable: "/bin/cat", args: [], environment: nil, execName: "cat")
            view.terminalDelegate = recorder
            return view
        }
        store.toggleBroadcast()
        #expect(store.isBroadcasting)

        let clipboard = "  café\r\n\n\tindented\r最後\n"
        let expected = "  café\r\r\tindented\r最後\r"
        views[0].sendPaste("café")
        views[0].feed(text: "\u{1b}[?2004h")
        views[0].sendPaste(clipboard)
        views[1].sendPaste(clipboard)

        let bracketed = "\u{1b}[200~" + expected + "\u{1b}[201~"
        #expect(recorders[0].input == ["café", bracketed, bracketed])
        #expect(recorders[1].input == ["café", expected, expected])
    }

    @Test func rightClickPastesOnlyWhenChosenAndUnmodified() {
        #expect(!SSHTerminalView.rightClickPastes(modifiers: [], setting: false))
        #expect(SSHTerminalView.rightClickPastes(modifiers: [], setting: true))
        #expect(!SSHTerminalView.rightClickPastes(modifiers: .control, setting: true))
        #expect(!SSHTerminalView.rightClickPastes(modifiers: .shift, setting: true))
        #expect(SSHTerminalView.rightClickPastes(modifiers: .command, setting: true))
    }

    @Test func aChangedCursorIsApplied() {
        let view = SSHTerminalView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.applyCursor(shape: .bar, blinks: false)
        #expect(view.getTerminal().options.cursorStyle == .steadyBar)
    }

    private func wheel(_ delta: Int32, units: CGScrollEventUnit = .line,
                       flags: CGEventFlags = []) throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 1,
                                        wheel1: delta, wheel2: 0, wheel3: 0))
        event.flags = flags
        event.location = CGPoint(x: 40, y: (NSScreen.main?.frame.height ?? 300) - 80)
        return try #require(NSEvent(cgEvent: event))
    }

    private func recordedTerminal() -> (SSHTerminalView, InputRecorder) {
        let view = SSHTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let recorder = InputRecorder(frame: .zero)
        view.startProcess(executable: "/bin/cat", args: [], environment: nil, execName: "cat")
        view.terminalDelegate = recorder
        return (view, recorder)
    }

    @Test func fullScreenScrollingUsesTheCursorModeAndHonorsTheSetting() throws {
        let (view, recorder) = recordedTerminal()
        defer { view.terminate() }
        view.feed(text: "\u{1b}[?1049h")
        view.scrollWheel(with: try wheel(1))
        view.scrollWheel(with: try wheel(-1))
        #expect(recorder.input == ["\u{1b}[A", "\u{1b}[B"])

        recorder.input = []
        view.feed(text: "\u{1b}[?1h")
        view.scrollWheel(with: try wheel(1))
        view.scrollWheel(with: try wheel(-1))
        #expect(recorder.input == ["\u{1b}OA", "\u{1b}OB"])

        recorder.input = []
        view.scrollWithArrowKeys = false
        view.scrollWheel(with: try wheel(-1))
        #expect(recorder.input.isEmpty)
        view.scrollWithArrowKeys = true
        view.feed(text: "\u{1b}[?1049l")
        view.scrollWheel(with: try wheel(-1))
        #expect(recorder.input.isEmpty, "Arrow scrolling is confined to the alternate screen")
    }

    @Test func applicationsCanDisableEnableAndQueryAlternateScrolling() throws {
        let (view, recorder) = recordedTerminal()
        defer { view.terminate() }
        view.feed(text: "\u{1b}[?1049h\u{1b}[?1007l\u{1b}[?1007$p")
        view.scrollWheel(with: try wheel(-1))
        #expect(recorder.input == ["\u{1b}[?1007;2$y"])

        recorder.input = []
        view.feed(text: "\u{1b}[?1007h\u{1b}[?1007$p")
        view.scrollWheel(with: try wheel(-1))
        #expect(recorder.input == ["\u{1b}[?1007;1$y", "\u{1b}[B"])

        view.feed(text: "\u{1b}[?1007l\u{1b}c\u{1b}[?1049h")
        recorder.input = []
        view.scrollWheel(with: try wheel(-1))
        #expect(recorder.input == ["\u{1b}[B"], "Reset restores alternate scrolling")
    }

    @Test func mouseWheelReportsKeepTheirPositionAndWorkWithArrowScrollingDisabled() throws {
        let (view, recorder) = recordedTerminal()
        defer { view.terminate() }
        view.scrollWithArrowKeys = false
        view.feed(text: "\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h")
        view.scrollWheel(with: try wheel(1))
        view.scrollWheel(with: try wheel(-1, flags: [.maskControl]))
        try #require(recorder.input.count == 2)
        let upward = recorder.input[0]
        #expect(upward.hasPrefix("\u{1b}[<64;"))
        #expect(upward.hasSuffix("M"))
        #expect(recorder.input[1] == upward.replacingOccurrences(of: "<64;", with: "<81;"))

        recorder.input = []
        view.scrollWithArrowKeys = true
        view.scrollWheel(with: try wheel(-1))
        #expect(recorder.input == [upward.replacingOccurrences(of: "<64;", with: "<65;")],
                "Mouse reporting takes priority over cursor keys")

        recorder.input = []
        view.feed(text: "\u{1b}[?1006l\u{1b}[?1000h")
        view.scrollWheel(with: try wheel(1))
        #expect(recorder.input.first?.hasPrefix("\u{1b}[M`") == true,
                "Wheel input also supports the legacy mouse encoding")
        #expect(recorder.input.count == 1, "The wheel has no button-release event")
        view.getTerminal().sendEvent(buttonFlags: 64, x: 300, y: 300)
        #expect(recorder.input.count == 2, "Legacy coordinates beyond its limit must not trap")
    }

    @Test func trackpadScrollingAccumulatesSmallMovements() throws {
        let (view, recorder) = recordedTerminal()
        defer { view.terminate() }
        view.feed(text: "\u{1b}[?1049h")
        let event = try wheel(-1, units: .pixel)
        try #require(event.hasPreciseScrollingDeltas)
        view.scrollWheel(with: event)
        #expect(recorder.input.isEmpty)
        for _ in 0..<100 { view.scrollWheel(with: event) }
        let arrows = recorder.input.joined()
        #expect(arrows.contains("\u{1b}[B"))
        #expect(arrows.count < 60, "A pixel of movement must not become a cursor key")

        recorder.input = []
        view.scrollWithArrowKeys = false
        view.scrollWithArrowKeys = true
        view.scrollWheel(with: event)
        #expect(recorder.input.isEmpty, "Changing the setting discards a partial scroll")
    }

    @Test func scrollingStaysInItsPaneWhileTypedKeysStillBroadcast() async throws {
        let store = ConnectionStore()
        defer { store.closeAll() }
        store.setLayout(.sideBySide)
        var output = ["", ""]
        let views = (0..<2).map { pane in
            store.focus(pane: pane)
            let tab = Connection(sessionID: nil, title: "Test", address: "", keyDescription: "")
            store.add(tab)
            let view = tab.terminalView
            view.onOutput = { output[pane] += String(decoding: $0, as: UTF8.self) }
            view.startProcess(executable: "/bin/sh", args: ["-c", "stty raw -echo; printf READY; exec /bin/cat"],
                              environment: nil, execName: "sh")
            view.eventInProgress = { nil }
            return view
        }
        for _ in 0..<100 where !output.allSatisfy({ $0.contains("READY") }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(output.allSatisfy { $0.contains("READY") })
        output = ["", ""]
        store.toggleBroadcast()
        try #require(store.isBroadcasting)

        views[0].feed(text: "\u{1b}[?1049h")
        views[0].scrollWheel(with: try wheel(-1))
        for _ in 0..<100 where output[0].isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(output[0] == "\u{1b}[B")
        #expect(output[1].isEmpty)

        output = ["", ""]
        views[0].feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        views[0].scrollWheel(with: try wheel(-1))
        for _ in 0..<100 where output[0].isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(output[0].hasPrefix("\u{1b}[<65;"))
        #expect(output[1].isEmpty)

        views[0].send(txt: "x")
        for _ in 0..<100 where !output[1].contains("x") {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(output[1] == "x", "Ordinary typing must still broadcast")
    }

    @Test func broadcastTypingReturnsParticipatingPanesToLiveInput() {
        let store = ConnectionStore()
        defer { store.closeAll() }
        store.setLayout(.grid)
        let views = (0..<4).map { pane in
            store.focus(pane: pane)
            let tab = Connection(sessionID: nil, title: "Test", address: "", keyDescription: "")
            store.add(tab)
            let view = tab.terminalView
            view.startProcess(executable: "/bin/cat", args: [], environment: nil, execName: "cat")
            view.eventInProgress = { nil }
            view.feed(text: (1...200).map { "line \($0)\r\n" }.joined())
            view.scrollUp(lines: 30)
            return view
        }
        let readingRows = views.map { $0.getTerminal().getTopVisibleRow() }
        for (index, view) in views.enumerated() {
            view.feed(text: "output while reading\r\n")
            #expect(view.getTerminal().getTopVisibleRow() == readingRows[index])
        }
        store.focus(pane: 0)
        store.toggleBroadcast()
        store.toggleBroadcast(pane: 2)

        views[0].send(txt: "hello")

        for pane in [0, 1, 3] {
            let view = views[pane]
            #expect(view.getTerminal().getTopVisibleRow() > readingRows[pane])
            let liveRow = view.getTerminal().getTopVisibleRow()
            view.feed(text: "output after typing\r\n")
            #expect(view.getTerminal().getTopVisibleRow() == liveRow + 1)
        }
        #expect(views[2].getTerminal().getTopVisibleRow() == readingRows[2],
                "A pane excluded from Broadcast Input keeps its reading position")
    }

    private func terminalWithHistory(scrollback: Int) -> SSHTerminalView {
        let view = SSHTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        view.scrollbackLines = scrollback
        view.feed(text: (1...200).map { "line \($0)\r\n" }.joined())
        return view
    }

    @Test func theWheelHoldsScrollbackUntilReturningToLiveOutput() throws {
        let view = terminalWithHistory(scrollback: 1000)
        let terminal = view.getTerminal()
        let bottom = terminal.getTopVisibleRow()
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                        wheel1: 3, wheel2: 0, wheel3: 0).flatMap(NSEvent.init(cgEvent:)))
        view.scrollWheel(with: event)
        let readingRow = terminal.getTopVisibleRow()
        try #require(readingRow < bottom)
        view.feed(text: "new output\r\n")
        #expect(terminal.getTopVisibleRow() == readingRow)

        view.scrollDown(lines: 1000)
        let liveRow = terminal.getTopVisibleRow()
        #expect(liveRow == bottom + 1)
        view.feed(text: "live again\r\n")
        #expect(terminal.getTopVisibleRow() == liveRow + 1)
    }

    @Test func theScrollbarKeepsTheSameTextWhenFullHistoryRollsOver() throws {
        let view = terminalWithHistory(scrollback: 40)
        let terminal = view.getTerminal()
        view.scroll(toPosition: 0.5)
        let readingRow = terminal.getTopVisibleRow()
        try #require(readingRow > 0)
        let firstLine = try #require(terminal.getLine(row: 0)).translateToString(trimRight: true)
        view.feed(text: "new output\r\n")
        #expect(terminal.getTopVisibleRow() == readingRow - 1)
        #expect(terminal.getLine(row: 0)?.translateToString(trimRight: true) == firstLine)

        view.scroll(toPosition: 0)
        let oldest = terminal.getLine(row: 0)?.translateToString(trimRight: true)
        view.feed(text: "one more line\r\n")
        #expect(terminal.getTopVisibleRow() == 0)
        #expect(terminal.getLine(row: 0)?.translateToString(trimRight: true) != oldest)
    }
}
