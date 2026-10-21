import AppKit
import Carbon.HIToolbox
import IOSurface
import Observation

/// What an RDP tab connects with, read from the session when it opens.
struct RDPLaunch: Equatable, Sendable {
    var host: String
    var port: Int
    var user: String
    var domain: String
    /// From the Keychain; empty when none is saved, and then the tab asks.
    var password: String
    var options: RDPOptions
    /// Where a password typed into the tab is saved, when the user asks.
    var passwordAccount: String?

    init(session: Session, password: String) {
        host = session.host
        port = session.port
        user = session.user
        domain = session.rdp.domain
        self.password = password
        options = session.rdp
        passwordAccount = SSHLaunch.sessionPasswordAccount(session.id)
    }
}

/// An RDP tab's remote desktop: the engine session, and the view it is shown
/// in. Like a tab's terminal, the view outlives any one pane.
@MainActor
@Observable
final class RDPDesktop {
    enum Phase: Equatable {
        case connecting
        /// The desktop is on screen.
        case showing
        case ended(String)
    }

    private(set) var phase: Phase = .ended("")
    /// The remote desktop in pixels, once there is one.
    private(set) var size: CGSize?

    /// A certificate macOS does not trust and the user has not trusted
    /// before, or one that changed: asked in the tab, as ssh asks about a
    /// host key in the terminal.
    struct CertificateQuestion: Equatable {
        var host: String
        var port: Int
        var subject: String
        var fingerprint: String
        /// Why macOS does not trust it.
        var problem: String
        /// Another certificate was trusted for this server before.
        var changed: Bool
    }

    /// The server wants a login the session does not have, or refused the
    /// one it has.
    struct LoginQuestion: Equatable {
        var host: String
        var user: String
        var domain: String
        /// Why it is asked again: the server refused the last one.
        var problem: String?
        /// The session has a Keychain entry to save the password to.
        var canSave: Bool
    }

    private(set) var certificateQuestion: CertificateQuestion?
    private(set) var loginQuestion: LoginQuestion?
    @ObservationIgnored private var certificateAnswer: ((Bool) -> Void)?
    @ObservationIgnored private var loginAnswer: ((RDPLogin?, Bool) -> Void)?
    /// How it ended, when the user is why: the engine reports only that the
    /// connection was cancelled.
    @ObservationIgnored private var endedByUser: String?
    @ObservationIgnored var knownHosts = RDPKnownHosts.shared
    @ObservationIgnored var keychain = KeychainStore.shared
    /// The Mac's clipboard, shared with the server when the session says
    /// so. A test swaps in a private one, so it never overwrites the user's.
    @ObservationIgnored var pasteboard: NSPasteboard = .general
    @ObservationIgnored private var clipboardWatch: Task<Void, Never>?
    /// The pasteboard's change count last offered or written: a change the
    /// server made is not offered back to it.
    @ObservationIgnored private var seenChange = -1

    @ObservationIgnored let view = RDPDesktopView()
    @ObservationIgnored private var engine: RDPEngineConnection?
    @ObservationIgnored private var attempt = 0
    /// What the session looks like, from its settings when it opened.
    @ObservationIgnored private var options = RDPOptions()
    @ObservationIgnored private var pendingResize: Task<Void, Never>?
    /// How long the tab's size must hold before the desktop follows it.
    /// Longer than a terminal's: the server redraws the whole screen.
    static let resizeDelay: Duration = .milliseconds(300)
    /// Lines for the tab's terminal, which shows what happened until the
    /// desktop is up and again once it has gone.
    @ObservationIgnored var log: ((String) -> Void)?
    /// The session ended by itself, with why; not called for `stop`.
    @ObservationIgnored var onEnded: ((String) -> Void)?
    /// How big the tab is now, in points, and the screen's scale; `nil`
    /// while it has not been laid out.
    @ObservationIgnored var availableSize: () -> (size: CGSize, scale: CGFloat)? = { nil }

    init() {
        view.desktop = self
    }

    // MARK: - Input, from the view

    func send(_ key: RDPKeyboard.Key, down: Bool) {
        guard phase == .showing else { return }
        engine?.key(Int(key.code), extended: key.extended, down: down)
    }

    func sendMouse(x: Int, y: Int, flags: Int) {
        guard phase == .showing else { return }
        engine?.mouse(x: x, y: y, flags: flags)
    }

