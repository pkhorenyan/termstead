import Foundation
import IOSurface

enum VNCService {
    static let name = "com.pavelkhorenyan.Termstead.vnc"
    static var engineInterface: NSXPCInterface {
        let i = NSXPCInterface(with: (any VNCEngineProtocol).self)
        for selector in [#selector((any VNCEngineProtocol).uploadFiles(_:revision:)),
                         #selector((any VNCEngineProtocol).downloadFiles(_:revision:))] {
            i.setClasses(NSSet(array: [NSArray.self, NSString.self]) as! Set<AnyHashable>, for: selector, argumentIndex: 0, ofReply: false)
        }
        return i
    }
    static var clientInterface: NSXPCInterface {
        let i = NSXPCInterface(with: (any VNCClientProtocol).self)
        for selector in [#selector((any VNCClientProtocol).serverFiles(_:revision:)),
                         #selector((any VNCClientProtocol).filesReady(_:revision:sending:error:))] {
            i.setClasses(NSSet(array: [NSArray.self, NSString.self]) as! Set<AnyHashable>, for: selector, argumentIndex: 0, ofReply: false)
        }
        return i
    }
}

@objc protocol VNCEngineProtocol {
    func connect(socket: FileHandle, host: String, user: String, password: String, allowNoAuth: Bool,
                 viewOnly: Bool, clipboard: Bool, receiveClipboard: Bool, quality: Int, requireTLS: Bool)
    func key(_ keysym: Int, down: Bool)
    func pointer(x: Int, y: Int, buttons: Int)
    func clipboard(_ text: String)
    func clipboardFocus(_ active: Bool, revision: Int, fetch: Bool)
    func uploadFiles(_ urls: [String], revision: Int)
    func downloadFiles(_ urls: [String], revision: Int)
    func cancelFiles()
    func resize(width: Int, height: Int)
    func disconnect()
}

@objc protocol VNCClientProtocol {
    func showSurface(_ surface: IOSurface, width: Int, height: Int)
    func surfaceChanged()
    func serverClipboard(_ text: String, revision: Int)
    func fileTransferSupport(_ supported: Bool)
    func serverFiles(_ urls: [String], revision: Int)
    func fileProgress(_ copied: Int64, total: Int64, revision: Int, sending: Bool)
    func filesReady(_ urls: [String], revision: Int, sending: Bool, error: String)
    /// Straight-alpha RGBA; zero dimensions mean an invisible cursor.
    func cursorShape(_ rgba: Data, width: Int, height: Int, hotX: Int, hotY: Int)
    func connected()
    func resizeSupport(_ supported: Bool)
    func verifyCertificate(_ pem: String, reply: @escaping @Sendable (Bool) -> Void)
    /// Codes: 1 transport/protocol, 2 password rejected, 3 ARD needs a user,
    /// 4 certificate rejected (never automatically retry).
    func disconnected(reason: String, code: Int)
}
