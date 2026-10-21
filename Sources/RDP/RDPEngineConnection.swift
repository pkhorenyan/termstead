import Foundation
import IOSurface

/// The app's end of one remote desktop: an XPC connection to TermsteadRDP.xpc,
/// whose one process holds every desktop. What the engine says arrives on the
/// main actor, in the order it said it.
@MainActor
final class RDPEngineConnection {
    /// A new surface to show, and its size in pixels.
    var onSurface: ((IOSurface, Int, Int) -> Void)?
    /// Part of the surface changed, in its pixels, top-left origin.
    var onChange: ((CGRect) -> Void)?
    /// The server's certificate chain as PEM; answer whether to go on.
    var onVerifyCertificate: ((_ pem: String, _ host: String, _ port: Int, _ reply: @escaping @Sendable (Bool) -> Void) -> Void)?
    /// The server wants a login the session lacks; answer with what the
    /// user typed, or `nil` to give up.
    var onAskCredentials: ((_ user: String, _ domain: String,
                            _ reply: @escaping @Sendable (RDPLogin?) -> Void) -> Void)?
    var onServerClipboard: ((String) -> Void)?
    /// Files copied on the server; their contents come through `fileData`.
    var onServerFiles: (([RDPClipboardFile]) -> Void)?
    /// A pointer shape from the server, under its id; and one it dropped.
    var onPointerShape: ((Int, RDPPointer.Shape) -> Void)?
    var onPointerForgotten: ((Int) -> Void)?
    /// The pointer to show: a shape's id, 0 for the arrow, -1 for none.
    var onShowPointer: ((Int) -> Void)?
    var onConnected: (() -> Void)?
    /// Once, however it ended: empty when asked to, else why, with
    /// FreeRDP's error code (0 when there is none).
    var onDisconnected: ((String, Int) -> Void)?

    private let connection: NSXPCConnection
    private var didEnd = false
    /// The Mac's files on offer, read for the server off the main thread.
    private let offeredFiles = RDPOfferedFiles()