    func synchronize(capsLock: Bool) {
        guard phase == .showing else { return }
        engine?.synchronize(capsLock: capsLock)
    }

    /// A key combination the Mac keeps for itself, pressed and let go.
    func press(_ keys: [RDPKeyboard.Key]) {
        for key in keys { send(key, down: true) }
        for key in keys.reversed() { send(key, down: false) }
    }

    /// Session ▸ Send Ctrl+Alt+Del: on a Mac those keys never get there.
    func sendControlAltDelete() {
        press([RDPKeyboard.leftControl, RDPKeyboard.leftAlt, RDPKeyboard.delete])
    }

    /// Session ▸ Send Windows Key: Command stays with the Mac.
    func sendWindowsKey() {
        press([RDPKeyboard.leftWindows])
    }

    /// Edit ▸ Copy, Paste and the rest — ⌘C, ⌘V — in the desktop. A paste
    /// first hands the server what is on the Mac's clipboard now, rather
    /// than at the next look a second later.
    func perform(_ command: RDPKeyboard.EditCommand) {
        guard phase == .showing else { return }
        if command == .paste, options.clipboard {
            offerClipboard(force: true)
            // The clipboard and the keys share the connection but not a
            // queue on the server: give it the text before the keys.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                self?.press(command.keys)
            }
            return
        }
        press(command.keys)
    }

    /// Opens `socket` and logs in over it.
    func start(_ launch: RDPLaunch, socket: @escaping @MainActor () async throws -> FileHandle) {
        stop()
        attempt += 1
        let current = attempt
        phase = .connecting
        log?("Connecting to \(launch.host):\(launch.port)…")
        Task { [weak self] in
            await self?.connect(launch, socket: socket, attempt: current)
        }
    }

    /// Ends the session, as asked: no `onEnded`.
    func stop() {
        attempt += 1
        stopClipboard()
        dropQuestions()
        engine?.close()
        engine = nil
        view.show(nil)
        size = nil
        if phase != .ended("") { phase = .ended("") }
    }

    // MARK: - Questions, from the tab

    func answerCertificate(trust: Bool) {
        let answer = certificateAnswer
        certificateAnswer = nil
        certificateQuestion = nil
        answer?(trust)
    }

    /// `nil` gives up. `save` puts the password in the Keychain for the
    /// session, as the session form would.
    func answerLogin(_ login: RDPLogin?, save: Bool) {
        let answer = loginAnswer
        loginAnswer = nil
        loginQuestion = nil
        answer?(login, save)
    }

    private func dropQuestions() {
        certificateQuestion = nil
        loginQuestion = nil
        certificateAnswer = nil
        loginAnswer = nil
    }

    /// FreeRDP's errors for a login the server turned down
    /// (FREERDP_ERROR_CONNECT_*: authentication failed, logon failure,
    /// wrong password, no or missing credentials).
    nonisolated static func isRefusedLogin(_ code: Int) -> Bool {
        [0x0002_0009, 0x0002_0014, 0x0002_0015, 0x0002_001B].contains(code)
    }

    private func connect(_ launch: RDPLaunch, socket open: @escaping @MainActor () async throws -> FileHandle,
                         attempt current: Int) async {
        let (width, height, scale) = await desktopSize(for: launch.options)
        guard current == attempt else { return }
        options = launch.options
        endedByUser = nil
        let socket: FileHandle
        do {
            socket = try await open()
        } catch {
            guard current == attempt else { return }
            end(String(describing: error))
            return
        }
        guard current == attempt else { return }

        let settings = RDPConnectSettings()
        settings.host = launch.host
        settings.port = launch.port
        settings.user = launch.user
        settings.domain = launch.domain
        settings.password = launch.password
        settings.width = width
        settings.height = height
        settings.desktopScale = scale
        settings.keyboardLayout = RDPKeyboard.sessionLayoutID
        settings.clipboard = launch.options.clipboard
        settings.sound = launch.options.sound

        let engine = RDPEngineConnection()
        self.engine = engine
        engine.onSurface = { [weak self] surface, width, height in
            guard let self, current == attempt else { return }
            size = CGSize(width: width, height: height)
            view.show(surface)
            if phase != .showing, launch.options.clipboard { watchClipboard() }
            phase = .showing
            view.synchronizeLocks()
        }
        engine.onChange = { [weak self] _ in
            guard let self, current == attempt else { return }
            view.surfaceChanged()
        }
        engine.onServerClipboard = { [weak self] text in
            guard let self, current == attempt, launch.options.clipboard else { return }
            received(text)
        }
        engine.onVerifyCertificate = { [weak self] pem, _, _, reply in
            guard let self, current == attempt else { return reply(false) }
            Task { await self.check(pem, for: launch, attempt: current, reply: reply) }
        }
        engine.onAskCredentials = { [weak self] user, domain, reply in
            guard let self, current == attempt else { return reply(nil) }
            ask(launch, user: user, domain: domain, problem: nil) { [weak self] login, save in
                if login == nil { self?.endedByUser = "Login cancelled." }
                if let login, save { self?.save(login.password, for: launch) }
                reply(login)
            }
        }
        engine.onDisconnected = { [weak self] reason, code in
            guard let self, current == attempt else { return }
            if Self.isRefusedLogin(code) {
                askAgain(launch, socket: open)
            } else {
                end(endedByUser ?? Self.explanation(code: code, reason: reason))
            }
        }
        engine.connect(settings, socket: socket)
    }

    /// Trusted by macOS for this host, or trusted by the user before, it
    /// goes ahead; otherwise the tab asks.
    /// The server's reasons for ending a session (ERRINFO_*, in FreeRDP's
    /// error class 1), said the way someone at the Mac would. FreeRDP's own
    /// words for "logged off" misled: xrdp sends it when the same user
    /// connects again from elsewhere and takes the desktop over.
    nonisolated static func explanation(code: Int, reason: String) -> String {
        switch code {
        case 0x0001_0001, 0x0001_000B: "The session was disconnected on the server."
        case 0x0001_0002: "The session was logged off from the server."
        case 0x0001_0003: "The server ended the session: it was idle too long."
        case 0x0001_0004: "The server ended the session: the login took too long."
        case 0x0001_0005: "The same user connected to the server from elsewhere and took the session over."
        case 0x0001_000C:
            "The session ended on the server: its user logged off, or connected again from elsewhere and took the desktop over."
        default: reason.isEmpty ? "The session ended." : reason
        }
    }

    private func check(_ pem: String, for launch: RDPLaunch, attempt current: Int,
                       reply: @escaping @Sendable (Bool) -> Void) async {
        guard let certificate = RDPCertificate(pem: pem) else { return reply(false) }
        let known = knownHosts.fingerprint(host: launch.host, port: launch.port)
        if known == certificate.fingerprint { return reply(true) }
        guard let problem = await certificate.systemDistrust(for: launch.host) else { return reply(true) }
        guard current == attempt else { return reply(false) }
        certificateQuestion = CertificateQuestion(host: launch.host, port: launch.port,
                                                  subject: certificate.subject,
                                                  fingerprint: certificate.fingerprint,
                                                  problem: problem, changed: known != nil)
        certificateAnswer = { [weak self] trust in
            if trust {
                self?.knownHosts.trust(certificate.fingerprint, host: launch.host, port: launch.port)
            } else {
                self?.endedByUser = "The server's certificate was not trusted."
            }
            reply(trust)
        }
    }

    private func ask(_ launch: RDPLaunch, user: String, domain: String, problem: String?,
                     answer: @escaping (RDPLogin?, Bool) -> Void) {
        loginQuestion = LoginQuestion(host: launch.host, user: user.isEmpty ? launch.user : user,
                                      domain: domain.isEmpty ? launch.domain : domain,
                                      problem: problem, canSave: launch.passwordAccount != nil)
        loginAnswer = answer
    }

    /// The server refused the login: ask for another, and connect again
    /// with it — over a new socket, the old one is spent.
    private func askAgain(_ launch: RDPLaunch, socket: @escaping @MainActor () async throws -> FileHandle) {
        engine?.close()
        engine = nil
        ask(launch, user: launch.user, domain: launch.domain,
            problem: "The user name or password is incorrect.") { [weak self] login, save in
            guard let self else { return }
            guard let login else { return end("Login cancelled.") }
            if save { self.save(login.password, for: launch) }
            var next = launch
            next.user = login.user
            next.domain = login.domain
            next.password = login.password
            attempt += 1
            let current = attempt
            log?("Logging in again as \(login.user)…")
            Task { [weak self] in await self?.connect(next, socket: socket, attempt: current) }
        }
    }

    private func save(_ password: String, for launch: RDPLaunch) {
        guard let account = launch.passwordAccount, !password.isEmpty else { return }
        keychain.set(password, for: account)
    }

    // MARK: - Clipboard

    /// Text copied here is offered to the server as it changes. The
    /// pasteboard says nothing when it changes, so it is looked at once a
    /// second — its change count, which costs nothing to read.
    private func watchClipboard() {
        stopClipboard()
        seenChange = -1
        clipboardWatch = Task { [weak self] in
            while !Task.isCancelled {
                self?.offerClipboard()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopClipboard() {
        clipboardWatch?.cancel()
        clipboardWatch = nil
    }

    private func offerClipboard(force: Bool = false) {
        guard let engine, force || pasteboard.changeCount != seenChange else { return }
        seenChange = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string) else { return }
        engine.clipboard(Self.serverText(text))
    }

    private func received(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(Self.macText(text), forType: .string)
        seenChange = pasteboard.changeCount
    }

    /// RDP's text has Windows line endings; the Mac's has its own.
    nonisolated static func serverText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    nonisolated static func macText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    // MARK: - Size

    /// The tab changed size, or moved to a screen of another scale. A
    /// desktop that fits its tab follows once the size holds still; one of
    /// a fixed size is only scaled.
    func tabSizeChanged() {
        guard phase == .showing, options.display == .fitTab else { return }
        pendingResize?.cancel()
        pendingResize = Task { [weak self] in
            try? await Task.sleep(for: Self.resizeDelay)
            guard !Task.isCancelled else { return }
            self?.resizeToFit()
        }
    }

    private func resizeToFit() {
        guard phase == .showing, let engine, let available = availableSize() else { return }
        let fit = Self.fit(points: available.size, screenScale: available.scale, options: options)
        guard CGSize(width: fit.width, height: fit.height) != size else { return }
        // The server answers with a desktop of the new size, as a new
        // surface; a server without Display Control ignores it, and the
        // picture is scaled instead.
        engine.resize(width: fit.width, height: fit.height, desktopScale: fit.scale)
    }

    private func end(_ reason: String) {
        stopClipboard()
        dropQuestions()
        engine?.close()
        engine = nil
        view.show(nil)
        size = nil
        phase = .ended(reason)
        onEnded?(reason)
    }

    /// The size to log in at. A tab just opened may not be laid out yet; it
    /// gets a moment.
    private func desktopSize(for options: RDPOptions) async -> (width: Int, height: Int, scale: Int) {
        var available = availableSize()
        for _ in 0..<20 where available == nil {
            try? await Task.sleep(for: .milliseconds(50))
            available = availableSize()
        }
        return Self.fit(points: available?.size ?? CGSize(width: 1280, height: 800),
                        screenScale: available?.scale ?? NSScreen.main?.backingScaleFactor ?? 1,
                        options: options)
    }

    /// The desktop for a tab of `points`: its pixels on a Retina screen with
    /// Windows at 200%, so text keeps its size and is sharp; one pixel a
    /// point otherwise. A fixed size is the session's own, scaled to fit.
    /// RDP takes an even width, and nothing outside 200…8192.
    nonisolated static func fit(points: CGSize, screenScale: CGFloat,
                                options: RDPOptions) -> (width: Int, height: Int, scale: Int) {
        let sharp = options.sharpOnRetina && screenScale >= 2
        let scale = sharp ? 200 : 100
        switch options.display {
        case .fixed(let width, let height):
            return (width, height, scale)
        case .fitTab:
            let factor = sharp ? screenScale : 1
            let width = min(max(Int(points.width * factor), 200), 8192) & ~1
            let height = min(max(Int(points.height * factor), 200), 8192)
            return (width, height, scale)
        }
    }
}

/// Shows the engine's IOSurface, and takes the keyboard and mouse for it.
/// The layer's contents are the surface itself, so a frame is never copied
/// on this side either.
final class RDPDesktopView: NSView {
    weak var desktop: RDPDesktop?
    private var surface: IOSurface?
    /// Keys down on the remote side, so none is left held there when the
    /// keyboard goes elsewhere — ⌘Tab away mid-Alt, say.
    private var pressed: Set<RDPKeyboard.Key> = []
    private var wheel = RDPPointer.Wheel()
    private var horizontalWheel = RDPPointer.Wheel()

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
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func show(_ surface: IOSurface?) {
        self.surface = surface
        apply()
    }

    /// The engine drew into the surface. A layer does not notice by itself
    /// that its IOSurface changed, so it is handed the surface again.
    func surfaceChanged() {
        apply()
    }

    private func apply() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = nil
        layer?.contents = surface
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 1
        desktop?.tabSizeChanged()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { desktop?.tabSizeChanged() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey),
                                                   name: NSWindow.didResignKeyNotification, object: window)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        synchronizeLocks()
        return true
    }

    override func resignFirstResponder() -> Bool {
        releaseAll()
        return true
    }

    @objc private func windowResignedKey() {
        releaseAll()
    }

    func synchronizeLocks() {
        desktop?.synchronize(capsLock: NSEvent.modifierFlags.contains(.capsLock))
    }

    override func keyDown(with event: NSEvent) {
        // ⌘ shortcuts the menus did not take still belong to the Mac.
        guard !event.modifierFlags.contains(.command) else { return }
        send(event.keyCode, down: true)
    }

    override func keyUp(with event: NSEvent) {
        send(event.keyCode, down: false)
    }

    override func flagsChanged(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_CapsLock) {
            // A toggle: each change is one press of the key.
            send(event.keyCode, down: true)
            send(event.keyCode, down: false)
        } else if let down = RDPKeyboard.modifierIsDown(keyCode: event.keyCode,
                                                         flags: event.modifierFlags.rawValue) {
            send(event.keyCode, down: down)
        }
    }

    private func send(_ keyCode: UInt16, down: Bool) {
        guard let key = RDPKeyboard.key(forKeyCode: keyCode) else { return }
        if down { pressed.insert(key) } else { pressed.remove(key) }
        desktop?.send(key, down: down)
    }

    private func releaseAll() {
        for key in pressed { desktop?.send(key, down: false) }
        pressed.removeAll()
    }

    // MARK: - Mouse

    private func sendMouse(_ event: NSEvent, flags: Int) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        let pixel = RDPPointer.pixel(at: point, desktop: CGSize(width: surface.width, height: surface.height),
                                     bounds: bounds.size)
        desktop?.sendMouse(x: pixel.x, y: pixel.y, flags: flags)
    }

    override func mouseMoved(with event: NSEvent) { sendMouse(event, flags: RDPPointer.move) }
    override func mouseDragged(with event: NSEvent) { sendMouse(event, flags: RDPPointer.move) }
    override func rightMouseDragged(with event: NSEvent) { sendMouse(event, flags: RDPPointer.move) }
    override func otherMouseDragged(with event: NSEvent) { sendMouse(event, flags: RDPPointer.move) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMouse(event, flags: RDPPointer.left | RDPPointer.down)
    }
    override func mouseUp(with event: NSEvent) { sendMouse(event, flags: RDPPointer.left) }
    override func rightMouseDown(with event: NSEvent) { sendMouse(event, flags: RDPPointer.right | RDPPointer.down) }
    override func rightMouseUp(with event: NSEvent) { sendMouse(event, flags: RDPPointer.right) }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        sendMouse(event, flags: RDPPointer.middle | RDPPointer.down)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        sendMouse(event, flags: RDPPointer.middle)
    }

    /// No menu of ours: the right button belongs to the remote desktop.
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    // MARK: - Edit menu

    // ⌘C, ⌘V and the rest reach the view as the Edit menu's actions, and go
    // to the desktop as Ctrl and the same key (`RDPKeyboard.EditCommand`).
    @objc func cut(_ sender: Any?) { desktop?.perform(.cut) }
    @objc func copy(_ sender: Any?) { desktop?.perform(.copy) }
    @objc func paste(_ sender: Any?) { desktop?.perform(.paste) }
    @objc override func selectAll(_ sender: Any?) { desktop?.perform(.selectAll) }
    @objc func undo(_ sender: Any?) { desktop?.perform(.undo) }
    @objc func redo(_ sender: Any?) { desktop?.perform(.redo) }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        desktop?.phase == .showing
    }

    override func scrollWheel(with event: NSEvent) {
        let precise = event.hasPreciseScrollingDeltas
        for step in wheel.steps(for: event.scrollingDeltaY, precise: precise) {
            sendMouse(event, flags: RDPPointer.wheelFlags(step, horizontal: false))
        }
        // macOS's positive is towards the left; Windows' is to the right.
        for step in horizontalWheel.steps(for: -event.scrollingDeltaX, precise: precise) {
            sendMouse(event, flags: RDPPointer.wheelFlags(step, horizontal: true))
        }
    }
}
