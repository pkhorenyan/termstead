import Foundation
import IOSurface

enum VNCService {
    static let name = "com.pavelkhorenyan.Termstead.vnc"
    static var engineInterface: NSXPCInterface { NSXPCInterface(with: (any VNCEngineProtocol).self) }
    static var clientInterface: NSXPCInterface { NSXPCInterface(with: (any VNCClientProtocol).self) }
}

@objc protocol VNCEngineProtocol {
    func connect(socket: FileHandle, host: String, user: String, password: String, allowNoAuth: Bool,
                 viewOnly: Bool, clipboard: Bool, receiveClipboard: Bool, quality: Int, requireTLS: Bool)
    func key(_ keysym: Int, down: Bool)
    func pointer(x: Int, y: Int, buttons: Int)
    func clipboard(_ text: String)
    func clipboardFocus(_ active: Bool, revision: Int, fetch: Bool)
    func resize(width: Int, height: Int)
    func disconnect()
}

@objc protocol VNCClientProtocol {
    func showSurface(_ surface: IOSurface, width: Int, height: Int)
    func surfaceChanged()
    func serverClipboard(_ text: String, revision: Int)
    /// Straight-alpha RGBA; zero dimensions mean an invisible cursor.
    func cursorShape(_ rgba: Data, width: Int, height: Int, hotX: Int, hotY: Int)
    func connected()
    func resizeSupport(_ supported: Bool)
    func verifyCertificate(_ pem: String, reply: @escaping @Sendable (Bool) -> Void)
    /// Codes: 1 transport/protocol, 2 password rejected, 3 ARD needs a user,
    /// 4 certificate rejected (never automatically retry).
    func disconnected(reason: String, code: Int)
}
