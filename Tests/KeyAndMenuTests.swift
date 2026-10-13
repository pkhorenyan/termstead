import AppKit
import Testing
@testable import Termstead

@MainActor
struct KeyAndMenuTests {
    private func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    @Test func deleteAndForwardDeleteAskToDelete() {
        let tree = TreeKeyView()
        var keys: [TreeKey] = []
        tree.onKey = { keys.append($0) }
        #expect(tree.acceptsFirstResponder)
        tree.keyDown(with: key(51, "\u{7F}"))
        tree.keyDown(with: key(117, "\u{F728}"))
        tree.keyDown(with: key(51, "\u{7F}", modifiers: .command))
        #expect(keys == [.delete, .delete, .delete])
    }

    @Test func otherKeysDoNot() {
        let tree = TreeKeyView()
        var keys: [TreeKey] = []
        tree.onKey = { keys.append($0) }
        tree.keyDown(with: key(0, "a"))
        tree.keyDown(with: key(51, "\u{7F}", modifiers: .option))
        #expect(keys.isEmpty)
    }

    /// The keyboard belongs to the tree's own view, which outlives the rows.
    @Test func aRowNeverTakesTheKeyboardItself() {
        #expect(!RowInteractionView().acceptsFirstResponder)
    }

    @Test func theTerminalMenuOffersCopyPasteSelectAll() {
        let view = SSHTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.feed(text: "some output\r\n")
        let click = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                       timestamp: 0, windowNumber: 0, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 1)!
        let menu = view.menu(for: click)
        #expect(menu?.items.map(\.title) == ["Copy", "Paste", "Select All"])
        #expect(menu?.items.first?.isEnabled == false, "Copy with nothing selected")

        view.copyOnSelect = false
        view.selectAll(nil)
        #expect(view.menu(for: click)?.items.first?.isEnabled == true)
    }
}
