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
    private var filePackets: [Data] = []
    private var pressedKeys: [UInt32] = []
    var receivedKeys: [UInt32] { lock.withLock { pressedKeys } }
    private var releasedKeys: [UInt32] = []
    var receivedKeyReleases: [UInt32] { lock.withLock { releasedKeys } }
    private var fileOffers: [[String]] = []
    var receivedFilePackets: [Data] { lock.withLock { filePackets } }
    var receivedFileOffers: [[String]] { lock.withLock { fileOffers } }
    let socket: FileHandle
    var requests: Int { lock.withLock { fetches } }
    var received: [String] { lock.withLock { local } }
    var vendorMessages: Int { lock.withLock { vendor } }
    var sentFrame: Bool { lock.withLock { frames > 0 } }
    var isClosed: Bool { writeLock.withLock { closed } }
    init(reply: [UInt8] = AppleBoardWire.text("remote initial"), apple: Bool = true,
         holdFirstReply: Bool = false, unsolicited: Bool = false,
         fileFixture: [Data] = [], holdFileReply: Bool = false) throws {
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
                        let files = items.filter { $0.0 == "public.file-url" }.map { String(decoding: $0.1, as: UTF8.self) }
                        lock.withLock {
                            if !files.isEmpty {
                                fileOffers.append(files)
                                self.reply = AppleBoardWire.packet(AppleBoardWire.archive(items))
                            } else if let text = items.first(where: { $0.0 == "public.utf8-plain-text" }) {
                                let value = String(decoding: text.1, as: UTF8.self)
                                local.append(value); self.reply = AppleBoardWire.text(value)
                            }
                        }
                    case 0x22:
                        let h = try read(5)
                        let n = h[1..<5].reduce(0) { $0 << 8 | Int($1) }
                        let packet = Data([0x22] + h + (try read(n)))
                        let message = try VNCFileMessage(wire: packet)
                        lock.withLock { filePackets.append(packet) }
                        if message.kind == 1 {
                            for data in fileFixture {
                                var reply = try VNCFileMessage(wire: data)
                                reply.session = message.session
                                try send(Array(reply.wire))
                            }
                        } else if message.kind == 104, !holdFileReply {
                            let packets = try lock.withLock { try filePackets.map { try VNCFileMessage(wire: $0) } }
                            let item = packets.first { $0.session == message.session && $0.kind == 101 }!
                            let n = Int(item.payload.be16(96))
                            let name = item.payload.subdata(in: 100..<100 + n)
                            try send(Array(VNCFileMessage(kind: 200, session: message.session,
                                                         argument: UInt32(n), payload: name + Data([0])).wire))
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
    func changeFiles(_ urls: [String], type: String = "public.file-url") throws {
        lock.withLock { reply = AppleBoardWire.packet(AppleBoardWire.archive(urls.map { (type, Array($0.utf8)) })) }
        try send([0x14, 0, 0, 4, 0, 1, 0, 2])
    }
    func sendFile(_ message: VNCFileMessage) throws { try send(Array(message.wire)) }
    func releaseReply() throws {
        let rest = lock.withLock { defer { held = nil }; return held }
        if let rest { try send(rest) }
    }
}

@MainActor @Suite(.serialized)
struct VNCAppleClipboardTests {
    @Test func nativeArchiveKeepsSeparateFileItems() async throws {
        let urls = ["file:///Users/test/first", "file:///Users/test/second%20folder"]
        let raw = urls.flatMap { AppleBoardWire.archive([("public.file-url", Array($0.utf8))]) }
        let peer = try AppleBoardPeer(reply: AppleBoardWire.packet(raw))
        let engine = VNCEngineConnection(); defer { engine.close() }
        var received: [String]?
        engine.onConnected = { engine.clipboardFocus(true, revision: 99) }
        engine.onServerFiles = { values, revision in
            #expect(revision == 99)
            received = values
        }
        engine.connect(launch(), socket: peer.socket)
        await wait { received != nil || peer.isClosed }
        #expect(received == urls)
    }

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
    @Test func fileUploadsUseTheAuthenticatedChannelAndPublishOnlyAfterCompletion() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("termstead-files-xpc-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("данные.bin")
        let data = Data((0..<170_003).map { UInt8(truncatingIfNeeded: $0) })
        try data.write(to: file)
        let peer = try AppleBoardPeer()
        let engine = VNCEngineConnection(); defer { engine.close() }
        var connected = false, ready = false
        engine.onConnected = { connected = true; engine.clipboardFocus(true, revision: 12) }
        engine.onFilesReady = { urls, revision, sending, error in
            #expect(error.isEmpty && revision == 12 && sending && urls.count == 1)
            ready = true
        }
        engine.connect(launch(), socket: peer.socket)
        await wait { connected }
        engine.uploadFiles([file], revision: 12)
        await wait { ready }
        try #require(ready && peer.receivedFileOffers.count == 1)
        let packets = try peer.receivedFilePackets.map { try VNCFileMessage(wire: $0) }
        #expect(packets.first?.kind == 2 && packets.contains { $0.kind == 104 })
        #expect(packets.filter { $0.kind == 102 }.reduce(into: Data()) { $0.append($1.payload) } == data)
        #expect(peer.receivedFileOffers.first?.first?.hasPrefix("file:///private/tmp/Termstead-") == true)
    }
    @Test(arguments: [false, true], ["public.file-url", "com.apple.finder.node"])
    func macFilesBecomeFinderURLsAfterAllBytesArrive(_ viewOnly: Bool, _ type: String) async throws {
        // Independently specified native sender layout: empty file and a
        // Unicode-named binary file, inside a directory (levels 0 and 1).
        let body = Data([0, 1, 2, 255, 13, 10, 42])
        let fixture = try [
            VNCFileMessage.item(session: 1, name: "folder", directory: true, level: 0, size: 0),
            .item(session: 1, name: "empty", directory: false, level: 1, size: 0),
            .item(session: 1, name: "данные.bin", directory: false, level: 1, size: UInt64(body.count)),
            VNCFileMessage(kind: 102, session: 1, argument: UInt32(body.count), payload: body),
            VNCFileMessage(kind: 104, session: 1)
        ].map(\.wire)
        let peer = try AppleBoardPeer(fileFixture: fixture)
        let board = NSPasteboard(name: .init("termstead-files-\(UUID())"))
        defer { board.releaseGlobally() }
        let desktop = VNCDesktop(); defer { desktop.stop() }
        desktop.pasteboard = board; desktop.hasKeyboard = { true }
        desktop.start(launch(viewOnly: viewOnly)) { peer.socket }
        await wait { desktop.phase == .showing }
        let path = "/Users/test/Папка с пробелами %25"
        let offered = type == "public.file-url" ? URL(fileURLWithPath: path).absoluteString : path
        try peer.changeFiles([offered], type: type)
        await wait { desktop.fileCopy?.done == true }
        try #require(desktop.fileCopy?.done == true && desktop.fileCopy?.error == nil)
        let files = try #require(board.readObjects(forClasses: [NSURL.self]) as? [URL])
        let folder = try #require(files.first)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        #expect(try Data(contentsOf: folder.appendingPathComponent("данные.bin")) == body)
        #expect(try Data(contentsOf: folder.appendingPathComponent("empty")).isEmpty)
        let count = peer.receivedFilePackets.count
        try await Task.sleep(for: .milliseconds(800))
        #expect(peer.receivedFilePackets.count == count, "file clipboard echoes must not download again")
        let request = try #require(peer.receivedFilePackets.first.map { try VNCFileMessage(wire: $0) })
        #expect(request.kind == 1)
        #expect(String(decoding: request.payload.dropFirst(6), as: UTF8.self) == path)
    }
    @Test func localFinderFilesWaitForExplicitPasteAndSurviveFocusingTheDesktop() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("termstead-files-paste-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try Data("file contents".utf8).write(to: file)
        let peer = try AppleBoardPeer()
        let board = NSPasteboard(name: .init("termstead-file-paste-\(UUID())")); defer { board.releaseGlobally() }
        board.writeObjects([file as NSURL])
        let desktop = VNCDesktop(); defer { desktop.stop() }
        desktop.pasteboard = board; desktop.hasKeyboard = { true }
        desktop.start(launch()) { peer.socket }
        await wait { desktop.phase == .showing }
        try await Task.sleep(for: .milliseconds(650))
        #expect(peer.receivedFilePackets.isEmpty && peer.requests == 0)
        #expect((board.readObjects(forClasses: [NSURL.self]) as? [URL]) == [file])
        desktop.view.paste(nil)
        await wait { desktop.fileCopy?.done == true && peer.receivedKeys.contains(0x76) }
        #expect(desktop.fileCopy?.done == true && desktop.fileCopy?.error == nil)
        #expect(peer.receivedFileOffers.count == 1 && peer.receivedKeys.contains(0x76))
        #expect(peer.receivedKeys.contains(0xffeb), "Native Mac file paste must use Command even with the default Linux keyboard profile")
        #expect(!peer.receivedKeys.contains(0xffe3))
        #expect(desktop.fileCopy?.paste == .sent)
    }
    @Test(arguments: [false, true])
    func remoteNotificationsDoNotReplaceLocalFinderFilesBeforePaste(_ fileOffer: Bool) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("termstead-focus-files-\(UUID())")
        let folder = root.appendingPathComponent("test_rdp")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("new local folder".utf8).write(to: folder.appendingPathComponent("proof.txt"))
        let peer = try AppleBoardPeer()
        let board = NSPasteboard(name: .init("termstead-focus-files-\(UUID())"))
        defer { board.releaseGlobally() }
        let desktop = VNCDesktop(); defer { desktop.stop() }
        var focused = true
        desktop.pasteboard = board; desktop.hasKeyboard = { focused }
        desktop.start(launch()) { peer.socket }
        await wait { board.string(forType: .string) == "remote initial" }
        focused = false; desktop.keyboardLeft()
        board.clearContents(); board.writeObjects([folder as NSURL])
        focused = true; desktop.keyboardArrived()
        try await Task.sleep(for: .milliseconds(300))
        // A late native pasteboard notification may fetch the old remote
        // selection after the newly copied local folder gained focus.
        if fileOffer { try peer.changeFiles(["file:///Users/test/old-folder"]) }
        else { try peer.change("Termstead Files") }
        try await Task.sleep(for: .milliseconds(200))
        #expect((board.readObjects(forClasses: [NSURL.self]) as? [URL]) == [folder])
        desktop.edit(0x76)
        await wait { desktop.fileCopy?.done == true && peer.receivedKeys.contains(0x76) }
        try #require(desktop.fileCopy?.done == true)
        let remote = try #require(peer.receivedFileOffers.last?.first.flatMap(URL.init(string:)))
        #expect(remote.lastPathComponent == "test_rdp")
        // Intentionally copying on the remote desktop must still work while
        // the local clipboard contains the files that were just uploaded.
        desktop.edit(0x63)
        try peer.change("intentional remote copy")
        await wait { board.string(forType: .string) == "intentional remote copy" }
        #expect(board.string(forType: .string) == "intentional remote copy")
        desktop.edit(0x63)
        board.clearContents(); board.writeObjects([folder as NSURL])
        desktop.offerClipboard()
        try await Task.sleep(for: .milliseconds(300))
        try peer.change("late reply to the previous remote copy")
        try await Task.sleep(for: .milliseconds(200))
        #expect((board.readObjects(forClasses: [NSURL.self]) as? [URL]) == [folder])
    }
    @Test(arguments: [false, true])
    func localFilesDoNotBlockReceiveOnlyOrViewOnlyClipboard(_ viewOnly: Bool) async throws {
        let peer = try AppleBoardPeer()
        let folder = URL.temporaryDirectory.appendingPathComponent("termstead-receive-files-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let board = NSPasteboard(name: .init("termstead-receive-files-\(UUID())"))
        defer { board.releaseGlobally() }
        let desktop = VNCDesktop(); defer { desktop.stop() }
        desktop.pasteboard = board; desktop.hasKeyboard = { true }
        desktop.start(launch(send: viewOnly, viewOnly: viewOnly)) { peer.socket }
        await wait { board.string(forType: .string) == "remote initial" }
        desktop.keyboardLeft()
        board.clearContents(); board.writeObjects([folder as NSURL])
        desktop.keyboardArrived()
        try await Task.sleep(for: .milliseconds(300))
        try peer.change("remote incoming")
        await wait { board.string(forType: .string) == "remote incoming" }
        #expect(board.string(forType: .string) == "remote incoming")
        #expect(peer.received.isEmpty && peer.receivedFilePackets.isEmpty)
    }
    @Test(arguments: [false, true])
    func delayedMacPasteCancelsAndReleasesCommand(_ loseFocus: Bool) async throws {
        let folder = URL.temporaryDirectory.appendingPathComponent("termstead-cancel-paste-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let peer = try AppleBoardPeer()
        let board = NSPasteboard(name: .init("termstead-cancel-paste-\(UUID())"))
        defer { board.releaseGlobally() }
        let desktop = VNCDesktop(); defer { desktop.stop() }
        var focused = true
        desktop.pasteboard = board; desktop.hasKeyboard = { focused }
        var options = launch(); options.options.keyboard = .macOS
        desktop.start(options) { peer.socket }
        await wait { board.string(forType: .string) == "remote initial" }
        board.clearContents(); board.writeObjects([folder as NSURL])
        desktop.edit(0x76)
        await wait { peer.receivedKeys.contains(0xffeb) }
        try #require(peer.receivedKeys.contains(0xffeb))
        if loseFocus { focused = false; desktop.keyboardLeft() }
        else { board.clearContents(); board.setString("new local copy", forType: .string) }
        await wait { peer.receivedKeyReleases.contains(0xffeb) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(peer.receivedKeyReleases.contains(0xffeb))
        #expect(!peer.receivedKeys.contains(0x76), "A stale or unfocused upload must not paste")
        #expect(desktop.fileCopy?.paste == .cancelled)
    }
    @Test func cancelledUploadDoesNotPublishOrPasteAndTextClipboardRecovers() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("termstead-files-cancel-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try Data("file contents".utf8).write(to: file)
        let peer = try AppleBoardPeer(holdFileReply: true)
        let board = NSPasteboard(name: .init("termstead-file-cancel-\(UUID())")); defer { board.releaseGlobally() }
        board.writeObjects([file as NSURL])
        let desktop = VNCDesktop(); defer { desktop.stop() }
        desktop.pasteboard = board; desktop.hasKeyboard = { true }
        desktop.start(launch()) { peer.socket }
        await wait { desktop.phase == .showing }
        desktop.edit(0x76)
        await wait { peer.receivedFilePackets.contains { (try? VNCFileMessage(wire: $0).kind) == 104 } }
        #expect(peer.receivedFileOffers.isEmpty && peer.receivedKeys.isEmpty)
        desktop.dismissFileCopy()
        await wait { peer.receivedFilePackets.contains { (try? VNCFileMessage(wire: $0).kind) == 5 } }
        #expect(peer.receivedFileOffers.isEmpty && peer.receivedKeys.isEmpty)
        board.clearContents(); board.setString("new text after cancel", forType: .string)
        desktop.offerClipboard()
        await wait { peer.received.contains("new text after cancel") }
        #expect(peer.received.contains("new text after cancel"))
    }
    @Test(arguments: [0, 1, 2])
    func fileDirectionsAndViewOnlyAreEnforcedInTheEngine(_ mode: Int) async throws {
        let file = URL.temporaryDirectory.appendingPathComponent("termstead-direction-\(UUID())")
        try Data([1]).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let peer = try AppleBoardPeer()
        let engine = VNCEngineConnection(); defer { engine.close() }
        var connected = false
        engine.onConnected = { connected = true; engine.clipboardFocus(true, revision: 1) }
        engine.connect(launch(send: mode != 0, receive: mode != 2, viewOnly: mode == 1), socket: peer.socket)
        await wait { connected }
        if mode == 2 { engine.downloadFiles(["file:///Users/test/file"], revision: 1) }
        else { engine.uploadFiles([file], revision: 1) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(peer.receivedFilePackets.isEmpty && peer.receivedFileOffers.isEmpty)
    }
    @Test func incomingFilesClearTheOldClipboardAndCannotOverwriteANewerCopy() async throws {
        let fixture = try [VNCFileMessage.item(session: 1, name: "late.bin", directory: false, level: 0, size: 3)].map(\.wire)
        let peer = try AppleBoardPeer(fileFixture: fixture)
        let board = NSPasteboard(name: .init("termstead-file-stale-\(UUID())")); defer { board.releaseGlobally() }
        board.setString("old local clipboard", forType: .string)
        let desktop = VNCDesktop(); defer { desktop.stop() }
        desktop.pasteboard = board; desktop.hasKeyboard = { true }
        desktop.start(launch()) { peer.socket }
        await wait { desktop.phase == .showing }
        try peer.changeFiles(["file:///Users/test/late.bin"])
        await wait { !peer.receivedFilePackets.isEmpty }
        try #require(!peer.receivedFilePackets.isEmpty && desktop.fileCopy?.done == false)
        #expect(board.string(forType: .string) == nil, "the old clipboard must not be pasted while files download")
        let id = try VNCFileMessage(wire: #require(peer.receivedFilePackets.first)).session
        board.clearContents(); board.setString("newer local clipboard", forType: .string)
        desktop.offerClipboard()
        await wait { peer.received.contains("newer local clipboard") }
        try peer.sendFile(VNCFileMessage(kind: 102, session: id, argument: 3, payload: Data([1, 2, 3])))
        try peer.sendFile(VNCFileMessage(kind: 104, session: id))
        try await Task.sleep(for: .milliseconds(100))
        #expect(board.string(forType: .string) == "newer local clipboard" && desktop.fileCopy == nil)
    }
    @Test func oversizedFileMessageIsRejectedWithoutWaitingForItsPayload() async throws {
        let peer = try AppleBoardPeer(reply: [0x22, 0, 0, 2, 0, 1])
        let engine = VNCEngineConnection(); defer { engine.close() }
        var ended = false
        engine.onConnected = { engine.clipboardFocus(true, revision: 1) }
        engine.onDisconnected = { _, _ in ended = true }
        engine.connect(launch(), socket: peer.socket)
        await wait { ended }
        #expect(ended)
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
    @Test(arguments: [0, 1, 2, 3, 4, 5, 6, 7, 8])
    func malformedArchivesAreRejected(_ variant: Int) async throws {
        let packet: [UInt8]
        switch variant {
        case 0: packet = [31, 0, 0, 0] + AppleBoardWire.u32(0) + AppleBoardWire.u32(1) + AppleBoardWire.u32(Int(UInt32.max))
        case 1: packet = AppleBoardWire.packet([], expanded: 8 * 1_048_576 + 1)
        case 2: packet = AppleBoardWire.packet(AppleBoardWire.u32(65))
        case 3: packet = AppleBoardWire.packet(AppleBoardWire.u32(1) + AppleBoardWire.u32(9999))
        case 4: packet = AppleBoardWire.packet([UInt8](repeating: 0, count: 1_048_576), expanded: 0)
        case 6, 7, 8:
            let path = variant == 6 ? "relative/file" : variant == 7 ? "/tmp/a\0b" : "/tmp/a\nb"
            packet = AppleBoardWire.packet(AppleBoardWire.archive([("com.apple.finder.node", Array(path.utf8))]))
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
