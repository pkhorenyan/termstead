import AppKit
import Foundation
import IOSurface
import SwiftUI
import Testing
@testable import Termstead

@MainActor
struct VNCSessionTests {
    private func session() -> Session {
        var session = Session(id: "vnc", user: "", host: "desktop.example", port: 5900,
                              icon: .monitor, auth: .password)
        session.kind = .vnc
        session.vnc.viewOnly = true
        session.vnc.clipboard = false
        session.vnc.zoom = 175
        session.vnc.keyboard = .macOS
        session.vnc.quality = .fast
        session.vnc.security = .tls
        session.vnc.sendClipboard = false
        session.vnc.receiveClipboard = false
        session.vnc.autoReconnect = false
        return session
    }
    @Test func optionsAndCredentialsRoundTripThroughEncryptedExport() throws {
        let source = SessionStore(tree: [], sessions: [:], selectedID: nil, pinnedIDs: [])
        source.createSession(session(), parentID: nil)
        let snapshot = source.snapshot
        let id = try #require(source.session("vnc")?.persistentID)
        let document = try SessionArchive.document(snapshot, credentials: [.init(sessionID: id, role: "password", value: "vnc-secret")])
        let encoded = try SessionArchive.encode(document, password: "archive-secret")
        let contents = try SessionArchive.decode(encoded, password: "archive-secret")
        let plan = try SessionTransfer.plan(contents, into: .empty, conflict: .keepBoth)
        let restored = try #require(plan.snapshot.sessions.first)
        #expect(restored.kind == .vnc)
        #expect(restored.vnc == session().vnc)
        #expect(plan.secrets.first?.value == "vnc-secret")
        #expect(plan.secrets.first?.account == SSHLaunch.sessionPasswordAccount(restored.id))
    }
    @Test func missingVNCOptionsTakeSafeDefaults() throws {
        let options = try JSONDecoder().decode(VNCOptions.self, from: Data("{}".utf8))
        #expect(options.clipboard)
        #expect(!options.allowNoAuth && !options.viewOnly)
        #expect(!SessionKind.vnc.hasTerminal)
        #expect(SessionKind.vnc.defaultPort == 5900)
        #expect(session().address == "desktop.example:5900")
    }
    @Test func vncIsNotAnSSHJumpHost() {
        let hop = session()
        let target = Session(id: "ssh", user: "u", host: "h", port: 22, icon: .server, jumps: [JumpHost(host: hop.id)])
        #expect(throws: SSHLaunchError.notSSH(hop.id)) {
            try SSHLaunch.plan(for: target, sessions: [hop.id: hop], keyExists: { _ in true })
        }
    }
    @Test func vncTabAsksForPasswordAndDoesNotAcceptSnippets() throws {
        let store = SessionStore(tree: [], sessions: [:], selectedID: nil, pinnedIDs: [])
        store.createSession(session(), parentID: nil)
        let tabs = ConnectionStore()
        // Start explicitly, so this test never reads the user's Keychain.
        let tab = Connection(sessionID: "vnc", title: "vnc", address: "", keyDescription: "VNC", kind: .vnc)
        tabs.add(tab)
        tab.start(VNCLaunch(session: session(), password: ""))
        let desktop = try #require(tab.vnc)
        #expect(desktop.loginQuestion != nil)
        #expect(tab.desktop == nil && tabs.snippetTarget == nil)
        #expect(tab.plan == nil)
        tab.renameSessionAccount(from: "vnc", to: "renamed")
        #expect(desktop.lastLaunch?.passwordAccount == SSHLaunch.sessionPasswordAccount("renamed"))
        tabs.closeAll()
        #expect(desktop.loginQuestion == nil && desktop.phase == .ended(""))
    }
    @Test func keyboardMapsUnicodeAndSpecialKeys() {
        #expect(VNCKeyboard.symbol(keyCode: 0, characters: "a") == 0x61)
        #expect(VNCKeyboard.symbol(keyCode: 0, characters: "ф") == 0x0100_0444)
        #expect(VNCKeyboard.symbol(keyCode: 0, characters: "🙂") == 0x0101_f642)
        #expect(VNCKeyboard.symbol(keyCode: 123, characters: nil) == 0xff51)
        #expect(VNCKeyboard.symbol(keyCode: 36, characters: "\r") == 0xff0d)
        #expect(VNCKeyboard.symbol(keyCode: 0, characters: "\u{01}") == nil)
    }
    @Test func theCursorIsLocalScalesWithTheDesktopAndResetsOnDisconnect() throws {
        let view = VNCDesktopView(frame: NSRect(x: 0, y: 0, width: 100, height: 50))
        let surface = try #require(IOSurface(properties: [.width: 200, .height: 100, .bytesPerElement: 4]))
        view.show(surface)
        #expect(view.cursor === NSCursor.arrow)
        let pixels = Data(repeating: 255, count: 8 * 8 * 4)
        view.showCursor(rgba: pixels, width: 8, height: 8, hotX: 4, hotY: 2)
        let cursor = view.cursor
        #expect(cursor.image.size == CGSize(width: 4, height: 4))
        #expect(cursor.hotSpot == CGPoint(x: 2, y: 1))
        // No connection or server response is involved in choosing the
        // hardware cursor; it remains cached between mouse moves.
        #expect(view.cursor === cursor)
        view.setFrameSize(CGSize(width: 200, height: 100))
        #expect(view.cursor.image.size == CGSize(width: 8, height: 8))
        view.showCursor(rgba: Data(), width: 0, height: 0, hotX: 0, hotY: 0)
        #expect(view.cursor === RDPPointer.hidden)
        view.show(nil)
        #expect(view.cursor === NSCursor.arrow)
    }
}

