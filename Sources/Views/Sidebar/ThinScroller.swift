import AppKit
import SwiftUI

/// Gives the scroll view it sits in a slim scroller that stays slim.
///
/// Two things made the system scroller loud in a 248pt sidebar. With a mouse
/// attached, or "Show scroll bars: Always", macOS uses the legacy style — a
/// 15pt bar with a track. And even the overlay style swells when the pointer
/// reaches it, growing a wider knob and a track. Neither can be switched off,
/// so this installs `SlimScroller`, which only ever draws a thin knob. SwiftUI
/// does not expose the scroller, so the `NSScrollView` behind the `ScrollView`
/// is reached from inside it, and the scroller is re-applied whenever the
/// system preference changes, since AppKit resets scroll views then.
struct ThinScroller: NSViewRepresentable {
    var isDark: Bool
    /// Keep the knob showing while the list overflows, instead of only while
    /// it scrolls. For short lists inside a form — the group picker — where
    /// nothing else says there is more below; the sidebar keeps the quiet
    /// overlay behaviour.
    var alwaysVisible = false

    func makeNSView(context: Context) -> Probe {
        Probe()
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.isDark = isDark
        view.alwaysVisible = alwaysVisible
        view.apply()
    }

    final class Probe: NSView {
        var isDark = true
        var alwaysVisible = false
        private var observer: (any NSObjectProtocol)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            guard observer == nil else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    // After AppKit has applied the new preference.
                    DispatchQueue.main.async { self?.apply() }
                }
            }
        }

        func apply() {
            guard let scroll = enclosingScrollView else { return }
            let scroller = scroll.verticalScroller as? SlimScroller ?? {
                let slim = SlimScroller()
                scroll.verticalScroller = slim
                return slim
            }()
            // The legacy style is the one that does not fade; `SlimScroller`
            // still draws it as a thin knob without a track.
            let style: NSScroller.Style = alwaysVisible ? .legacy : .overlay
            if scroll.scrollerStyle != style { scroll.scrollerStyle = style }
            scroll.autohidesScrollers = true
            let color = isDark ? NSColor.white.withAlphaComponent(0.28) : NSColor.black.withAlphaComponent(0.25)
            if scroller.knobColor != color {
                scroller.knobColor = color
                scroller.needsDisplay = true
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// A scroller that is a thin rounded knob and nothing else: no track, and no
/// swelling when the pointer is over it.
final class SlimScroller: NSScroller {
    /// What the always-visible (legacy) style takes beside the content while
    /// the bar shows: AppKit narrows the visible area by the scroller's width.
    /// The overlay style takes nothing and draws over the content instead.
    static var lane: CGFloat { scrollerWidth(for: .regular, scrollerStyle: .legacy) }
    static let knobWidth: CGFloat = 5
    static let edgeInset: CGFloat = 3

    var knobColor: NSColor = NSColor.white.withAlphaComponent(0.28)

    /// Required for a scroller subclass to be used in the overlay style.
    override class var isCompatibleWithOverlayScrollers: Bool {
        self == SlimScroller.self
    }

    /// Narrow even in the legacy style, which reserves its width beside the
    /// content rather than floating over it.
    override class func scrollerWidth(for controlSize: NSControl.ControlSize,
                                      scrollerStyle: NSScroller.Style) -> CGFloat {
        knobWidth + edgeInset * 2
    }

    /// The track the overlay style draws on hover — never.
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        let rect = Self.knobRect(slot: rect(for: .knob), in: bounds)
        guard rect.height > 0 else { return }
        knobColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.width / 2, yRadius: rect.width / 2).fill()
    }

    /// The same width whatever width AppKit gives the scroller — it widens it
    /// on hover — pinned to the trailing edge.
    static func knobRect(slot: NSRect, in bounds: NSRect) -> NSRect {
        NSRect(x: bounds.maxX - knobWidth - edgeInset,
               y: slot.minY + 2,
               width: knobWidth,
               height: max(0, slot.height - 4))
    }
}
