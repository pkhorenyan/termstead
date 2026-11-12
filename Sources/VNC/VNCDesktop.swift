import AppKit
import IOSurface
import Observation

struct VNCLaunch: Equatable, Sendable {
    var host: String
    var port: Int
    var user: String
    var password: String
    var passwordAccount: String?
    var options: VNCOptions

    init(session: Session, password: String) {
        host = session.host; port = session.port; user = session.user
        self.password = password
        passwordAccount = SSHLaunch.sessionPasswordAccount(session.id)
        options = session.vnc
    }
}

@MainActor @Observable
final class VNCDesktop {
    enum Phase: Equatable { case connecting, showing, ended(String) }
    struct LoginQuestion: Equatable {
        var host: String
        var user: String
        var problem: String?
        var canSave: Bool
    }
    private(set) var phase: Phase = .ended("")
    private(set) var size: CGSize?
    private(set) var loginQuestion: LoginQuestion?
    private(set) var certificateQuestion: RDPDesktop.CertificateQuestion?
    private(set) var retryMessage: String?
    private(set) var supportsResize = false
    private(set) var resizeMessage: String?
    var asksScale = false
    @ObservationIgnored let view = VNCDesktopView()
    @ObservationIgnored lazy var viewport = VNCViewport(view: view)
    @ObservationIgnored var knownHosts = RDPKnownHosts(url: URL.applicationSupportDirectory
        .appendingPathComponent("Termstead/vnc_known_hosts"))
    @ObservationIgnored var keychain = KeychainStore.shared
    @ObservationIgnored var pasteboard: NSPasteboard = .general
    @ObservationIgnored var hasKeyboard: () -> Bool = { false }
    @ObservationIgnored var onEnded: ((String) -> Void)?
    @ObservationIgnored var onConnected: (() -> Void)?
    @ObservationIgnored var onStableDisconnect: (() -> Void)?
    @ObservationIgnored var log: ((String) -> Void)?
    @ObservationIgnored private var engine: VNCEngineConnection?
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var clipboardWatch: Task<Void, Never>?
    @ObservationIgnored private var clipboardFocusState: (Bool, Int)?
    @ObservationIgnored private var seenChange = -1
    @ObservationIgnored private var pendingClipboard: String?
    @ObservationIgnored private var openSocket: (@MainActor () async throws -> FileHandle)?
    @ObservationIgnored private(set) var lastLaunch: VNCLaunch?
    @ObservationIgnored private var certificateAnswer: ((Bool) -> Void)?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private var retries = 0
    @ObservationIgnored var reconnectDelays = Connection.reconnectDelays
    @ObservationIgnored private var didConnect = false
    @ObservationIgnored private var connectedAt: TimeInterval?
    @ObservationIgnored var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Backoff time is not time spent connected. The tunnel owner checks this
    /// before stopping a desktop whose SSH transport has dropped.
    var hasStableConnection: Bool {
        connectedAt.map { uptime() - $0 >= 30 } ?? false
    }
    private(set) var zoomOverride: Int?
    static let zoomSteps = [25, 50, 75, 100, 125, 150, 200, 300, 400]
    var zoom: Int {
        let value = zoomOverride ?? lastLaunch?.options.zoom ?? 0
        return value == 0 ? 0 : min(max(value, 25), 400)
    }
    func setZoom(_ value: Int) {
        zoomOverride = value == 0 ? 0 : min(max(value, 25), 400)
        viewport.zoom = zoom
        view.updateImageFrame()
    }
    func zoomed(by delta: Int) -> Int? {
        let current = zoom > 0 ? zoom : Int((size.map { RDPPointer.scale(of: $0, in: viewport.contentView.bounds.size) } ?? 1) * 100)
        return delta > 0 ? Self.zoomSteps.first { $0 > current } : Self.zoomSteps.last { $0 < current }
    }
    func zoom(by delta: Int) { if let next = zoomed(by: delta) { setZoom(next) } }
    func resetZoom() { zoomOverride = nil; viewport.zoom = zoom; view.updateImageFrame() }

