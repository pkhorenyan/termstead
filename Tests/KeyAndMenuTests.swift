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
        let row = RowInteractionView()
        var asked = 0
        row.onDeleteKey = { asked += 1 }
        #expect(row.acceptsFirstResponder)
        row.keyDown(with: key(51, "\u{7F}"))
        row.keyDown(with: key(117, "\u{F728}"))
        row.keyDown(with: key(51, "\u{7F}", modifiers: .command))
        #expect(asked == 3)
    }

    @Test func otherKeysDoNot() {
        let row = RowInteractionView()
        var asked = 0
        row.onDeleteKey = { asked += 1 }
        row.keyDown(with: key(0, "a"))
        row.keyDown(with: key(51, "\u{7F}", modifiers: .option))
        #expect(asked == 0)
    }

    @Test func aRowWithoutDeletionNeverTakesTheKeyboard() {
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
