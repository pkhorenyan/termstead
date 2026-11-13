import CoreVideo
import Foundation
import IOSurface

/// LibVNCClient and every write into it stay on one worker thread. XPC
/// queues only enqueue input; shutdown interrupts even a partial server read.
final class VNCEngine: NSObject, VNCEngineProtocol, @unchecked Sendable {
    private weak var connection: NSXPCConnection?
    private let lock = NSLock()
    private var started = false
    private var stopped = false
    private var descriptor: Int32 = -1
    private enum Input: Sendable {
        case key(UInt32, Bool), pointer(Int, Int, Int), clipboard(String), resize(Int, Int)
        case clipboardFocus(Bool, Int, Bool), files([String], Int, Bool), cancelFiles, filesTimeout(UInt32)
    }
    private var inputs: [Input] = []
    private var certificateAnswer: CertificateAnswer?
    private let wakeRead: Int32
    private let wakeWrite: Int32
    // Worker-thread state only.
    private var surface: IOSurfaceRef?
    private var fileTransfer: VNCFileTransfer?
    private var remoteFiles: [String] = []
    private var publishedFiles: [String] = []
    private var fileSession: UInt32 = 1
    private var lastFileProgress: TimeInterval = 0
    private var lastFileActivity: TimeInterval = 0
    private var fileRevision = -1
    private var focused = false
    private var sendingFiles = false
    private var receivingFiles = false
    private var sessionForFiles: OpaquePointer?


    init(connection: NSXPCConnection) {
        self.connection = connection
        var descriptors: [Int32] = [-1, -1]
        if pipe(&descriptors) == 0 {
            for fd in descriptors {
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            }
        }
        wakeRead = descriptors[0]
        wakeWrite = descriptors[1]
    }
    deinit {
        if wakeRead >= 0 { close(wakeRead) }
        if wakeWrite >= 0 { close(wakeWrite) }
    }
    /// Called under `lock`. A full pipe already represents a pending wake.
    private func wake() {
        guard wakeWrite >= 0 else { return }
        var byte: UInt8 = 1
        var result: Int
        repeat { result = withUnsafePointer(to: &byte) { Darwin.write(wakeWrite, $0, 1) } }
        while result < 0 && errno == EINTR
    }
    private var client: (any VNCClientProtocol)? {
        connection?.remoteObjectProxyWithErrorHandler { _ in } as? any VNCClientProtocol
    }

    func connect(socket: FileHandle, host: String, user: String, password: String, allowNoAuth: Bool,
                 viewOnly: Bool, clipboard: Bool, receiveClipboard: Bool, quality: Int, requireTLS: Bool) {
        lock.lock()
        guard !started, !stopped else { lock.unlock(); return }
        started = true
        let fd = wakeRead >= 0 ? dup(socket.fileDescriptor) : -1
        descriptor = fd
        lock.unlock()
        let thread = Thread { [self] in
            run(socket: fd, host: host, user: user, password: password, allowNoAuth: allowNoAuth,
                viewOnly: viewOnly, clipboard: clipboard, receiveClipboard: receiveClipboard,
                quality: quality, requireTLS: requireTLS)
        }
        thread.name = "LibVNCClient"
        thread.stackSize = 4 << 20
        thread.start()
    }

