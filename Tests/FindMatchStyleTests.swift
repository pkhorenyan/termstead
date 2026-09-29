import AppKit
import Testing
@testable import Termstead

/// A find match is drawn as a solid fill with its own text color; a selection
/// made with the mouse keeps the theme's translucent accent.
@MainActor
struct FindMatchStyleTests {
    // The cursor is hidden: in High contrast it is the yellow of the match.
    private static let output = "boot ok\r\nnginx: \u{1B}[31mERROR\u{1B}[0m upstream timed out\r\ndisk ok\r\n\u{1B}[?25l"

    private func terminal(_ theme: Theme = .graphite) -> (SSHTerminalView, NSPasteboard) {
        let view = SSHTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 120))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("termstead-test-\(UUID().uuidString)"))
        view.copyPasteboard = pasteboard
        let font = ThemeStore.font(family: ThemeStore.bundledFontFamily, size: 13)!
        TerminalStyle.apply(theme: theme, font: font, to: view)
        view.feed(text: Self.output)
        return (view, pasteboard)
    }

    @Test func aMatchTakesTheMatchStyle() {
        let (view, pasteboard) = terminal()
        defer { pasteboard.releaseGlobally() }
        #expect(view.find("upstream", upward: true, caseSensitive: false))
        #expect(view.selectedTextBackgroundColor == Theme.graphite.findMatch.nsColor)
        #expect(view.selectedTextForegroundColor == Theme.graphite.onFindMatch.nsColor)
    }

    @Test func aSelectionMadeAfterwardsLooksLikeASelection() {
        let (view, pasteboard) = terminal()
        defer { pasteboard.releaseGlobally() }
        view.find("upstream", upward: true, caseSensitive: false)
        view.selectAll(nil)
        #expect(view.selectedTextBackgroundColor == view.selectionStyle.fill)
        #expect(view.selectedTextForegroundColor == nil, "a selection keeps each cell's own text color")
    }

    @Test func endingTheSearchGoesBackToTheSelectionStyle() {
        let (view, pasteboard) = terminal()
        defer { pasteboard.releaseGlobally() }
        view.find("disk", upward: true, caseSensitive: false)
        view.endFind()
        #expect(view.selectedTextBackgroundColor == view.selectionStyle.fill)
        #expect(view.selectedTextForegroundColor == nil)
    }

    @Test func aThemeChangeDuringASearchRecolorsTheMatch() {
        let (view, pasteboard) = terminal()
        defer { pasteboard.releaseGlobally() }
        view.find("upstream", upward: true, caseSensitive: false)
        TerminalStyle.apply(theme: .daylight, font: view.font, to: view)
        #expect(view.selectionActive, "a theme change keeps the match")
        #expect(view.selectedTextBackgroundColor == Theme.daylight.findMatch.nsColor)
        #expect(view.selectedTextForegroundColor == Theme.daylight.onFindMatch.nsColor)
    }

    /// The match must read at a glance and its text must stay easy to read,
    /// in every theme.
    @Test(arguments: Theme.all)
    func theMatchStandsOutAndStaysReadable(_ theme: Theme) {
        #expect(theme.onFindMatch.contrast(with: theme.findMatch) >= 6.5,
                "\(theme.name): text on the match")
        #expect(theme.findMatch.contrast(with: theme.terminal) >= (theme.isDark ? 7 : 1.8),
                "\(theme.name): the match against the canvas")
    }

    /// Through SwiftTerm's own drawing: the patch that gives a selection its
    /// own text color (Vendor/SwiftTerm/PATCHES.md) reaches the screen.
    @Test(arguments: Theme.all)
    func theMatchIsDrawnInItsColors(_ theme: Theme) throws {
        let (view, pasteboard) = terminal(theme)
        defer { pasteboard.releaseGlobally() }
        view.find("upstream", upward: true, caseSensitive: false)
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let rgb = { (x: Int, y: Int) -> RGB? in
            rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB).map {
                RGB(r: Double($0.redComponent), g: Double($0.greenComponent), b: Double($0.blueComponent))
            }
        }
        // The fill's bounding box is the match; inside it, every glyph pixel
        // must be the match's text color, not the cells' own.
        var box: (minX: Int, minY: Int, maxX: Int, maxY: Int)?
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where rgb(x, y).map({ $0.distance(to: theme.findMatch) < 0.02 }) == true {
                box = box.map { (min($0.minX, x), min($0.minY, y), max($0.maxX, x), max($0.maxY, y)) } ?? (x, y, x, y)
            }
        }
        let match = try #require(box, "\(theme.name): no match fill on screen")
        let cellWidth = Double(rep.pixelsWide) / Double(view.getTerminal().cols)
        let width = Double(match.maxX - match.minX + 1)
        #expect(abs(width / cellWidth - 8) < 0.6, "\(theme.name): the fill spans \(width / cellWidth) cells, not 8")

        var newText = 0, oldText = 0
        for y in match.minY...match.maxY {
            for x in match.minX...match.maxX {
                guard let pixel = rgb(x, y) else { continue }
                if pixel.distance(to: theme.onFindMatch) < 0.15 { newText += 1 }
                if pixel.distance(to: theme.ansiText) < 0.15 { oldText += 1 }
            }
        }
        #expect(newText > 20, "\(theme.name): \(newText) glyph pixels in the match's text color")
        if theme.ansiText.distance(to: theme.onFindMatch) > 0.3 {
            #expect(oldText == 0, "\(theme.name): \(oldText) pixels still in the cells' own text color")
        }
    }
}

private extension RGB {
    func distance(to other: RGB) -> Double {
        max(abs(r - other.r), abs(g - other.g), abs(b - other.b))
    }
}
