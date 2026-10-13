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

    private func commandW(_ modifiers: NSEvent.ModifierFlags = .command) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: 0, context: nil, characters: "w",
                         charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)!
    }

    /// ⌘W is Close Tab's alone. While the stock File ▸ Close had it too,
    /// SwiftUI dropped the shortcut from Close Tab, and ⌘W closed the main
    /// window instead, leaving the app running with none.
    @Test func commandWBelongsToCloseTab() {
        let items = (NSApp.mainMenu?.items ?? []).compactMap { $0.submenu }.flatMap { $0.items }
        let commandW = items.filter {
            $0.keyEquivalent == "w"
                && $0.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == .command
        }
        #expect(commandW.map(\.title) == ["Close Tab"])
        #expect(!items.contains { $0.action == #selector(NSWindow.performClose(_:)) })
    }

    /// With no menu item closing windows, a form closes itself on ⌘W.
    @Test func commandWClosesAForm() {
        let window = FormWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        var cancelled = 0
        window.onCancel = { cancelled += 1 }
        #expect(window.performKeyEquivalent(with: commandW()))
        #expect(!window.performKeyEquivalent(with: commandW([.command, .shift])))
        #expect(cancelled == 1)
    }

    /// The panes' commands, as SwiftUI builds them into the View menu.
    @Test func thePaneCommandsAreInTheMenu() throws {
        let items = (NSApp.mainMenu?.items ?? []).compactMap { $0.submenu }.flatMap { $0.items }
        func item(_ title: String) throws -> NSMenuItem { try #require(items.first { $0.title == title }, "\(title)") }
        let mask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let vertical = try item("Split Vertically")
        #expect(vertical.keyEquivalent.lowercased() == "d")
        #expect(vertical.keyEquivalentModifierMask.intersection(mask) == .command)
        let horizontal = try item("Split Horizontally")
        #expect(horizontal.keyEquivalent.lowercased() == "d")
        #expect(horizontal.keyEquivalentModifierMask.intersection(mask) == [.command, .shift])
        #expect(try item("Next Pane").keyEquivalent == "]")
        #expect(try item("Previous Pane").keyEquivalent == "[")
        _ = try item("Single Pane")
        _ = try item("Four Panes")
    }
}

