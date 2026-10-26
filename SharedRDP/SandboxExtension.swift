import Darwin

/// Read-write access to one folder for the RDP engine, which is sandboxed
/// and can open nothing of its own. The app, which is not, issues a token
/// for the folder a session shares; the engine consumes it for as long as
/// the session lasts.
///
/// libsandbox's extension calls are not public API, but they are what NSXPC,
/// WebKit and Chromium use for this. A URL sent over XPC was tried first: it
/// gave the engine no access at all — reading worked in tests only through
/// the read-only exception Xcode adds to a Debug build — and writing was
/// refused. If these calls go away, sharing a folder stops working and
/// nothing else does.
enum SandboxExtension {
    private static var all: UnsafeMutableRawPointer? { UnsafeMutableRawPointer(bitPattern: -2) } // RTLD_DEFAULT
    private typealias Issue = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UInt32)
        -> UnsafeMutablePointer<CChar>?
    private typealias Consume = @convention(c) (UnsafePointer<CChar>) -> Int64
    private typealias Release = @convention(c) (Int64) -> Int32

    /// A token for reading and writing in `path`; `nil` when none is issued.
    static func issue(readWrite path: String) -> String? {
        guard let symbol = dlsym(all, "sandbox_extension_issue_file") else { return nil }
        let issue = unsafeBitCast(symbol, to: Issue.self)
        guard let token = issue("com.apple.app-sandbox.read-write", path, 0) else { return nil }
        defer { free(token) }
        return String(cString: token)
    }

    /// Takes a token up; the handle gives it back (`release`). `nil` when
    /// it is not accepted.
    static func consume(_ token: String) -> Int64? {
        guard let symbol = dlsym(all, "sandbox_extension_consume") else { return nil }
        let handle = unsafeBitCast(symbol, to: Consume.self)(token)
        return handle >= 0 ? handle : nil
    }

    static func release(_ handle: Int64) {
        guard let symbol = dlsym(all, "sandbox_extension_release") else { return }
        _ = unsafeBitCast(symbol, to: Release.self)(handle)
    }
}
