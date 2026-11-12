import Foundation
import IOSurface

enum VNCService {
    static let name = "com.pavelkhorenyan.Termstead.vnc"
    static var engineInterface: NSXPCInterface { NSXPCInterface(with: (any VNCEngineProtocol).self) }
    static var clientInterface: NSXPCInterface { NSXPCInterface(with: (any VNCClientProtocol).self) }
}

@objc protocol VNCEngineProtocol {
    func connect(socket: FileHandle, user: String, password: String, allowNoAuth: Bool,
                 viewOnly: Bool, clipboard: Bool)
    func key(_ keysym: Int, down: Bool)
    func pointer(x: Int, y: Int, buttons: Int)
    func clipboard(_ text: String)
    func disconnect()
}

@objc protocol VNCClientProtocol {
    func showSurface(_ surface: IOSurface, width: Int, height: Int)
    func surfaceChanged()
    func serverClipboard(_ text: String)
    func connected()
    /// Codes: 1 transport/protocol, 2 password rejected, 3 ARD needs a user.
    func disconnected(reason: String, code: Int)
}
