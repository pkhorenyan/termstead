import AppKit
import SwiftTerm
import Testing
@testable import Termstead

@MainActor
struct TerminalBehaviourTests {
    /// A loop rather than test arguments: SwiftTerm's `CursorStyle` is not
    /// `Sendable`, which parameterised tests require.
    @Test func cursorShapeAndBlinkMapToSwiftTerm() {
        let expected: [(ThemeStore.CursorShape, Bool, CursorStyle)] = [
            (.block, true, .blinkBlock), (.block, false, .steadyBlock),
            (.underline, true, .blinkUnderline), (.underline, false, .steadyUnderline),
            (.bar, true, .blinkBar), (.bar, false, .steadyBar),
        ]
        for (shape, blinks, style) in expected {
            #expect(SSHTerminalView.cursorStyle(shape: shape, blinks: blinks) == style)
        }
    }

    @Test func oneLineIsPastedWithoutAsking() {
        #expect(!SSHTerminalView.needsPasteConfirmation(for: "ls -la"))
        #expect(!SSHTerminalView.needsPasteConfirmation(for: "ls -la\n"))
        #expect(!SSHTerminalView.needsPasteConfirmation(for: "ls -la\r\n"))
    }

    @Test func severalLinesAsk() {
        #expect(SSHTerminalView.needsPasteConfirmation(for: "cd /tmp\nrm -rf build"))
        #expect(SSHTerminalView.needsPasteConfirmation(for: "a\r\nb\r\n"))
        #expect(SSHTerminalView.needsPasteConfirmation(for: "a\rb"))
    }

    @Test func rightClickPastesOnlyWhenChosenAndUnmodified() {
        #expect(!SSHTerminalView.rightClickPastes(modifiers: [], setting: false))
        #expect(SSHTerminalView.rightClickPastes(modifiers: [], setting: true))
        #expect(!SSHTerminalView.rightClickPastes(modifiers: .control, setting: true))
        #expect(!SSHTerminalView.rightClickPastes(modifiers: .shift, setting: true))
        #expect(SSHTerminalView.rightClickPastes(modifiers: .command, setting: true))
    }

    @Test func aChangedCursorIsApplied() {
        let view = SSHTerminalView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.applyCursor(shape: .bar, blinks: false)
        #expect(view.getTerminal().options.cursorStyle == .steadyBar)
    }
}
