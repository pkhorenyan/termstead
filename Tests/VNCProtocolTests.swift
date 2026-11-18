import Foundation
import IOSurface
import Testing
@testable import Termstead

/// A deliberately small RFB peer checks legacy security and malformed
/// framebuffer sizes without depending on a desktop server's behavior.
private final class VNCFakeServer: @unchecked Sendable {
    enum Scenario: Sendable, Equatable {
        case legacyNoAuth, rawFrame, oversized, cursorShapes, unsafeVeNCrypt, partialFrame
        case disabledEncoding(UInt32)
        case authenticationFailure(String)
    }
    private let lock = NSLock()
    private var initialized = false
    private var keys: [UInt32] = []
    private var pointerCount = 0
    private var partial = false
    private var closed = false
    private var updates = 0
    var receivedKeys: [UInt32] { lock.withLock { keys } }
    var receivedPointers: Int { lock.withLock { pointerCount } }
    var receivedClientInit: Bool { lock.withLock { initialized } }
    var hasPartialFrame: Bool { lock.withLock { partial } }
    var isClosed: Bool { lock.withLock { closed } }
    var updateRequests: Int { lock.withLock { updates } }
    let socket: FileHandle

    init(_ scenario: Scenario) throws {
        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw CocoaError(.fileReadUnknown) }
        socket = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        let fd = descriptors[1]
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        DispatchQueue.global().async { [self] in
            defer { close(fd); lock.withLock { closed = true } }
            func read(_ count: Int) throws -> [UInt8] {
                var result = [UInt8](repeating: 0, count: count)
                var offset = 0
                while offset < count {
                    let n = result.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), count - offset) }
                    guard n > 0 else { throw CocoaError(.fileReadUnknown) }
                    offset += n
                }
                return result
            }
            func write(_ bytes: [UInt8]) throws {
                var offset = 0
                while offset < bytes.count {
                    let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
                    guard n > 0 else { throw CocoaError(.fileWriteUnknown) }
                    offset += n
                }
            }
            do {
                try write(Array((scenario == .legacyNoAuth ? "RFB 003.003\n" : "RFB 003.008\n").utf8))
                _ = try read(12)
                if scenario == .legacyNoAuth {
                    try write([0, 0, 0, 1])
                } else if scenario == .unsafeVeNCrypt {
                    // Offer VeNCrypt, then anonymous TLSVnc (259) and Plain
                    // (256). Neither may bypass Require TLS's X.509 policy.
                    try write([1, 19])
                    _ = try read(1)
                    try write([0, 2])
                    _ = try read(2)
                    try write([0, 2, 0, 0, 1, 3, 0, 0, 1, 0])
                    _ = try read(4)
                    lock.withLock { initialized = true }
                    return
                } else {
                    try write([1, 1])
                    _ = try read(1)
                    if case .authenticationFailure(let reason) = scenario {
                        let text = Array(reason.utf8)
                        let length = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: text.count >> $0) }
                        try write([0, 0, 0, 1] + length + text)
                        return
                    }
                    try write([0, 0, 0, 0])
                }
                _ = try read(1)
                lock.withLock { initialized = true }
                let size: [UInt8] = scenario == .oversized ? [32, 0, 32, 0] : [0, 2, 0, 2]
                try write(size + [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0] + [0, 0, 0, 4] + Array("fake".utf8))
                var sentCursor = false
                var hidCursor = false
                while true {
                    switch try read(1)[0] {
                    case 0: _ = try read(19) // SetPixelFormat
                    case 2:
                        let header = try read(3)
                        _ = try read((Int(header[1]) << 8 | Int(header[2])) * 4)
                    case 3:
                        let request = try read(9)
                        lock.withLock { updates += 1 }
                        if scenario == .cursorShapes {
                            if !sentCursor {
                                sentCursor = true
                                // RichCursor: hot spot (1,0), 2x1 BGRA pixels,
                                // with only the first pixel visible in its mask.
                                try write([0, 0, 0, 1] + [0, 1, 0, 0, 0, 2, 0, 1, 255, 255, 255, 17] +
                                          [0, 0, 255, 0, 0, 255, 0, 0, 128])
                            } else if !hidCursor {
                                hidCursor = true
                                try write([0, 0, 0, 1] + [0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 255, 17])
                            }
                            continue
                        }
                        if request[0] != 0 { continue }
                        if case .disabledEncoding(let encoding) = scenario {
                            let encoded = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: encoding >> $0) }
                            // A benign empty payload would succeed in the old
                            // Ultra/UltraZip decoders, even when not requested.
                            try write([0, 0, 0, 1] + [0, 0, 0, 0, 0, 1, 0, 1] + encoded + [0, 0, 0, 0])
                            continue
                        }
                        let pixels = Array(repeating: [UInt8](arrayLiteral: 0, 0, 255, 0), count: 4).flatMap { $0 }
                        // Two messages in one write: the second can remain in
                        // LibVNCClient's read-ahead buffer while select is idle.
                        let clipboard: [UInt8] = [3, 0, 0, 0, 0, 0, 0, 5] + Array("ready".utf8)
                        let frame = [UInt8](arrayLiteral: 0, 0, 0, 1) + [0, 0, 0, 0, 0, 2, 0, 2, 0, 0, 0, 0] + pixels
                        if scenario == .partialFrame {
                            try write(Array(frame.prefix(20)))
                            lock.withLock { partial = true }
                            // Do not send the remaining pixels until BOTH key
                            // events arrive. A worker blocked on the frame can
                            // never satisfy this handshake.
                            for _ in 0..<2 {
                                let event = try read(8)
                                guard event[0] == 4 else { return }
                                let symbol = event.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                                lock.withLock { keys.append(symbol) }
                            }
                            try write(Array(frame.dropFirst(20)))
                        } else {
                            try write(frame + clipboard)
                        }
                    case 4:
                        let key = try read(7)
                        let symbol = key.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                        lock.withLock { keys.append(symbol) }
                    case 5:
                        _ = try read(5)
                        lock.withLock { pointerCount += 1 }
                    default: return
                    }
                }
            } catch { /* An expected EOF when the client rejects the handshake. */ }
        }
    }
}

