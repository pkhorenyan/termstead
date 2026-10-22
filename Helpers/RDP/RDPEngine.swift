import CoreVideo
import Foundation
import IOSurface

/// One remote desktop: a FreeRDP session (`rdp_bridge.c`) on a thread of its
/// own, drawing into an IOSurface the app shows.
///
/// XPC calls arrive on XPC's queues and FreeRDP calls back on its thread, so
/// the session and the surface are only touched under `lock`.
final class RDPEngine: NSObject, RDPEngineProtocol, @unchecked Sendable {
    private weak var connection: NSXPCConnection?
    private let lock = NSLock()
    private var session: OpaquePointer?
    private var surface: IOSurfaceRef?
    private var isStarted = false
    /// The app let go before the session existed: it is stopped as soon as
    /// it does, or it would log in and stay, with no one to show it to.
    private var stopRequested = false
    /// Gives up the question the session's thread is waiting on, if any:
    /// a tab closed meanwhile must not leave that thread blocked for good.
    private var cancelQuestion: (() -> Void)?
    /// What the app last offered, kept for a session not yet started.
    private var localClipboard: (text: String?, files: [RDPClipboardFile])?
    /// The app's requests for the server's files, by stream id, waiting
    /// for the server's answer.
    private var fileRequests: [UInt32: @Sendable (Data?) -> Void] = [:]
    private var nextStream: UInt32 = 0

    /// Changed areas, gathered between messages to the app: FreeRDP ends a
    /// paint for every update, a few hundred a second while a window moves.
    private var pendingChange: CGRect?
    private var flushScheduled = false
    private var lastFlush = Date.distantPast
    private let flushQueue = DispatchQueue(label: "com.pavelkhorenyan.Termstead.rdp.frames")
    static let frameInterval: TimeInterval = 1.0 / 60

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    private var client: (any RDPClientProtocol)? {
        connection?.remoteObjectProxyWithErrorHandler { _ in } as? any RDPClientProtocol
    }

    // MARK: - RDPEngineProtocol

    func connect(_ settings: RDPConnectSettings, socket: FileHandle) {
        lock.lock()
        let first = !isStarted
        isStarted = true
        lock.unlock()
        // One session per connection; a reconnect is a new connection.
        guard first else { return }
        let descriptor = dup(socket.fileDescriptor)
        let thread = Thread { [self] in run(settings, socket: descriptor) }
        thread.name = "FreeRDP"
        // FreeRDP's codecs keep large buffers on the stack.
        thread.stackSize = 8 << 20
        thread.start()
    }

    func key(_ scancode: Int, extended: Bool, down: Bool) {
        withSession { tsr_send_scancode($0, UInt16(truncatingIfNeeded: scancode), extended, down) }
    }

    func unicode(_ character: Int, down: Bool) {
        withSession { tsr_send_unicode($0, UInt16(truncatingIfNeeded: character), down) }
    }

    func synchronize(capsLock: Bool) {
        withSession { tsr_send_sync($0, capsLock) }
    }

    func mouse(x: Int, y: Int, flags: Int) {
        withSession {
            tsr_send_mouse($0, UInt16(truncatingIfNeeded: flags),
                           UInt16(clamping: max(x, 0)), UInt16(clamping: max(y, 0)))
        }
    }

    func resize(width: Int, height: Int, desktopScale: Int) {
        withSession { tsr_resize($0, UInt32(clamping: width), UInt32(clamping: height), UInt32(clamping: desktopScale)) }
    }

    func clipboard(_ text: String?, files: [RDPClipboardFile]) {
        lock.lock()
        defer { lock.unlock() }
        // Before the session exists, it waits for it.
        localClipboard = (text, files)
        if let session { Self.offer(text, files: files, to: session) }
    }

