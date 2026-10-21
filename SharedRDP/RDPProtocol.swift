import Foundation
import IOSurface

/// What passes between Termstead and its RDP engine, `TermsteadRDP.xpc`.
///
/// The engine is FreeRDP in a process of its own, sandboxed and with no
/// network: the app opens the connection (directly, or through an ssh
/// tunnel's Unix socket) and hands over the socket. A crash or an exploit in
/// FreeRDP's C code then takes down the remote desktops, not the app and
/// every ssh session in it, and an exploit has no network to reach. The desktop is drawn into an IOSurface the two
/// processes share, so a frame is never copied: the engine says which part
/// changed, and the app's layer shows it.
enum RDPService {
    /// The XPC service's bundle identifier.
    static let name = "com.pavelkhorenyan.Termstead.rdp"

    static var engineInterface: NSXPCInterface { NSXPCInterface(with: (any RDPEngineProtocol).self) }
    static var clientInterface: NSXPCInterface { NSXPCInterface(with: (any RDPClientProtocol).self) }
}

/// Everything one connection logs in and draws with.
@objc(TermsteadRDPConnectSettings)
final class RDPConnectSettings: NSObject, NSSecureCoding, @unchecked Sendable {
    static let supportsSecureCoding = true

    /// The server's name as the session has it: what TLS and NTLM check,
    /// whatever the socket was opened to.
    @objc var host = ""
    @objc var port = 3389
    @objc var user = ""
    @objc var domain = ""
    @objc var password = ""
    /// The desktop in pixels.
    @objc var width = 1280
    @objc var height = 800
    /// Windows' scale for its own UI, in percent: 200 on a Retina display
    /// with sharp text, so everything keeps its size.
    @objc var desktopScale = 100
    /// Windows keyboard layout id (0x409 US English, 0x419 Russian).
    @objc var keyboardLayout = 0x409
    @objc var clipboard = true
    @objc var sound = true

    override init() { super.init() }

    func encode(with coder: NSCoder) {
        coder.encode(host, forKey: "host")
        coder.encode(port, forKey: "port")
        coder.encode(user, forKey: "user")
        coder.encode(domain, forKey: "domain")
        coder.encode(password, forKey: "password")
        coder.encode(width, forKey: "width")
        coder.encode(height, forKey: "height")
        coder.encode(desktopScale, forKey: "desktopScale")
        coder.encode(keyboardLayout, forKey: "keyboardLayout")
        coder.encode(clipboard, forKey: "clipboard")
        coder.encode(sound, forKey: "sound")
    }

    init?(coder: NSCoder) {
        func string(_ key: String) -> String {
            coder.decodeObject(of: NSString.self, forKey: key) as String? ?? ""
        }
        host = string("host")
        port = coder.decodeInteger(forKey: "port")
        user = string("user")
        domain = string("domain")
        password = string("password")
        width = coder.decodeInteger(forKey: "width")
        height = coder.decodeInteger(forKey: "height")
        desktopScale = coder.decodeInteger(forKey: "desktopScale")
        keyboardLayout = coder.decodeInteger(forKey: "keyboardLayout")
        clipboard = coder.decodeBool(forKey: "clipboard")
        sound = coder.decodeBool(forKey: "sound")
        super.init()
    }
}

/// The app asks the engine. One engine per XPC connection, one connection
/// per tab.
@objc protocol RDPEngineProtocol {
    /// Logs in over `socket`, already connected to the server. The outcome
    /// comes back as `connected()` or `disconnected(reason:)`.
    func connect(_ settings: RDPConnectSettings, socket: FileHandle)
    /// A key by its scan code, as a PC keyboard sends it; `extended` for
    /// the keys that send 0xE0 first (arrows, right Ctrl and Alt, …).
    func key(_ scancode: Int, extended: Bool, down: Bool)
    /// A character with no key behind it, by its UTF-16 unit.
    func unicode(_ character: Int, down: Bool)
    /// The lock keys as they are here: on taking the keyboard, so Caps Lock
    /// toggled in another app does not end up the other way round there.
    func synchronize(capsLock: Bool)
    /// The pointer, in desktop pixels, with FreeRDP's PTR_FLAGS_*.
    func mouse(x: Int, y: Int, flags: Int)
    /// A new size for the desktop, through the Display Control channel.
    func resize(width: Int, height: Int, desktopScale: Int)
    /// Text copied on this Mac, offered to the server's clipboard.
    func clipboard(_ text: String)
    func disconnect()
}

/// The engine tells the app. Called on an XPC queue, not the main thread.
@objc protocol RDPClientProtocol {
    /// A new surface to show: at login, and whenever the desktop's size
    /// changes. Its pixels are BGRA, `width` × `height`.
    func showSurface(_ surface: IOSurface, width: Int, height: Int)
    /// Part of the surface changed, in its pixels, top-left origin.
    func surfaceChanged(x: Int, y: Int, width: Int, height: Int)
    /// The server's certificate chain, as PEM, for the app to decide on:
    /// trusted by macOS for this host, trusted before, or ask the user.
    func verifyCertificate(pem: String, host: String, port: Int, reply: @escaping @Sendable (Bool) -> Void)
    /// Text copied on the server.
    func serverClipboard(_ text: String)
    func connected()
    /// The session ended; `reason` is empty when it ended as asked.
    func disconnected(reason: String)
}
