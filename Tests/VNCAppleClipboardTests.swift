import AppKit
import Foundation
import Testing
import zlib
@testable import Termstead

private enum AppleBoardWire {
    static func u32(_ n: Int) -> [UInt8] { [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: n >> $0) } }
    static func blob(_ bytes: [UInt8]) -> [UInt8] { u32(bytes.count) + bytes }
    static func archive(_ items: [(String, [UInt8])]) -> [UInt8] {
        u32(items.count) + items.flatMap { blob(Array($0.0.utf8)) + u32(0) + u32(0) + blob($0.1) }
    }
    static func packet(_ raw: [UInt8], expanded: Int? = nil) -> [UInt8] {
        var length = compressBound(uLong(raw.count))
        var packed = [UInt8](repeating: 0, count: Int(length))
        let status = packed.withUnsafeMutableBufferPointer { out in
            raw.withUnsafeBufferPointer { input in compress2(out.baseAddress, &length, input.baseAddress, uLong(raw.count), Z_DEFAULT_COMPRESSION) }
        }
        precondition(status == Z_OK)
        return [31, 0, 0, 0] + u32(0) + u32(expanded ?? raw.count) + u32(Int(length)) + packed.prefix(Int(length))
    }
    static func text(_ value: String) -> [UInt8] { packet(archive([("public.utf8-plain-text", Array(value.utf8))])) }
    static func unpackLocal(_ header: [UInt8], _ packed: [UInt8]) throws -> [(String, [UInt8])] {
        let count = header[7..<11].reduce(0) { $0 << 8 | Int($1) }
        guard count <= 2_000_000 else { throw CocoaError(.fileReadCorruptFile) }
        var raw = [UInt8](repeating: 0, count: count + 1)
        let capacity = raw.count
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw CocoaError(.fileReadCorruptFile) }
        defer { inflateEnd(&stream) }
        let status = raw.withUnsafeMutableBufferPointer { out in
            packed.withUnsafeBufferPointer { input in
                stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress); stream.avail_in = uInt(packed.count)
                stream.next_out = out.baseAddress; stream.avail_out = uInt(capacity)
                return inflate(&stream, Z_SYNC_FLUSH)
            }
        }
        guard status == Z_OK || status == Z_STREAM_END else { throw CocoaError(.fileReadCorruptFile) }
        var offset = 0
        func number() throws -> Int {
            guard offset + 4 <= count else { throw CocoaError(.fileReadCorruptFile) }
            defer { offset += 4 }
            return raw[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
        }
        func bytes() throws -> [UInt8] {
            let length = try number()
            guard length <= count - offset else { throw CocoaError(.fileReadCorruptFile) }
            defer { offset += length }
            return Array(raw[offset..<offset + length])
        }
        var result: [(String, [UInt8])] = []
        while offset < count {
            let flavors = try number()
            guard flavors <= 64 else { throw CocoaError(.fileReadCorruptFile) }
            for _ in 0..<flavors {
                let type = String(decoding: try bytes(), as: UTF8.self)
                guard try number() == 0, try number() == 0 else { throw CocoaError(.fileReadCorruptFile) }
                result.append((type, try bytes()))
            }
        }
        return result
    }
}

