import AppKit
import Testing
@testable import Termstead

@MainActor
struct TabKeysTests {
    @Test func nextAndPreviousWrapRoundTheStrip() {
        let store = ConnectionStore()
        for name in ["a", "b", "c"] {
            store.add(Connection(sessionID: nil, title: name, address: name, keyDescription: ""))
        }
        store.activeID = store.connections[0].id
        store.showTab(offset: -1)
        #expect(store.active?.title == "c")
        store.showTab(offset: 1)
        #expect(store.active?.title == "a")
        store.showTab(offset: 1)
        #expect(store.active?.title == "b")
    }

    @Test func aSingleTabStaysPut() {
        let store = ConnectionStore()
        store.add(Connection(sessionID: nil, title: "only", address: "only", keyDescription: ""))
        store.showTab(offset: 1)
        #expect(store.active?.title == "only")
    }

    /// What the keyboard sends for ⇧⌘] and ⇧⌘[ — the shifted characters, as
    /// `charactersIgnoringModifiers` keeps Shift — must reach the menu items
    /// as SwiftUI builds them.
    @Test(arguments: [("}", UInt16(30), "Show Next Tab"), ("{", UInt16(33), "Show Previous Tab")])
    func shiftCommandBracketReachesTheMenu(_ characters: String, _ code: UInt16, _ title: String) throws {
        let menus = (NSApp.mainMenu?.items ?? []).compactMap { $0.submenu }
        let item = try #require(menus.flatMap { $0.items }.first { $0.title == title })
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                                     timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        // A lone copy of the item, so the test does not depend on whether the
        // app's own item is enabled right now.
        final class Target: NSObject { var fired = 0; @objc func act(_ sender: Any?) { fired += 1 } }
        let target = Target()
        let copy = NSMenuItem(title: title, action: #selector(Target.act(_:)), keyEquivalent: item.keyEquivalent)
        copy.keyEquivalentModifierMask = item.keyEquivalentModifierMask
        copy.target = target
        let menu = NSMenu()
        menu.addItem(copy)
        #expect(menu.performKeyEquivalent(with: event), "\(title) did not match ⇧⌘ + \(characters)")
        #expect(target.fired == 1)
    }
}
