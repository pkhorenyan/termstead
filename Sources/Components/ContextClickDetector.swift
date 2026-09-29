import AppKit
import SwiftUI

/// Hears a right-click (or ⌃-click) on the view it overlays and lets it go on
/// to SwiftUI's `.contextMenu`, so the item can be selected before its menu
/// opens, as in Finder. SwiftUI offers no event for that.
///
/// It is transparent to every click: it only looks at the event it is being
/// hit-tested for and always answers "not me". Hit-testing is where AppKit
/// asks, so that is where the layer hears of the click at all.
struct ContextClickDetector: NSViewRepresentable {
    var onContextClick: () -> Void

    func makeNSView(context: Context) -> DetectorView { DetectorView() }

    func updateNSView(_ view: DetectorView, context: Context) {
        view.onContextClick = onContextClick
    }

    final class DetectorView: NSView {
        var onContextClick: () -> Void = {}
        /// Replaceable so a test can hand it an event.
        var currentEvent: () -> NSEvent? = { NSApp.currentEvent }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard super.hitTest(point) != nil, let event = currentEvent() else { return nil }
            let isContextClick = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            // Hit-testing may run more than once per click; selecting is idempotent.
            if isContextClick { onContextClick() }
            return nil
        }
    }
}