/// Independent wire peer: checks the negotiated vendor path, pasteboard
/// formats, event-driven requests and partial-message races through XPC.
private final class AppleBoardPeer: @unchecked Sendable {
    private let lock = NSLock()
    private let writeLock = NSLock()
    private let descriptor: Int32
    private var closed = false
    private var reply: [UInt8]
    private var held: [UInt8]?
    private var fetches = 0
    private var local: [String] = []
    private var vendor = 0
    private var frames = 0
    private var pressedKeys: [UInt32] = []
    var receivedKeys: [UInt32] { lock.withLock { pressedKeys } }
    private var releasedKeys: [UInt32] = []
    var receivedKeyReleases: [UInt32] { lock.withLock { releasedKeys } }
    let socket: FileHandle
    var requests: Int { lock.withLock { fetches } }
    var received: [String] { lock.withLock { local } }
    var vendorMessages: Int { lock.withLock { vendor } }
    var sentFrame: Bool { lock.withLock { frames > 0 } }
    var isClosed: Bool { writeLock.withLock { closed } }
    init(reply: [UInt8] = AppleBoardWire.text("remote initial"), apple: Bool = true,
         holdFirstReply: Bool = false, unsolicited: Bool = false) throws {
        self.reply = reply
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw CocoaError(.fileReadUnknown) }
        socket = FileHandle(fileDescriptor: pair[0], closeOnDealloc: true)
        descriptor = pair[1]
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        DispatchQueue.global().async { [self] in
            defer { writeLock.withLock { closed = true; close(descriptor) } }
            func read(_ count: Int) throws -> [UInt8] {
                var bytes = [UInt8](repeating: 0, count: count), offset = 0
                while offset < count {
                    let n = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!.advanced(by: offset), count - offset) }
                    guard n > 0 else { throw CocoaError(.fileReadUnknown) }
                    offset += n
                }
                return bytes
            }
            do {
                try send(Array((apple ? "RFB 003.889\n" : "RFB 003.008\n").utf8))
                _ = try read(12)
                try send([1, 1]); _ = try read(1); try send([0, 0, 0, 0]); _ = try read(1)
                try send([0, 2, 0, 2, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0, 0, 0, 0, 4] + Array("fake".utf8))
                while true {
                    switch try read(1)[0] {
                    case 0: _ = try read(19)
                    case 2:
                        let h = try read(3); _ = try read((Int(h[1]) << 8 | Int(h[2])) * 4)
                    case 3:
                        let request = try read(9)
                        if request[0] == 0 {
                            let pixels = Array(repeating: [UInt8](arrayLiteral: 0, 0, 255, 0), count: 4).flatMap { $0 }
                            try send([0, 0, 0, 1, 0, 0, 0, 0, 0, 2, 0, 2, 0, 0, 0, 0] + pixels)
                            lock.withLock { frames += 1 }
                            if unsolicited { try send(reply) }
                        }
                    case 0x21:
                        let h = try read(3); let n = Int(h[1]) << 8 | Int(h[2]); _ = try read(n)
                        lock.withLock { vendor += 1 }
                    case 0x15: _ = try read(7); lock.withLock { vendor += 1 }
                    case 0x0b:
                        _ = try read(7)
                        let (number, value) = lock.withLock { fetches += 1; return (fetches, self.reply) }
                        if holdFirstReply && number == 1 {
                            lock.withLock { held = Array(value.dropFirst(16)) }
                            try send(Array(value.prefix(16)))
                        } else { try send(value) }
                    case 0x1f:
                        let h = try read(15)
                        let n = h[11..<15].reduce(0) { $0 << 8 | Int($1) }
                        let items = try AppleBoardWire.unpackLocal(h, read(n))
                        lock.withLock {
                            if let text = items.first(where: { $0.0 == "public.utf8-plain-text" }) {
                                let value = String(decoding: text.1, as: UTF8.self)
                                local.append(value); self.reply = AppleBoardWire.text(value)
                            }
                        }
                    case 4:
                        let h = try read(7)
                        let key = h[3..<7].reduce(0) { $0 << 8 | UInt32($1) }
                        lock.withLock {
                            if h[0] != 0 { pressedKeys.append(key) }
                            else { releasedKeys.append(key) }
                        }
                    case 5: _ = try read(5)
                    case 6:
                        let h = try read(7); let n = h[3..<7].reduce(0) { $0 << 8 | Int($1) }
                        let value = String(decoding: try read(n), as: UTF8.self)
                        lock.withLock { local.append(value) }
                    default: return
                    }
                }
            } catch { /* EOF or deliberately rejected malformed peer. */ }
        }
    }
    private func send(_ bytes: [UInt8]) throws {
        try writeLock.withLock {
            guard !closed else { throw CocoaError(.fileWriteUnknown) }
            var offset = 0
            while offset < bytes.count {
                let n = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
                guard n > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += n
            }
        }
    }
    func change(_ text: String) throws {
        lock.withLock { reply = AppleBoardWire.text(text) }
        try send([0x14, 0, 0, 4, 0, 1, 0, 2])
    }
    func releaseReply() throws {
        let rest = lock.withLock { defer { held = nil }; return held }
        if let rest { try send(rest) }
    }
}

