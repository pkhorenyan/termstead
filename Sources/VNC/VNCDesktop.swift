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
    @ObservationIgnored let view = VNCDesktopView()
    @ObservationIgnored var keychain = KeychainStore.shared
    @ObservationIgnored var pasteboard: NSPasteboard = .general
    @ObservationIgnored var hasKeyboard: () -> Bool = { false }
    @ObservationIgnored var onEnded: ((String) -> Void)?
    @ObservationIgnored var log: ((String) -> Void)?
    @ObservationIgnored private var engine: VNCEngineConnection?
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var clipboardWatch: Task<Void, Never>?
    @ObservationIgnored private var seenChange = -1
    @ObservationIgnored private var pendingClipboard: String?
    @ObservationIgnored private var openSocket: (@MainActor () async throws -> FileHandle)?
    @ObservationIgnored private(set) var lastLaunch: VNCLaunch?

    init() {
        view.desktop = self
        let view = view
        hasKeyboard = { view.hasKeyboard }
    }
    func start(_ launch: VNCLaunch, socket: @escaping @MainActor () async throws -> FileHandle) {
        stop()
        lastLaunch = launch
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
        clipboardWatch?.cancel(); clipboardWatch = nil
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
                    view.show(surface)
                }
                made.onChange = { [weak self] in
                    guard let self, current == attempt else { return }
                    view.surfaceChanged()
                }
                made.onConnected = { [weak self] in
                    guard let self, current == attempt else { return }
                    phase = .showing
                    startClipboard()
                }
                made.onClipboard = { [weak self] text in
                    guard let self, current == attempt, launch.options.clipboard else { return }
                    pendingClipboard = text
                    if hasKeyboard() { receiveClipboard() }
                }
                made.onDisconnected = { [weak self] reason, code in
                    guard let self, current == attempt else { return }
                    clipboardWatch?.cancel(); clipboardWatch = nil
                    engine = nil
                    view.show(nil)
                    if code == 2 || code == 3 {
                        phase = .connecting
                        askLogin(problem: reason)
                    } else {
                        phase = .ended(reason)
                        onEnded?(reason)
                    }
                }
                made.connect(launch, socket: socket)
            } catch {
                guard current == attempt else { return }
                let reason = String(describing: error)
                phase = .ended(reason)
                onEnded?(reason)
            }
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

    private func startClipboard() {
        guard lastLaunch?.options.clipboard == true else { return }
        seenChange = -1
        clipboardWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                if hasKeyboard() { offerClipboard() }
            }
        }
    }
    func keyboardArrived() {
        if pendingClipboard != nil { receiveClipboard() } else { offerClipboard() }
    }
    func keyboardLeft() { view.releaseInput() }
    private func receiveClipboard() {
        guard lastLaunch?.options.clipboard == true, let text = pendingClipboard else { return }
        pendingClipboard = nil
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        seenChange = pasteboard.changeCount
    }
    func offerClipboard(onPaste: Bool = false) {
        guard phase == .showing, !viewOnly, hasKeyboard(), lastLaunch?.options.clipboard == true,
              onPaste || pasteboard.changeCount != seenChange else { return }
        seenChange = pasteboard.changeCount
        guard RDPDesktop.mayShare(pasteboard.types ?? [], onPaste: onPaste),
              let text = pasteboard.string(forType: .string), text.utf8.count <= 1_048_576 else { return }
        engine?.clipboard(text)
    }
}
