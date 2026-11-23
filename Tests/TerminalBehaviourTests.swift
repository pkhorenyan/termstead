import AppKit
import SwiftTerm
import Testing
@testable import Termstead

@MainActor
struct TerminalBehaviourTests {
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
