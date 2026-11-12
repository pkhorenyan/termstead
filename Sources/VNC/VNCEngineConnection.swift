import Foundation
import IOSurface

@MainActor
final class VNCEngineConnection {
    var onSurface: ((IOSurface, Int, Int) -> Void)?
    var onChange: (() -> Void)?
    var onClipboard: ((String, Int) -> Void)?
    var onCursor: ((Data, Int, Int, Int, Int) -> Void)?
    var onConnected: (() -> Void)?
    var onResizeSupport: ((Bool) -> Void)?
    var onCertificate: ((String, @escaping @Sendable (Bool) -> Void) -> Void)?
    var onDisconnected: ((String, Int) -> Void)?
    private let connection: NSXPCConnection
    private var ended = false

    init() {
        connection = NSXPCConnection(serviceName: VNCService.name)
        connection.remoteObjectInterface = VNCService.engineInterface
        connection.exportedInterface = VNCService.clientInterface
        let receiver = Receiver()
        receiver.owner = self
        connection.exportedObject = receiver
        let stopped: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async { self?.finish("The VNC engine stopped.", code: 1) }
        }
        connection.interruptionHandler = stopped
        connection.invalidationHandler = stopped
        connection.resume()
    }
    private var engine: (any VNCEngineProtocol)? {
        connection.remoteObjectProxyWithErrorHandler { _ in } as? any VNCEngineProtocol
    }
    func connect(_ launch: VNCLaunch, socket: FileHandle) {
        engine?.connect(socket: socket, host: launch.host, user: launch.user, password: launch.password,
                        allowNoAuth: launch.options.allowNoAuth, viewOnly: launch.options.viewOnly,
                        clipboard: launch.options.clipboard && launch.options.sendClipboard,
                        receiveClipboard: launch.options.clipboard && launch.options.receiveClipboard,
                        quality: launch.options.quality == .fast ? 2 : launch.options.quality == .sharp ? 1 : 0,
                        requireTLS: launch.options.security == .tls)
    }
    func key(_ symbol: UInt32, down: Bool) { engine?.key(Int(symbol), down: down) }
    func pointer(x: Int, y: Int, buttons: Int) { engine?.pointer(x: x, y: y, buttons: buttons) }
    func clipboard(_ text: String) { engine?.clipboard(text) }
    func clipboardFocus(_ active: Bool, revision: Int) { engine?.clipboardFocus(active, revision: revision) }
    func resize(width: Int, height: Int) { engine?.resize(width: width, height: height) }
    func close() {
        guard !ended else { return }
        ended = true
        engine?.disconnect()
        connection.invalidate()
    }
    private func finish(_ reason: String, code: Int) {
        guard !ended else { return }
        ended = true
        onDisconnected?(reason, code)
        connection.invalidate()
    }
    private final class Receiver: NSObject, VNCClientProtocol, @unchecked Sendable {
        weak var owner: VNCEngineConnection?
        private func onMain(_ body: @escaping @MainActor (VNCEngineConnection) -> Void) {
            DispatchQueue.main.async { [weak self] in
                guard let owner = self?.owner else { return }
                body(owner)
            }
        }
        func showSurface(_ surface: IOSurface, width: Int, height: Int) {
            let box = SurfaceBox(surface: surface)
            onMain { $0.onSurface?(box.surface, width, height) }
        }
        func surfaceChanged() { onMain { $0.onChange?() } }
        func serverClipboard(_ text: String, revision: Int) { onMain { $0.onClipboard?(text, revision) } }
        func cursorShape(_ rgba: Data, width: Int, height: Int, hotX: Int, hotY: Int) {
            guard width >= 0, height >= 0, width <= 1024, height <= 1024,
                  rgba.count == width * height * 4 else { return }
            onMain { $0.onCursor?(rgba, width, height, hotX, hotY) }
        }
        func connected() { onMain { $0.onConnected?() } }
        func resizeSupport(_ supported: Bool) { onMain { $0.onResizeSupport?(supported) } }
        func verifyCertificate(_ pem: String, reply: @escaping @Sendable (Bool) -> Void) {
            DispatchQueue.main.async { [weak self] in
                guard let owner = self?.owner, !owner.ended, let question = owner.onCertificate else { return reply(false) }
                question(pem, reply)
            }
        }
        func disconnected(reason: String, code: Int) { onMain { $0.finish(reason, code: code) } }
    }
}
private struct SurfaceBox: @unchecked Sendable { let surface: IOSurface }