    /// FreeRDP copies what it is given, so the names need only last the call.
    @discardableResult
    private static func offer(_ text: String?, files: [RDPClipboardFile], to session: OpaquePointer) -> Bool {
        let names = files.map { strdup($0.name) }
        defer { names.forEach { free($0) } }
        var list = files.enumerated().map { index, file in
            tsr_file(name: UnsafePointer(names[index]), size: UInt64(max(file.size, 0)),
                     directory: file.isDirectory, modified: file.modified)
        }
        return tsr_set_clipboard(session, text, &list, list.count)
    }

    func fileData(index: Int, offset: Int64, length: Int, sizeOnly: Bool,
                  reply: @escaping @Sendable (Data?) -> Void) {
        lock.lock()
        guard let session else {
            lock.unlock()
            return reply(nil)
        }
        nextStream &+= 1
        let stream = nextStream
        fileRequests[stream] = reply
        let sent = tsr_request_file_data(session, stream, UInt32(clamping: index), UInt64(max(offset, 0)),
                                         UInt32(clamping: length), sizeOnly)
        if !sent { fileRequests[stream] = nil }
        lock.unlock()
        if !sent { reply(nil) }
    }

    private func fileDataArrived(stream: UInt32, data: Data?) {
        lock.lock()
        let reply = fileRequests.removeValue(forKey: stream)
        lock.unlock()
        reply?(data)
    }

    /// The server pastes: the app reads the file, and the answer goes back
    /// under the server's stream id — if the session is still there.
    private func readFile(stream: UInt32, index: Int, offset: Int64, length: Int) {
        guard let client else { return withSession { tsr_file_data_reply($0, stream, nil, 0); return true } }
        client.readFile(index: index, offset: offset, length: length) { [weak self] data in
            self?.withSession { session in
                if let data {
                    data.withUnsafeBytes { tsr_file_data_reply(session, stream, $0.bindMemory(to: UInt8.self).baseAddress, data.count) }
                } else {
                    tsr_file_data_reply(session, stream, nil, 0)
                }
                return true
            }
        }
    }

    func disconnect() {
        lock.lock()
        let cancel = cancelQuestion
        stopRequested = true
        lock.unlock()
        cancel?()
        withSession {
            tsr_stop($0)
            return true
        }
    }

    private func withSession(_ body: (OpaquePointer) -> Bool) {
        lock.lock()
        defer { lock.unlock() }
        if let session { _ = body(session) }
    }

    // MARK: - The session's thread

