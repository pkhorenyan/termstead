import AppKit
import SwiftUI

/// An RDP tab in its pane: the remote desktop once it is up, and until then —
/// and after it ends — the tab's terminal, which says how connecting went.
///
/// The terminal's container serves both: it already knows how a view that
/// belongs to a tab moves between panes, and how a click focuses its pane.
struct RDPPane: NSViewRepresentable {
    var connection: Connection
    @Bindable var desktop: RDPDesktop
    var theme: Theme
    var font: NSFont
    var takesFocus = true
    var onFocus: () -> Void = {}

    private static let terminalInset = NSEdgeInsets(top: 8, left: 12, bottom: 4, right: 4)

    func makeNSView(context: Context) -> TerminalPane.Container {
        TerminalPane.Container()
    }

    func updateNSView(_ container: TerminalPane.Container, context: Context) {
        container.layer?.backgroundColor = theme.terminal.nsColor.cgColor
        container.onFocus = onFocus
        let gainsFocus = takesFocus && !container.takesFocus
        container.takesFocus = takesFocus
        if desktop.phase == .showing {
            container.inset = NSEdgeInsets()
            container.mount(desktop.view)
        } else {
            TerminalStyle.apply(theme: theme, font: font, to: connection.terminalView)
            container.inset = Self.terminalInset
            container.mount(connection.terminalView)
        }
        if gainsFocus { container.focusTerminal() }
    }
}
