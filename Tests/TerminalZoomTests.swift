import AppKit
import Testing
@testable import Termstead

/// The store reads defaults of its own and `terminalFontSize` is never set
/// here: its `didSet` writes to the app's real defaults, which the hosted test
/// shares. So the Settings size is the new-user 13 throughout.
@MainActor
struct TerminalZoomTests {
    private let store = ThemeStore(defaults: UserDefaults(suiteName: "TerminalZoomTests")!)

    @Test func zoomStartsFromTheSettingsSize() {
        #expect(store.terminalFontSize == 13)
        #expect(store.zoomedSize(from: nil, by: 1) == 14)
        #expect(store.zoomedSize(from: nil, by: -1) == 12)
        #expect(store.zoomedSize(from: 14, by: 1) == 15)
    }

    @Test func backAtTheSettingsSizeTheTabFollowsSettingsAgain() {
        #expect(store.zoomedSize(from: 14, by: -1) == nil)
        #expect(store.zoomedSize(from: 12, by: 1) == nil)
    }

    @Test func zoomStopsAtTheEndsOfItsRange() {
        let range = ThemeStore.zoomRange
        #expect(store.zoomedSize(from: range.upperBound, by: 1) == range.upperBound)
        #expect(store.zoomedSize(from: range.lowerBound, by: -1) == range.lowerBound)
        #expect(range.contains(ThemeStore.fontSizeRange.lowerBound)
                && range.contains(ThemeStore.fontSizeRange.upperBound),
                "a tab can always zoom from any Settings size")
    }

    @Test func theFontTakesTheTabsSize() {
        #expect(store.terminalFont(size: 20).pointSize == 20)
        #expect(store.terminalFont(size: nil).pointSize == 13)
        #expect(store.terminalFont(size: 20).familyName == store.terminalFont.familyName)
    }

    @Test func aZoomedFontReachesTheTerminal() {
        let view = SSHTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        TerminalStyle.apply(theme: .graphite, font: store.terminalFont(size: nil), to: view)
        let columns = view.getTerminal().cols
        TerminalStyle.apply(theme: .graphite, font: store.terminalFont(size: 20), to: view)
        #expect(view.font.pointSize == 20)
        #expect(view.getTerminal().cols < columns, "bigger cells, fewer of them")
    }
}

@MainActor
struct ZoomKeyTests {
    private func key(_ characters: String, code: UInt16, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private final class Target: NSObject {
        var fired = 0
        @objc func act(_ sender: Any?) { fired += 1 }
    }

    /// The menu item as SwiftUI builds it for `.keyboardShortcut("+")`.
    private func biggerMenu(_ target: Target) -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Bigger", action: #selector(Target.act(_:)), keyEquivalent: "+")
        item.keyEquivalentModifierMask = .command
        item.target = target
        menu.addItem(item)
        return menu
    }

    @Test func commandEqualsAloneMissesTheBiggerItem() {
        // Why the rewrite exists: if AppKit ever matches it, it can go.
        let target = Target()
        _ = biggerMenu(target).performKeyEquivalent(with: key("=", code: 24, .command))
        #expect(target.fired == 0)
    }

    @Test func commandEqualsReachesBiggerOnceRewritten() throws {
        let target = Target()
        let rewritten = try #require(AppDelegate.plusForEquals(key("=", code: 24, .command)))
        #expect(rewritten.charactersIgnoringModifiers == "+")
        #expect(rewritten.keyCode == 24)
        #expect(biggerMenu(target).performKeyEquivalent(with: rewritten))
        #expect(target.fired == 1)
    }

    @Test func otherKeysAreLeftAlone() {
        #expect(AppDelegate.plusForEquals(key("+", code: 24, [.command, .shift])) == nil, "already ⌘+")
        #expect(AppDelegate.plusForEquals(key("=", code: 24, [])) == nil, "typing =")
        #expect(AppDelegate.plusForEquals(key("=", code: 24, [.command, .option])) == nil)
        #expect(AppDelegate.plusForEquals(key("-", code: 27, .command)) == nil)
    }

    @Test func capsLockDoesNotGetInTheWay() {
        #expect(AppDelegate.plusForEquals(key("=", code: 24, [.command, .capsLock])) != nil)
    }

    /// The rewrite is only right while SwiftUI builds "Bigger" as "+" with ⌘.
    @Test func theAppsViewMenuCarriesTheZoomItems() throws {
        let menus = (NSApp.mainMenu?.items ?? []).compactMap { $0.submenu }
        let items = menus.flatMap { $0.items }
        let bigger = try #require(items.first { $0.title == "Bigger" })
        #expect(bigger.menu?.title == "View")
        #expect(bigger.keyEquivalent == "+")
        #expect(bigger.keyEquivalentModifierMask == .command)
        #expect(items.first { $0.title == "Smaller" }?.keyEquivalent == "-")
        #expect(items.first { $0.title == "Default Font Size" }?.keyEquivalent == "0")
    }
}