    init() {
        view.desktop = self
        let view = view
        hasKeyboard = { view.hasKeyboard }
    }
    func start(_ launch: VNCLaunch, socket: @escaping @MainActor () async throws -> FileHandle) {
        stop()
        lastLaunch = launch
        retries = 0; didConnect = false
        viewport.zoom = zoom
        openSocket = socket
        phase = .connecting
        if launch.password.isEmpty && !launch.options.allowNoAuth {
            askLogin(problem: nil)
        } else {
            connect()
        }
    }
    func stop() {
        attempt += 1
        reconnectTask?.cancel(); reconnectTask = nil
        resizeTask?.cancel(); resizeTask = nil
        retryMessage = nil; supportsResize = false; resizeMessage = nil
        asksScale = false
        connectedAt = nil
        let answer = certificateAnswer
        certificateAnswer = nil; certificateQuestion = nil
        answer?(false)
        clipboardWatch?.cancel(); clipboardWatch = nil
        clipboardFocusState = nil
        engine?.close(); engine = nil
        loginQuestion = nil
        openSocket = nil
        pendingClipboard = nil
        view.releaseInput()
        view.show(nil)
        size = nil
        phase = .ended("")
    }
    private func askLogin(problem: String?) {
        guard let launch = lastLaunch else { return }
        loginQuestion = LoginQuestion(host: launch.host, user: launch.user, problem: problem,
                                       canSave: launch.passwordAccount != nil)
    }
    func answerLogin(user: String, password: String, save: Bool) {
        guard loginQuestion != nil, var launch = lastLaunch else { return }
        loginQuestion = nil
        launch.user = user
        launch.password = password
        lastLaunch = launch
        if save, let account = launch.passwordAccount { keychain.set(password, for: account) }
        connect()
    }
    func cancelLogin() {
        stop()
        phase = .ended("Connection cancelled.")
        onEnded?("Connection cancelled.")
    }
    private func connect() {
        guard let launch = lastLaunch, let open = openSocket else { return }
        attempt += 1
        let current = attempt
        phase = .connecting
        retryMessage = nil
        pendingClipboard = nil
        clipboardFocusState = nil
        engine?.close(); engine = nil
        log?("Connecting to \(launch.host):\(launch.port) over VNC…")
        Task { [weak self] in
            guard let self else { return }
            do {
                let socket = try await open()
                guard current == attempt else { try? socket.close(); return }
                let made = VNCEngineConnection()
                engine = made
                made.onSurface = { [weak self] surface, width, height in
                    guard let self, current == attempt else { return }
                    size = CGSize(width: width, height: height)
                    viewport.pixels = CGSize(width: width, height: height)
                    if resizeTask != nil {
                        resizeTask?.cancel(); resizeTask = nil
                        resizeMessage = "Server desktop: \(width) × \(height)"
                    }
                    view.show(surface)
                }
                made.onChange = { [weak self] in
                    guard let self, current == attempt else { return }
                    view.surfaceChanged()
                }
                made.onCursor = { [weak self] rgba, width, height, hotX, hotY in
                    guard let self, current == attempt else { return }
                    view.showCursor(rgba: rgba, width: width, height: height, hotX: hotX, hotY: hotY)
                }
                made.onConnected = { [weak self] in
                    guard let self, current == attempt else { return }
                    phase = .showing
                    didConnect = true; connectedAt = uptime()
                    onConnected?()
                    startClipboard()
                }
                made.onResizeSupport = { [weak self] supported in
                    guard let self, current == attempt else { return }
                    supportsResize = supported
                }
                made.onCertificate = { [weak self] pem, reply in
                    Task { @MainActor [weak self] in
                        guard let self, current == attempt else { return reply(false) }
                        await check(pem, launch: launch, current: current, reply: reply)
                    }
                }
                made.onClipboard = { [weak self] text, revision in
                    guard let self, current == attempt, launch.options.clipboard, launch.options.receiveClipboard else { return }
                    if revision >= 0, !hasKeyboard() { return }
                    // A fetched Apple archive may arrive after the user copied
                    // something new locally. Preserve that copy and resync.
                    if revision >= 0, pasteboard.changeCount != revision {
                        offerClipboard()
                        updateClipboardFocus()
                        return
                    }
                    pendingClipboard = text
                    if hasKeyboard() { receiveClipboard() }
                }
                made.onDisconnected = { [weak self] reason, code in
                    guard let self, current == attempt else { return }
                    if hasStableConnection { retries = 0; onStableDisconnect?() }
                    connectedAt = nil
                    clipboardWatch?.cancel(); clipboardWatch = nil
                    view.releaseInput()
                    let answer = certificateAnswer
                    certificateAnswer = nil; certificateQuestion = nil
                    answer?(false)
                    engine = nil
                    supportsResize = false
                    view.show(nil)
                    if code == 2 || code == 3 {
                        phase = .connecting
                        askLogin(problem: reason)
                    } else {
                        failed(reason, retry: code == 1)
                    }
                }
                made.connect(launch, socket: socket)
            } catch {
                guard current == attempt else { return }
                let reason = String(describing: error)
                failed(reason, retry: true)
            }
        }
    }

