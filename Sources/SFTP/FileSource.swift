import AppKit
import Darwin

/// Where the Files panel's files are: a server over SFTP, or this Mac for a
/// local terminal. Paths are absolute, `/` between folders, either way.
protocol FileSource: Sendable {
    /// This Mac's own disk: deleting moves to the Trash, and a file opens
    /// where it is instead of as a copy sent back on save.
    var isLocal: Bool { get }
    func home() async throws -> String
    /// Lists `path` and returns it resolved — through symlinks — with its entries.
    func list(_ path: String) async throws -> (path: String, files: [RemoteFile])
    /// Whether `path` is a directory, following symlinks.
    func isDirectory(_ path: String) async -> Bool
    func download(_ remote: String, recursive: Bool, to localDirectory: URL, as name: String) async throws
    func upload(_ local: URL, to remoteDirectory: String) async throws
    /// Writes a local file over a remote one, for Open and Edit.
    func replace(_ remote: String, with local: URL) async throws
    func makeDirectory(_ path: String) async throws
    func rename(_ path: String, to newPath: String) async throws
    func removeFile(_ path: String) async throws
    func removeDirectory(_ path: String) async throws
    /// The folder the tab's shell is in, for "follow the terminal".
    func terminalDirectory() async -> String?
}

extension SFTPClient: FileSource {
    var isLocal: Bool { false }
}

/// A local terminal's files: this Mac's disk, through `FileManager`.
struct LocalFiles: FileSource {
    /// The tab's shell, and its terminal, for "follow the terminal".
    var shellPID: pid_t
    var terminalFD: Int32

    var isLocal: Bool { true }

    func home() async throws -> String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    func list(_ path: String) async throws -> (path: String, files: [RemoteFile]) {
        try await Self.offMain {
            // realpath, as the kernel names the shell's folder: URL's own
            // resolving drops `/private` from `/private/var`, and following
            // the terminal would see a move on every Return.
            let resolved = URL(fileURLWithPath: Self.realPath(path) ?? path)
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                                          .contentModificationDateKey]
            let urls: [URL]
            do {
                urls = try FileManager.default.contentsOfDirectory(at: resolved, includingPropertiesForKeys: keys)
            } catch {
                throw SFTPError.failed(Self.message(error, path: resolved.path))
            }
            let files = urls.map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
                let kind: RemoteFile.Kind = values?.isSymbolicLink == true ? .symlink
                    : values?.isDirectory == true ? .directory : .file
                let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
                return RemoteFile(name: url.lastPathComponent,
                                  path: RemotePath.join(resolved.path, url.lastPathComponent),
                                  kind: kind, size: Int64(values?.fileSize ?? 0),
                                  modified: values?.contentModificationDate,
                                  permissions: Self.permissions(mode),
                                  owner: attributes[.ownerAccountName] as? String ?? "",
                                  group: attributes[.groupOwnerAccountName] as? String ?? "")
            }
            return (resolved.path, files)
        }
    }

    func isDirectory(_ path: String) async -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
    }

    func download(_ remote: String, recursive: Bool, to localDirectory: URL, as name: String) async throws {
        try await copy(URL(fileURLWithPath: remote), to: localDirectory.appendingPathComponent(name))
    }

    func upload(_ local: URL, to remoteDirectory: String) async throws {
        try await copy(local, to: URL(fileURLWithPath: remoteDirectory).appendingPathComponent(local.lastPathComponent))
    }

    func replace(_ remote: String, with local: URL) async throws {
        // Never called: a local file is edited where it is.
        try await Self.offMain {
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: remote), withItemAt: local)
        }
    }

    func makeDirectory(_ path: String) async throws {
        try await Self.offMain {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        }
    }

    func rename(_ path: String, to newPath: String) async throws {
        try await Self.offMain { try FileManager.default.moveItem(atPath: path, toPath: newPath) }
    }

    /// To the Trash, as Finder does: on this Mac a delete can be taken back.
    func removeFile(_ path: String) async throws {
        try await Self.offMain { try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) }
    }

    func removeDirectory(_ path: String) async throws {
        try await removeFile(path)
    }

    /// The working folder of what runs in the terminal — the shell, or a
    /// shell started from it (`bash`, `sudo -s` aside: another user's process
    /// tells nothing). macOS says it directly; no prompt has to be read.
    func terminalDirectory() async -> String? {
        let foreground = terminalFD >= 0 ? tcgetpgrp(terminalFD) : -1
        return Self.workingDirectory(of: foreground > 0 ? foreground : shellPID)
            ?? Self.workingDirectory(of: shellPID)
    }

    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.hasPrefix("/") ? path : nil
    }

    private func copy(_ source: URL, to target: URL) async throws {
        try await Self.offMain {
            do {
                try FileManager.default.copyItem(at: source, to: target)
            } catch {
                throw SFTPError.failed(Self.message(error, path: source.path))
            }
        }
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `rwxr-xr-x`, as `ls` writes it.
    static func permissions(_ mode: UInt16) -> String {
        let letters: [Character] = ["r", "w", "x"]
        return String((0..<9).map { bit in
            mode & (1 << (8 - bit)) != 0 ? letters[bit % 3] : "-"
        })
    }

    private static func message(_ error: any Error, path: String) -> String {
        let reason = (error as NSError).localizedFailureReason ?? error.localizedDescription
        return "\(RemotePath.name(of: path)): \(reason)"
    }

    /// A big folder or a big copy must not hold up the main thread, nor a
    /// thread of Swift's shared pool (`BlockingWork`).
    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await BlockingWork.run(work)
    }
}
