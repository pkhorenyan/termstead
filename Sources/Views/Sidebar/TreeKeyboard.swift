import AppKit
import SwiftUI

/// A key the session tree acts on while it has the keyboard.
enum TreeKey: Equatable {
    case delete
    case step(SessionStore.TreeStep, extending: Bool)
    /// Return or Enter: connect, or open and close a group.
    case open
    /// Escape: the keyboard goes back to the terminal.
    case leave

    /// ⌫ and ⌦, alone or with ⌘ as in Finder; the arrows, with ⇧ extending
    /// ↑ and ↓; Return and Enter; Escape. Anything else is not the tree's.
    static func from(_ event: NSEvent) -> TreeKey? {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 51, 117:
            return modifiers.subtracting(.command).isEmpty ? .delete : nil
        case 126, 125:
            guard modifiers.subtracting(.shift).isEmpty else { return nil }
            return .step(event.keyCode == 126 ? .up : .down, extending: modifiers.contains(.shift))
        case 123, 124:
            return modifiers.isEmpty ? .step(event.keyCode == 123 ? .left : .right, extending: false) : nil
        case 36, 76:
            return modifiers.isEmpty ? .open : nil
        case 53:
            return modifiers.isEmpty ? .leave : nil
        default:
            return nil
        }
    }
}

/// Where a click on a row sends the keyboard: to the tree's `TreeKeyView`.
@MainActor
final class TreeKeyboardFocus {
    fileprivate weak var view: TreeKeyView?

    func take() {
        guard let view, let window = view.window, window.firstResponder !== view else { return }
        window.makeFirstResponder(view)
    }
}

/// The session tree's keyboard: one view behind the list rather than the
/// row that was clicked. The rows sit in a lazy stack, so a group folding up
/// or a long scroll takes a row out of the window — and the keyboard with
/// it, had that row kept it, as it did while ⌫ was all there was.
struct TreeKeyboard: NSViewRepresentable {
    var focus: TreeKeyboardFocus
    var onKey: (TreeKey) -> Void

    func makeNSView(context: Context) -> TreeKeyView {
        TreeKeyView()
    }

    /// The closure captures this render's rows, so it is reassigned each time.
    func updateNSView(_ view: TreeKeyView, context: Context) {
        focus.view = view
        view.onKey = onKey
    }
}

final class TreeKeyView: NSView {
    var onKey: (TreeKey) -> Void = { _ in }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if let key = TreeKey.from(event) {
            onKey(key)
        } else {
            super.keyDown(with: event)
        }
    }

    /// It only listens; the rows above it get the mouse.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
