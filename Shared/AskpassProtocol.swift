import Foundation

/// What `termstead-askpass` and the app say to each other over the connection's
/// Unix socket: one JSON line each way. Compiled into both targets.
enum AskpassProtocol {
    static let socketVariable = "TERMSTEAD_ASKPASS_SOCKET"
    static let tokenVariable = "TERMSTEAD_ASKPASS_TOKEN"

    struct Request: Codable, Sendable {
        var token: String
        var prompt: String
    }

    struct Reply: Codable, Sendable {
        /// `nil` means "ask the user in the terminal".
        var secret: String?
    }

    /// Whether what ssh is asking for is something to hide while it is typed.
    /// Everything is hidden except the questions that are plainly not secrets,
    /// so an unfamiliar prompt errs on the side of not echoing.
    static func isConfirmation(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        return lower.contains("(yes/no") || lower.contains("continue connecting")
    }

    /// `sockaddr_un` for `path`, or `nil` if it does not fit (104 bytes on macOS).
    static func address(for path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }
}
