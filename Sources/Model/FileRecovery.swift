import Foundation

enum FileRecovery {
    /// Unique names keep separate failures from replacing an earlier recovery
    /// copy. Finish the backup before permitting an atomic replacement.
    @discardableResult
    static func backup(_ data: Data, from url: URL, reason: String) throws -> URL {
        let target = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).\(reason)-\(UUID().uuidString)")
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return target
    }

    static func isMissing(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain
            && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code)
    }
}
