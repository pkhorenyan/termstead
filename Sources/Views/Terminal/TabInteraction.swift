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
    /// Where the pointer is in the window during a drag, in SwiftUI's global
    /// space (top-left origin) — for dropping the tab on another pane.
    var onDragPointer: (CGPoint) -> Void = { _ in }
    var onDragEnd: () -> Void

    func makeNSView(context: Context) -> TabInteractionView { TabInteractionView() }

    func updateNSView(_ view: TabInteractionView, context: Context) {
        view.onSelect = onSelect
        view.onMiddleClick = onMiddleClick
        view.onDrag = onDrag
        view.onDragPointer = onDragPointer
        view.onDragEnd = onDragEnd
    }
}

final class TabInteractionView: NSView {
    var onSelect: () -> Void = {}
    var onMiddleClick: () -> Void = {}
    var onDrag: (CGFloat) -> Void = { _ in }
    var onDragPointer: (CGPoint) -> Void = { _ in }
    var onDragEnd: () -> Void = {}

    /// How far the pointer moves before a press becomes a drag, so a click
    /// with a slight wobble still only selects.
    static let dragThreshold: CGFloat = 4
    /// How close to either end of a scrolling strip a dragged tab starts it
    /// moving, and how fast it moves at the very edge (points per second).
    static let edgeZone: CGFloat = 48
    static let edgeSpeed: CGFloat = 900

    private var pressX: CGFloat?
    private var pointer: NSPoint?
    private var isDragging = false
    private var edgeTimer: Timer?
    private var lastTick = Date()

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The tab's context menu is SwiftUI's, under this layer, so a right-click
    /// or a Control-click goes on to it — as the sidebar's rows do it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit != nil, let event = NSApp.currentEvent else { return hit }
        switch event.type {
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            return nil
        case .leftMouseDown, .leftMouseUp:
            return event.modifierFlags.contains(.control) ? nil : hit
        default:
            return hit
        }
    }

    /// Where the pointer is along the strip. In a scrolling strip it is
    /// measured in the scrolled content, so the tab stays under the pointer
    /// while the strip moves beneath it; this view itself moves with the tab.
    private func stripX(_ windowPoint: NSPoint) -> CGFloat {
        guard let document = enclosingScrollView?.documentView else { return windowPoint.x }
        return document.convert(windowPoint, from: nil).x
    }

    override func mouseDown(with event: NSEvent) {
        pressX = stripX(event.locationInWindow)
        pointer = event.locationInWindow
        isDragging = false
        onSelect()
    }

    override func mouseDragged(with event: NSEvent) {
        pointer = event.locationInWindow
        reportTravel()
        updateEdgeScrolling()
    }

    override func mouseUp(with event: NSEvent) {
        stopEdgeScrolling()
        if isDragging { onDragEnd() }
        pressX = nil
        pointer = nil
        isDragging = false
    }

    private func reportTravel() {
        guard let pressX, let pointer else { return }
        let travel = stripX(pointer) - pressX
        guard isDragging || abs(travel) >= Self.dragThreshold else { return }
        isDragging = true
        // Where the pointer is first: off the strip the tab is carried, and
        // a carried tab must not take a slot along the strip on its way out.
        if let point = globalPoint(pointer) { onDragPointer(point) }
        onDrag(travel)
    }

    /// A window point as SwiftUI's global space has it: from the content
    /// view's top-left corner.
    private func globalPoint(_ windowPoint: NSPoint) -> CGPoint? {
        guard let content = window?.contentView else { return nil }
        let local = content.convert(windowPoint, from: nil)
        return CGPoint(x: local.x, y: content.isFlipped ? local.y : content.bounds.height - local.y)
    }

    /// Scrolls the strip while a dragged tab is held near either end — the
    /// pointer usually stops there, so no drag events arrive to do it.
    private func updateEdgeScrolling() {
        guard isDragging, edgeSpeedNow() != 0 else {
            stopEdgeScrolling()
            return
        }
        guard edgeTimer == nil else { return }
        lastTick = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.edgeTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        edgeTimer = timer
    }

    private func stopEdgeScrolling() {
        edgeTimer?.invalidate()
        edgeTimer = nil
    }

    /// Faster the closer the pointer is to the edge, full speed past it.
    private func edgeSpeedNow() -> CGFloat {
        guard let pointer, let scrollView = enclosingScrollView else { return 0 }
        let x = scrollView.convert(pointer, from: nil).x
        let width = scrollView.bounds.width
        if x > width - Self.edgeZone {
            return Self.edgeSpeed * min((x - (width - Self.edgeZone)) / Self.edgeZone, 1)
        }
        if x < Self.edgeZone {
            return -Self.edgeSpeed * min((Self.edgeZone - x) / Self.edgeZone, 1)
        }
        return 0
    }

    private func edgeTick() {
        let now = Date()
        let elapsed = CGFloat(now.timeIntervalSince(lastTick))
        lastTick = now
        let speed = edgeSpeedNow()
        guard isDragging, speed != 0, let scrollView = enclosingScrollView else {
            stopEdgeScrolling()
            return
        }
        TabStripScrollingView.scroll(scrollView, by: speed * elapsed)
        reportTravel()
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        onMiddleClick()
    }
}

