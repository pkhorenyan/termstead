import AppKit
import Observation
import SwiftTerm

/// One tab: an ssh process in a pseudo-terminal, and the terminal view drawing it.
///
/// The view is created once and kept for the life of the tab. SwiftUI shows
/// whichever connection is active by handing this same view back, so switching
/// tabs never loses scrollback or restarts anything.
@MainActor
@Observable
final class Connection: Identifiable {
    enum State: Equatable {
        /// The ssh process is alive. That is all it means: authentication may
        /// still be in progress, and a password prompt counts as running.
        case running
        case exited(code: Int32?)
        /// ssh was never started, for example because the session's settings
        /// cannot be turned into a valid config.
        case failed(String)

        var isRunning: Bool { self == .running }
    }

    let id = UUID()
    /// The saved session this tab belongs to; `nil` for a quick connection.
    var sessionID: String?
    var title: String
    /// `user@host:port`, as the status bar shows it.
    var address: String
    var keyDescription: String
    private(set) var state: State = .running
    private(set) var columns = 0
    private(set) var rows = 0
    /// This tab's own text size, from ⌘+ / ⌘−. `nil` follows Settings, so a
    /// tab that was never zoomed picks up a size changed there.
    var fontSize: Int?
    /// The pane the tab is in — see `ConnectionStore.layout`.
    var pane = 0
    /// The server's CPU, memory, disk and network for the status bar. Kept
    /// while the tab is in the background, so it shows at once on return;
    /// cleared when ssh ends.
    private(set) var serverLoad: ServerLoad?
    /// Set for the tab in front while Settings asks for server load — see
    /// `ConnectionStore.watchesServerLoad`. The watch itself runs only once
    /// ssh has logged in.
    var watchesLoad = false {
        didSet { if watchesLoad != oldValue { updateLoadWatch() } }
    }
    /// The server has no /proc to read; asking again would not change that.
    @ObservationIgnored private(set) var loadIsUnsupported = false
    @ObservationIgnored private var loadWatch: ServerLoadWatch?
    /// ssh has logged in to the target (see `watchForLogin`).
    private(set) var isLoggedIn = false

    @ObservationIgnored let terminalView: SSHTerminalView
    @ObservationIgnored private var relay: ProcessRelay?
    @ObservationIgnored private var workDirectory: URL?
    @ObservationIgnored private var askpass: AskpassServer?
    @ObservationIgnored private let keychain: KeychainStore
    @ObservationIgnored private var exitWatch: (any DispatchSourceProcess)?
    @ObservationIgnored private var loginWatch: (any DispatchSourceFileSystemObject)?
    /// Called each time ssh has logged in to the target — see `watchForLogin`.
    @ObservationIgnored var onLogin: (@MainActor () -> Void)?
    @ObservationIgnored private var plan: SSHLaunchPlan?
    @ObservationIgnored private var didClose = false

    /// A session's tunnels are opened by one of its tabs at a time: a second
    /// ssh asking for the same ports gets "Address already in use" for each.
    /// This tab's ssh has them open (or is asking its master for them).
    private(set) var holdsForwards = false
    /// Whether this tab may open the tunnels: no other tab of its session
    /// holds them. Asked by `ConnectionStore`, which sees every tab.
    @ObservationIgnored var mayForward: (Connection) -> Bool = { _ in true }
    /// Tunnels the user stopped. They stay down when another tab takes over.
    @ObservationIgnored var isForwardStopped: (UUID) -> Bool = { _ in false }
    /// Told when this tab stops holding the tunnels, so another can take them.
    @ObservationIgnored var onForwardsReleased: (() -> Void)?

    init(sessionID: String?, title: String, address: String, keyDescription: String,
         keychain: KeychainStore = .shared) {
        self.keychain = keychain
        self.sessionID = sessionID
        self.title = title
        self.address = address
        self.keyDescription = keyDescription
        terminalView = SSHTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        terminalView.optionAsMetaKey = true
        let relay = ProcessRelay(owner: self)
        self.relay = relay
        terminalView.processDelegate = relay
        terminalView.onInputWhileStopped = { [weak self] data in
            // Return on a closed tab reconnects, as the closing line says.
            if data.contains(13) { self?.restart() }
        }
        terminalView.onReturnWhileRunning = { [weak self] in
            // A `cd` takes effect on Return; the Files tab may want to follow.
            self?.browser?.terminalMayHaveMoved()
        }
        terminalView.onUserInput = { [weak self] data in self?.onInput?(data) }
    }