@MainActor @Suite(.serialized)
struct VNCProtocolTests {
    private func launch(allowNone: Bool) -> VNCLaunch {
        var session = Session(id: "fake", user: "", host: "fake", port: 5900, icon: .monitor, auth: .password)
        session.kind = .vnc
        session.vnc.allowNoAuth = allowNone
        return VNCLaunch(session: session, password: "test")
    }
    private func wait(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(25)) }
    }
    @Test(arguments: ["Authentication or authorization failure", "authentication failed", "AUTHENTICATION FAILURE"])
    func authenticationFailuresAskForCorrectedCredentials(_ reason: String) async throws {
        let peer = try VNCFakeServer(.authenticationFailure(reason))
        let desktop = VNCDesktop()
        defer { desktop.stop() }
        var ended = false
        desktop.onEnded = { _ in ended = true }
        desktop.start(launch(allowNone: true)) { peer.socket }
        await wait { desktop.loginQuestion != nil || desktop.phase != .connecting }
        #expect(desktop.loginQuestion?.problem != nil)
        #expect(desktop.phase == .connecting && desktop.retryMessage == nil && !ended)
    }
    @Test(arguments: [UInt32(9), UInt32(0xffff0009)])
    func ultraAndUltraZipAreRejectedEvenWhenTheServerIgnoresOurEncodings(_ encoding: UInt32) async throws {
        let peer = try VNCFakeServer(.disabledEncoding(encoding))
        let engine = VNCEngineConnection()
        defer { engine.close() }
        var reason: String?
        var painted = false
        engine.onDisconnected = { text, _ in reason = text }
        engine.onChange = { painted = true }
        engine.connect(launch(allowNone: true), socket: peer.socket)
        await wait { reason != nil }
        #expect(reason != nil && !painted)
        #expect(peer.updateRequests == 1, "the disabled decoder must not accept the rectangle and request another frame")
    }
    @Test func queuedKeysAreSentBeforeTheRestOfAFrameArrives() async throws {
        let peer = try VNCFakeServer(.partialFrame)
        let engine = VNCEngineConnection()
        defer { engine.close() }
        var painted = false
        var ended = false
        engine.onChange = { painted = true }
        engine.onDisconnected = { _, _ in ended = true }
        engine.connect(launch(allowNone: true), socket: peer.socket)
        await wait { peer.hasPartialFrame }
        try #require(peer.hasPartialFrame && !painted)
        engine.key(0x61, down: true)
        engine.key(0x61, down: false)
        await wait { painted || ended }
        #expect(peer.receivedKeys == [0x61, 0x61])
        #expect(painted && !ended)
    }
    @Test func closingWhileAPartialFrameWaitsInterruptsTheWorker() async throws {
        let peer = try VNCFakeServer(.partialFrame)
        let engine = VNCEngineConnection()
        defer { engine.close() }
        var ended = false
        engine.onDisconnected = { _, _ in ended = true }
        engine.connect(launch(allowNone: true), socket: peer.socket)
        await wait { peer.hasPartialFrame }
        try #require(peer.hasPartialFrame)
        let began = ContinuousClock.now
        engine.close()
        await wait { peer.isClosed }
        #expect(peer.isClosed && began.duration(to: .now) < .seconds(1))
        #expect(!ended)
    }
    @Test func backoffBetweenBriefConnectionsDoesNotRenewTheRetryBudget() async throws {
        let desktop = VNCDesktop()
        defer { desktop.stop() }
        desktop.reconnectDelays = [0, 0]
        var time: TimeInterval = 0
        desktop.uptime = { time }
        var peers: [VNCFakeServer] = []
        var connections = 0
        var ended = false
        desktop.onConnected = { connections += 1 }
        desktop.onEnded = { _ in ended = true }
        desktop.start(launch(allowNone: true)) {
            // Simulate a long backoff without making the test sleep. No
            // active connection exists while this clock advances.
            time += 60
            let peer = try VNCFakeServer(.rawFrame)
            peers.append(peer)
            return peer.socket
        }
        for count in 1...3 {
            await wait { connections >= count || ended }
            try #require(connections == count && desktop.phase == .showing)
            shutdown(try #require(peers.last).socket.fileDescriptor, SHUT_RDWR)
        }
        await wait { ended }
        #expect(ended && connections == 3 && peers.count == 3)
    }
    @Test func thirtySecondsOfContinuousConnectionRenewsTheRetryBudget() async throws {
        let desktop = VNCDesktop()
        defer { desktop.stop() }
        desktop.reconnectDelays = [0]
        var time: TimeInterval = 0
        desktop.uptime = { time }
        var peers: [VNCFakeServer] = []
        var connections = 0, stableLosses = 0
        var ended = false
        desktop.onConnected = { connections += 1 }
        desktop.onStableDisconnect = { stableLosses += 1 }
        desktop.onEnded = { _ in ended = true }
        desktop.start(launch(allowNone: true)) {
            let peer = try VNCFakeServer(.rawFrame)
            peers.append(peer)
            return peer.socket
        }
        for count in 1...3 {
            await wait { connections >= count || ended }
            try #require(connections == count && desktop.phase == .showing)
            if count == 2 { time += 31 }
            #expect(desktop.hasStableConnection == (count == 2))
            shutdown(try #require(peers.last).socket.fileDescriptor, SHUT_RDWR)
        }
        await wait { ended }
        #expect(ended && connections == 3 && peers.count == 3)
        #expect(stableLosses == 1)
    }
    @Test func legacyRFB33CannotBypassTheAuthenticationSetting() async throws {
        let peer = try VNCFakeServer(.legacyNoAuth)
        let engine = VNCEngineConnection()
        defer { engine.close() }
        var ended: String?
        var showed = false
        engine.onDisconnected = { reason, _ in ended = reason }
        engine.onSurface = { _, _, _ in showed = true }
        engine.connect(launch(allowNone: false), socket: peer.socket)
        await wait { ended != nil }
        #expect(ended != nil)
        #expect(!peer.receivedClientInit)
        #expect(!showed)
    }
    @Test func oversizedFramebufferIsRejectedBeforeItCanBeAllocated() async throws {
        let peer = try VNCFakeServer(.oversized)
        let engine = VNCEngineConnection()
        defer { engine.close() }
        var ended: String?
        var showed = false
        engine.onDisconnected = { reason, _ in ended = reason }
        engine.onSurface = { _, _, _ in showed = true }
        engine.connect(launch(allowNone: true), socket: peer.socket)
        await wait { ended != nil }
        #expect(ended?.contains("16 million pixels") == true)
        #expect(!showed)
    }
    @Test func rawPixelsAreOpaqueAndKeepTheirColors() async throws {
        let peer = try VNCFakeServer(.rawFrame)
        let engine = VNCEngineConnection()
        defer { engine.close() }
        var surface: IOSurface?
        var changed = false
        engine.onSurface = { made, _, _ in surface = made }
        engine.onChange = { changed = true }
        engine.connect(launch(allowNone: true), socket: peer.socket)
        await wait { changed }
        let drawn = try #require(surface)
        #expect(drawn.width == 2 && drawn.height == 2)
        drawn.lock(options: .readOnly, seed: nil)
        let pixel = drawn.baseAddress.load(as: UInt32.self)
        drawn.unlock(options: .readOnly, seed: nil)
        #expect(pixel == 0xffff0000)
    }
    @Test(arguments: VNCOptions.Keyboard.allCases)
    func editCommandsUseTheRemoteSystemsModifier(_ keyboard: VNCOptions.Keyboard) async throws {
        let peer = try VNCFakeServer(.rawFrame)
        let desktop = VNCDesktop()
        defer { desktop.stop() }
        var settings = launch(allowNone: true)
        settings.options.keyboard = keyboard
        desktop.start(settings) { peer.socket }
        await wait { desktop.phase == .showing }
        try #require(desktop.phase == .showing)
        desktop.edit(0x63)
        await wait { peer.receivedKeys.count >= 4 }
        let modifier: UInt32 = keyboard == .macOS ? 0xffeb : 0xffe3
        #expect(peer.receivedKeys == [modifier, 0x63, 0x63, modifier])
    }
    @Test(arguments: VNCOptions.Keyboard.allCases)
    func systemShortcutsReachTheRemoteDesktop(_ keyboard: VNCOptions.Keyboard) async throws {
        let peer = try VNCFakeServer(.rawFrame)
        let desktop = VNCDesktop()
        defer { desktop.stop() }
        var settings = launch(allowNone: true)
        settings.options.keyboard = keyboard
        desktop.start(settings) { peer.socket }
        await wait { desktop.phase == .showing }
        try #require(desktop.phase == .showing)
        let expected = desktop.shortcuts.flatMap { shortcut in
            shortcut.symbols + Array(shortcut.symbols.reversed())
        }
        for shortcut in desktop.shortcuts { desktop.sendShortcut(shortcut) }
        await wait { peer.receivedKeys.count >= expected.count }
        #expect(peer.receivedKeys == expected)
    }
    @Test(arguments: [AF_INET, AF_INET6])
    func responsiveKeepaliveConfiguresDirectTCPSocket(_ family: Int32) throws {
        let fd = socket(family, SOCK_STREAM, IPPROTO_TCP)
        try #require(fd >= 0)
        defer { Darwin.close(fd) }
        try RDPSocket.configureResponsiveKeepalive(fd)
        let options: [(Int32, Int32, Int32)] = [
            (SOL_SOCKET, SO_KEEPALIVE, 1),
            (IPPROTO_TCP, TCP_KEEPALIVE, 30),
            (IPPROTO_TCP, TCP_KEEPINTVL, 10),
            (IPPROTO_TCP, TCP_KEEPCNT, 3)
        ]
        for (level, option, expected) in options {
            var actual: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            #expect(getsockopt(fd, level, option, &actual, &size) == 0)
            if level == SOL_SOCKET { #expect(actual != 0) }
            else { #expect(actual == expected) }
        }
    }
    @Test func requireTLSNeverDowngradesToClassicOrAnonymousVNC() async throws {
        let peer = try VNCFakeServer(.rawFrame)
        let engine = VNCEngineConnection()
        defer { engine.close() }
        var settings = launch(allowNone: true)
        settings.options.security = .tls
        var ended = false
        engine.onDisconnected = { _, _ in ended = true }
        engine.connect(settings, socket: peer.socket)
        await wait { ended }
        #expect(ended && !peer.receivedClientInit)
    }
    @Test func veNCryptCannotHideAnonymousTLSOrPlainAuthentication() async throws {
        let peer = try VNCFakeServer(.unsafeVeNCrypt)
        let engine = VNCEngineConnection()
        defer { engine.close() }
        var settings = launch(allowNone: true)
        settings.user = "lab"
        settings.options.security = .tls
        var ended = false
        engine.onDisconnected = { _, _ in ended = true }
        engine.connect(settings, socket: peer.socket)
        await wait { ended }
        #expect(ended && !peer.receivedClientInit)
    }
    @Test(arguments: [false, true])
    func incomingClipboardIsFilteredInTheEngine(_ receive: Bool) async throws {
        let peer = try VNCFakeServer(.rawFrame)
        let engine = VNCEngineConnection()
        defer { engine.close() }
        var settings = launch(allowNone: true)
        settings.options.receiveClipboard = receive
        var connected = false
        var text: String?
        engine.onConnected = { connected = true }
        engine.onClipboard = { value, _ in text = value }
        engine.connect(settings, socket: peer.socket)
        await wait { connected }
        try await Task.sleep(for: .milliseconds(200))
        #expect(text == (receive ? "ready" : nil))
    }
    @Test(arguments: [false, true])
    func viewOnlyIsEnforcedByTheEngine(_ viewOnly: Bool) async throws {
        let peer = try VNCFakeServer(.rawFrame)
        let engine = VNCEngineConnection()
        defer { engine.close() }
        var connected = false
        engine.onConnected = { connected = true }
        var settings = launch(allowNone: true)
        settings.options.viewOnly = viewOnly
        engine.connect(settings, socket: peer.socket)
        await wait { connected }
        try #require(connected)
        engine.key(0x61, down: true)
        engine.key(0x61, down: false)
        engine.pointer(x: 1, y: 1, buttons: 1)
        engine.pointer(x: 1, y: 1, buttons: 0)
        try await Task.sleep(for: .milliseconds(150))
        #expect(peer.receivedKeys == (viewOnly ? [] : [0x61, 0x61]))
        #expect(peer.receivedPointers == (viewOnly ? 0 : 2))
    }
    @Test func readAheadMessagesAreDeliveredWithoutMoreSocketTraffic() async throws {
        let peer = try VNCFakeServer(.rawFrame)
        let engine = VNCEngineConnection()
        defer { engine.close() }
        var text: String?
        engine.onClipboard = { value, _ in text = value }
        engine.connect(launch(allowNone: true), socket: peer.socket)
        await wait { text != nil }
        #expect(text == "ready")
    }
    @Test func cursorShapesKeepTheirMaskHotSpotAndHiddenState() async throws {
        let peer = try VNCFakeServer(.cursorShapes)
        let engine = VNCEngineConnection()
        defer { engine.close() }
        var shapes: [(Data, Int, Int, Int, Int)] = []
        engine.onCursor = { shapes.append(($0, $1, $2, $3, $4)) }
        engine.connect(launch(allowNone: true), socket: peer.socket)
        await wait { shapes.count >= 2 }
        try #require(shapes.count == 2)
        #expect(shapes[0].0 == Data([255, 0, 0, 255, 0, 255, 0, 0]))
        #expect(shapes[0].1 == 2 && shapes[0].2 == 1 && shapes[0].3 == 1 && shapes[0].4 == 0)
        #expect(shapes[1].0.isEmpty && shapes[1].1 == 0 && shapes[1].2 == 0)
    }
}
