import SwiftUI
import UniformTypeIdentifiers

/// Which parts of a row accept a drop.
enum DropMode: Hashable, Sendable {
    /// Reordering only, above or below: a session is not a container.
    case between
    /// A group: above, below, or inside it.
    case intoAndBetween
    /// Always inside — a top-level header, or the strip under the last row.
    case intoOnly
}

/// The mouse layer under a sidebar row.
///
/// Clicking and dragging live here in AppKit rather than in SwiftUI gestures.
/// A row used to carry a `Button` for its primary action *and*
/// `.onTapGesture(count: 2)` for its settings; SwiftUI resolves those
/// exclusively, so the single click could not fire until the double-click
/// interval had elapsed — a quarter to half a second of waiting, with no work
/// being done. `NSEvent.clickCount` says on the first `mouseDown` how many
/// clicks this is, so both actions can be immediate.
///
/// The same view is the drag source and the drop target, which also means the
/// drop indicator is drawn here instead of through `@State`: a drag no longer
/// invalidates SwiftUI rows as the pointer crosses them.
struct RowInteraction: NSViewRepresentable {
    /// What this row puts on the pasteboard, or nil if it cannot be dragged.
    var item: SidebarDragItem?
    var dropMode: DropMode
    var theme: Theme
    /// Label and glyph for the picture that follows the pointer.
    var dragLabel: String
    var dragSymbol: String
    var dragTint: RGB?
    /// Where the insertion line starts, so it lines up with the row's text
    /// rather than the full width of the sidebar.
    var indicatorLeading: CGFloat = 0
    /// The strip where a click belongs to a SwiftUI button drawn under this
    /// layer — the disclosure chevron.
    var passthrough: ClosedRange<CGFloat>?
    /// Everything a drag from this row carries — the whole selection when the
    /// row is part of one. `nil` means just `item`.
    var dragItems: (() -> [SidebarDragItem])?
    /// This row is one of several selected: a plain click on it waits for the
    /// mouse to come up, so that pressing on the selection can start dragging
    /// all of it instead of first narrowing it to this row.
    var isInMultiSelection = false
    var onClick: (NSEvent.ModifierFlags) -> Void
    var onDoubleClick: () -> Void
    var canDrop: ([SidebarDragItem], DropEdge) -> Bool
    var performDrop: ([SidebarDragItem], DropEdge) -> Bool
    /// Called when a drag hovers over this collapsed group long enough.
    var onSpringOpen: (() -> Void)?
    /// Delete / Forward Delete while the sidebar has the keyboard. Setting it
    /// lets a click on the row take keyboard focus, as a click in Finder's list
    /// does — so ⌫ still reaches the terminal or a text field when they have it.
    var onDeleteKey: (() -> Void)?
    /// A right-click (or ⌃-click) on the row, just before SwiftUI shows its
    /// context menu — so the row it applies to is highlighted, as in Finder.
    var onContextClick: (() -> Void)?

    func makeNSView(context: Context) -> RowInteractionView {
        RowInteractionView()
    }

    /// Every closure captures this render's row data, so all of them are
    /// reassigned rather than only set up once.
    func updateNSView(_ view: RowInteractionView, context: Context) {
        view.item = item
        view.dropMode = dropMode
        view.indicatorLeading = indicatorLeading
        view.passthrough = passthrough
        view.dragItems = dragItems
        view.isInMultiSelection = isInMultiSelection
        view.accent = theme.accent.nsColor
        view.accentFill = theme.accent.nsColor.withAlphaComponent(0.18)
        view.dragBackground = theme.elevated.nsColor
        view.dragBorder = theme.borderStrong.nsColor
        view.dragLabel = dragLabel
        view.dragSymbol = dragSymbol
        view.dragTint = (dragTint ?? theme.text).nsColor
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.canDrop = canDrop
        view.performDrop = performDrop
        view.onSpringOpen = onSpringOpen
        view.onDeleteKey = onDeleteKey
        view.onContextClick = onContextClick
    }
}

final class RowInteractionView: NSView {
    var item: SidebarDragItem?
    var dropMode: DropMode = .between
    var indicatorLeading: CGFloat = 0
    /// The strip that belongs to the SwiftUI disclosure chevron underneath.
    var passthrough: ClosedRange<CGFloat>?
    var dragItems: (() -> [SidebarDragItem])?
    var isInMultiSelection = false
    var accent: NSColor = .controlAccentColor
    var accentFill: NSColor = .controlAccentColor.withAlphaComponent(0.18)
    var dragBackground: NSColor = .windowBackgroundColor
    var dragBorder: NSColor = .separatorColor
    var dragLabel = ""
    var dragSymbol = "square"
    var dragTint: NSColor = .labelColor
    var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    var canDrop: ([SidebarDragItem], DropEdge) -> Bool = { _, _ in false }
    var performDrop: ([SidebarDragItem], DropEdge) -> Bool = { _, _ in false }
    var onSpringOpen: (() -> Void)?
    var onDeleteKey: (() -> Void)?
    var onContextClick: (() -> Void)?
    /// The event being hit-tested for; replaceable so a test can hand it one.
    var currentEvent: () -> NSEvent? = { NSApp.currentEvent }

