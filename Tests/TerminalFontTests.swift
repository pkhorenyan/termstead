import AppKit
import Testing
@testable import Termstead

/// Static API only: setting `terminalFontFamily` would write to the app's real
/// defaults, which the hosted test shares.
@MainActor
struct TerminalFontTests {
    @Test func listStartsWithTheBuiltInAndTheSystemFace() {
        let families = ThemeStore.monospacedFamilies()
        #expect(Array(families.prefix(2)) == [ThemeStore.bundledFontFamily, ThemeStore.systemFontFamily])
        #expect(Set(families).count == families.count, "no family listed twice")
    }

    /// A prompt's icon (powerlevel10k's, from the Nerd Fonts' private use
    /// area) is drawn from the installed symbols font; the text is not.
    @Test(.enabled(if: ThemeStore.symbolFontFamily != nil, "no Nerd Font symbols installed"))
    func promptIconsComeFromTheSymbolsFont() throws {
        let base = try #require(ThemeStore.font(family: ThemeStore.bundledFontFamily, size: 13))
        let font = ThemeStore.withSymbols(base) as CTFont
        func family(of text: String) -> String {
            let used = CTFontCreateForString(font, text as CFString, CFRange(location: 0, length: (text as NSString).length))
            return CTFontCopyFamilyName(used) as String
        }
        // A folder from the Nerd Fonts' Font Awesome set: JetBrains Mono has
        // the powerline arrows itself, but none of these.
        #expect(family(of: "\u{F07C}") == ThemeStore.symbolFontFamily, "drawn from \(family(of: "\u{F07C}"))")
        #expect(family(of: "a") == CTFontCopyFamilyName(base as CTFont) as String)
    }

    /// A Nerd Font's plain variant is not flagged fixed-pitch: its icons
    /// are double width. Its letters are, and it is offered.
    @Test(.enabled(if: NSFontManager.shared.availableFontFamilies.contains("FiraCode Nerd Font"),
                   "FiraCode Nerd Font not installed"))
    func aNerdFontIsOffered() {
        #expect(ThemeStore.monospacedFamilies().contains("FiraCode Nerd Font"))
    }

    @Test func onlyMonospacedFamiliesAreOffered() {
        let families = ThemeStore.monospacedFamilies()
        // Menlo ships with every macOS; Helvetica is proportional.
        #expect(families.contains("Menlo"))
        #expect(!families.contains("Helvetica"))
        #expect(!families.contains { $0.hasPrefix(".") })
        for family in families {
            let font = ThemeStore.font(family: family, size: 13)
            #expect(font != nil, "\(family) is listed but cannot be loaded")
            let widths = ["i", "W", "m"].map { ($0 as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13)]).width }
            #expect(widths.allSatisfy { abs($0 - widths[0]) < 0.01 }, "\(family) is not monospaced: \(widths)")
            #expect(font.map { CharacterSet(charactersIn: "Aa0").isSubset(of: $0.coveredCharacterSet) } == true,
                    "\(family) has no letters to write with")
        }
    }

    @Test func theBuiltInFaceIsTheBundledOne() {
        #expect(ThemeStore.font(family: ThemeStore.bundledFontFamily, size: 13)?.fontName
                == SBFont.MonoWeight.regular.postScriptName)
    }

    @Test func aMissingFamilyResolvesToNothing() {
        #expect(ThemeStore.font(family: "No Such Font 12345", size: 13) == nil)
    }
}

@MainActor
struct FontPopUpTests {
    @Test func theMenuListsEveryFamilyAndSelectsTheCurrentOne() {
        let families = ThemeStore.monospacedFamilies()
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        FontPopUp.configure(button, families: families, selection: "Menlo")

        #expect(button.numberOfItems == families.count)
        #expect(button.itemArray.compactMap { $0.representedObject as? String } == families)
        #expect(button.selectedItem?.representedObject as? String == "Menlo")
        // Each item is set in its own face.
        let menloFont = button.selectedItem?.attributedTitle?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(menloFont?.familyName == "Menlo")
    }

    @Test func reconfiguringOnlyMovesTheSelection() {
        let families = ThemeStore.monospacedFamilies()
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        FontPopUp.configure(button, families: families, selection: "Menlo")
        let first = button.itemArray.first
        FontPopUp.configure(button, families: families, selection: ThemeStore.bundledFontFamily)
        #expect(button.itemArray.first === first, "items were rebuilt for a selection change")
        #expect(button.indexOfSelectedItem == 0)
    }
}