    /// Typed or pasted into this tab — see `ConnectionStore.broadcast`.
    @ObservationIgnored var onInput: ((ArraySlice<UInt8>) -> Void)?

    /// Starts ssh with `plan`, or restarts it after it exited.
    func start(_ plan: SSHLaunchPlan) {
        guard !didClose else { return }
        self.plan = plan
        isLoggedIn = false
        stopLoadWatch()
        serverLoad = nil
        removeWorkDirectory()

        // `plan` keeps the tunnels, so a tab started without them can still
        // take them over later (`takeOverForwards`).
        var launched = plan
        holdsForwards = !plan.forwards.isEmpty && mayForward(self)
        launched.forwards = holdsForwards ? plan.forwards.filter { !isForwardStopped($0.id) } : []
        if !plan.forwards.isEmpty && !holdsForwards {
            terminalView.feed(text: "\u{1b}[2mPort forwarding is open in another tab of this session; this tab takes it over if that one closes.\u{1b}[0m\r\n")
        }

        do {
            let directory = try Self.makeWorkDirectory()
            workDirectory = directory
            let configURL = directory.appendingPathComponent("ssh_config")
            try Self.writePrivate(plan.config, to: configURL)

            // The helper is only brought in when there is something stored to
            // give it; otherwise ssh prompts exactly as it always would.
            var extra: [String: String] = [:]
            if AskpassServer.hasStoredSecrets(for: plan, keychain: keychain),
               let server = AskpassServer(directory: directory, matcher: AskpassMatcher(plan: plan),
                                          keychain: keychain) {
                askpass = server
                extra = server.environment
            }

            state = .running
            let control = directory.appendingPathComponent("cm").path
            terminalView.startProcess(executable: SSHLaunch.executable,
                                      args: launched.arguments(configPath: configURL.path, controlPath: control),
                                      environment: Self.environment(extra: extra),
                                      execName: "ssh")
            watchForExit(of: terminalView.process.shellPid)
            watchForLogin(controlPath: control, in: directory)
        } catch {
            fail("Could not prepare the connection: \(error.localizedDescription)")
        }
    }

    /// How the Files panel reaches this tab's server: `sftp` over the
    /// terminal's own connection. `nil` while ssh is not running.
    var sftp: SFTPClient? {
        guard state.isRunning, let workDirectory, let plan else { return nil }
        return SFTPClient(configPath: workDirectory.appendingPathComponent("ssh_config").path,
                          controlPath: workDirectory.appendingPathComponent("cm").path,
                          alias: plan.target.alias)
    }

    /// The tab's file browser, made the first time the Files panel shows it.
    @ObservationIgnored private var browser: FileBrowser?
    var fileBrowser: FileBrowser {
        if let browser { return browser }
        let made = FileBrowser(connection: self)
        browser = made
        return made
    }

    func restart() {
        guard let plan, !state.isRunning else { return }
        // The old output stays above, the way a terminal keeps a finished
        // command's: it is often what the user needs to read.
        terminalView.feed(text: "\r\n")
        start(plan)
    }

    /// Ends the process and cleans up; the tab is going away.
    func close() {
        didClose = true
        stopLoadWatch()
        browser?.stop()
        exitWatch?.cancel()
        exitWatch = nil
        let pid = terminalView.process.shellPid
        if state.isRunning { terminalView.terminate() }
        removeWorkDirectory()
        releaseForwards(afterExitOf: state.isRunning ? pid : 0)
    }