    init() {
        connection = NSXPCConnection(serviceName: RDPService.name)
        connection.remoteObjectInterface = RDPService.engineInterface
        connection.exportedInterface = RDPService.clientInterface
        let receiver = Receiver(files: offeredFiles)
        connection.exportedObject = receiver
        receiver.owner = self
        // The engine's process died: a crash in FreeRDP ends every desktop.
        let ended: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.ended("The RDP engine stopped.", code: 0) }
            }
        }
        connection.interruptionHandler = ended
        connection.invalidationHandler = ended
        connection.resume()
    }

    private var engine: (any RDPEngineProtocol)? {
        connection.remoteObjectProxyWithErrorHandler { _ in } as? any RDPEngineProtocol
    }

    func connect(_ settings: RDPConnectSettings, socket: FileHandle) {
        engine?.connect(settings, socket: socket)
    }

    func key(_ scancode: Int, extended: Bool, down: Bool) {
        engine?.key(scancode, extended: extended, down: down)
    }

    func unicode(_ character: Int, down: Bool) {
        engine?.unicode(character, down: down)
    }

    func synchronize(capsLock: Bool) {
        engine?.synchronize(capsLock: capsLock)
    }

    func mouse(x: Int, y: Int, flags: Int) {
        engine?.mouse(x: x, y: y, flags: flags)
    }

    func resize(width: Int, height: Int, desktopScale: Int) {
        engine?.resize(width: width, height: height, desktopScale: desktopScale)
    }

    /// Offers text and files copied on the Mac; both `nil` withdraws the
    /// offer.
    func clipboard(_ text: String?, files: RDPLocalFiles? = nil) {
        offeredFiles.current = files
        engine?.clipboard(text, files: files?.clipboardFiles ?? [])
    }

    /// Part of a file the server copied; `nil` when it could not be had.
    func fileData(index: Int, offset: Int64, length: Int, sizeOnly: Bool) async -> Data? {
        guard let engine else { return nil }
        return await withCheckedContinuation { continuation in
            let once = Once(continuation)
            // The engine's process gone, the answer never comes: the error
            // handler gives it instead.
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.resume(nil) } as? any RDPEngineProtocol
            (proxy ?? engine).fileData(index: index, offset: offset, length: length, sizeOnly: sizeOnly) {
                once.resume($0)
            }
        }
    }

    /// Ends the session and the engine's process with it.
    func close() {
        engine?.disconnect()
        didEnd = true
        connection.invalidate()
    }

    fileprivate func ended(_ reason: String, code: Int) {
        guard !didEnd else { return }
        didEnd = true
        onDisconnected?(reason, code)
        connection.invalidate()
    }

    /// Receives the engine's calls on XPC's queue and hands them to the main
    /// queue — not to `Task`s, which could run out of order: a surface
    /// must arrive before the changes drawn into it.
    private final class Receiver: NSObject, RDPClientProtocol, @unchecked Sendable {
        weak var owner: RDPEngineConnection?
        private let files: RDPOfferedFiles

        init(files: RDPOfferedFiles) {
            self.files = files
        }

        private func onMain(_ body: @escaping @MainActor (RDPEngineConnection) -> Void) {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let owner = self?.owner else { return }
                    body(owner)
                }
            }
        }

        func showSurface(_ surface: IOSurface, width: Int, height: Int) {
            let box = SurfaceBox(surface: surface)
            onMain { $0.onSurface?(box.surface, width, height) }
        }

        func surfaceChanged(x: Int, y: Int, width: Int, height: Int) {
            onMain { $0.onChange?(CGRect(x: x, y: y, width: width, height: height)) }
        }

        func verifyCertificate(pem: String, host: String, port: Int, reply: @escaping @Sendable (Bool) -> Void) {
            onMain { owner in
                guard let ask = owner.onVerifyCertificate else { return reply(false) }
                ask(pem, host, port, reply)
            }
        }

        func askCredentials(user: String, domain: String,
                            reply: @escaping @Sendable (Bool, String, String, String) -> Void) {
            onMain { owner in
                guard let ask = owner.onAskCredentials else { return reply(false, "", "", "") }
                ask(user, domain) { login in
                    if let login {
                        reply(true, login.user, login.domain, login.password)
                    } else {
                        reply(false, "", "", "")
                    }
                }
            }
        }

        func serverClipboard(_ text: String) {
            onMain { $0.onServerClipboard?(text) }
        }

        func serverFiles(_ list: [RDPClipboardFile]) {
            onMain { $0.onServerFiles?(list) }
        }

        func readFile(index: Int, offset: Int64, length: Int, reply: @escaping @Sendable (Data?) -> Void) {
            let current = files.current
            DispatchQueue.global(qos: .userInitiated).async {
                reply(current?.read(index: index, offset: offset, length: length))
            }
        }

        func pointerShape(id: Int, rgba: Data, width: Int, height: Int, hotX: Int, hotY: Int) {
            guard let shape = RDPPointer.Shape(rgba: rgba, width: width, height: height, hotX: hotX, hotY: hotY)
            else { return }
            onMain { $0.onPointerShape?(id, shape) }
        }

        func pointerForgotten(id: Int) {
            onMain { $0.onPointerForgotten?(id) }
        }

        func showPointer(id: Int) {
            onMain { $0.onShowPointer?(id) }
        }

        func connected() {
            onMain { $0.onConnected?() }
        }

        func disconnected(reason: String, code: Int) {
            onMain { $0.ended(reason, code: code) }
        }
    }
}

/// An IOSurface handed from XPC's queue to the main one. The surface itself
/// is shared memory, safe to pass along; the type just does not say so.
private struct SurfaceBox: @unchecked Sendable {
    let surface: IOSurface
}

/// A continuation resumed once, whichever answer comes first.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?

    init(_ continuation: CheckedContinuation<Data?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Data?) {
        let taken = lock.withLock { () -> CheckedContinuation<Data?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        taken?.resume(returning: value)
    }
}

/// A user name, domain and password typed into the tab.
struct RDPLogin: Equatable, Sendable {
    var user: String
    var domain: String
    var password: String
}
