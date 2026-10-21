import AppKit
import IOSurface
import Observation

/// What an RDP tab connects with, read from the session when it opens.
struct RDPLaunch: Equatable, Sendable {
    var host: String
    var port: Int
    var user: String
    var domain: String
    /// From the Keychain; empty when none is saved, and then the server asks
    /// (xrdp shows its own login screen).
    var password: String
    var options: RDPOptions

    init(session: Session, password: String) {
        host = session.host
        port = session.port
        user = session.user
        domain = session.rdp.domain
        self.password = password
        options = session.rdp
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

    @ObservationIgnored let view = RDPDesktopView()
    @ObservationIgnored private var engine: RDPEngineConnection?
    @ObservationIgnored private var attempt = 0
    /// Lines for the tab's terminal, which shows what happened until the
    /// desktop is up and again once it has gone.
    @ObservationIgnored var log: ((String) -> Void)?
    /// The session ended by itself, with why; not called for `stop`.
    @ObservationIgnored var onEnded: ((String) -> Void)?
    /// How big the tab is now, in points, and the screen's scale; `nil`
    /// while it has not been laid out.
    @ObservationIgnored var availableSize: () -> (size: CGSize, scale: CGFloat)? = { nil }

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
        engine?.close()
        engine = nil
        view.show(nil)
        size = nil
        if phase != .ended("") { phase = .ended("") }
    }

    private func connect(_ launch: RDPLaunch, socket open: @MainActor () async throws -> FileHandle,
                         attempt current: Int) async {
        let (width, height, scale) = await desktopSize(for: launch.options)
        guard current == attempt else { return }
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
        settings.clipboard = launch.options.clipboard
        settings.sound = launch.options.sound

        let engine = RDPEngineConnection()
        self.engine = engine
        engine.onSurface = { [weak self] surface, width, height in
            guard let self, current == attempt else { return }
            size = CGSize(width: width, height: height)
            view.show(surface)
            phase = .showing
        }
        engine.onChange = { [weak self] _ in
            guard let self, current == attempt else { return }
            view.surfaceChanged()
        }
        engine.onVerifyCertificate = { [weak self] pem, host, port, reply in
            // Checking against macOS's trust and asking the user come with
            // the certificate prompt; until then the chain is only logged.
            self?.log?("Server certificate for \(host):\(port) accepted without checking.")
            reply(true)
        }
        engine.onDisconnected = { [weak self] reason in
            guard let self, current == attempt else { return }
            end(reason.isEmpty ? "The session ended." : reason)
        }
        engine.connect(settings, socket: socket)
    }

    private func end(_ reason: String) {
        engine?.close()
        engine = nil
        view.show(nil)
        size = nil
        phase = .ended(reason)
        onEnded?(reason)
    }

    /// The tab's size in pixels, or the fixed size the session asks for.
    /// A tab just opened may not be laid out yet; it gets a moment.
    private func desktopSize(for options: RDPOptions) async -> (width: Int, height: Int, scale: Int) {
        var available = availableSize()
        for _ in 0..<20 where available == nil {
            try? await Task.sleep(for: .milliseconds(50))
            available = availableSize()
        }
        let screenScale = available?.scale ?? NSScreen.main?.backingScaleFactor ?? 1
        let sharp = options.sharpOnRetina && screenScale >= 2
        let scale = sharp ? 200 : 100
        switch options.display {
        case .fixed(let width, let height):
            return (width, height, scale)
        case .fitTab:
            let points = available?.size ?? CGSize(width: 1280, height: 800)
            let factor = sharp ? screenScale : 1
            return Self.even(points.width * factor, points.height * factor, scale: scale)
        }
    }

    /// RDP takes an even width, and nothing outside 200…8192.
    private static func even(_ width: CGFloat, _ height: CGFloat, scale: Int) -> (Int, Int, Int) {
        let w = min(max(Int(width), 200), 8192) & ~1
        let h = min(max(Int(height), 200), 8192)
        return (w, h, scale)
    }
}

/// Shows the engine's IOSurface: the layer's contents are the surface
/// itself, so a frame is never copied on this side either.
final class RDPDesktopView: NSView {
    private var surface: IOSurface?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.isOpaque = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

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
    }
}
