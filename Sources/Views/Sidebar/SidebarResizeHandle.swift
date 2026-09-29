import AppKit
import SwiftUI

/// The drag target straddling the sidebar's inner edge — its trailing edge, or
/// its leading one when the sidebar is on the right of the window.
///
/// This is AppKit rather than a SwiftUI `DragGesture` on purpose. The window
/// used to set `isMovableByWindowBackground`, and AppKit then claimed drags that
/// began on any view whose `mouseDownCanMoveWindow` is true — which a plain
/// SwiftUI shape is — so the drag moved the window instead of resizing the
/// sidebar. The window no longer does that, but this view still says no, and it
/// gets a reliable resize cursor through a tracking area rather than hover state.
struct SidebarResizeHandle: NSViewRepresentable {
    @Binding var width: Double
    var range: ClosedRange<Double>
    /// Restored on a double-click, the way macOS split views behave.
    var defaultWidth: Double
    /// The sidebar is on the right, so dragging left widens it.
    var growsLeftward = false

    /// Grab zone. The sidebar insets its content by 10pt, so a strip this wide
    /// sits clear of the row buttons at the edge.
    static let grabWidth: CGFloat = 10

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: HandleView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: HandleView) {
        view.range = range
        view.currentWidth = width
        view.growsLeftward = growsLeftward
        view.onChange = { width = $0 }
        view.onReset = { width = defaultWidth }
    }

    final class HandleView: NSView {
        var onChange: ((Double) -> Void)?
        var onReset: (() -> Void)?
        var range: ClosedRange<Double> = 190...400
        /// Kept in sync from SwiftUI so a drag starts from the live width.
        var currentWidth: Double = 248
        var growsLeftward = false

        /// Width when the current drag began; `nil` while not dragging.
        private var dragOrigin: Double?
        /// Mouse position in *window* coordinates at mouse-down. The view
        /// itself slides as the sidebar resizes, so its own coordinate space
        /// would move under the pointer mid-drag.
        private var dragStartX: CGFloat = 0

        /// Stops AppKit from treating a drag here as "move the window".
        override var mouseDownCanMoveWindow: Bool { false }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                owner: self
            ))
        }

        /// Only enough on macOS 14. From 15 on, SwiftUI runs the pointer itself
        /// inside its hosting view and puts the arrow back on every mouse move,
        /// so the cursor set here never showed — see `resizeCursor()`.
        override func cursorUpdate(with event: NSEvent) {
            NSCursor.resizeLeftRight.set()
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onReset?()
                return
            }
            dragOrigin = currentWidth
            dragStartX = event.locationInWindow.x
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragOrigin else { return }
            NSCursor.resizeLeftRight.set()
            onChange?(SidebarResizeHandle.width(from: dragOrigin,
                                                dragged: Double(event.locationInWindow.x - dragStartX),
                                                growsLeftward: growsLeftward, range: range))
        }

        override func mouseUp(with event: NSEvent) {
            dragOrigin = nil
        }
    }
}

extension SidebarResizeHandle {
    /// The width a drag of `dragged` points (rightward positive) makes of
    /// `origin`, clamped to `range`.
    static func width(from origin: Double, dragged: Double, growsLeftward: Bool,
                      range: ClosedRange<Double>) -> Double {
        let proposed = growsLeftward ? origin - dragged : origin + dragged
        return min(range.upperBound, max(range.lowerBound, proposed))
    }
}

extension View {
    /// The left-right resize pointer over the sidebar's grab strip. On macOS 15
    /// and later it has to be declared to SwiftUI: its pointer handling
    /// overrides whatever an AppKit view inside the hosting view sets.
    @ViewBuilder
    func resizeCursor() -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.columnResize)
        } else {
            self
        }
    }
}
