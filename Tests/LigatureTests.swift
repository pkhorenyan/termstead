import AppKit
import Testing
@testable import SwiftTerm
@testable import Termstead

@MainActor
struct LigatureTests {
    private let base = NSFont(name: SBFont.MonoWeight.regular.postScriptName, size: 13)!

    private func features(_ font: NSFont) -> Any? {
        font.fontDescriptor.object(forKey: .featureSettings)
    }

    /// Set through the defaults the store reads, never through the property:
    /// that would write the user's own preferences (the tests share them).
    @Test func ligaturesAreOffUnlessTurnedOn() throws {
        let suite = "termstead-ligatures-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let off = ThemeStore(defaults: defaults)
        #expect(!off.fontLigatures)
        #expect(features(off.terminalFont(size: nil)) != nil)

        defaults.set(true, forKey: "appearance.fontLigatures")
        let on = ThemeStore(defaults: defaults)
        #expect(on.fontLigatures)
        #expect(features(on.terminalFont(size: nil)) == nil)
    }

    /// Same family, same size: the style is only re-applied when its key
    /// changes, so the key has to know about ligatures.
    @Test func switchingLigaturesReachesAnOpenTerminal() {
        let view = SSHTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        TerminalStyle.apply(theme: .graphite, font: base, to: view)
        #expect(features(view.font) == nil)
        TerminalStyle.apply(theme: .graphite, font: ThemeStore.withoutLigatures(base), to: view)
        #expect(features(view.font) != nil, "the terminal kept its ligatures")
        TerminalStyle.apply(theme: .graphite, font: base, to: view)
        #expect(features(view.font) == nil)
    }

    /// SwiftTerm derives bold and italic through NSFontManager, which drops
    /// feature settings (see Vendor/SwiftTerm/PATCHES.md).
    @Test func boldAndItalicTextFollowTheSetting() {
        let set = TerminalView.FontSet(font: ThemeStore.withoutLigatures(base))
        #expect(features(set.bold) != nil)
        #expect(features(set.italic) != nil)
        #expect(features(set.boldItalic) != nil)
        #expect(features(TerminalView.FontSet(font: base).bold) == nil)
    }
}
