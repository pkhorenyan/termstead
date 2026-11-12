import Foundation
import IOSurface
import Testing
@testable import Termstead

/// A deliberately small RFB peer checks legacy security and malformed
/// framebuffer sizes without depending on a desktop server's behavior.
private final class VNCFakeServer: @unchecked Sendable {
    enum Scenario: Sendable { case legacyNoAuth, rawFrame, oversized }
    private let lock = NSLock()
    private var initialized = false
    private var keys: [UInt32] = []
    private var pointerCount = 0
    var receivedKeys: [UInt32] { lock.withLock { keys } }
    var receivedPointers: Int { lock.withLock { pointerCount } }
    var receivedClientInit: Bool { lock.withLock { initialized } }
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
            defer { close(fd) }
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
                } else {
                    try write([1, 1])
                    _ = try read(1)
                    try write([0, 0, 0, 0])
                }
                _ = try read(1)
                lock.withLock { initialized = true }
                let size: [UInt8] = scenario == .oversized ? [32, 0, 32, 0] : [0, 2, 0, 2]
                try write(size + [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0] + [0, 0, 0, 4] + Array("fake".utf8))
                while true {
                    switch try read(1)[0] {
                    case 0: _ = try read(19) // SetPixelFormat
                    case 2:
                        let header = try read(3)
                        _ = try read((Int(header[1]) << 8 | Int(header[2])) * 4)
                    case 3:
                        let request = try read(9)
                        if request[0] != 0 { continue }
                        let pixels = Array(repeating: [UInt8](arrayLiteral: 0, 0, 255, 0), count: 4).flatMap { $0 }
                        // Two messages in one write: the second can remain in
                        // LibVNCClient's read-ahead buffer while select is idle.
                        let clipboard: [UInt8] = [3, 0, 0, 0, 0, 0, 0, 5] + Array("ready".utf8)
                        try write([0, 0, 0, 1] + [0, 0, 0, 0, 0, 2, 0, 2, 0, 0, 0, 0] + pixels + clipboard)
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
        engine.onClipboard = { text = $0 }
        engine.connect(launch(allowNone: true), socket: peer.socket)
        await wait { text != nil }
        #expect(text == "ready")
    }
}
