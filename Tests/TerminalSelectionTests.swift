import AppKit
import Testing
@testable import Termstead

@MainActor
struct TerminalSelectionTests {
    private func terminal() -> SSHTerminalView {
        let view = SSHTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 150))
        view.copyOnSelect = false
        view.wantsLayer = true
        TerminalStyle.apply(theme: .graphite, font: view.font, to: view)
        view.feed(text: "plain text\r\n\u{1b}[31mRED \u{1b}[33mYELLOW \u{1b}[44mBLUE BACKGROUND\u{1b}[0m\r\n\u{1b}[?25l")
        view.selectAll(nil)
        return view
    }

    @Test(arguments: [Theme.daylight, .sepia])
    func switchingToALightThemeKeepsTheSelectionReadable(_ theme: Theme) throws {
        let view = terminal()
        TerminalStyle.apply(theme: theme, font: view.font, to: view)
        #expect(view.selectionActive)
        #expect(view.getSelection()?.contains("BLUE BACKGROUND") == true)
        #expect(view.selectedTextBackgroundColor.alphaComponent == 1)
        #expect(view.selectedTextForegroundColor == theme.ansiText.nsColor)
        #expect(theme.ansiText.contrast(with: theme.terminalSelection) >= 7)
        #expect(view.layer?.backgroundColor == theme.terminal.nsColor.cgColor)

        // Exercise SwiftTerm's drawing, including explicitly colored cells:
        // checking the style alone missed the unreadable selection on screen.
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var fillPixels = 0, textPixels = 0, redPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let pixel = RGB(r: color.redComponent, g: color.greenComponent, b: color.blueComponent)
                if pixel.isNear(theme.terminalSelection) { fillPixels += 1 }
                if pixel.isNear(theme.ansiText) { textPixels += 1 }
                if pixel.isNear(theme.ansiRed) { redPixels += 1 }
            }
        }
        #expect(fillPixels > 1000, "The selection must have its light fill on screen")
        #expect(textPixels > 30, "Selected glyphs must use the dark foreground")
        #expect(redPixels == 0, "Selected ANSI text must use the readable foreground too")

        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let preview = FileManager.default.temporaryDirectory
            .appendingPathComponent("termstead-selection-\(theme.id).png")
        try png.write(to: preview)
        print("TERMINAL_SELECTION_PREVIEW \(preview.path)")

        // Returning to a dark theme restores ANSI foregrounds and its canvas.
        TerminalStyle.apply(theme: .graphite, font: view.font, to: view)
        #expect(view.selectionActive)
        #expect(view.selectedTextForegroundColor == nil)
        #expect(view.layer?.backgroundColor == Theme.graphite.terminal.nsColor.cgColor)
    }

    @Test(arguments: [Theme.daylight, .sepia])
    func endingFindRestoresTheLightSelectionColors(_ theme: Theme) {
        let view = terminal()
        TerminalStyle.apply(theme: theme, font: view.font, to: view)
        #expect(view.find("YELLOW", upward: true, caseSensitive: false))
        #expect(view.selectedTextForegroundColor == theme.onFindMatch.nsColor)
        view.endFind()
        view.selectAll(nil)
        #expect(view.selectedTextBackgroundColor == theme.terminalSelection.nsColor)
        #expect(view.selectedTextForegroundColor == theme.ansiText.nsColor)
    }
}

private extension RGB {
    func isNear(_ other: RGB) -> Bool {
        max(abs(r - other.r), abs(g - other.g), abs(b - other.b)) < 0.04
    }
}