/// Lets a full strip of tabs scroll with what most people turn: a mouse
/// wheel or a vertical swipe. The scroll view on its own moves only for a
/// sideways swipe, or with Shift held. Sits behind the tabs, inside the
/// scroll view, and catches the wheel anywhere over the strip — over the
/// close buttons and the gaps too, which belong to SwiftUI.
struct TabStripScrolling: NSViewRepresentable {
    func makeNSView(context: Context) -> TabStripScrollingView { TabStripScrollingView() }
    func updateNSView(_ view: TabStripScrollingView, context: Context) {}
}

final class TabStripScrollingView: NSView {
    /// Points one notch of a mouse wheel moves the strip.
    static let wheelStep: CGFloat = 40

    private var monitor: Any?
    /// Where the notches so far are taking the strip, so quick notches add
    /// up instead of each starting from wherever the glide has got to.
    private var wheelTarget: CGFloat?
    private var lastWheel = Date.distantPast

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let taken = MainActor.assumeIsolated { self?.take(event) == true }
            return taken ? nil : event
        }
    }

    /// Moves the strip by `delta` points, within its ends.
    static func scroll(_ scrollView: NSScrollView, by delta: CGFloat) {
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        origin.x = clamped(origin.x + delta, in: scrollView)
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    private static func clamped(_ x: CGFloat, in scrollView: NSScrollView) -> CGFloat {
        let limit = max((scrollView.documentView?.frame.width ?? 0) - scrollView.contentView.bounds.width, 0)
        return min(max(x, 0), limit)
    }

    private func take(_ event: NSEvent) -> Bool {
        guard event.window === window, let scrollView = enclosingScrollView,
              scrollView.bounds.contains(scrollView.convert(event.locationInWindow, from: nil)),
              // A sideways swipe is the scroll view's own, momentum and all.
              abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return false }

        wheel(event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas, in: scrollView)
        return true
    }

    /// Down or towards you moves the strip on to the tabs further right.
    func wheel(_ deltaY: CGFloat, precise: Bool, in scrollView: NSScrollView) {
        if precise {
            // A trackpad or Magic Mouse: already smooth, point for point.
            wheelTarget = nil
            Self.scroll(scrollView, by: -deltaY)
            return
        }
        let clip = scrollView.contentView
        let gliding = Date().timeIntervalSince(lastWheel) < 0.3
        let start = gliding ? wheelTarget ?? clip.bounds.minX : clip.bounds.minX
        let target = Self.clamped(start - deltaY * Self.wheelStep, in: scrollView)
        wheelTarget = target
        lastWheel = Date()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            clip.animator().setBoundsOrigin(NSPoint(x: target, y: clip.bounds.minY))
        }
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

    /// Where a dragged tab is drawn: it follows the pointer, but stops at
    /// either end of the strip instead of sliding past the first slot or over
    /// the "+" button, where there is nowhere left to go.
    static func clamped(_ offset: CGFloat, at index: Int, widths: [CGFloat]) -> CGFloat {
        guard widths.indices.contains(index) else { return 0 }
        let before = widths[..<index].reduce(0, +)
        let after = widths[(index + 1)...].reduce(0, +)
        return min(max(offset, -before), after)
    }
}
