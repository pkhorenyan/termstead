import CryptoKit
import Darwin
import Foundation

/// Remembers private upload folders until the server confirms their removal.
/// Locks keep another tab or app instance from cleaning an active upload.
struct SFTPStageJournal: Equatable, Sendable {
    static let prefix = ".termstead-transfer-"
    private static let defaultDirectory: URL = {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("termstead-test-stages-\(ProcessInfo.processInfo.processIdentifier)")
        }
        return SessionPersistence.defaultURL.deletingLastPathComponent()
            .appendingPathComponent("SFTP Transfer Cleanup")
    }()

    private let directory: URL

    init(config: String, directory: URL? = nil) {
        let scope = SHA256.hash(data: Data(config.utf8)).map { String(format: "%02x", $0) }.joined()
        self.directory = (directory ?? Self.defaultDirectory).appendingPathComponent(scope, isDirectory: true)
    }

    struct Record: Sendable {
        let url: URL
        let handle: FileHandle

        func remove() { try? FileManager.default.removeItem(at: url) }
        func close() { try? handle.close() }
    }

    func register(_ stage: String) throws -> Record {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(RemotePath.name(of: stage))
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Self.posixError() }
        let record = Record(url: url, handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
        do {
            guard flock(descriptor, LOCK_EX) == 0 else { throw Self.posixError() }
            try record.handle.write(contentsOf: Data(stage.utf8))
            try record.handle.synchronize()
            return record
        } catch {
            record.remove()
            record.close()
            throw error
        }
    }

    func recover(using client: SFTPClient) async {
        let records = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in records {
            guard !Task.isCancelled else { return }
            let name = url.lastPathComponent
            guard name.hasPrefix(Self.prefix), UUID(uuidString: String(name.dropFirst(Self.prefix.count))) != nil else { continue }
            let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { continue }
            let record = Record(url: url, handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
            defer { record.close() }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0,
                  let data = try? record.handle.read(upToCount: 16_384),
                  let stage = String(data: data, encoding: .utf8),
                  stage.hasPrefix("/"), !stage.utf8.contains(0), RemotePath.name(of: stage) == name else { continue }
            do {
                let parent = RemotePath.parent(of: stage)
                let listing = try await client.list(parent)
                guard listing.path == parent else { continue }
                if listing.files.contains(where: { $0.path == stage }) {
                    try await client.discardTransferStage(stage)
                }
                record.remove()
            } catch {
                // The next login can try again if the server was unreachable.
            }
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