    private func failed(_ reason: String, retry: Bool) {
        guard retry, didConnect, lastLaunch?.options.autoReconnect == true,
              retries < reconnectDelays.count else {
            phase = .ended(reason); onEnded?(reason); return
        }
        let delay = reconnectDelays[retries]
        retries += 1
        retryMessage = "Connection lost. Reconnecting in \(delay) s (\(retries)/\(reconnectDelays.count))…"
        log?(retryMessage!)
        phase = .connecting
        let current = attempt
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, current == attempt else { return }
            reconnectTask = nil
            connect()
        }
    }
    private func check(_ pem: String, launch: VNCLaunch, current: Int,
                       reply: @escaping @Sendable (Bool) -> Void) async {
        guard let certificate = RDPCertificate(pem: pem) else { return reply(false) }
        let known = knownHosts.fingerprint(host: launch.host, port: launch.port)
        if known == certificate.fingerprint { return reply(true) }
        let problem = await certificate.systemDistrust(for: launch.host)
        guard current == attempt else { return reply(false) }
        // A changed pin always asks, even if the new certificate has a valid CA.
        if known == nil, problem == nil { return reply(true) }
        certificateQuestion = .init(host: launch.host, port: launch.port, subject: certificate.subject,
                                    fingerprint: certificate.fingerprint,
                                    problem: problem ?? "The saved certificate differs.", changed: known != nil)
        certificateAnswer = { [weak self] trust in
            if trust { self?.knownHosts.trust(certificate.fingerprint, host: launch.host, port: launch.port) }
            reply(trust)
        }
    }
    func answerCertificate(trust: Bool) {
        let answer = certificateAnswer
        certificateAnswer = nil; certificateQuestion = nil
        answer?(trust)
    }
    func requestResolution(width: Int, height: Int) {
        guard phase == .showing, supportsResize, !viewOnly, width >= 320, height >= 200,
              width <= 8192, height <= 8192, width * height <= 16_777_216 else { return }
        resizeTask?.cancel()
        engine?.resize(width: width, height: height)
        resizeMessage = "Requesting \(width) × \(height)…"
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            resizeMessage = "The server did not change its resolution."
            resizeTask = nil
        }
    }

    var viewOnly: Bool { lastLaunch?.options.viewOnly ?? false }
    func renameAccount(from old: String, to new: String) {
        if lastLaunch?.passwordAccount == old { lastLaunch?.passwordAccount = new }
    }
    func send(_ symbol: UInt32, down: Bool) {
        guard phase == .showing, !viewOnly else { return }
        engine?.key(symbol, down: down)
    }
    func pointer(x: Int, y: Int, buttons: Int) {
        guard phase == .showing, !viewOnly else { return }
        engine?.pointer(x: x, y: y, buttons: buttons)
    }
    func press(_ symbols: [UInt32]) {
        symbols.forEach { send($0, down: true) }
        symbols.reversed().forEach { send($0, down: false) }
    }
    func sendControlAltDelete() { press([0xffe3, 0xffe9, 0xffff]) }
    func sendWindowsKey() { press([0xffeb]) }
    var keyboard: VNCOptions.Keyboard { lastLaunch?.options.keyboard ?? .linux }
    func edit(_ letter: UInt32) { press([keyboard == .macOS ? 0xffeb : 0xffe3, letter]) }
    func redo() {
        if keyboard == .macOS { press([0xffeb, 0xffe1, 0x7a]) }
        else { press([0xffe3, 0x79]) }
    }

    private func startClipboard() {
        guard lastLaunch?.options.clipboard == true else { return }
        seenChange = -1
        offerClipboard()
        updateClipboardFocus()
        clipboardWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                if hasKeyboard() { offerClipboard() }
                updateClipboardFocus()
            }
        }
    }
    func keyboardArrived() {
        if pendingClipboard != nil { receiveClipboard() } else { offerClipboard() }
        updateClipboardFocus()
    }
    func keyboardLeft() {
        view.releaseInput()
        if let launch = lastLaunch, launch.options.clipboard {
            let revision = pasteboard.changeCount
            clipboardFocusState = (false, revision)
            engine?.clipboardFocus(false, revision: revision)
        }
    }
    private func updateClipboardFocus() {
        guard phase == .showing, lastLaunch?.options.clipboard == true else { return }
        let active = hasKeyboard(), revision = pasteboard.changeCount
        if let previous = clipboardFocusState, previous.0 == active, previous.1 == revision { return }
        clipboardFocusState = (active, revision)
        engine?.clipboardFocus(active, revision: revision)
    }
    private func receiveClipboard() {
        guard lastLaunch?.options.clipboard == true, lastLaunch?.options.receiveClipboard == true,
              let text = pendingClipboard else { return }
        pendingClipboard = nil
        // Apple notifications can include an echo of a local copy. Do not
        // rewrite identical text or turn it into a clipboard change loop.
        if pasteboard.string(forType: .string) != text {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        seenChange = pasteboard.changeCount
        updateClipboardFocus()
    }
    func offerClipboard(onPaste: Bool = false) {
        guard phase == .showing, !viewOnly, hasKeyboard(), lastLaunch?.options.clipboard == true,
              lastLaunch?.options.sendClipboard == true,
              onPaste || pasteboard.changeCount != seenChange else { return }
        seenChange = pasteboard.changeCount
        guard RDPDesktop.mayShare(pasteboard.types ?? [], onPaste: onPaste),
              let text = pasteboard.string(forType: .string), text.utf8.count <= 1_048_576 else { return }
        engine?.clipboard(text)
    }
}