    /// The ports stay bound until ssh has actually gone, a moment after the
    /// hang-up; another tab asking for them sooner is refused.
    private func releaseForwards(afterExitOf pid: pid_t) {
        guard holdsForwards, pid > 0 else { return releaseForwards() }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        // The source holds the tab until it fires; cancelling breaks the cycle.
        source.setEventHandler {
            MainActor.assumeIsolated {
                source.cancel()
                self.releaseForwards()
            }
        }
        exitWatch = source
        source.resume()
        // Gone before the watch began.
        if kill(pid, 0) != 0 {
            source.cancel()
            releaseForwards()
        }
    }

    func fail(_ message: String) {
        state = .failed(message)
        terminalView.feed(text: "\r\n\u{1b}[31m\(message)\u{1b}[0m\r\n")
    }

    /// SwiftTerm 1.11 cannot be relied on to say that ssh ended: when the
    /// terminal reaches end-of-file before its exit monitor fires, it cancels
    /// the monitor and — the call is commented out in `LocalProcess` — never
    /// reports the exit, leaving the tab "connected" for good. It happened in
    /// about one run in three. So the process is watched here as well; whichever
    /// notices first wins, and `processEnded` ignores the second.
    private func watchForExit(of pid: pid_t) {
        exitWatch?.cancel()
        guard pid > 0 else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            var status: Int32 = 0
            // -1 (ECHILD) when SwiftTerm reaped it first; its report then wins.
            let reaped = waitpid(pid, &status, WNOHANG) == pid
            MainActor.assumeIsolated {
                self?.processEnded(exitCode: reaped ? Self.exitCode(fromWaitStatus: status) : nil)
            }
        }
        exitWatch = source
        source.resume()
    }

    /// ssh opens its connection-sharing socket only once it is logged in to
    /// the target, through every jump host — after any host-key question,
    /// password or passphrase, and never for a refused login. So the socket
    /// appearing is the moment of login. The work directory is watched
    /// rather than polled: nothing runs while a password prompt waits.
    private func watchForLogin(controlPath: String, in directory: URL) {
        loginWatch?.cancel()
        let descriptor = Darwin.open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            guard FileManager.default.fileExists(atPath: controlPath) else { return }
            MainActor.assumeIsolated { self?.loggedIn() }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        loginWatch = source
        source.resume()
        // In case ssh was quicker than the watch.
        if FileManager.default.fileExists(atPath: controlPath) { loggedIn() }
    }

    private func loggedIn() {
        guard loginWatch != nil else { return }
        loginWatch?.cancel()
        loginWatch = nil
        isLoggedIn = true
        onLogin?()
        updateLoadWatch()
        // The tab that held them may have closed while this one logged in.
        takeOverForwards()
    }

    /// Opens the session's tunnels over this tab's running connection, with
    /// `ssh -O forward` to its master — no new login, and the shell carries on.
    func takeOverForwards() {
        guard !didClose, isLoggedIn, state.isRunning, !holdsForwards,
              let plan, !plan.forwards.isEmpty, mayForward(self) else { return }
        // Claimed at once: two tabs must not both ask while the first answer
        // is on its way.
        holdsForwards = true
        let running = plan.forwards.filter { !isForwardStopped($0.id) }
        guard !running.isEmpty else { return }
        multiplex("forward", running.flatMap(\.arguments)) { [weak self] problem in
            guard let self, let problem, holdsForwards else { return }
            holdsForwards = false
            terminalView.feed(text: "\r\n\u{1b}[31mCould not take over port forwarding: \(problem)\u{1b}[0m\r\n")
        }
    }

    /// Stops one of the tunnels this tab holds (`ssh -O cancel`), or opens it
    /// again. `done` gets ssh's complaint, or `nil` once it is done.
    func setForward(_ id: UUID, running: Bool, done: @escaping @MainActor (String?) -> Void) {
        guard holdsForwards, isLoggedIn, state.isRunning else { return done("The session is not connected.") }
        guard let forward = plan?.forwards.first(where: { $0.id == id }) else {
            return done("Added after the session connected: reconnect to open it.")
        }
        multiplex(running ? "forward" : "cancel", forward.arguments, done: done)
    }

    /// The tunnel was in the settings this tab connected with.
    func carriesForward(_ id: UUID) -> Bool {
        plan?.forwards.contains { $0.id == id } ?? false
    }

    /// Runs `ssh -O <operation>` against this tab's connection master.
    private func multiplex(_ operation: String, _ arguments: [String],
                           done: @escaping @MainActor (String?) -> Void) {
        guard let client = sftp else { return done("The session is not connected.") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: SSHLaunch.executable)
        process.arguments = ["-F", client.configPath, "-o", "ControlPath=\(client.controlPath)",
                             "-O", operation] + arguments + [client.alias]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        process.terminationHandler = { finished in
            let succeeded = finished.terminationStatus == 0
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { done(succeeded ? nil : message) }
            }
        }
        do { try process.run() } catch { done(error.localizedDescription) }
    }

    private func releaseForwards() {
        guard holdsForwards else { return }
        holdsForwards = false
        onForwardsReleased?()
    }

    /// Starts or stops reading the server's load to match `watchesLoad`. It
    /// rides the connection master, so it needs ssh logged in.
    private func updateLoadWatch() {
        guard watchesLoad, isLoggedIn, state.isRunning, !loadIsUnsupported, let client = sftp else {
            stopLoadWatch()
            return
        }
        guard loadWatch == nil else { return }
        let watch = ServerLoadWatch(
            onLoad: { [weak self] load in
                guard let self else { return }
                serverLoad = load.filling(from: serverLoad)
            },
            onUnsupported: { [weak self] in
                self?.loadIsUnsupported = true
                self?.stopLoadWatch()
            })
        loadWatch = watch
        watch.start(arguments: client.shellArguments(ServerLoadScript.text))
    }

    private func stopLoadWatch() {
        loadWatch?.stop()
        loadWatch = nil
    }

    /// The code a shell would report: the exit status, or 128 + the signal.
    nonisolated static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    fileprivate func processEnded(exitCode: Int32?) {
        guard state.isRunning else { return }
        exitWatch?.cancel()
        exitWatch = nil
        state = .exited(code: exitCode)
        isLoggedIn = false
        releaseForwards()
        stopLoadWatch()
        serverLoad = nil
        removeWorkDirectory()
        let detail = exitCode.map { " (exit code \($0))" } ?? ""
        terminalView.feed(text: "\r\n\u{1b}[2mConnection closed\(detail). Press Return to reconnect.\u{1b}[0m\r\n")
    }

    fileprivate func sizeChanged(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    // MARK: - Files and environment

    /// Short on purpose: the askpass socket lives in here, and a Unix socket's
    /// path must fit in 104 bytes.
    private static func makeWorkDirectory() throws -> URL {
        let name = "sb-" + UUID().uuidString.prefix(8).lowercased()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }

    /// ssh refuses a config file that others can write to, and this one names
    /// keys, so it is created readable by the owner alone.
    private static func writePrivate(_ text: String, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func removeWorkDirectory() {
        loginWatch?.cancel()
        loginWatch = nil
        askpass?.stop()
        askpass = nil
        guard let workDirectory else { return }
        try? FileManager.default.removeItem(at: workDirectory)
        self.workDirectory = nil
    }

    /// The app's own environment — which is where `SSH_AUTH_SOCK` comes from,
    /// and without it the agent is invisible — with the terminal's settings on top.
    static func environment(extra: [String: String]) -> [String] {
        var values = ProcessInfo.processInfo.environment
        values["TERM"] = "xterm-256color"
        values["COLORTERM"] = "truecolor"
        if values["LANG"] == nil { values["LANG"] = "en_US.UTF-8" }
        for (key, value) in extra { values[key] = value }
        return values.map { "\($0.key)=\($0.value)" }.sorted()
    }
}

/// SwiftTerm's view, told what to do with keystrokes once ssh has gone: they
/// would otherwise be written into a closed pseudo-terminal and vanish.
final class SSHTerminalView: LocalProcessTerminalView {
    var onInputWhileStopped: ((ArraySlice<UInt8>) -> Void)?
    /// Theme and font last applied, so `TerminalStyle` repaints only on change.
    var appliedStyle: String?
    /// Copy a selection to the clipboard as soon as it is made.
    var copyOnSelect = true
    /// Where copy-on-select writes. A test swaps in a private pasteboard so
    /// that running the suite does not overwrite the user's clipboard.
    var copyPasteboard: NSPasteboard = .general
    private var pendingCopy: Task<Void, Never>?

    var rightClickPastes = false
    var confirmMultilinePaste = true
    var bellMode: ThemeStore.BellMode = .sound

    /// Set while a find moves the selection. A match is shown as a selection,
    /// and with no mouse button down copy-on-select would put every match on
    /// the clipboard.
    private var isFinding = false

    /// Selects the next match of `term` and scrolls to it. `upward` searches
    /// toward older output. Returns whether anything matched.
    @discardableResult
    func find(_ term: String, upward: Bool, caseSensitive: Bool) -> Bool {
        guard !term.isEmpty else { return false }
        isFinding = true
        defer { isFinding = false }
        // Before the search moves the selection, so the redraw it asks for
        // already uses the match's colors.
        showsMatch = true
        let options = SearchOptions(caseSensitive: caseSensitive)
        return upward ? findPrevious(term, options: options) : findNext(term, options: options)
    }

    /// Drops the match highlight and the search position.
    func endFind() {
        isFinding = true
        defer { isFinding = false }
        clearSearch()
        showsMatch = false
    }

    struct SelectionStyle {
        var fill: NSColor
        /// `nil` keeps each cell's own text color.
        var text: NSColor?
    }

    /// Set by `TerminalStyle`. SwiftTerm shows a find match as the selection,
    /// so the view switches between the two as the selection changes hands:
    /// a match is a solid fill with its own text color, a selection made with
    /// the mouse keeps the translucent one.
    var selectionStyle = SelectionStyle(fill: .selectedTextBackgroundColor) {
        didSet { applySelectionStyle() }
    }
    var matchStyle = SelectionStyle(fill: .findHighlightColor, text: .black) {
        didSet { applySelectionStyle() }
    }
    /// Whether the selection on screen is a find match.
    private(set) var showsMatch = false {
        didSet { if showsMatch != oldValue { applySelectionStyle() } }
    }

    private func applySelectionStyle() {
        let style = showsMatch ? matchStyle : selectionStyle
        selectedTextBackgroundColor = style.fill
        selectedTextForegroundColor = style.text
        needsDisplay = true
    }

    /// History kept above the screen. Shrinking it drops the oldest lines.
    var scrollbackLines: Int {
        get { getTerminal().options.scrollback }
        set {
            guard newValue != getTerminal().options.scrollback else { return }
            getTerminal().changeHistorySize(newValue)
        }
    }

    /// Keyword highlighting; changing it repaints what is on screen.
    var highlightMode: KeywordHighlighter.Mode = .off {
        didSet {
            guard highlightMode != oldValue else { return }
            // Other rules: what was scanned before says nothing now.
            painter.forget()
            scheduleHighlight()
        }
    }
    private let painter = HighlightPainter()
    private var highlightScheduled = false

    /// New output is highlighted in passes at most every 30 ms: `cat` of a big
    /// file arrives in hundreds of chunks, and one pass over the screen per
    /// chunk would be wasted work on text already scrolled past.
    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        scheduleHighlight()
    }

    private func scheduleHighlight() {
        guard highlightMode != .off, !highlightScheduled else { return }
        highlightScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            MainActor.assumeIsolated { self?.highlightNow() }
        }
    }

    /// One pass over the visible rows. Public for tests.
    func highlightNow() {
        highlightScheduled = false
        let rules = KeywordHighlighter.rules(for: highlightMode)
        // Only the rows it recoloured; the whole view was redrawn before.
        if let rows = painter.paint(getTerminal(), rules: rules) { setNeedsDisplay(rows: rows) }
    }
    /// What "Sound" plays. A test swaps it to count rings instead of beeping.
    var playBell: () -> Void = { NSSound.beep() }
    private var lastBell: Date = .distantPast
    private var flashLayer: CALayer?

    /// A held Tab or a script can ring dozens of times a second; one ring per
    /// burst is the signal, the rest is noise.
    static let bellGap: TimeInterval = 0.1

    override func bell(source: Terminal) {
        let now = Date()
        guard bellMode != .off, now.timeIntervalSince(lastBell) >= Self.bellGap else { return }
        lastBell = now
        switch bellMode {
        case .sound: playBell()
        case .flash: flash()
        case .off: break
        }
    }

    /// A quick wash of the text colour over the terminal, fading out.
    private func flash() {
        wantsLayer = true
        guard let host = layer else { return }
        let overlay = flashLayer ?? {
            let made = CALayer()
            made.opacity = 0
            host.addSublayer(made)
            flashLayer = made
            return made
        }()
        overlay.frame = host.bounds
        overlay.backgroundColor = nativeForegroundColor.withAlphaComponent(0.18).cgColor
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.25
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        overlay.add(fade, forKey: "bell")
    }

    /// The flash's layer, for tests.
    var bellFlashLayer: CALayer? { flashLayer }
    /// "Don't ask again" in the paste confirmation turns the setting off.
    var onStopConfirmingPaste: (() -> Void)?
    private var appliedCursor: CursorStyle?

    /// Shape and blink, applied only when they change. A program can still set
    /// its own shape while it runs — vim does — as in any terminal.
    func applyCursor(shape: ThemeStore.CursorShape, blinks: Bool) {
        let style = Self.cursorStyle(shape: shape, blinks: blinks)
        guard appliedCursor != style else { return }
        appliedCursor = style
        getTerminal().setCursorStyle(style)
    }

    static func cursorStyle(shape: ThemeStore.CursorShape, blinks: Bool) -> CursorStyle {
        switch (shape, blinks) {
        case (.block, true): .blinkBlock
        case (.block, false): .steadyBlock
        case (.underline, true): .blinkUnderline
        case (.underline, false): .steadyUnderline
        case (.bar, true): .blinkBar
        case (.bar, false): .steadyBar
        }
    }

    /// With "Paste" chosen, a plain right-click pastes; ⌃ or ⇧ with it still
    /// opens the menu, so Copy and Select All stay reachable.
    static func rightClickPastes(modifiers: NSEvent.ModifierFlags, setting: Bool) -> Bool {
        setting && modifiers.intersection([.control, .shift]).isEmpty
    }

    override func rightMouseDown(with event: NSEvent) {
        if Self.rightClickPastes(modifiers: event.modifierFlags, setting: rightClickPastes) {
            paste(self)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    /// More than one line — one line that ends in a newline is still one line,
    /// just copied whole.
    static func needsPasteConfirmation(for text: String) -> Bool {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmed = normalized.hasSuffix("\n") ? String(normalized.dropLast()) : normalized
        return trimmed.contains("\n")
    }

    /// ⌘V, the menu's Paste and a right-click paste all arrive here. Several
    /// lines ask first, as a sheet on the window — each line would otherwise
    /// run as a command the moment it lands.
    override func paste(_ sender: Any) {
        guard confirmMultilinePaste,
              let text = NSPasteboard.general.string(forType: .string),
              Self.needsPasteConfirmation(for: text),
              let window else {
            pasteWithoutAsking(sender)
            return
        }
        let lines = text.split(whereSeparator: \.isNewline)
        let alert = NSAlert()
        alert.messageText = "Paste \(lines.count) lines?"
        let preview = lines.prefix(4).joined(separator: "\n")
        alert.informativeText = preview + (lines.count > 4 ? "\n…" : "")
            + "\n\nEach line may run as a command as soon as it is pasted."
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                if alert.suppressionButton?.state == .on { self.onStopConfirmingPaste?() }
                if response == .alertFirstButtonReturn { self.pasteWithoutAsking(sender) }
            }
        }
    }

    private func pasteWithoutAsking(_ sender: Any) {
        isPasting = true
        defer { isPasting = false }
        super.paste(sender)
    }

    /// Right-click: Copy, Paste, Select All — whether or not copy-on-select is
    /// on, as in Terminal and iTerm. Paste is the part copy-on-select never
    /// covered. SwiftTerm leaves right-clicks to NSView, which asks for this.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let copy = NSMenuItem(title: "Copy", action: #selector(menuCopy), keyEquivalent: "c")
        copy.isEnabled = selectionActive
        let paste = NSMenuItem(title: "Paste", action: #selector(menuPaste), keyEquivalent: "v")
        paste.isEnabled = NSPasteboard.general.string(forType: .string) != nil
        let all = NSMenuItem(title: "Select All", action: #selector(menuSelectAll), keyEquivalent: "a")
        for item in [copy, paste, all] {
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func menuCopy() { copy(self) }
    @objc private func menuPaste() { paste(self) }
    @objc private func menuSelectAll() { selectAll(nil) }

    /// Copies once the mouse lets go, not on every step of the drag that makes
    /// the selection: each copy would land in a clipboard manager's history.
    /// SwiftTerm's `mouseUp` is `public`, not `open`, so it cannot be
    /// overridden here — the button state is polled instead, briefly.
    override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        if !isFinding { showsMatch = false }
        guard copyOnSelect, selectionActive, !isFinding else { return }
        pendingCopy?.cancel()
        pendingCopy = Task { @MainActor [weak self] in
            for _ in 0..<600 where NSEvent.pressedMouseButtons & 1 != 0 {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
            }
            guard let self, !Task.isCancelled, self.selectionActive,
                  let text = self.getSelection(), !text.isEmpty else { return }
            self.copyPasteboard.clearContents()
            self.copyPasteboard.setString(text, forType: .string)
        }
    }

    /// Return was sent to a live shell — see `FileBrowser.terminalMayHaveMoved`.
    var onReturnWhileRunning: (() -> Void)?
    /// What the user typed or pasted, for broadcast input
    /// (`ConnectionStore.broadcast`). Never the terminal's own replies.
    var onUserInput: ((ArraySlice<UInt8>) -> Void)?

    /// The terminal answering the program — a cursor position, colours,
    /// focus in and out — comes through `send(source: TerminalView, …)`
    /// like typing does. Those answers belong to this terminal's state
    /// alone, so they are marked here and never broadcast.
    private var isReplying = false
    private var isPasting = false
    /// The event being handled; replaceable so a test can hand it one.
    var eventInProgress: () -> NSEvent? = { NSApp.currentEvent }

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        isReplying = true
        defer { isReplying = false }
        super.send(source: source, data: data)
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if process.running {
            super.send(source: source, data: data)
            if data.contains(13) { onReturnWhileRunning?() }
            if isUserInput { onUserInput?(data) }
        } else {
            onInputWhileStopped?(data)
        }
    }

    /// Typed or pasted: not a reply, and not a mouse report — a click or the
    /// wheel in vim or htop is sent too, and means nothing to another pane.
    private var isUserInput: Bool {
        if isReplying { return false }
        if isPasting { return true }
        switch eventInProgress()?.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp,
             .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel:
            return false
        default:
            return true
        }
    }

    /// Input broadcast from another pane: straight to the program, as if typed
    /// here, without being broadcast again.
    func receiveBroadcast(_ data: ArraySlice<UInt8>) {
        guard process.running else { return }
        process.send(data: data)
        if data.contains(13) { onReturnWhileRunning?() }
    }
}

/// Receives SwiftTerm's process callbacks. SwiftTerm is built in Swift 5 mode
/// and its delegate protocol is not actor-isolated; it delivers on the main
/// queue (the `LocalProcess` default), which is what `assumeIsolated` relies on.
private final class ProcessRelay: LocalProcessTerminalViewDelegate {
    weak var owner: Connection?

    init(owner: Connection) { self.owner = owner }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        let owner = owner
        MainActor.assumeIsolated { owner?.sizeChanged(columns: newCols, rows: newRows) }
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // SwiftTerm hands over the raw `waitpid` status, not the exit code.
        let owner = owner
        let code = exitCode.map(Connection.exitCode(fromWaitStatus:))
        MainActor.assumeIsolated { owner?.processEnded(exitCode: code) }
    }
}