    private var mouseDownAt: NSPoint?
    private var draggingStarted = false
    /// A plain click on a row of a multi-selection, held until mouse-up.
    private var pendingClick = false
    private var edge: DropEdge?
    private var springOpen: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.termsteadSidebarItemPasteboard])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not loaded from a nib") }

    /// Top-down coordinates, so "before" really is the upper edge.
    override var isFlipped: Bool { true }

    /// The window is movable by its background, and AppKit hands such a window
    /// every drag that starts on a view which allows it — which silently ate
    /// the sidebar's resize handle once already.
    override var mouseDownCanMoveWindow: Bool { false }

    /// The first click into an inactive window should land on the row, not just
    /// raise the window and be swallowed.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The layer has to be in front — as a `.background` it was hit-tested and
    /// returned itself, but SwiftUI still swallowed the `mouseDown` before
    /// AppKit could deliver it. Being on top means stepping aside for the parts
    /// of the row SwiftUI still owns.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        guard let event = currentEvent() else { return hit }
        switch event.type {
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            // The row's context menu is still SwiftUI's, so the click goes on
            // to it — but this is the only place the layer hears of it, and the
            // row should be selected before the menu opens.
            if event.type == .rightMouseDown { onContextClick?() }
            return nil
        case .leftMouseDown, .leftMouseUp:
            // Control-click is the other way of asking for that menu.
            if event.modifierFlags.contains(.control) {
                if event.type == .leftMouseDown { onContextClick?() }
                return nil
            }
            if let passthrough, passthrough.contains(convert(point, from: superview).x) {
                return nil
            }
            return hit
        default:
            // Dragging keeps the whole row, so the drop indicator does not blink
            // out over the buttons.
            return hit
        }
    }

    // MARK: - Clicks

    override var acceptsFirstResponder: Bool { onDeleteKey != nil }

    /// ⌫ and ⌦, alone or with ⌘ as in Finder.
    override func keyDown(with event: NSEvent) {
        let isDelete = event.keyCode == 51 || event.keyCode == 117
        let others = event.modifierFlags.intersection([.option, .control, .shift])
        if isDelete, others.isEmpty, let onDeleteKey {
            onDeleteKey()
        } else {
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if onDeleteKey != nil { window?.makeFirstResponder(self) }
        mouseDownAt = event.locationInWindow
        draggingStarted = false
        pendingClick = false
        let modifiers = event.modifierFlags.intersection([.command, .shift])
        // Acting on the press is the whole point: waiting for mouse-up would
        // bring back the delay this layer exists to remove. The one exception
        // is a plain press on a multi-selection, which may be the start of
        // dragging all of it.
        if event.clickCount >= 2, modifiers.isEmpty {
            onDoubleClick()
        } else if modifiers.isEmpty, isInMultiSelection {
            pendingClick = true
        } else {
            onClick(modifiers)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !draggingStarted, let item, let start = mouseDownAt else { return }
        let dx = event.locationInWindow.x - start.x
        let dy = event.locationInWindow.y - start.y
        // A few points of slack so a click with a shaky hand stays a click.
        guard dx * dx + dy * dy > 9 else { return }
        draggingStarted = true
        beginDrag(dragItems?() ?? [item], with: event)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownAt = nil
        if pendingClick, !draggingStarted { onClick([]) }
        pendingClick = false
    }

    // MARK: - Drag source

    private func beginDrag(_ items: [SidebarDragItem], with event: NSEvent) {
        guard !items.isEmpty, let data = SidebarDragItem.pasteboardData(items) else { return }
        let entry = NSPasteboardItem()
        entry.setData(data, forType: .termsteadSidebarItemPasteboard)

        let dragged = NSDraggingItem(pasteboardWriter: entry)
        let image = items.count > 1
            ? dragImage(label: "\(items.count) items", symbol: "square.stack", tint: dragTint)
            : dragImage(label: dragLabel, symbol: dragSymbol, tint: dragTint)
        let pointer = convert(event.locationInWindow, from: nil)
        dragged.setDraggingFrame(
            NSRect(x: pointer.x - 14, y: pointer.y - image.size.height / 2,
                   width: image.size.width, height: image.size.height),
            contents: image
        )
        beginDraggingSession(with: [dragged], event: event, source: self)
    }

    /// Drawn rather than snapshotted: `cacheDisplay` over SwiftUI's own layers
    /// is unreliable, and a deliberate chip reads better than a half-captured
    /// row.
    private func dragImage(label: String, symbol: String, tint: NSColor) -> NSImage {
        let dragTint = tint
        let font = SBFont.nsUI(12.5, .medium)
        let text = label as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: dragTint,
        ]
        let textSize = text.size(withAttributes: attributes)
        let glyphBox: CGFloat = 16
        let padding: CGFloat = 8
        let gap: CGFloat = 6
        let size = NSSize(width: min(padding * 2 + glyphBox + gap + textSize.width, 260),
                          height: max(textSize.height, glyphBox) + padding)

        let image = NSImage(size: size)
        image.lockFocus()
        let body = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: body, xRadius: 6, yRadius: 6)
        dragBackground.withAlphaComponent(0.95).setFill()
        shape.fill()
        dragBorder.setStroke()
        shape.lineWidth = 1
        shape.stroke()

        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let tinted = NSImage(size: glyph.size, flipped: false) { rect in
                dragTint.set()
                glyph.draw(in: rect)
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: padding,
                                   y: (size.height - glyph.size.height) / 2,
                                   width: glyph.size.width, height: glyph.size.height))
        }
        text.draw(in: NSRect(x: padding + glyphBox + gap,
                             y: (size.height - textSize.height) / 2,
                             width: size.width - padding * 2 - glyphBox - gap,
                             height: textSize.height),
                  withAttributes: attributes)
        image.unlockFocus()
        return image
    }

    // MARK: - Drop target

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        resolve(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        // Lets a drag reach rows that are scrolled out of sight.
        if let event = NSApp.currentEvent, event.type == .leftMouseDragged {
            autoscroll(with: event)
        }
        return resolve(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        clear()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        clear()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { clear() }
        guard let items = SidebarDragItem.items(from: sender.draggingPasteboard) else { return false }
        let target = dropEdge(for: sender)
        guard canDrop(items, target) else { return false }
        // Read straight off the pasteboard and apply here: `loadTransferable`
        // resolves asynchronously, which is why the row used to move a beat
        // after the mouse came up.
        return performDrop(items, target)
    }

    private func resolve(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let items = SidebarDragItem.items(from: sender.draggingPasteboard) else { return [] }
        let candidate = dropEdge(for: sender)
        guard canDrop(items, candidate) else {
            clear()
            return []
        }
        if edge != candidate {
            edge = candidate
            needsDisplay = true
            // Hovering somewhere else restarts the wait to open a group.
            springOpen?.cancel()
            springOpen = nil
        }
        if candidate == .into, onSpringOpen != nil, springOpen == nil {
            springOpen = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, let self else { return }
                self.springOpen = nil
                self.onSpringOpen?()
            }
        }
        return .move
    }

    private func clear() {
        springOpen?.cancel()
        springOpen = nil
        guard edge != nil else { return }
        edge = nil
        needsDisplay = true
    }

    // MARK: - Where the pointer is inside the row

    private func dropEdge(for sender: any NSDraggingInfo) -> DropEdge {
        switch dropMode {
        case .intoOnly:
            return .into
        case .between:
            let y = convert(sender.draggingLocation, from: nil).y
            return y < bounds.height / 2 ? .before : .after
        case .intoAndBetween:
            // The middle half re-parents, the outer quarters reorder — the same
            // split an NSOutlineView uses.
            let y = convert(sender.draggingLocation, from: nil).y
            if y < bounds.height * 0.25 { return .before }
            if y > bounds.height * 0.75 { return .after }
            return .into
        }
    }

    // MARK: - Indicator

    override func draw(_ dirtyRect: NSRect) {
        guard let edge else { return }
        switch edge {
        case .into:
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                     xRadius: 6, yRadius: 6)
            accentFill.setFill()
            shape.fill()
            accent.setStroke()
            shape.lineWidth = 2
            shape.stroke()

        case .before, .after:
            let y = edge == .before ? 1.0 : bounds.height - 1
            accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: indicatorLeading + 6, y: y - 1,
                                             width: max(bounds.width - indicatorLeading - 6, 0),
                                             height: 2),
                         xRadius: 1, yRadius: 1).fill()
            // The ring at the leading end marks the depth the row will land at.
            let ring = NSRect(x: indicatorLeading, y: y - 3, width: 6, height: 6)
            NSBezierPath(ovalIn: ring).fill()
        }
    }
}

extension RowInteractionView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    /// The tree is the only place these items mean anything, so a drag that ends
    /// elsewhere should not animate back as if it had been refused mid-flight.
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}