    private func run(_ settings: RDPConnectSettings, socket: Int32) {
        var callbacks = tsr_callbacks()
        callbacks.user = Unmanaged.passUnretained(self).toOpaque()
        // FreeRDP's threads last as long as the session, and what a call to
        // the app autoreleases on one stays until the thread ends: every
        // half-megabyte piece of a file copied from the server was kept until
        // the tab closed (three copies of 47 MB took the engine from 22 to
        // 162 MB). So each callback that talks to the app drains its own.
        callbacks.surface = { user, width, height, stride in
            autoreleasepool {
                RDPEngine.from(user).makeSurface(width: Int(width), height: Int(height), stride: stride)
            }
        }
        callbacks.begin_paint = { user in RDPEngine.from(user).beginPaint() }
        callbacks.end_paint = { user, x, y, width, height in
            RDPEngine.from(user).endPaint(CGRect(x: Int(x), y: Int(y), width: Int(width), height: Int(height)))
        }
        callbacks.verify_certificate = { user, pem, length, host, port in
            autoreleasepool {
                guard let pem, let host else { return false }
                let text = String(decoding: UnsafeRawBufferPointer(start: pem, count: length), as: UTF8.self)
                return RDPEngine.from(user).verifyCertificate(pem: text, host: String(cString: host), port: Int(port))
            }
        }
        callbacks.authenticate = { user, username, domain, outUser, outDomain, outPassword in
            autoreleasepool {
                let given = RDPEngine.from(user).askCredentials(user: username.map { String(cString: $0) } ?? "",
                                                                domain: domain.map { String(cString: $0) } ?? "")
                guard let given else { return false }
                outUser?.pointee = strdup(given.user)
                outDomain?.pointee = strdup(given.domain)
                outPassword?.pointee = strdup(given.password)
                return true
            }
        }
        callbacks.connected = { user in autoreleasepool { RDPEngine.from(user).client?.connected() } }
        callbacks.closing = { user in RDPEngine.from(user).letGo() }
        callbacks.server_files = { user, files, count in
            autoreleasepool {
                guard let files else { return }
                let list = UnsafeBufferPointer(start: files, count: count).map { file in
                    RDPClipboardFile(name: file.name.map { String(cString: $0) } ?? "",
                                     size: file.size == UInt64.max ? -1 : Int64(clamping: file.size),
                                     isDirectory: file.directory, modified: file.modified)
                }
                RDPEngine.from(user).client?.serverFiles(list)
            }
        }
        callbacks.read_file = { user, stream, index, offset, length in
            autoreleasepool {
                RDPEngine.from(user).readFile(stream: stream, index: Int(index), offset: Int64(clamping: offset),
                                              length: Int(length))
            }
        }
        callbacks.file_data = { user, stream, data, length in
            autoreleasepool {
                RDPEngine.from(user).fileDataArrived(stream: stream, data: data.map { Data(bytes: $0, count: length) })
            }
        }
        callbacks.clipboard = { user, text in
            autoreleasepool {
                guard let text else { return }
                RDPEngine.from(user).client?.serverClipboard(String(cString: text))
            }
        }
        callbacks.pointer_new = { user, id, rgba, width, height, hotX, hotY in
            autoreleasepool {
                guard let rgba else { return }
                let pixels = Data(bytes: rgba, count: Int(width) * Int(height) * 4)
                RDPEngine.from(user).client?.pointerShape(id: Int(id), rgba: pixels, width: Int(width),
                                                          height: Int(height), hotX: Int(hotX), hotY: Int(hotY))
            }
        }
        callbacks.pointer_free = { user, id in
            autoreleasepool { RDPEngine.from(user).client?.pointerForgotten(id: Int(id)) }
        }
        callbacks.pointer_set = { user, id in
            autoreleasepool { RDPEngine.from(user).client?.showPointer(id: Int(id)) }
        }

        // FreeRDP copies every string into its settings, so these need only
        // last through `tsr_new`.
        let strings = [settings.host, settings.user, settings.domain, settings.password].map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var params = tsr_params()
        params.host = UnsafePointer(strings[0])
        params.port = UInt16(clamping: settings.port)
        params.username = UnsafePointer(strings[1])
        params.domain = UnsafePointer(strings[2])
        params.password = UnsafePointer(strings[3])
        params.width = UInt32(clamping: settings.width)
        params.height = UInt32(clamping: settings.height)
        params.desktop_scale = UInt32(clamping: settings.desktopScale)
        params.keyboard_layout = UInt32(clamping: settings.keyboardLayout)
        params.clipboard = settings.clipboard
        params.sound = settings.sound
        params.socket = socket

        guard let created = tsr_new(&params, &callbacks) else {
            close(socket)
            client?.disconnected(reason: "The RDP engine could not start.", code: 0)
            return
        }
        lock.lock()
        session = created
        if let localClipboard { Self.offer(localClipboard.text, files: localClipboard.files, to: created) }
        if stopRequested { tsr_stop(created) }
        lock.unlock()

        let reason = String(cString: tsr_run(created))
        let code = Int(tsr_last_error(created))

        lock.lock()
        session = nil
        let unanswered = fileRequests.values
        fileRequests = [:]
        lock.unlock()
        unanswered.forEach { $0(nil) }
        tsr_free(created)
        client?.disconnected(reason: reason, code: code)
    }

    /// The session is about to disconnect: from here on `withSession` finds
    /// none. It holds `lock` through each call into FreeRDP, so once this
    /// returns no call from the app is still inside.
    private func letGo() {
        lock.lock()
        session = nil
        lock.unlock()
    }

