import AppKit
import SwiftTerm
import SwiftUI

/// Shows the active connection's terminal.
///
/// The container is SwiftUI's; the terminal view inside it belongs to the
/// `Connection` and outlives it. Switching tabs swaps which terminal view is
/// mounted rather than creating a new one, so scrollback and the running process
/// are untouched.
struct TerminalPane: NSViewRepresentable {
    var connection: Connection
    var theme: Theme
    var font: NSFont
    var copyOnSelect: Bool
    var cursorShape: ThemeStore.CursorShape
    var cursorBlinks: Bool
    var rightClickPastes: Bool
    var confirmMultilinePaste: Bool
    var bell: ThemeStore.BellMode
    var optionAsMeta: Bool
    var highlighting: KeywordHighlighter.Mode
    var scrollbackLines: Int
    var onStopConfirmingPaste: () -> Void

    /// Space between the canvas edge and the first column, as in the mockup's
    /// transcript.
    private static let inset = NSEdgeInsets(top: 8, left: 12, bottom: 4, right: 4)

    func makeNSView(context: Context) -> Container {
        Container()
    }

    func updateNSView(_ container: Container, context: Context) {
        container.inset = Self.inset
        container.layer?.backgroundColor = theme.terminal.nsColor.cgColor
        let terminal = connection.terminalView
        TerminalStyle.apply(theme: theme, font: font, to: terminal)
        terminal.copyOnSelect = copyOnSelect
        terminal.applyCursor(shape: cursorShape, blinks: cursorBlinks)
        terminal.rightClickPastes = rightClickPastes
        terminal.confirmMultilinePaste = confirmMultilinePaste
        terminal.bellMode = bell
        terminal.optionAsMetaKey = optionAsMeta
        terminal.highlightMode = highlighting
        terminal.scrollbackLines = scrollbackLines
        terminal.onStopConfirmingPaste = onStopConfirmingPaste
        container.mount(terminal)
    }

    final class Container: NSView {
        var inset = NSEdgeInsets()
        private weak var mounted: NSView?
        /// Sits over the terminal's scroll bar; see `ScrollerShield`.
        private let shield = ScrollerShield()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            addSubview(shield)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        func mount(_ view: NSView) {
            guard mounted !== view else { return }
            mounted?.removeFromSuperview()
            addSubview(view, positioned: .below, relativeTo: shield)
            mounted = view
            shield.scroller = view.subviews.compactMap { $0 as? NSScroller }.first
            needsLayout = true
            // A tab brought to the front takes the keyboard, the way Terminal's do.
            DispatchQueue.main.async { [weak view] in
                guard let view, let window = view.window else { return }
                window.makeFirstResponder(view)
            }
        }

        /// While a drag resizes the terminal — the sidebar's edge, the
        /// window's — its size follows at most every `resizeInterval`, then
        /// lands on the final one. Each change of width makes SwiftTerm reflow
        /// the whole scrollback: 57 ms a column with 10k lines (Debug), and a
        /// drag changes the width on nearly every mouse move.
        static let resizeInterval: TimeInterval = 0.1
        private var lastResize = Date.distantPast
        private var trailingResize = false

        override func layout() {
            super.layout()
            guard let mounted else { return }
            let target = NSRect(x: inset.left, y: inset.bottom,
                                width: max(0, bounds.width - inset.left - inset.right),
                                height: max(0, bounds.height - inset.top - inset.bottom))
            if mounted.frame.size != target.size, isInteractiveResize,
               Date().timeIntervalSince(lastResize) < Self.resizeInterval {
                mounted.frame.origin = target.origin
                scheduleTrailingResize()
            } else {
                if mounted.frame.size != target.size { lastResize = Date() }
                mounted.frame = target
            }
            mounted.layoutSubtreeIfNeeded()
            if let scroller = shield.scroller {
                shield.frame = mounted.convert(scroller.frame, to: self)
                window?.invalidateCursorRects(for: shield)
            }
        }

        private var isInteractiveResize: Bool { interactiveResize(self) }
        /// Replaceable so a test can play a drag without a mouse.
        var interactiveResize: (NSView) -> Bool = { view in
            view.window?.inLiveResize == true || NSEvent.pressedMouseButtons & 1 != 0
        }

        private func scheduleTrailingResize() {
            guard !trailingResize else { return }
            trailingResize = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.resizeInterval) { [weak self] in
                MainActor.assumeIsolated {
                    self?.trailingResize = false
                    self?.needsLayout = true
                }
            }
        }

        override func viewDidEndLiveResize() {
            super.viewDidEndLiveResize()
            needsLayout = true
        }

        /// The shield, for tests.
        var scrollerShield: ScrollerShield { shield }
    }
}

/// Theme and font for a terminal view. Applied only when something changed:
/// installing a palette makes SwiftTerm repaint every cell.
@MainActor
enum TerminalStyle {
    static func apply(theme: Theme, font: NSFont, to view: SSHTerminalView) {
        let key = "\(theme.id)|\(font.fontName)|\(font.pointSize)"
        guard view.appliedStyle != key else { return }
        view.appliedStyle = key

        view.nativeBackgroundColor = theme.terminal.nsColor
        view.nativeForegroundColor = theme.ansiText.nsColor
        view.caretColor = theme.accent.nsColor
        view.selectionStyle = .init(fill: theme.accent.nsColor.withAlphaComponent(theme.isDark ? 0.32 : 0.26))
        view.matchStyle = .init(fill: theme.findMatch.nsColor, text: theme.onFindMatch.nsColor)
        view.installColors(theme.terminalPalette.map(\.terminalColor))
        // SwiftTerm's font setter clears the selection, so a theme change
        // that set the same font again dropped a find match off the screen.
        if view.font != font { view.font = font }
    }
}

private extension RGB {
    var terminalColor: SwiftTerm.Color {
        func channel(_ value: Double) -> UInt16 { UInt16((min(max(value, 0), 1) * 65535).rounded()) }
        return SwiftTerm.Color(red: channel(r), green: channel(g), blue: channel(b))
    }
}

/// An arrow over the terminal's scroll bar.
///
/// SwiftTerm claims its whole view for the text cursor — `resetCursorRects`
/// and `cursorUpdate` both set the I-beam, and neither can be overridden from
/// outside the package — and its scroll bar is a private subview inside that
/// view, so the I-beam showed over the scroll bar too. This view lies on top of
/// the scroll bar, shows the arrow, and hands every mouse event to the scroll
/// bar underneath (or, for the wheel, to the terminal), so scrolling behaves
/// exactly as before.
final class ScrollerShield: NSView {
    weak var scroller: NSScroller?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        scroller == nil ? nil : super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // NSScroller runs its own tracking loop inside `mouseDown`, so the press
    // is all it needs.
    override func mouseDown(with event: NSEvent) { scroller?.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { scroller?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { scroller?.mouseUp(with: event) }
    override func scrollWheel(with event: NSEvent) {
        (scroller?.superview ?? nextResponder)?.scrollWheel(with: event)
    }
    override func rightMouseDown(with event: NSEvent) {
        scroller?.superview?.rightMouseDown(with: event)
    }
}
