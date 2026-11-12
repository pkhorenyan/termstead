import AppKit
import IOSurface

/// A server-sized framebuffer, fitted to the pane without changing the
/// desktop shared by other VNC viewers. Mouse coordinates use the same fit.
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

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.isOpaque = true
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
    func show(_ surface: IOSurface?) { self.surface = surface; surfaceChanged() }
    func surfaceChanged() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = nil
        layer?.contents = surface
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
        guard let surface, desktop?.viewOnly == false else { return }
        let rect = RDPPointer.shownRect(of: CGSize(width: surface.width, height: surface.height), in: bounds.size)
        addCursorRect(rect, cursor: RDPPointer.hidden)
    }
    override func cursorUpdate(with event: NSEvent) {
        // The server paints its own pointer when cursor pseudo-encodings are
        // off; a local arrow on top would draw two pointers at different scales.
        if desktop?.viewOnly == false { RDPPointer.hidden.set() } else { NSCursor.arrow.set() }
    }
    override func becomeFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in self?.desktop?.keyboardArrived() }
        return true
    }
    override func resignFirstResponder() -> Bool { releaseInput(); return true }
    @objc private func resigned() { desktop?.keyboardLeft() }
    @objc private func arrived() { if hasKeyboard { desktop?.keyboardArrived() } }
    func releaseInput() {
        pressed.values.forEach { desktop?.send($0, down: false) }
        pressed.removeAll()
        if buttons != 0 { desktop?.pointer(x: lastPointer.x, y: lastPointer.y, buttons: 0) }
        buttons = 0
        wheelUnits = 0; horizontalWheelUnits = 0
    }
    override func keyDown(with event: NSEvent) {
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
           !RDPPointer.shownRect(of: CGSize(width: surface.width, height: surface.height), in: bounds.size).contains(point) { return }
        lastPointer = RDPPointer.pixel(at: point, desktop: CGSize(width: surface.width, height: surface.height), bounds: bounds.size)
        if down { buttons |= button } else { buttons &= ~button }
        desktop?.pointer(x: lastPointer.x, y: lastPointer.y, buttons: buttons | scroll)
        if scroll != 0 { desktop?.pointer(x: lastPointer.x, y: lastPointer.y, buttons: buttons) }
    }
    override func mouseMoved(with event: NSEvent) { move(event) }
    override func mouseDragged(with event: NSEvent) { move(event) }
    override func rightMouseDragged(with event: NSEvent) { move(event) }
    override func otherMouseDragged(with event: NSEvent) { move(event) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); move(event, button: 1, down: true) }
    override func mouseUp(with event: NSEvent) { move(event, button: 1) }
    override func rightMouseDown(with event: NSEvent) { move(event, button: 4, down: true) }
    override func rightMouseUp(with event: NSEvent) { move(event, button: 4) }
    override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 { move(event, button: 2, down: true) } }
    override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { move(event, button: 2) } }
    override func scrollWheel(with event: NSEvent) {
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
    private func edit(_ letter: UInt32) { desktop?.press([0xffe3, letter]) }
    @objc func copy(_ sender: Any?) { edit(0x63) }
    @objc func cut(_ sender: Any?) { edit(0x78) }
    @objc func paste(_ sender: Any?) { desktop?.offerClipboard(onPaste: true); edit(0x76) }
    @objc override func selectAll(_ sender: Any?) { edit(0x61) }
    @objc func undo(_ sender: Any?) { edit(0x7a) }
    @objc func redo(_ sender: Any?) { edit(0x79) }
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool { desktop?.phase == .showing && desktop?.viewOnly == false }
}