@MainActor @Suite(.serialized)
struct VNCAppleClipboardTests {
    private func launch(send: Bool = true, receive: Bool = true, viewOnly: Bool = false) -> VNCLaunch {
        var session = Session(id: "apple-test", user: "", host: "fake", port: 5900, icon: .monitor, auth: .password)
        session.kind = .vnc
        session.vnc.allowNoAuth = true; session.vnc.autoReconnect = false
        session.vnc.sendClipboard = send; session.vnc.receiveClipboard = receive; session.vnc.viewOnly = viewOnly
        return VNCLaunch(session: session, password: "test")
    }
    private func wait(_ condition: () -> Bool) async {
        let until = Date().addingTimeInterval(6)
        while !condition(), Date() < until { try? await Task.sleep(for: .milliseconds(20)) }
    }
    @Test func unicodeTransfersBothWaysOnNotificationsWithoutPolling() async throws {
        let peer = try AppleBoardPeer()
        let engine = VNCEngineConnection(); defer { engine.close() }
        var received: [(String, Int)] = []
        engine.onConnected = { engine.clipboardFocus(true, revision: 7) }
        engine.onClipboard = { received.append(($0, $1)) }
        engine.connect(launch(), socket: peer.socket)
        await wait { !received.isEmpty }
        #expect(received.first?.0 == "remote initial" && received.first?.1 == 7)
        let initial = peer.requests
        try await Task.sleep(for: .milliseconds(650))
        #expect(peer.requests == initial, "an idle clipboard must not be polled")
        let local = "local — привет 🙂"
        engine.clipboard(local)
        await wait { peer.received.contains(local) }
        #expect(peer.received == [local])
        try peer.change("remote — 日本語 ✓")
        await wait { received.last?.0 == "remote — 日本語 ✓" }
        #expect(received.last?.0 == "remote — 日本語 ✓")
        engine.clipboardFocus(false, revision: 8)
        // A later local write is a barrier for the preceding focus message.
        engine.clipboard("focus barrier")
        await wait { peer.received.contains("focus barrier") }
        let inactive = peer.requests
        try peer.change("copied while inactive")
        try await Task.sleep(for: .milliseconds(100))
        #expect(peer.requests == inactive)
        engine.clipboardFocus(true, revision: 8)
        await wait { received.last?.0 == "copied while inactive" }
        #expect(received.last?.0 == "copied while inactive" && received.last?.1 == 8)
    }
    @Test(arguments: [false, true])
    func sendingDisabledAndViewOnlyStillAllowReceiving(_ viewOnly: Bool) async throws {
        let peer = try AppleBoardPeer()
        let engine = VNCEngineConnection(); defer { engine.close() }
        var text: String?
        engine.onConnected = { engine.clipboardFocus(true, revision: 1); engine.clipboard("must not leave") }
        engine.onClipboard = { value, _ in text = value }
        engine.connect(launch(send: false, viewOnly: viewOnly), socket: peer.socket)
        await wait { text != nil }
        #expect(text == "remote initial" && peer.received.isEmpty)
    }
    @Test func receivingDisabledDoesNotMonitorOrFetch() async throws {
        let peer = try AppleBoardPeer()
        let engine = VNCEngineConnection(); defer { engine.close() }
        engine.onConnected = { engine.clipboardFocus(true, revision: 1); engine.clipboard("send only") }
        engine.connect(launch(receive: false), socket: peer.socket)
        await wait { peer.received.contains("send only") }
        #expect(peer.received == ["send only"] && peer.requests == 0 && peer.vendorMessages == 0)
    }
    @Test func ordinaryServersKeepTheStandardClipboard() async throws {
        let peer = try AppleBoardPeer(apple: false)
        let engine = VNCEngineConnection(); defer { engine.close() }
        engine.onConnected = { engine.clipboardFocus(true, revision: 1); engine.clipboard("standard") }
        engine.connect(launch(), socket: peer.socket)
        await wait { peer.received.contains("standard") }
        #expect(peer.received == ["standard"] && peer.vendorMessages == 0 && peer.requests == 0)
    }
    @Test func aCopyMadeDuringAPartialReplyIsNotOverwritten() async throws {
        let board = NSPasteboard(name: .init("termstead-apple-race-\(UUID())")); defer { board.releaseGlobally() }
        let peer = try AppleBoardPeer(holdFirstReply: true)
        let desktop = VNCDesktop(); defer { desktop.stop() }
        desktop.pasteboard = board
        var focused = false
        desktop.hasKeyboard = { focused }
        desktop.start(launch()) { peer.socket }
        await wait { desktop.phase == .showing }
        focused = true; desktop.keyboardArrived()
        await wait { peer.requests == 1 }
        let text = "new local copy — ✓"
        board.clearContents(); board.setString(text, forType: .string)
        desktop.offerClipboard(onPaste: true)
        await wait { peer.received.contains(text) }
        try #require(peer.received.contains(text), "input must be sent while a clipboard reply waits for its body")
        try peer.releaseReply()
        await wait { peer.requests >= 2 }
        try await Task.sleep(for: .milliseconds(150))
        #expect(board.string(forType: .string) == text && desktop.phase == .showing)
        let requests = peer.requests
        try await Task.sleep(for: .milliseconds(600))
        #expect(peer.requests == requests, "echoes must settle instead of producing a clipboard loop")
    }
    @Test func remoteTextCopyReplacesLocalFinderFilesWithoutFetchingOnFocus() async throws {
        let file = URL.temporaryDirectory.appendingPathComponent("vnc-local-copy-\(UUID())")
        try Data("local file".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let board = NSPasteboard(name: .init("termstead-apple-files-\(UUID())"))
        defer { board.releaseGlobally() }
        #expect(board.writeObjects([file as NSURL]))

        let peer = try AppleBoardPeer()
        let desktop = VNCDesktop(); defer { desktop.stop() }
        desktop.pasteboard = board
        desktop.hasKeyboard = { true }
        desktop.start(launch()) { peer.socket }
        await wait { desktop.phase == .showing && peer.vendorMessages > 0 }
        try #require(desktop.phase == .showing)
        try await Task.sleep(for: .milliseconds(150))
        #expect(peer.requests == 0, "focusing VNC must preserve the Finder selection")

        let copied = "copied on the remote Mac with the mouse"
        try peer.change(copied)
        await wait { board.string(forType: .string) == copied }
        #expect(board.string(forType: .string) == copied)
    }
    @Test func utf8IsPreferredToLegacyFlavors() async throws {
        let wire = AppleBoardWire.packet(AppleBoardWire.archive([
            ("com.apple.traditional-mac-plain-text", Array("legacy".utf8)),
            ("public.utf8-plain-text", Array("Unicode ✓".utf8))]))
        let peer = try AppleBoardPeer(reply: wire)
        let engine = VNCEngineConnection(); defer { engine.close() }
        var text: String?
        engine.onConnected = { engine.clipboardFocus(true, revision: 1) }
        engine.onClipboard = { value, _ in text = value }
        engine.connect(launch(), socket: peer.socket)
        await wait { text != nil }
        #expect(text == "Unicode ✓")
    }
    @Test(arguments: [0, 1, 2, 3, 4])
    func alternateTextFlavorsAndNonTextPasteboards(_ variant: Int) async throws {
        let items: [(String, [UInt8])]
        let expected: String?
        switch variant {
        case 0:
            items = [("public.utf16-plain-text", [0xfe, 0xff, 0, 65, 0xd8, 0x3d, 0xde, 0x42])]
            expected = "A🙂"
        case 1: items = [("com.apple.traditional-mac-plain-text", [99, 97, 102, 0x8e])]; expected = "café"
        case 2: items = [("public.png", [0, 1, 2, 3])]; expected = nil
        case 3: items = []; expected = nil
        default: items = [("public.utf8-plain-text", [])]; expected = ""
        }
        let peer = try AppleBoardPeer(reply: AppleBoardWire.packet(AppleBoardWire.archive(items)))
        let engine = VNCEngineConnection(); defer { engine.close() }
        var text: String?, ended = false
        engine.onConnected = { engine.clipboardFocus(true, revision: 1) }
        engine.onClipboard = { value, _ in text = value }
        engine.onDisconnected = { _, _ in ended = true }
        engine.connect(launch(), socket: peer.socket)
        await wait { peer.requests == 1 }
        if expected != nil { await wait { text != nil || ended } }
        else { try await Task.sleep(for: .milliseconds(100)) }
        #expect(text == expected && !ended)
    }
    @Test(arguments: [0, 1, 2, 3, 4, 5])
    func malformedArchivesAreRejected(_ variant: Int) async throws {
        let packet: [UInt8]
        switch variant {
        case 0: packet = [31, 0, 0, 0] + AppleBoardWire.u32(0) + AppleBoardWire.u32(1) + AppleBoardWire.u32(Int(UInt32.max))
        case 1: packet = AppleBoardWire.packet([], expanded: 8 * 1_048_576 + 1)
        case 2: packet = AppleBoardWire.packet(AppleBoardWire.u32(65))
        case 3: packet = AppleBoardWire.packet(AppleBoardWire.u32(1) + AppleBoardWire.u32(9999))
        case 4: packet = AppleBoardWire.packet([UInt8](repeating: 0, count: 1_048_576), expanded: 0)
        default:
            var truncated = Array(AppleBoardWire.text("truncated").dropLast(2))
            truncated.replaceSubrange(12..<16, with: AppleBoardWire.u32(truncated.count - 16))
            packet = truncated
        }
        let peer = try AppleBoardPeer(reply: packet)
        let engine = VNCEngineConnection(); defer { engine.close() }
        var ended = false, clipboard = false
        engine.onConnected = { engine.clipboardFocus(true, revision: 1) }
        engine.onClipboard = { _, _ in clipboard = true }
        engine.onDisconnected = { _, _ in ended = true }
        engine.connect(launch(), socket: peer.socket)
        await wait { ended }
        #expect(ended && !clipboard)
    }
}