enum TestLabVNC {
    static func command(_ arguments: [String]) -> (status: Int32, output: String) {
        guard let docker = TestLabRDP.docker else { return (-1, "") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: docker)
        process.arguments = ["exec", "-u", "lab", "-e", "DISPLAY=:1", "termstead-lab-vnc-1"] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
    static let isUp: Bool = {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(5901).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }()
}

@MainActor @Suite(.serialized, .enabled(if: TestLabVNC.isUp, "VNC lab is not running"))
struct VNCLabTests {
    private func wait(_ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(15)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }
    private func launch() -> VNCLaunch { VNCLaunch(session: SessionStore.sample().session("lab-vnc")!, password: "lab") }
    @Test func viewportAndKeyboardSurvivePresentingAndRestoringSplitPanes() async throws {
        let store = ConnectionStore()
        store.setLayout(.sideBySide)
        let settings = launch()
        let tab = Connection(sessionID: "lab-vnc", title: "VNC", address: "lab", keyDescription: "VNC", kind: .vnc)
        store.add(tab)
        defer { store.close(tab.id) }
        tab.start(settings)
        let desktop = try #require(tab.vnc)
        await wait { desktop.phase == .showing }
        try #require(desktop.phase == .showing)
        desktop.setZoom(175)
        let host = NSHostingView(rootView: PaneLayoutView()
            .environment(store).environment(ThemeStore()).environment(SessionStore.sample())
            .environment(AppState()).environment(\.theme, Theme.graphite))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        #expect(desktop.view.window === window && window.firstResponder === desktop.view)
        desktop.view.scroll(CGPoint(x: 100, y: 100))
        let origin = desktop.viewport.contentView.bounds.origin
        store.presentsDesktop = true
        try await Task.sleep(for: .milliseconds(250))
        #expect(store.layout == .sideBySide && desktop.zoom == 175)
        #expect(desktop.view.window === window && window.firstResponder === desktop.view)
        #expect(desktop.viewport.contentView.bounds.origin == origin)
        store.presentsDesktop = false
        try await Task.sleep(for: .milliseconds(250))
        #expect(store.layout == .sideBySide && desktop.zoom == 175)
        #expect(desktop.view.window === window && window.firstResponder === desktop.view)
        #expect(desktop.viewport.contentView.bounds.origin == origin)
    }
    @Test(arguments: [false, true])
    func tlsRequiresCertificateApprovalBeforeConnecting(_ approve: Bool) async throws {
        let engine = VNCEngineConnection()
        defer { engine.close() }
        var settings = launch(); settings.options.security = .tls
        var asked = false; var connected = false; var code: Int?
        engine.onCertificate = { pem, reply in
            asked = RDPCertificate(pem: pem) != nil
            #expect(!connected)
            reply(approve)
        }
        engine.onConnected = { connected = true }
        engine.onDisconnected = { _, result in code = result }
        engine.connect(settings, socket: try await RDPSocket.connect(host: "127.0.0.1", port: 5901))
        await wait { connected || code != nil }
        #expect(asked)
        #expect(connected == approve)
        #expect(code == (approve ? nil : 4))
    }
    @Test func classicAndTLSLoginsCanAlternateInOneEngineProcess() async throws {
        for tls in [false, true, false, true] {
            let engine = VNCEngineConnection()
            var settings = launch()
            settings.options.security = tls ? .tls : .standard
            var connected = false; var error: String?
            engine.onCertificate = { _, reply in reply(true) }
            engine.onConnected = { connected = true }
            engine.onDisconnected = { reason, _ in error = reason }
            engine.connect(settings, socket: try await RDPSocket.connect(host: "127.0.0.1", port: 5901))
            await wait { connected || error != nil }
            #expect(connected, "TLS=\(tls): \(error ?? "no error")")
            engine.close()
        }
    }
    @Test func tlsTrustIsRememberedAndChangedPinsAskAgain() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vnc-cert-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let desktop = VNCDesktop()
        defer { desktop.stop() }
        desktop.knownHosts = RDPKnownHosts(url: folder.appendingPathComponent("known_hosts"))
        var settings = launch(); settings.options.security = .tls
        func start() { desktop.start(settings) { try await RDPSocket.connect(host: "127.0.0.1", port: 5901) } }
        start()
        await wait { desktop.certificateQuestion != nil || desktop.phase != .connecting }
        let question = try #require(desktop.certificateQuestion)
        #expect(!question.changed && desktop.phase != .showing)
        desktop.answerCertificate(trust: true)
        await wait { desktop.phase == .showing }
        #expect(desktop.phase == .showing)
        #expect(desktop.knownHosts.fingerprint(host: "127.0.0.1", port: 5901) == question.fingerprint)
        desktop.stop(); start()
        await wait { desktop.phase == .showing || desktop.certificateQuestion != nil }
        #expect(desktop.phase == .showing && desktop.certificateQuestion == nil)
        desktop.stop()
        desktop.knownHosts.trust("another certificate", host: "127.0.0.1", port: 5901)
        start()
        await wait { desktop.certificateQuestion != nil }
        #expect(desktop.certificateQuestion?.changed == true)
        desktop.answerCertificate(trust: false)
        await wait { desktop.phase != .connecting }
        #expect(desktop.phase != .showing && desktop.retryMessage == nil)
    }
    @Test func closingWhileCertificateApprovalIsPendingDoesNotReconnect() async throws {
        let desktop = VNCDesktop()
        defer { desktop.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vnc-close-cert-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        desktop.knownHosts = RDPKnownHosts(url: folder.appendingPathComponent("known_hosts"))
        var settings = launch(); settings.options.security = .tls
        desktop.start(settings) { try await RDPSocket.connect(host: "127.0.0.1", port: 5901) }
        await wait { desktop.certificateQuestion != nil || desktop.phase != .connecting }
        try #require(desktop.certificateQuestion != nil)
        desktop.stop()
        try await Task.sleep(for: .milliseconds(200))
        #expect(desktop.certificateQuestion == nil && desktop.phase == .ended(""))
        await open(desktop)
        #expect(desktop.phase == .showing)
    }
    @Test(arguments: VNCOptions.Quality.allCases)
    func qualityProfilesProduceVisiblePixels(_ profile: VNCOptions.Quality) async throws {
        let engine = VNCEngineConnection()
        defer { engine.close() }
        var settings = launch(); settings.options.quality = profile
        var surface: IOSurface?; var painted = false
        engine.onSurface = { made, _, _ in surface = made }
        engine.onChange = { painted = true }
        engine.connect(settings, socket: try await RDPSocket.connect(host: "127.0.0.1", port: 5901))
        func visiblePixels() -> Int {
            guard let pixels = surface else { return 0 }
            pixels.lock(options: .readOnly, seed: nil)
            defer { pixels.unlock(options: .readOnly, seed: nil) }
            var count = 0
            for y in stride(from: 0, to: pixels.height, by: 32) {
                for x in stride(from: 0, to: pixels.width, by: 32) {
                    let value = pixels.baseAddress.advanced(by: pixels.bytesPerRow * y + x * 4).load(as: UInt32.self)
                    if value & 0xff000000 == 0xff000000, value & 0x00ffffff != 0 { count += 1 }
                }
            }
            return count
        }
        // The first update can contain only a cursor shape. Wait for pixels,
        // not just FinishedFrameBufferUpdate or one particular screen point.
        await wait { painted && visiblePixels() > 100 }
        #expect(visiblePixels() > 100)
    }
    @Test func lostTransportReconnectsButRepeatedFailuresAreBounded() async throws {
        let desktop = VNCDesktop()
        defer { desktop.stop() }
        desktop.reconnectDelays = [0, 0]
        var attempts = 0; var socket: FileHandle?; var ended = 0
        desktop.onEnded = { _ in ended += 1 }
        desktop.start(launch()) {
            attempts += 1
            if attempts > 1 { throw CocoaError(.fileReadUnknown) }
            let made = try await RDPSocket.connect(host: "127.0.0.1", port: 5901)
            socket = made
            return made
        }
        await wait { desktop.phase == .showing }
        try #require(desktop.phase == .showing)
        shutdown(try #require(socket).fileDescriptor, SHUT_RDWR)
        await wait { ended > 0 }
        #expect(attempts == 3 && ended == 1)
        #expect(desktop.phase != .connecting && desktop.phase != .showing)
    }
    @Test func serverResolutionChangesOnlyAfterAnExplicitRequest() async throws {
        let desktop = VNCDesktop()
        defer { desktop.stop() }
        await open(desktop)
        await wait { desktop.supportsResize }
        try #require(desktop.supportsResize)
        desktop.setZoom(200)
        #expect(desktop.size == CGSize(width: 1280, height: 800))
        desktop.requestResolution(width: 1440, height: 900)
        await wait { desktop.size == CGSize(width: 1440, height: 900) }
        #expect(desktop.size == CGSize(width: 1440, height: 900))
        desktop.requestResolution(width: 1280, height: 800)
        await wait { desktop.size == CGSize(width: 1280, height: 800) }
        #expect(desktop.size == CGSize(width: 1280, height: 800))
    }
    private func open(_ desktop: VNCDesktop) async {
        desktop.start(launch()) { try await RDPSocket.connect(host: "127.0.0.1", port: 5901) }
        await wait { desktop.phase == .showing || desktop.loginQuestion != nil || desktop.phase != .connecting }
    }
    @Test func drawsDesktopReconnectsAndCloses() async throws {
        let desktop = VNCDesktop()
        defer { desktop.stop() }
        await open(desktop)
        #expect(desktop.phase == .showing)
        #expect(desktop.size == CGSize(width: 1280, height: 800))
        #expect(desktop.view.layer?.sublayers?.first?.contents != nil)
        desktop.stop()
        #expect(desktop.size == nil)
        await open(desktop)
        #expect(desktop.phase == .showing)
    }
    @Test func refusedPasswordCanBeCorrectedWithoutClosingTheTab() async throws {
        let desktop = VNCDesktop()
        defer { desktop.stop() }
        var bad = launch(); bad.password = "wrong"
        desktop.start(bad) { try await RDPSocket.connect(host: "127.0.0.1", port: 5901) }
        await wait { desktop.loginQuestion != nil || desktop.phase != .connecting }
        #expect(desktop.loginQuestion?.problem != nil)
        desktop.answerLogin(user: "", password: "lab", save: false)
        await wait { desktop.phase == .showing }
        #expect(desktop.phase == .showing)
    }
    @Test func connectsThroughASavedJumpHost() async throws {
        let store = SessionStore.sample()
        let session = try #require(store.session("lab-vnc-via-bastion"))
        var plan = try ConnectionStore.tunnelPlan(for: session, in: store)
        plan.config = "Host *\n StrictHostKeyChecking no\n UserKnownHostsFile /dev/null\n IdentityAgent none\n\n" + plan.config
        let tab = Connection(sessionID: session.id, title: session.id, address: session.statusAddress,
                             keyDescription: "VNC", kind: .vnc)
        defer { tab.close() }
        tab.start(VNCLaunch(session: session, password: "lab"), tunnel: plan)
        let desktop = try #require(tab.vnc)
        await wait { desktop.phase == .showing || !tab.state.isRunning }
        #expect(desktop.phase == .showing)
        #expect(tab.state.isRunning)
        #expect(tab.plan?.target.host == "127.0.0.1")
    }
    @Test func tunnelRetryBudgetSurvivesBriefVNCLoginsAndRenewsAfterStableUse() async throws {
        let store = SessionStore.sample()
        let session = try #require(store.session("lab-vnc-via-bastion"))
        var plan = try ConnectionStore.tunnelPlan(for: session, in: store)
        plan.config = "Host *\n StrictHostKeyChecking no\n UserKnownHostsFile /dev/null\n IdentityAgent none\n\n" + plan.config
        let tab = Connection(sessionID: session.id, title: session.id, address: session.statusAddress,
                             keyDescription: "VNC", kind: .vnc)
        defer { tab.close() }
        let desktop = try #require(tab.vnc)
        var time: TimeInterval = 0
        desktop.uptime = { time }
        var connections = 0
        desktop.onConnected = { connections += 1 }
        tab.start(VNCLaunch(session: session, password: "lab"), tunnel: plan)
        for count in 1...3 {
            await wait { connections == count && desktop.phase == .showing }
            try #require(connections == count && desktop.phase == .showing)
            #expect(tab.reconnectAttempts == count - 1)
            if count == 3 { time += 31 }
            tab.terminalView.terminate() // Drop only this viewer's SSH tunnel.
        }
        await wait { connections == 4 && desktop.phase == .showing }
        #expect(connections == 4 && desktop.phase == .showing)
        #expect(tab.reconnectAttempts == 1, "stable VNC use renews the SSH tunnel retry budget")
        tab.terminalView.terminate()
        await wait { !tab.state.isRunning && tab.reconnectAttempts == 2 }
        try #require(!tab.state.isRunning && tab.reconnectAttempts == 2)
        tab.restart() // A manual retry starts a fresh budget, without the wait.
        await wait { connections == 5 && desktop.phase == .showing }
        #expect(connections == 5 && desktop.phase == .showing)
        #expect(tab.reconnectAttempts == 0)
    }
    @Test func closingAnEngineDoesNotReportAFailure() async throws {
        let engine = VNCEngineConnection()
        var ended: String?
        var connected = false
        engine.onConnected = { connected = true }
        engine.onDisconnected = { reason, _ in ended = reason }
        engine.connect(launch(), socket: try await RDPSocket.connect(host: "127.0.0.1", port: 5901))
        await wait { connected || ended != nil }
        #expect(connected)
        engine.close()
        try await Task.sleep(for: .milliseconds(100))
        #expect(ended == nil)
    }
    @Test func theRealServerDrawsNonBlackPixels() async throws {
        let engine = VNCEngineConnection()
        defer { engine.close() }
        var surface: IOSurface?
        var changed = false
        engine.onSurface = { made, _, _ in surface = made }
        engine.onChange = { changed = true }
        engine.connect(launch(), socket: try await RDPSocket.connect(host: "127.0.0.1", port: 5901))
        func coloredPixels() -> Int {
            guard let frame = surface else { return 0 }
            frame.lock(options: .readOnly, seed: nil)
            defer { frame.unlock(options: .readOnly, seed: nil) }
            let stride = frame.bytesPerRow / 4
            let pixels = frame.baseAddress.bindMemory(to: UInt32.self, capacity: stride * frame.height)
            var colored = 0
            for y in Swift.stride(from: 0, to: frame.height, by: 8) {
                for x in Swift.stride(from: 0, to: frame.width, by: 8) {
                    if pixels[y * stride + x] & 0x00ffffff != 0 { colored += 1 }
                }
            }
            return colored
        }
        await wait { changed && coloredPixels() > 100 }
        #expect(coloredPixels() > 100)
    }
    @Test func twoViewersStayIndependent() async throws {
        let first = VNCDesktop(), second = VNCDesktop()
        defer { first.stop(); second.stop() }
        await open(first)
        await open(second)
        #expect(first.phase == .showing && second.phase == .showing)
        first.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(second.phase == .showing)
    }
    @Test(arguments: [false, true])
    func keyboardInputRunsACommandOnTheServer(_ tls: Bool) async throws {
        let desktop = VNCDesktop()
        defer { desktop.stop() }
        let pins = FileManager.default.temporaryDirectory.appendingPathComponent("vnc-input-\(UUID())")
        defer { try? FileManager.default.removeItem(at: pins) }
        desktop.knownHosts = RDPKnownHosts(url: pins)
        var settings = launch()
        settings.options.security = tls ? .tls : .standard
        desktop.start(settings) { try await RDPSocket.connect(host: "127.0.0.1", port: 5901) }
        await wait { desktop.phase == .showing || desktop.certificateQuestion != nil || desktop.phase != .connecting }
        if desktop.certificateQuestion != nil { desktop.answerCertificate(trust: true) }
        await wait { desktop.phase == .showing || desktop.phase != .connecting }
        try #require(desktop.phase == .showing)
        let marker = "/tmp/termstead-vnc-typed-\(Int.random(in: 1000...9999))"
        desktop.press([0xffe3, 0xffe9, 0x74]) // Xfce: Ctrl+Alt+T
        try await Task.sleep(for: .seconds(2))
        for scalar in "touch \(marker); exit".unicodeScalars {
            desktop.press([scalar.value])
        }
        desktop.press([0xff0d])
        var found = false
        for _ in 0..<20 where !found {
            try await Task.sleep(for: .milliseconds(100))
            found = TestLabVNC.command(["test", "-e", marker]).status == 0
        }
        _ = TestLabVNC.command(["rm", "-f", marker])
        #expect(found)
    }
    @Test func clipboardGoesBothWaysOnlyWithTheKeyboard() async throws {
        let board = NSPasteboard(name: .init("termstead-vnc-test-\(UUID())"))
        defer { board.releaseGlobally() }
        let desktop = VNCDesktop()
        defer { desktop.stop() }
        var focused = false
        desktop.pasteboard = board
        desktop.hasKeyboard = { focused }
        await open(desktop)
        try #require(desktop.phase == .showing)
        let local = "from Mac \(UUID()) — привет ✓"
        board.clearContents(); board.setString(local, forType: .string)
        focused = true
        desktop.offerClipboard(onPaste: true)
        var remote = ""
        for _ in 0..<10 where remote != local {
            try await Task.sleep(for: .milliseconds(100))
            remote = TestLabVNC.command(["timeout", "2", "xclip", "-selection", "clipboard", "-o"]).output
        }
        #expect(remote == local)
        focused = false
        let server = "from VNC \(UUID()) — привет ✓"
        _ = TestLabVNC.command(["sh", "-c", "printf '%s' '\(server)' | xclip -selection clipboard -l 10 >/dev/null 2>&1"])
        try await Task.sleep(for: .milliseconds(700))
        #expect(board.string(forType: .string) == local)
        focused = true
        desktop.keyboardArrived()
        await wait { board.string(forType: .string) == server }
        #expect(board.string(forType: .string) == server)
    }
    @Test func concealedTextIsSentOnlyByAnExplicitPaste() async throws {
        let board = NSPasteboard(name: .init("termstead-vnc-concealed-\(UUID())"))
        defer { board.releaseGlobally() }
        let desktop = VNCDesktop()
        defer { desktop.stop() }
        desktop.pasteboard = board
        desktop.hasKeyboard = { true }
        await open(desktop)
        try #require(desktop.phase == .showing)
        let text = "private-\(UUID())"
        board.clearContents()
        board.declareTypes([.string, .init("org.nspasteboard.ConcealedType")], owner: nil)
        board.setString(text, forType: .string)
        desktop.offerClipboard()
        try await Task.sleep(for: .milliseconds(600))
        #expect(TestLabVNC.command(["timeout", "2", "xclip", "-selection", "clipboard", "-o"]).output != text)
        desktop.offerClipboard(onPaste: true)
        var remote = ""
        for _ in 0..<10 where remote != text {
            try await Task.sleep(for: .milliseconds(100))
            remote = TestLabVNC.command(["timeout", "2", "xclip", "-selection", "clipboard", "-o"]).output
        }
        #expect(remote == text)
    }
}
