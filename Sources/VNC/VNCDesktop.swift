import AppKit
import IOSurface
import Observation
import OSLog

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
    struct FileCopy: Equatable {
        enum Paste: Equatable { case waiting, sent, cancelled }
        var revision: Int
        var sending: Bool
        var copied: Int64 = 0
        var total: Int64 = 0
        var done = false
        var error: String?
        var paste: Paste?
    }
    private(set) var fileCopy: FileCopy?
    private(set) var supportsFiles = false
    private(set) var linuxFileConnection: String?
    private(set) var linuxFilesReady = false
    @ObservationIgnored private var linuxFiles: VNCLinuxFiles?
    @ObservationIgnored private var linuxTransfer: Task<Void, Never>?
    @ObservationIgnored private var linuxTransferID = 0
    @ObservationIgnored private var linuxSelectionSerial: Int?
    @ObservationIgnored private var linuxCaptureRevision: Int?
    @ObservationIgnored private var linuxCaptureID = 0
    @ObservationIgnored private var pendingFilePaste: Int?
    @ObservationIgnored private var lastPointer: (x: Int, y: Int, buttons: Int)?
    @ObservationIgnored private var filePasteTask: Task<Void, Never>?
    @ObservationIgnored private var filePasteModifier: UInt32?
    @ObservationIgnored private let fileLogger = Logger(subsystem: "com.pavelkhorenyan.Termstead", category: "VNCFiles")
    private func traceFiles(_ event: String) {
        fileLogger.info("\(event, privacy: .public) attempt=\(self.attempt) revision=\(self.pasteboard.changeCount) focused=\(self.hasKeyboard())")
    }
    @ObservationIgnored private var receivedFileURLs: [String] = []
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
    @ObservationIgnored private var remoteCopyRevision: Int?
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
        disconnectLinuxFiles()
        cancelFilePaste()
        attempt += 1
        reconnectTask?.cancel(); reconnectTask = nil
        resizeTask?.cancel(); resizeTask = nil
        retryMessage = nil; supportsResize = false; resizeMessage = nil
        asksScale = false
        fileCopy = nil; supportsFiles = false; pendingFilePaste = nil
        receivedFileURLs = []
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
        remoteCopyRevision = nil
        lastPointer = nil
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
        disconnectLinuxFiles()
        cancelFilePaste()
        attempt += 1
        let current = attempt
        phase = .connecting
        retryMessage = nil
        fileCopy = nil; supportsFiles = false; pendingFilePaste = nil
        pendingClipboard = nil
        remoteCopyRevision = nil
        lastPointer = nil
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
                made.onFileSupport = { [weak self] supported in
                    guard let self, current == attempt else { return }
                    supportsFiles = supported
                }
                made.onServerFiles = { [weak self] urls, revision in
                    guard let self, current == attempt, hasKeyboard(), pasteboard.changeCount == revision,
                          !localFilesAwaitPaste,
                          launch.options.clipboard, launch.options.receiveClipboard,
                          fileCopy?.sending != true || fileCopy?.done == true || fileCopy?.error != nil else { return }
                    if receivedFileURLs == urls, fileCopy?.done == false, fileCopy?.error == nil { return }
                    receivedFileURLs = urls
                    // Do not let a quick Finder paste insert the previous
                    // clipboard while the newly copied files are downloading.
                    pendingClipboard = nil
                    pasteboard.clearContents()
                    seenChange = pasteboard.changeCount
                    fileCopy = FileCopy(revision: seenChange, sending: false)
                    clipboardFocusState = (true, seenChange)
                    engine?.clipboardFocus(true, revision: seenChange, fetch: false)
                    engine?.downloadFiles(urls, revision: seenChange)
                }
                made.onFileProgress = { [weak self] copied, total, revision, sending in
                    guard let self, current == attempt, fileCopy?.revision == revision, fileCopy?.sending == sending else { return }
                    fileCopy?.copied = copied; fileCopy?.total = total
                }
                made.onFilesReady = { [weak self] urls, revision, sending, error in
                    guard let self, current == attempt, fileCopy?.revision == revision, fileCopy?.sending == sending else { return }
                    guard pasteboard.changeCount == revision else { dismissFileCopy(); return }
                    traceFiles(error.isEmpty ? "transport-complete" : "transport-failed")
                    if !error.isEmpty { fileCopy?.error = error; pendingFilePaste = nil; return }
                    fileCopy?.done = true
                    if sending {
                        if pendingFilePaste == revision, hasKeyboard() {
                            pendingFilePaste = nil
                            pasteUploadedFiles(revision: revision)
                        }
                    } else {
                        let local = urls.compactMap(URL.init(string:))
                        guard local.count == urls.count, local.allSatisfy(\.isFileURL) else { return }
                        pasteboard.clearContents()
                        pasteboard.writeObjects(local as [NSURL])
                        seenChange = pasteboard.changeCount
                    }
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
                    guard self?.linuxFiles == nil else { return }
                    guard let self, current == attempt, launch.options.clipboard, launch.options.receiveClipboard,
                          !localFilesAwaitPaste,
                          fileCopy?.sending != true || fileCopy?.done == true || fileCopy?.error != nil else { return }
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
                    disconnectLinuxFiles()
                    if hasStableConnection { retries = 0; onStableDisconnect?() }
                    connectedAt = nil
                    clipboardWatch?.cancel(); clipboardWatch = nil
                    view.releaseInput()
                    let answer = certificateAnswer
                    certificateAnswer = nil; certificateQuestion = nil
                    answer?(false)
                    engine = nil
                    if fileCopy?.done == false { fileCopy?.error = "The connection closed before the files were copied." }
                    pendingFilePaste = nil; supportsFiles = false
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
        lastPointer = (x, y, buttons)
        engine?.pointer(x: x, y: y, buttons: buttons)
    }
    func press(_ symbols: [UInt32]) {
        symbols.forEach { send($0, down: true) }
        symbols.reversed().forEach { send($0, down: false) }
    }
    func sendControlAltDelete() { press([0xffe3, 0xffe9, 0xffff]) }
    func sendWindowsKey() { press([0xffeb]) }
    var keyboard: VNCOptions.Keyboard { lastLaunch?.options.keyboard ?? .linux }
    func edit(_ letter: UInt32) {
        if letter == 0x76 { traceFiles("paste-requested") }
        if letter == 0x63 || letter == 0x78 {
            cancelFilePaste(); pendingFilePaste = nil
            if linuxFiles != nil {
                if linuxTransfer != nil { dismissFileCopy() }
                beginLinuxCapture()
            }
            // Explicit remote Copy/Cut may replace a pending local file copy.
            // Focus changes and unsolicited clipboard notifications may not.
            remoteCopyRevision = pasteboard.changeCount
            pendingClipboard = nil
        }
        if letter == 0x76, offerClipboard(onPaste: true) { return }
        press([keyboard == .macOS ? 0xffeb : 0xffe3, letter])
    }
    func dismissFileCopy() {
        linuxTransferID += 1
        linuxTransfer?.cancel(); linuxTransfer = nil
        cancelFilePaste()
        engine?.cancelFiles(); fileCopy = nil; pendingFilePaste = nil
    }
    private func cancelFilePaste() {
        if fileCopy?.paste == .waiting {
            fileCopy?.paste = .cancelled
            traceFiles("paste-cancelled")
        }
        filePasteTask?.cancel(); filePasteTask = nil
        if let modifier = filePasteModifier { send(modifier, down: false) }
        filePasteModifier = nil
    }
    private func pasteUploadedFiles(revision: Int) {
        // File transport is currently native Apple only. Its destination is
        // always Finder, regardless of the user's general keyboard profile.
        cancelFilePaste()
        fileCopy?.paste = .waiting
        traceFiles("paste-scheduled")
        let current = attempt
        filePasteTask = Task { [weak self] in
            // Allow the native agent's input/clipboard handoff to settle,
            // then refresh pointer state and pace the shortcut.
            // No synthetic mouse click is needed.
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, !Task.isCancelled, current == attempt else { return }
            guard hasKeyboard(), pasteboard.changeCount == revision,
                  phase == .showing, fileCopy?.revision == revision else { cancelFilePaste(); return }
            if let pointer = lastPointer {
                engine?.pointer(x: pointer.x, y: pointer.y, buttons: pointer.buttons)
            }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard !Task.isCancelled, current == attempt else { return }
            guard hasKeyboard(), pasteboard.changeCount == revision,
                  phase == .showing, fileCopy?.revision == revision else { cancelFilePaste(); return }
            filePasteModifier = 0xffeb
            send(0xffeb, down: true)
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard !Task.isCancelled, current == attempt else { return }
            guard hasKeyboard(), pasteboard.changeCount == revision,
                  phase == .showing, fileCopy?.revision == revision else { cancelFilePaste(); return }
            send(0x76, down: true); send(0x76, down: false)
            fileCopy?.paste = .sent
            traceFiles("paste-chord-sent")
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard !Task.isCancelled, current == attempt else { return }
            cancelFilePaste()
        }
    }
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
        updateLinuxFocus()
        if fileCopy != nil { traceFiles("focus-lost") }
        cancelFilePaste()
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
        updateLinuxFocus()
        if let copy = fileCopy, !copy.done, copy.revision != revision { dismissFileCopy() }
        if let previous = clipboardFocusState, previous.0 == active, previous.1 == revision { return }
        clipboardFocusState = (active, revision)
        // Files are sent only on Paste. Fetching the old remote clipboard on
        // focus here would erase the local Finder selection before that paste.
        let files = pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        engine?.clipboardFocus(active, revision: revision, fetch: !files)
    }
    private func receiveClipboard() {
        guard lastLaunch?.options.clipboard == true, lastLaunch?.options.receiveClipboard == true,
              let text = pendingClipboard else { return }
        pendingClipboard = nil
        guard !localFilesAwaitPaste else { return }
        remoteCopyRevision = nil
        // Apple notifications can include an echo of a local copy. Do not
        // rewrite identical text or turn it into a clipboard change loop.
        if pasteboard.string(forType: .string) != text {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        seenChange = pasteboard.changeCount
        updateClipboardFocus()
    }
    private var localFilesAwaitPaste: Bool {
        lastLaunch?.options.sendClipboard == true && !viewOnly &&
        remoteCopyRevision != pasteboard.changeCount &&
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }
    @discardableResult
    func offerClipboard(onPaste: Bool = false) -> Bool {
        guard phase == .showing, !viewOnly, hasKeyboard(), lastLaunch?.options.clipboard == true,
              lastLaunch?.options.sendClipboard == true,
              onPaste || pasteboard.changeCount != seenChange else { return false }
        seenChange = pasteboard.changeCount
        guard RDPDesktop.mayShare(pasteboard.types ?? [], onPaste: onPaste) else { return false }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            // Copying a multi-GB folder must start on an explicit paste, not
            // merely because the user focused a remote desktop.
            guard onPaste else { return false }
            if let linuxFiles {
                uploadLinuxFiles(urls, using: linuxFiles, revision: seenChange)
                return true
            }
            guard supportsFiles else {
                traceFiles("upload-unsupported")
                fileCopy = FileCopy(revision: seenChange, sending: true,
                    error: "This VNC server does not provide file clipboard transfer. For a Linux X11 desktop, open an SSH session as its desktop user, then select it in this tab’s Linux File Clipboard menu.")
                return true
            }
            if fileCopy?.revision != seenChange || fileCopy?.sending != true || fileCopy?.done != false || fileCopy?.error != nil {
                traceFiles("upload-requested")
                fileCopy = FileCopy(revision: seenChange, sending: true)
                engine?.clipboardFocus(true, revision: seenChange, fetch: false)
                engine?.uploadFiles(urls, revision: seenChange)
            }
            pendingFilePaste = seenChange
            return true
        }
        if fileCopy?.revision != seenChange { dismissFileCopy() }
        guard let text = pasteboard.string(forType: .string), text.utf8.count <= 1_048_576 else { return false }
        engine?.clipboard(text)
        return false
    }

    func connectLinuxFiles(client: SFTPClient, title: String) {
        disconnectLinuxFiles()
        guard phase == .showing, !supportsFiles, keyboard == .linux,
              !viewOnly, lastLaunch?.options.clipboard == true else { return }
        let bridge = VNCLinuxFiles(client: client, title: title)
        linuxFiles = bridge; linuxFileConnection = title
        let current = attempt
        bridge.onReady = { [weak self, weak bridge] in
            guard let self, let bridge, current == attempt, linuxFiles === bridge else { return }
            linuxFilesReady = true
            bridge.setActive(hasKeyboard() && lastLaunch?.options.receiveClipboard == true)
        }
        bridge.onError = { [weak self, weak bridge] message in
            guard let self, let bridge, current == attempt, linuxFiles === bridge else { return }
            linuxFilesReady = bridge.isReady
            linuxTransferID += 1
            linuxTransfer?.cancel(); linuxTransfer = nil
            if !bridge.isReady { disconnectLinuxFiles() }
            fileCopy = FileCopy(revision: pasteboard.changeCount, sending: false, error: message)
        }
        bridge.onSelection = { [weak self, weak bridge] selection in
            guard let self, let bridge, current == attempt, linuxFiles === bridge,
                  hasKeyboard() || linuxCaptureRevision == pasteboard.changeCount,
                  !viewOnly, lastLaunch?.options.receiveClipboard == true,
                  !localFilesAwaitPaste, linuxSelectionSerial != selection.serial,
                  linuxTransfer == nil else { return }
            linuxSelectionSerial = selection.serial
            guard !selection.files.isEmpty else { return }
            finishLinuxCapture()
            downloadLinuxFiles(selection, using: bridge)
        }
        bridge.onText = { [weak self, weak bridge] text in
            guard let self, let bridge, current == attempt, linuxFiles === bridge,
                  hasKeyboard() || linuxCaptureRevision == pasteboard.changeCount,
                  lastLaunch?.options.receiveClipboard == true,
                  !localFilesAwaitPaste, linuxTransfer == nil else { return }
            finishLinuxCapture()
            pendingClipboard = text
            receiveClipboard()
        }
        do { try bridge.start() } catch {
            disconnectLinuxFiles()
            fileCopy = FileCopy(revision: pasteboard.changeCount, sending: false, error: error.localizedDescription)
        }
    }
    func disconnectLinuxFiles() {
        guard linuxFiles != nil else { return }
        linuxTransferID += 1
        linuxTransfer?.cancel(); linuxTransfer = nil
        linuxFiles?.close(); linuxFiles = nil
        linuxFileConnection = nil; linuxFilesReady = false; linuxSelectionSerial = nil
        linuxCaptureRevision = nil; linuxCaptureID += 1
        fileCopy = nil
    }
    private func beginLinuxCapture() {
        guard linuxFilesReady, !viewOnly, lastLaunch?.options.receiveClipboard == true else { return }
        linuxCaptureID += 1
        let capture = linuxCaptureID
        linuxCaptureRevision = pasteboard.changeCount
        updateLinuxFocus()
        // An explicit Copy may finish after the user switches to Finder.
        // Keep that one request alive; never monitor background changes after it.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, linuxCaptureID == capture else { return }
            finishLinuxCapture()
        }
    }
    private func finishLinuxCapture() {
        linuxCaptureRevision = nil; linuxCaptureID += 1
        updateLinuxFocus()
    }
    private func updateLinuxFocus() {
        if let revision = linuxCaptureRevision, revision != pasteboard.changeCount {
            linuxCaptureRevision = nil; linuxCaptureID += 1
        }
        linuxFiles?.setActive((hasKeyboard() || linuxCaptureRevision != nil) && !viewOnly &&
                             lastLaunch?.options.receiveClipboard == true)
    }
    private func uploadLinuxFiles(_ urls: [URL], using bridge: VNCLinuxFiles, revision: Int) {
        if linuxTransfer != nil {
            if fileCopy?.revision == revision, fileCopy?.sending == true { return }
            dismissFileCopy()
        }
        let current = attempt
        linuxTransferID += 1
        let transfer = linuxTransferID
        fileCopy = FileCopy(revision: revision, sending: true, paste: .waiting)
        linuxTransfer = Task { [weak self, weak bridge] in
            guard let self, let bridge else { return }
            defer { if transfer == linuxTransferID { linuxTransfer = nil } }
            do {
                try await bridge.upload(urls)
                guard !Task.isCancelled, current == attempt, linuxFiles === bridge,
                      pasteboard.changeCount == revision else { return }
                fileCopy?.done = true
                if hasKeyboard(), fileCopy?.paste == .waiting {
                    press([0xffe3, 0x76])
                    fileCopy?.paste = .sent
                }
            } catch {
                if !Task.isCancelled, current == attempt, linuxFiles === bridge {
                    fileCopy?.error = error.localizedDescription
                }
            }
        }
    }
    private func downloadLinuxFiles(_ selection: VNCLinuxFiles.Selection, using bridge: VNCLinuxFiles) {
        let current = attempt
        linuxTransferID += 1
        let transfer = linuxTransferID
        pendingClipboard = nil
        // Avoid pasting the previous local clipboard before the download ends.
        pasteboard.clearContents(); seenChange = pasteboard.changeCount
        let revision = seenChange
        fileCopy = FileCopy(revision: revision, sending: false, total: selection.total)
        linuxTransfer = Task { [weak self, weak bridge] in
            guard let self, let bridge else { return }
            defer { if transfer == linuxTransferID { linuxTransfer = nil } }
            do {
                let urls = try await bridge.download(selection)
                guard !Task.isCancelled, current == attempt, linuxFiles === bridge,
                      pasteboard.changeCount == revision else {
                    if let first = urls.first {
                        let folder = first.deletingLastPathComponent().deletingLastPathComponent()
                        _ = await BlockingWork.wait { try? FileManager.default.removeItem(at: folder) }
                    }
                    return
                }
                pasteboard.clearContents(); pasteboard.writeObjects(urls as [NSURL])
                seenChange = pasteboard.changeCount
                fileCopy?.copied = selection.total; fileCopy?.done = true
            } catch {
                if !Task.isCancelled, current == attempt, linuxFiles === bridge {
                    fileCopy?.error = error.localizedDescription
                }
            }
        }
    }
}
