import AppKit
import SwiftTerm
import Testing
@testable import Termstead

/// What one highlighting pass costs on a full screen. Printed so a change can
/// be compared; the bound only catches a pass gone badly wrong.
@MainActor
struct HighlightCostTests {
    @Test func aPassOverAFullScreenIsCheap() {
        let view = SSHTerminalView(frame: NSRect(x: 0, y: 0, width: 1600, height: 900))
        view.getTerminal().resize(cols: 200, rows: 50)
        for index in 0..<50 {
            view.feed(text: "2026-09-29 08:12:00 INFO request \(index) served from 10.0.1.\(index) in 12 ms, error=none, status OK, see https://example.com/r/\(index)\r\n")
        }
        let terminal = view.getTerminal()
        let painter = HighlightPainter()
        let rules = KeywordHighlighter.rules(for: .standard)
        painter.paint(terminal, rules: rules)   // colours everything once

        // The steady state while output streams: the screen mostly holds
        // text that was already coloured.
        let passes = 200
        let start = Date()
        for _ in 0..<passes { painter.paint(terminal, rules: rules) }
        let perPass = Date().timeIntervalSince(start) / Double(passes) * 1000
        print("HIGHLIGHT_COST_MS \(String(format: "%.3f", perPass)) per pass, 200x50")
        #expect(perPass < 50)
    }

    /// A row is skipped only while its text and its colours are as they were
    /// left. Rewriting the same text in the default colour brings the
    /// highlighting back on the next pass.
    @Test func sameTextRewrittenGetsColouredAgain() {
        let view = SSHTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let terminal = view.getTerminal()
        let painter = HighlightPainter()
        let rules = KeywordHighlighter.rules(for: .standard)
        view.feed(text: "disk error on sda\r\n")
        #expect(painter.paint(terminal, rules: rules) == 0...0)
        #expect(terminal.getLine(row: 0)?[5].attribute.fg != .defaultColor)

        // Unchanged: nothing to do, nothing to redraw.
        #expect(painter.paint(terminal, rules: rules) == nil)

        // The same text again, over it, in the default colour.
        view.feed(text: "\u{1b}[1;1H\u{1b}[0mdisk error on sda")
        #expect(terminal.getLine(row: 0)?[5].attribute.fg == .defaultColor)
        #expect(painter.paint(terminal, rules: rules) == 0...0)
        #expect(terminal.getLine(row: 0)?[5].attribute.fg != .defaultColor)
    }

    /// Dragging the sidebar's edge changes the terminal's width a column at a
    /// time; SwiftTerm reflows the whole scrollback on each change.
    @Test func resizingWithAFullScrollback() {
        let view = SSHTerminalView(frame: NSRect(x: 0, y: 0, width: 1600, height: 900))
        let terminal = view.getTerminal()
        terminal.resize(cols: 160, rows: 50)
        view.scrollbackLines = 10_000
        for index in 0..<10_050 {
            view.feed(text: "2026-09-29 08:12:00 INFO request \(index) served from 10.0.1.5 in 12 ms, status OK\r\n")
        }
        let steps = 20
        let start = Date()
        for step in 0..<steps { terminal.resize(cols: 159 - step, rows: 50) }
        let perStep = Date().timeIntervalSince(start) / Double(steps) * 1000
        print("RESIZE_COST_MS \(String(format: "%.2f", perStep)) per column, 10k scrollback")
        #expect(perStep < 1000)
    }
}