    private func enqueue(_ input: Input) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        let wasEmpty = inputs.isEmpty
        // Coalesce adjacent mouse moves; never drop a key release.
        if case .pointer(_, _, let buttons) = input,
           case .pointer(_, _, let previous) = inputs.last, previous == buttons {
            inputs[inputs.count - 1] = input
        } else if inputs.count < 4096 {
            inputs.append(input)
        } else {
            stopped = true
            if descriptor >= 0 { shutdown(descriptor, SHUT_RDWR) }
        }
        if wasEmpty { wake() }
    }

    func key(_ keysym: Int, down: Bool) { enqueue(.key(UInt32(clamping: keysym), down)) }
    func pointer(x: Int, y: Int, buttons: Int) {
        enqueue(.pointer(min(max(x, 0), 8191), min(max(y, 0), 8191), buttons & 255))
    }
    func clipboard(_ text: String) {
        guard text.utf8.count <= 1_048_576 else { return }
        enqueue(.clipboard(text))
    }
    func clipboardFocus(_ active: Bool, revision: Int, fetch: Bool) { enqueue(.clipboardFocus(active, revision, fetch)) }
    func uploadFiles(_ urls: [String], revision: Int) {
        guard VNCFileTransfer.fileURLs(urls) != nil else { return }
        enqueue(.files(urls, revision, true))
    }
    func downloadFiles(_ urls: [String], revision: Int) {
        guard VNCFileTransfer.fileURLs(urls) != nil else { return }
        enqueue(.files(urls, revision, false))
    }
    func cancelFiles() { enqueue(.cancelFiles) }
    func resize(width: Int, height: Int) { enqueue(.resize(width, height)) }
    func disconnect() {
        lock.lock()
        stopped = true
        inputs.removeAll()
        if descriptor >= 0 { shutdown(descriptor, SHUT_RDWR) }
        wake()
        let answer = certificateAnswer
        lock.unlock()
        answer?.give(false)
    }

    private func run(socket: Int32, host: String, user: String, password: String, allowNoAuth: Bool,
                     viewOnly: Bool, clipboard: Bool, receiveClipboard: Bool, quality: Int, requireTLS: Bool) {
        let callbacks = tsv_callbacks(
            context: Unmanaged.passUnretained(self).toOpaque(),
            resize: { context, width, height in
                autoreleasepool { owner(context).resize(width: Int(width), height: Int(height)) }
            },
            pixels: { context, source, stride, x, y, width, height in
                owner(context).pixels(source!, stride: Int(stride), x: Int(x), y: Int(y),
                                      width: Int(width), height: Int(height))
            },
            frame: { context in autoreleasepool { owner(context).client?.surfaceChanged() } },
            clipboard: { context, bytes, length, utf8, revision in
                autoreleasepool {
                    guard let bytes, length >= 0, length <= 1_048_576 else { return }
                    let data = Data(bytes: bytes, count: Int(length))
                    guard owner(context).fileTransfer?.sending != true else { return }
                    if let text = String(data: data, encoding: utf8 ? .utf8 : .isoLatin1) {
                        owner(context).client?.serverClipboard(text, revision: Int(revision))
                    }
                }
            },
            cursor: { context, bytes, width, height, hotX, hotY in
                autoreleasepool {
                    let data = bytes.map { Data(bytes: $0, count: Int(width) * Int(height) * 4) } ?? Data()
                    owner(context).client?.cursorShape(data, width: Int(width), height: Int(height),
                                                       hotX: Int(hotX), hotY: Int(hotY))
                }
            },
            certificate: { context, pem in
                autoreleasepool {
                    guard let pem else { return false }
                    return owner(context).verify(String(cString: pem))
                }
            },
            resize_support: { context, supported in
                autoreleasepool { owner(context).client?.resizeSupport(supported) }
            },
            input: { context, session in
                autoreleasepool {
                    if let session { owner(context).flushInput(session) }
                }
            },
            files: { context, urls, revision in
                autoreleasepool {
                    guard let urls else { return }
                    owner(context).copiedFiles(String(cString: urls).components(separatedBy: "\n"), revision: Int(revision))
                }
            },
            file_message: { context, bytes, length in
                autoreleasepool {
                    if let bytes { owner(context).fileMessage(Data(bytes: bytes, count: Int(length))) }
                }
            })
        guard socket >= 0,
              let session = tsv_new(socket, host, user, password, allowNoAuth, viewOnly, clipboard,
                                    receiveClipboard, Int32(clamping: quality), requireTLS, callbacks) else {
            lock.withLock { descriptor = -1 }
            client?.disconnected(reason: "Could not create the VNC connection.", code: 1)
            return
        }
        defer {
            lock.withLock { descriptor = -1 }
            tsv_free(session)
            surface = nil
            fileTransfer = nil; sessionForFiles = nil
        }
        tsv_set_wakeup(session, wakeRead)
        if lock.withLock({ stopped }) { return }
        guard tsv_connect(session) else {
            let code = Int(tsv_error_code(session))
            let detail = String(cString: tsv_error(session)).trimmingCharacters(in: .whitespacesAndNewlines)
            let reason: String
            switch code {
            case 2: reason = "The VNC server refused the password."
            case 3: reason = "Apple Remote Desktop authentication needs a user name and password."
            case 4: reason = "The VNC server's certificate was not trusted."
            default:
                reason = "Could not complete the VNC handshake. \(detail)" + (requireTLS ? " Require TLS needs a VeNCrypt server with an X.509 certificate; plain VNC and anonymous TLS are refused." : " Check the server's authentication and transport settings.")
            }
            if !lock.withLock({ stopped }) { client?.disconnected(reason: reason, code: code) }
            return
        }
        sessionForFiles = session
        sendingFiles = clipboard && !viewOnly && tsv_is_apple(session)
        receivingFiles = receiveClipboard && tsv_is_apple(session)
        client?.fileTransferSupport(tsv_is_apple(session))
        client?.connected()
        while !lock.withLock({ stopped }) {
            autoreleasepool { flushInput(session) }
            if tsv_poll(session) < 0 { break }
        }
        if !lock.withLock({ stopped }) {
            client?.disconnected(reason: "The VNC connection closed.", code: 1)
        }
    }

    /// Always on the worker, including while a partially received RFB message
    /// waits for more bytes. Outgoing messages do not mutate the read buffer.
    private func flushInput(_ session: OpaquePointer) {
        let pending = lock.withLock { () -> [Input] in
            guard !stopped else { return [] }
            defer { inputs.removeAll(keepingCapacity: true) }
            return inputs
        }
        for event in pending {
            switch event {
            case .key(let symbol, let down): tsv_key(session, symbol, down)
            case .pointer(let x, let y, let buttons):
                tsv_pointer(session, Int32(x), Int32(y), Int32(buttons))
            case .clipboard(let text):
                cancelFileTransfer(session)
                publishedFiles = []
                let latin = text.data(using: .isoLatin1, allowLossyConversion: true) ?? Data()
                latin.withUnsafeBytes { bytes in
                    tsv_clipboard(session, text, Int32(text.utf8.count),
                                  bytes.bindMemory(to: CChar.self).baseAddress, Int32(latin.count))
                }
            case .resize(let width, let height): tsv_resize(session, Int32(clamping: width), Int32(clamping: height))
            case .clipboardFocus(let active, let revision, let fetch):
                focused = active; fileRevision = revision
                if let copy = fileTransfer, copy.revision != revision { cancelFileTransfer(session) }
                tsv_clipboard_focus(session, active, Int64(revision), fetch)
            case .files(let values, let revision, let sending):
                guard (sending ? sendingFiles : receivingFiles), focused,
                      revision == fileRevision, sending || values == remoteFiles,
                      let urls = VNCFileTransfer.fileURLs(values) else { continue }
                cancelFileTransfer(session)
                do {
                    fileSession &+= 128
                    if sending { publishedFiles = [] }
                    fileTransfer = try VNCFileTransfer(urls: urls, revision: revision, upload: sending, id: fileSession)
                    lastFileProgress = 0
                    lastFileActivity = ProcessInfo.processInfo.systemUptime
                    scheduleFileTimeout(fileSession, after: 30)
                } catch {
                    client?.filesReady([], revision: revision, sending: sending, error: String(describing: error))
                }
            case .cancelFiles: cancelFileTransfer(session)
            case .filesTimeout(let id):
                if fileTransfer?.token == id {
                    let left = 30 - (ProcessInfo.processInfo.systemUptime - lastFileActivity)
                    if left <= 0 { failFiles("The remote Mac did not complete the file copy.") }
                    else { scheduleFileTimeout(id, after: left) }
                }

            }
        }
        advanceFiles(session)
    }

    private func copiedFiles(_ urls: [String], revision: Int) {
        guard receivingFiles, fileTransfer?.sending != true,
              VNCFileTransfer.fileURLs(urls) != nil, urls != publishedFiles else { return }
        remoteFiles = urls
        client?.serverFiles(urls, revision: revision)
    }
    private func fileMessage(_ data: Data) {
        guard let copy = fileTransfer, let session = sessionForFiles else { return }
        do {
            let message = try VNCFileMessage(wire: data)
            guard message.session == copy.session else { return }
            lastFileActivity = ProcessInfo.processInfo.systemUptime
            try copy.accept(message)
            if message.kind == 104 || message.kind == 200 {
                let finished = VNCFileMessage(kind: 5, session: message.session).wire
                finished.withUnsafeBytes {
                    _ = tsv_file_message(session, $0.bindMemory(to: UInt8.self).baseAddress, finished.count, copy.sending)
                }
            }
            if let urls = copy.ready {
                if copy.sending {
                    publishedFiles = urls
                    let joined = urls.joined(separator: "\n")
                    tsv_clipboard_files(session, joined, joined.utf8.count)
                }
                client?.filesReady(urls, revision: copy.revision, sending: copy.sending, error: "")
                fileTransfer = nil
            } else { advanceFiles(session) }
        } catch { failFiles(String(describing: error)) }
    }
    private func advanceFiles(_ session: OpaquePointer) {
        guard let copy = fileTransfer else { return }
        do {
            if let packet = try copy.next() {
                let okay = packet.withUnsafeBytes {
                    tsv_file_message(session, $0.bindMemory(to: UInt8.self).baseAddress, packet.count, copy.sending)
                }
                guard okay else { throw VNCFileError.changed }
                lastFileActivity = ProcessInfo.processInfo.systemUptime
                if !copy.waitingForUploadReply, copy.sending { lock.withLock { wake() } }
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastFileProgress >= 0.1 {
                lastFileProgress = now
                client?.fileProgress(Int64(copy.copied), total: Int64(copy.total), revision: copy.revision, sending: copy.sending)
            }
        } catch { failFiles(String(describing: error)) }
    }
    private func cancelFileTransfer(_ session: OpaquePointer) {
        if let copy = fileTransfer {
            let packet = VNCFileMessage(kind: 5, session: copy.session).wire
            packet.withUnsafeBytes {
                _ = tsv_file_message(session, $0.bindMemory(to: UInt8.self).baseAddress, packet.count, copy.sending)
            }
        }
        fileTransfer = nil
    }
    private func failFiles(_ error: String) {
        guard let copy = fileTransfer else { return }
        client?.filesReady([], revision: copy.revision, sending: copy.sending, error: error)
        if let session = sessionForFiles { cancelFileTransfer(session) }
        else { fileTransfer = nil }
    }
    private func scheduleFileTimeout(_ id: UInt32, after seconds: TimeInterval) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in self?.enqueue(.filesTimeout(id)) }
    }

    private func verify(_ pem: String) -> Bool {
        let answer = CertificateAnswer()
        lock.lock()
        guard !stopped, let connection else { lock.unlock(); return false }
        certificateAnswer = answer
        lock.unlock()
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in answer.give(false) } as? any VNCClientProtocol
        if let proxy { proxy.verifyCertificate(pem) { answer.give($0) } }
        else { answer.give(false) }
        let result = answer.wait()
        lock.withLock { certificateAnswer = nil }
        return result
    }

    private func resize(width: Int, height: Int) -> Bool {
        let stride = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4)
        let properties: [String: Any] = [
            kIOSurfaceWidth as String: width, kIOSurfaceHeight as String: height, kIOSurfaceBytesPerElement as String: 4,
            kIOSurfaceBytesPerRow as String: stride, kIOSurfaceAllocSize as String: stride * height,
            kIOSurfacePixelFormat as String: kCVPixelFormatType_32BGRA
        ]
        guard let made = IOSurfaceCreate(properties as CFDictionary) else { return false }
        surface = made
        client?.showSurface(made, width: width, height: height)
        return true
    }

    private func pixels(_ source: UnsafePointer<UInt8>, stride: Int,
                        x: Int, y: Int, width: Int, height: Int) {
        guard let surface else { return }
        IOSurfaceLock(surface, [], nil)
        defer { IOSurfaceUnlock(surface, [], nil) }
        let destination = IOSurfaceGetBaseAddress(surface)
        let rowBytes = IOSurfaceGetBytesPerRow(surface)
        for row in y..<(y + height) {
            memcpy(destination.advanced(by: row * rowBytes + x * 4),
                   source.advanced(by: row * stride + x * 4), width * 4)
        }
    }
}

private final class CertificateAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var value: Bool?
    func give(_ result: Bool) {
        let first = lock.withLock { () -> Bool in
            guard value == nil else { return false }
            value = result
            return true
        }
        if first { semaphore.signal() }
    }
    func wait() -> Bool {
        semaphore.wait()
        return lock.withLock { value ?? false }
    }
}

private func owner(_ pointer: UnsafeMutableRawPointer?) -> VNCEngine {
    Unmanaged<VNCEngine>.fromOpaque(pointer!).takeUnretainedValue()
}
