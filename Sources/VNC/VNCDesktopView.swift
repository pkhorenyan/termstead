import AppKit
import IOSurface

/// One framebuffer at Fit or a fixed scale, without changing the shared
/// server desktop. Rendering, mouse coordinates and cursor use one rectangle.
final class VNCDesktopView: NSView {
    weak var desktop: VNCDesktop?
    private var surface: IOSurface?
    private var pressed: [UInt16: UInt32] = [:]
    private var buttons = 0
    private var lastPointer = (x: 0, y: 0)
    private var wheel = RDPPointer.Wheel()
    private var horizontalWheel = RDPPointer.Wheel()
    private var wheelUnits = 0
    private var horizontalWheelUnits = 0
    private var cursorShape: RDPPointer.Shape?
    private var cursorIsHidden = false
    private var contextClick: (id: UUID, event: NSEvent, released: Bool)?
    private var madeCursor: NSCursor?
    /// In Fit mode the whole pane is the drawing area; at a fixed zoom the
    /// document can be larger in just one direction, leaving centered margins.
    var shownRect: CGRect {
        guard let surface else { return bounds }
        if let zoom = desktop?.zoom, zoom > 0 {
            let size = CGSize(width: CGFloat(surface.width) * CGFloat(zoom) / 100,
                              height: CGFloat(surface.height) * CGFloat(zoom) / 100)
            return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                          width: size.width, height: size.height)
        }
        return RDPPointer.shownRect(of: CGSize(width: surface.width, height: surface.height), in: bounds.size)
    }
    private let imageLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.isOpaque = true
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .nearest
        layer?.addSublayer(imageLayer)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var hasKeyboard: Bool {
        NSApp.isActive && window?.isKeyWindow == true && window?.firstResponder === self
    }
    func show(_ surface: IOSurface?) {
        self.surface = surface
        if surface == nil { cursorShape = nil; cursorIsHidden = false }
        cursorChanged()
        surfaceChanged()
    }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { updateImageFrame() }
    }
    func updateImageFrame() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.frame = shownRect
        CATransaction.commit()
        cursorChanged()
    }
    func showCursor(rgba: Data, width: Int, height: Int, hotX: Int, hotY: Int) {
        if width == 0 || height == 0 {
            cursorShape = nil
            cursorIsHidden = true
        } else {
            guard let shape = RDPPointer.Shape(rgba: rgba, width: width, height: height, hotX: hotX, hotY: hotY) else { return }
            cursorShape = shape
            cursorIsHidden = false
        }
        cursorChanged()
    }
    var cursor: NSCursor {
        if let madeCursor { return madeCursor }
        let result: NSCursor
        if cursorIsHidden {
            result = RDPPointer.hidden
        } else if let cursorShape, let surface {
            result = cursorShape.cursor(scale: shownRect.width / CGFloat(surface.width))
        } else {
            result = .arrow
        }
        madeCursor = result
        return result
    }
    private func cursorChanged() {
        madeCursor = nil
        guard let window else { return }
        window.invalidateCursorRects(for: self)
        let root = window.contentView?.superview ?? window.contentView
        if window.isKeyWindow,
           root?.hitTest(root!.convert(window.mouseLocationOutsideOfEventStream, from: nil)) === self {
            cursor.set()
        }
    }
    func surfaceChanged() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = shownRect
        imageLayer.contents = nil
        imageLayer.contents = surface
        CATransaction.commit()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(resigned),
                                                   name: NSWindow.didResignKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(arrived),
                                                   name: NSWindow.didBecomeKeyNotification, object: window)
        } else { releaseInput() }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }
    override func cursorUpdate(with event: NSEvent) {
        cursor.set()
    }
    override func becomeFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in self?.desktop?.keyboardArrived() }
        return true
    }
    override func resignFirstResponder() -> Bool {
        if let desktop { desktop.keyboardLeft() } else { releaseInput() }
        return true
    }
    @objc private func resigned() { desktop?.keyboardLeft() }
    @objc private func arrived() { if hasKeyboard { desktop?.keyboardArrived() } }
    func releaseInput() {
        contextClick = nil
        pressed.values.forEach { desktop?.send($0, down: false) }
        pressed.removeAll()
        if buttons != 0 { desktop?.pointer(x: lastPointer.x, y: lastPointer.y, buttons: 0) }
        buttons = 0
        wheelUnits = 0; horizontalWheelUnits = 0
    }
    override func keyDown(with event: NSEvent) {
        contextClick = nil
        guard !event.modifierFlags.contains(.command) else { return }
        let chars = event.modifierFlags.intersection([.control, .option]).isEmpty
            ? event.characters : event.charactersIgnoringModifiers
        guard let symbol = VNCKeyboard.symbol(keyCode: event.keyCode, characters: chars) else { return }
        if let previous = pressed[event.keyCode], previous != symbol { desktop?.send(previous, down: false) }
        pressed[event.keyCode] = symbol
        desktop?.send(symbol, down: true)
    }
    override func keyUp(with event: NSEvent) {
        if let symbol = pressed.removeValue(forKey: event.keyCode) { desktop?.send(symbol, down: false) }
    }
    override func flagsChanged(with event: NSEvent) {
        if event.keyCode == 57 {
            desktop?.press([0xffe5])
        } else if let symbol = VNCKeyboard.modifiers[event.keyCode],
                  let down = RDPKeyboard.modifierIsDown(keyCode: event.keyCode, flags: event.modifierFlags.rawValue) {
            if down { pressed[event.keyCode] = symbol } else { pressed[event.keyCode] = nil }
            desktop?.send(symbol, down: down)
        }
    }
    private func move(_ event: NSEvent, button: Int = 0, down: Bool = false, scroll: Int = 0) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        // Clicks in the letterbox do not land on the server's nearest edge.
        if button != 0, down,
           !shownRect.contains(point) { return }
        let rect = shownRect
        guard rect.width > 0, rect.height > 0 else { return }
        lastPointer = (min(max(Int((point.x - rect.minX) * CGFloat(surface.width) / rect.width), 0), surface.width - 1),
                       min(max(Int((point.y - rect.minY) * CGFloat(surface.height) / rect.height), 0), surface.height - 1))
        if down { buttons |= button } else { buttons &= ~button }
        desktop?.pointer(x: lastPointer.x, y: lastPointer.y, buttons: buttons | scroll)
        if scroll != 0 { desktop?.pointer(x: lastPointer.x, y: lastPointer.y, buttons: buttons) }
    }
    override func mouseMoved(with event: NSEvent) {
        // SwiftUI can put its arrow back when the mouse moves over an NSView.
        if NSCursor.current !== cursor { cursor.set() }
        move(event)
    }
    override func mouseDragged(with event: NSEvent) { move(event) }
    override func rightMouseDragged(with event: NSEvent) { if contextClick == nil { move(event) } }
    override func otherMouseDragged(with event: NSEvent) { move(event) }
    override func mouseDown(with event: NSEvent) { contextClick = nil; window?.makeFirstResponder(self); move(event, button: 1, down: true) }
    override func mouseUp(with event: NSEvent) { move(event, button: 1) }
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard shownRect.contains(convert(event.locationInWindow, from: nil)), let desktop else { return }
        let id = UUID()
        contextClick = (id, event, false)
        let waiting = desktop.prepareContextMenu { [weak self] ready in
            guard let self, let click = contextClick, click.id == id else { return }
            contextClick = nil
            guard ready else { return }
            move(click.event, button: 4, down: true)
            if click.released { move(click.event, button: 4) }
        }
        if !waiting { contextClick = nil; move(event, button: 4, down: true) }
    }
    override func rightMouseUp(with event: NSEvent) {
        if contextClick != nil { contextClick?.released = true }
        else { move(event, button: 4) }
    }
    override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 { move(event, button: 2, down: true) } }
    override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { move(event, button: 2) } }
    override func scrollWheel(with event: NSEvent) {
        // Option-scroll pans the local viewport; an ordinary wheel still
        // scrolls the remote application, including at 100% zoom.
        if event.modifierFlags.contains(.option), enclosingScrollView != nil {
            super.scrollWheel(with: event); return
        }
        wheelUnits += wheel.steps(for: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas).reduce(0, +)
        while abs(wheelUnits) >= 120 {
            let up = wheelUnits > 0
            move(event, scroll: up ? 8 : 16)
            wheelUnits += up ? -120 : 120
        }
        horizontalWheelUnits += horizontalWheel.steps(for: event.scrollingDeltaX, precise: event.hasPreciseScrollingDeltas).reduce(0, +)
        while abs(horizontalWheelUnits) >= 120 {
            let left = horizontalWheelUnits > 0
            move(event, scroll: left ? 32 : 64)
            horizontalWheelUnits += left ? -120 : 120
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    private func edit(_ letter: UInt32) { contextClick = nil; desktop?.edit(letter) }
    @objc func copy(_ sender: Any?) { edit(0x63) }
    @objc func cut(_ sender: Any?) { edit(0x78) }
    @objc func paste(_ sender: Any?) { edit(0x76) }
    @objc override func selectAll(_ sender: Any?) { edit(0x61) }
    @objc func undo(_ sender: Any?) { edit(0x7a) }
    @objc func redo(_ sender: Any?) { desktop?.redo() }
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool { desktop?.phase == .showing && desktop?.viewOnly == false }
}
