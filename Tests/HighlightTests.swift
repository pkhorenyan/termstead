import AppKit
import SwiftTerm
import Testing
@testable import Termstead

@MainActor
struct HighlightRuleTests {
    private func colored(_ text: String, _ mode: KeywordHighlighter.Mode = .standard) -> [String: UInt8] {
        let ns = text as NSString
        var out: [String: UInt8] = [:]
        for run in KeywordHighlighter.runs(in: text, rules: KeywordHighlighter.rules(for: mode)) {
            out[ns.substring(with: NSRange(location: run.range.lowerBound, length: run.range.count))] = run.color
        }
        return out
    }

    @Test func standardWords() {
        let runs = colored("Connection refused to 10.0.1.5:22, warning: retrying. OK")
        #expect(runs["refused"] == KeywordHighlighter.red)
        #expect(runs["10.0.1.5:22"] == KeywordHighlighter.cyan)
        #expect(runs["warning"] == KeywordHighlighter.yellow)
        #expect(runs["retrying"] == KeywordHighlighter.yellow)
        #expect(runs["OK"] == KeywordHighlighter.green)
    }

    @Test func wordsInsideOtherWordsAreLeftAlone() {
        #expect(colored("terrors okay booked").isEmpty)
    }

    @Test func aURLStaysOneRunEvenWithErrorInIt() {
        let runs = colored("see https://example.com/error-codes for details")
        #expect(runs["https://example.com/error-codes"] == KeywordHighlighter.blue)
        #expect(runs["error"] == nil)
    }

    @Test func networkAddsInterfacesAndState() {
        let runs = colored("GigabitEthernet0/1 is up, Vlan10 is administratively down", .network)
        #expect(runs["GigabitEthernet0/1"] == KeywordHighlighter.magenta)
        #expect(runs["up"] == KeywordHighlighter.green)
        #expect(runs["administratively down"] == KeywordHighlighter.red)
        #expect(colored("Vlan10 is up", .standard)["Vlan10"] == nil)
    }

    @Test func offHasNoRules() {
        #expect(KeywordHighlighter.rules(for: .off).isEmpty)
    }
}

@MainActor
struct HighlightPaintingTests {
    private func terminal(_ text: String, mode: KeywordHighlighter.Mode = .standard) -> SSHTerminalView {
        let view = SSHTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        view.feed(text: text)
        view.highlightMode = mode
        view.highlightNow()
        return view
    }

    /// Colour of the first cell of `word` on the first row.
    private func color(of word: String, in view: SSHTerminalView, row: Int = 0) -> Attribute.Color? {
        guard let line = view.getTerminal().getLine(row: row) else { return nil }
        let text = line.translateToString()
        guard let range = text.range(of: word) else { return nil }
        let column = text.distance(from: text.startIndex, to: range.lowerBound)
        return line[column].attribute.fg
    }

    @Test func plainTextGetsColoured() {
        let view = terminal("ERROR: disk failed\r\n")
        #expect(color(of: "ERROR", in: view) == .ansi256(code: KeywordHighlighter.red))
        #expect(color(of: "failed", in: view) == .ansi256(code: KeywordHighlighter.red))
        #expect(color(of: "disk", in: view) == .defaultColor)
    }

    @Test func whatTheServerColouredKeepsItsColour() {
        let view = terminal("\u{1b}[32mfailed\u{1b}[0m and failed\r\n")
        #expect(color(of: "failed", in: view) == .ansi256(code: 2))
        let line = view.getTerminal().getLine(row: 0)!
        #expect(line[11].attribute.fg == .ansi256(code: KeywordHighlighter.red), "the second, uncoloured one")
    }

    @Test func boldStaysBold() {
        let view = terminal("\u{1b}[1merror\u{1b}[0m\r\n")
        let attribute = view.getTerminal().getLine(row: 0)![0].attribute
        #expect(attribute.fg == .ansi256(code: KeywordHighlighter.red))
        #expect(attribute.style.contains(.bold))
    }

    @Test func fullScreenProgramsAreLeftAlone() {
        let view = terminal("\u{1b}[?1049herror in vim\r\n")
        #expect(color(of: "error", in: view) == .defaultColor)
    }

    @Test func offLeavesEverything() {
        let view = terminal("error\r\n", mode: .off)
        #expect(color(of: "error", in: view) == .defaultColor)
    }
}

@MainActor
struct QuickConnectRouteTests {
    @Test func theFormHasItsOwnWindowTitle() {
        #expect(AppState.Route.quickConnect.formTitle == "Quick connect")
        #expect(AppState.Route.quickConnect.id == "quickConnect")
    }
}
