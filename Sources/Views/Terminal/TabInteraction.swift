import AppKit
import SwiftUI

/// The mouse layer over a tab: it comes to the front on the press, a drag
/// sideways moves it along the strip, and the middle button closes it.
///
/// AppKit rather than SwiftUI gestures, for the sidebar's reason (see
/// `RowInteraction`): a `Button` and a drag gesture on one view are resolved
/// against each other, and the click waits for the outcome. Here nothing
/// waits — the tab is selected on mouse-down, as in Safari and Terminal, and
/// a drag is simply the same press moving. The tab's own `Button` stays
/// underneath for accessibility.
struct TabInteraction: NSViewRepresentable {
    var onSelect: () -> Void
    var onMiddleClick: () -> Void
    /// The pointer's horizontal travel since the press, once it is a drag.
    var onDrag: (CGFloat) -> Void
    var onDragEnd: () -> Void

    func makeNSView(context: Context) -> TabInteractionView { TabInteractionView() }

    func updateNSView(_ view: TabInteractionView, context: Context) {
        view.onSelect = onSelect
        view.onMiddleClick = onMiddleClick
        view.onDrag = onDrag
        view.onDragEnd = onDragEnd
    }
}

final class TabInteractionView: NSView {
    var onSelect: () -> Void = {}
    var onMiddleClick: () -> Void = {}
    var onDrag: (CGFloat) -> Void = { _ in }
    var onDragEnd: () -> Void = {}

    /// How far the pointer moves before a press becomes a drag, so a click
    /// with a slight wobble still only selects.
    static let dragThreshold: CGFloat = 4

    private var pressX: CGFloat?
    private var isDragging = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Window coordinates: the tab moves under the pointer while it is
        // dragged, so a position inside this view would not measure travel.
        pressX = event.locationInWindow.x
        isDragging = false
        onSelect()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressX else { return }
        let travel = event.locationInWindow.x - pressX
        guard isDragging || abs(travel) >= Self.dragThreshold else { return }
        isDragging = true
        onDrag(travel)
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging { onDragEnd() }
        pressX = nil
        isDragging = false
    }

    /// Points per line a mouse wheel reports.
    private static let wheelLine: CGFloat = 16

    /// A mouse wheel turns vertically and the strip scrolls only sideways, so
    /// without this a full strip moved only with Shift held. A trackpad's
    /// sideways swipe already scrolls it and passes through untouched.
    override func scrollWheel(with event: NSEvent) {
        guard !event.hasPreciseScrollingDeltas, event.scrollingDeltaX == 0, event.scrollingDeltaY != 0,
              let scrollView = enclosingScrollView, let document = scrollView.documentView else {
            super.scrollWheel(with: event)
            return
        }
        let clip = scrollView.contentView
        let limit = max(document.frame.width - clip.bounds.width, 0)
        var origin = clip.bounds.origin
        origin.x = min(max(origin.x - event.scrollingDeltaY * Self.wheelLine, 0), limit)
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        onMiddleClick()
    }
}

/// Where a dragged tab belongs. Once it has moved past half of a neighbour's
/// width it takes that neighbour's slot, and the neighbour slides over.
enum TabReorder {
    /// - Parameters:
    ///   - index: the tab's slot now.
    ///   - offset: how far it is drawn from that slot.
    ///   - widths: every tab's width, in strip order.
    /// - Returns: the slot it belongs in, and how far that slot is from the
    ///   current one.
    static func slot(from index: Int, offset: CGFloat, widths: [CGFloat]) -> (index: Int, shift: CGFloat) {
        guard widths.indices.contains(index) else { return (index, 0) }
        // The neighbours as they stand around the dragged tab: once it has
        // passed one, that one is its neighbour on the other side.
        var others = widths
        others.remove(at: index)
        var target = index
        var shift: CGFloat = 0
        while target < others.count, offset - shift > others[target] / 2 {
            shift += others[target]
            target += 1
        }
        while target > 0, offset - shift < -others[target - 1] / 2 {
            shift -= others[target - 1]
            target -= 1
        }
        return (target, shift)
    }
}