    private static func from(_ user: UnsafeMutableRawPointer?) -> RDPEngine {
        Unmanaged<RDPEngine>.fromOpaque(user!).takeUnretainedValue()
    }

    /// A surface for the whole desktop, shared with the app. The old one is
    /// let go once the app has the new one.
    private func makeSurface(width: Int, height: Int, stride: UnsafeMutablePointer<UInt32>?) -> UnsafeMutablePointer<UInt8>? {
        let properties = [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfacePixelFormat: Int(kCVPixelFormatType_32BGRA),
        ] as CFDictionary
        guard let made = IOSurfaceCreate(properties) else { return nil }
        lock.lock()
        surface = made
        lock.unlock()
        stride?.pointee = UInt32(IOSurfaceGetBytesPerRow(made))
        // IOSurfaceRef and IOSurface are one object, toll-free bridged; XPC
        // sends the object.
        client?.showSurface(unsafeBitCast(made, to: IOSurface.self), width: width, height: height)
        return IOSurfaceGetBaseAddress(made).assumingMemoryBound(to: UInt8.self)
    }

    private func beginPaint() {
        lock.lock()
        let current = surface
        lock.unlock()
        if let current { IOSurfaceLock(current, [], nil) }
    }

    private func endPaint(_ changed: CGRect) {
        lock.lock()
        let current = surface
        if !changed.isEmpty {
            pendingChange = pendingChange.map { $0.union(changed) } ?? changed
        }
        let schedule = pendingChange != nil && !flushScheduled
        if schedule { flushScheduled = true }
        let wait = max(0, Self.frameInterval - Date().timeIntervalSince(lastFlush))
        lock.unlock()
        if let current { IOSurfaceUnlock(current, [], nil) }
        if schedule {
            flushQueue.asyncAfter(deadline: .now() + wait) { [self] in flush() }
        }
    }

    private func flush() {
        lock.lock()
        let changed = pendingChange
        pendingChange = nil
        flushScheduled = false
        lastFlush = Date()
        lock.unlock()
        guard let changed else { return }
        client?.surfaceChanged(x: Int(changed.minX), y: Int(changed.minY),
                               width: Int(changed.width), height: Int(changed.height))
    }

    /// Waits for the app, which may be waiting for the user. A connection
    /// lost meanwhile, or the session stopped, counts as no.
    private func verifyCertificate(pem: String, host: String, port: Int) -> Bool {
        ask(otherwise: false) { proxy, answer in
            proxy.verifyCertificate(pem: pem, host: host, port: port) { answer($0) }
        }
    }

    private struct Credentials: Sendable {
        var user: String
        var domain: String
        var password: String
    }

    private func askCredentials(user: String, domain: String) -> Credentials? {
        ask(otherwise: nil) { proxy, answer in
            proxy.askCredentials(user: user, domain: domain) { ok, user, domain, password in
                answer(ok ? Credentials(user: user, domain: domain, password: password) : nil)
            }
        }
    }

    /// Blocks the session's thread on a question to the app.
    private func ask<T: Sendable>(otherwise fallback: T,
                                  _ question: (any RDPClientProtocol, @escaping @Sendable (T) -> Void) -> Void) -> T {
        guard let connection else { return fallback }
        let answer = Answer<T>(fallback: fallback)
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in answer.give(fallback) } as? any RDPClientProtocol
        guard let proxy else { return fallback }
        lock.lock()
        cancelQuestion = { answer.give(fallback) }
        lock.unlock()
        question(proxy) { answer.give($0) }
        let value = answer.wait()
        lock.lock()
        cancelQuestion = nil
        lock.unlock()
        return value
    }
}

/// An answer from another thread, given once.
private final class Answer<T: Sendable>: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: T
    private var given = false

    init(fallback: T) {
        value = fallback
    }

    func give(_ answer: T) {
        lock.lock()
        let first = !given
        if first {
            given = true
            value = answer
        }
        lock.unlock()
        if first { semaphore.signal() }
    }

    func wait() -> T {
        semaphore.wait()
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
