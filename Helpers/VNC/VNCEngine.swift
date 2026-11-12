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
        case key(UInt32, Bool), pointer(Int, Int, Int), clipboard(String)
    }
    private var inputs: [Input] = []
    // Worker-thread state only.
    private var surface: IOSurfaceRef?

    init(connection: NSXPCConnection) { self.connection = connection }
    private var client: (any VNCClientProtocol)? {
        connection?.remoteObjectProxyWithErrorHandler { _ in } as? any VNCClientProtocol
    }

    func connect(socket: FileHandle, user: String, password: String, allowNoAuth: Bool,
                 viewOnly: Bool, clipboard: Bool) {
        lock.lock()
        guard !started, !stopped else { lock.unlock(); return }
        started = true
        let fd = dup(socket.fileDescriptor)
        descriptor = fd
        lock.unlock()
        let thread = Thread { [self] in
            run(socket: fd, user: user, password: password, allowNoAuth: allowNoAuth,
                viewOnly: viewOnly, clipboard: clipboard)
        }
        thread.name = "LibVNCClient"
        thread.stackSize = 4 << 20
        thread.start()
    }

    private func enqueue(_ input: Input) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
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
    }

    func key(_ keysym: Int, down: Bool) { enqueue(.key(UInt32(clamping: keysym), down)) }
    func pointer(x: Int, y: Int, buttons: Int) {
        enqueue(.pointer(min(max(x, 0), 8191), min(max(y, 0), 8191), buttons & 255))
    }
    func clipboard(_ text: String) {
        guard text.utf8.count <= 1_048_576 else { return }
        enqueue(.clipboard(text))
    }
    func disconnect() {
        lock.lock()
        stopped = true
        inputs.removeAll()
        if descriptor >= 0 { shutdown(descriptor, SHUT_RDWR) }
        lock.unlock()
    }

    private func run(socket: Int32, user: String, password: String, allowNoAuth: Bool,
                     viewOnly: Bool, clipboard: Bool) {
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
            clipboard: { context, bytes, length, utf8 in
                autoreleasepool {
                    guard let bytes, length >= 0, length <= 1_048_576 else { return }
                    let data = Data(bytes: bytes, count: Int(length))
                    if let text = String(data: data, encoding: utf8 ? .utf8 : .isoLatin1) {
                        owner(context).client?.serverClipboard(text)
                    }
                }
            },
            cursor: { context, bytes, width, height, hotX, hotY in
                autoreleasepool {
                    let data = bytes.map { Data(bytes: $0, count: Int(width) * Int(height) * 4) } ?? Data()
                    owner(context).client?.cursorShape(data, width: Int(width), height: Int(height),
                                                       hotX: Int(hotX), hotY: Int(hotY))
                }
            })
        guard socket >= 0,
              let session = tsv_new(socket, user, password, allowNoAuth, viewOnly, clipboard, callbacks) else {
            lock.withLock { descriptor = -1 }
            client?.disconnected(reason: "Could not create the VNC connection.", code: 1)
            return
        }
        defer {
            lock.withLock { descriptor = -1 }
            tsv_free(session)
            surface = nil
        }
        if lock.withLock({ stopped }) { return }
        guard tsv_connect(session) else {
            let code = Int(tsv_error_code(session))
            let detail = String(cString: tsv_error(session)).trimmingCharacters(in: .whitespacesAndNewlines)
            let reason: String
            switch code {
            case 2: reason = "The VNC server refused the password."
            case 3: reason = "Apple Remote Desktop authentication needs a user name and password."
            default:
                reason = "Could not complete the VNC handshake. \(detail) Supported authentication: VNC password or Apple Remote Desktop; TLS-only servers are not supported yet."
            }
            if !lock.withLock({ stopped }) { client?.disconnected(reason: reason, code: code) }
            return
        }
        client?.connected()
        while !lock.withLock({ stopped }) {
            let pending = lock.withLock { () -> [Input] in
                defer { inputs.removeAll(keepingCapacity: true) }
                return inputs
            }
            for event in pending {
                switch event {
                case .key(let symbol, let down): tsv_key(session, symbol, down)
                case .pointer(let x, let y, let buttons):
                    tsv_pointer(session, Int32(x), Int32(y), Int32(buttons))
                case .clipboard(let text):
                    let latin = text.data(using: .isoLatin1, allowLossyConversion: true) ?? Data()
                    latin.withUnsafeBytes { bytes in
                        tsv_clipboard(session, text, Int32(text.utf8.count),
                                      bytes.bindMemory(to: CChar.self).baseAddress, Int32(latin.count))
                    }
                }
            }
            if tsv_poll(session) < 0 { break }
        }
        if !lock.withLock({ stopped }) {
            client?.disconnected(reason: "The VNC connection closed.", code: 1)
        }
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

private func owner(_ pointer: UnsafeMutableRawPointer?) -> VNCEngine {
    Unmanaged<VNCEngine>.fromOpaque(pointer!).takeUnretainedValue()
}
