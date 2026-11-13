import Foundation

/// Worker-owned copy state. One call produces at most one 64 KB network write,
/// so pointer/keyboard events get serviced between file blocks.
final class VNCFileUpload {
    struct Entry {
        var url: URL
        var name: String
        var level: Int
        var directory: Bool
        var size: UInt64
        var resource: UInt64
        var mode: UInt16
        var modified: TimeInterval
    }
    let session: UInt32
    let revision: Int
    let remoteURLs: [String]
    let total: UInt64
    private(set) var copied: UInt64 = 0
    private(set) var awaitingReply = false
    private var entries: [Entry]
    private var index = -3
    private var handle: FileHandle?
    private var resourceFork = false
    private var remaining: UInt64 = 0

    init(urls: [URL], session: UInt32, revision: Int) throws {
        guard !urls.isEmpty, urls.count <= 64 else { throw VNCFileError.limit }
        self.session = session; self.revision = revision
        let directory = "Termstead-\(UUID().uuidString)"
        var entries = [Entry(url: .temporaryDirectory, name: directory, level: 0,
                             directory: true, size: 0, resource: 0, mode: 0o700, modified: Date().timeIntervalSince1970)]
        var total: UInt64 = 0, names = Set<String>()
        func add(_ url: URL, level: Int) throws {
            guard level <= 64, entries.count < 10_000 else { throw VNCFileError.limit }
            let name = url.lastPathComponent
            guard url.isFileURL, VNCFileMessage.safeName(name) else { throw VNCFileError.invalid }
            let v = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            guard v.isSymbolicLink != true, v.isDirectory == true || v.isRegularFile == true else {
                throw VNCFileError.unsupported
            }
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let mode = UInt16((attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644) & 0o777
            let size = v.isDirectory == true ? 0 : UInt64(max(v.fileSize ?? 0, 0))
            let fork = url.path + "/..namedfork/rsrc"
            let resource = v.isDirectory == true ? 0 :
                ((try? FileManager.default.attributesOfItem(atPath: fork)[.size] as? NSNumber)?.uint64Value ?? 0)
            guard size <= VNCFileMessage.limit - total,
                  resource <= VNCFileMessage.limit - total - size else { throw VNCFileError.limit }
            total += size + resource
            entries.append(Entry(url: url, name: name, level: level, directory: v.isDirectory == true,
                                 size: size, resource: resource, mode: mode,
                                 modified: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0))
            if v.isDirectory == true {
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    try add(child, level: level + 1)
                }
            }
        }
        for url in urls {
            guard names.insert(url.lastPathComponent.lowercased()).inserted else { throw VNCFileError.invalid }
            try add(url, level: 1)
        }
        self.entries = entries; self.total = total
        remoteURLs = urls.map { URL(fileURLWithPath: "/private/tmp/\(directory)/\($0.lastPathComponent)").absoluteString }
    }
    deinit { try? handle?.close() }

    func next() throws -> Data? {
        guard !awaitingReply else { return nil }
        if index == -3 { index += 1; return try VNCFileMessage.start(session: session, path: "/private/tmp", upload: true).wire }
        if index == -2 {
            index += 1
            var p = Data(repeating: 0, count: 48)
            p.putBE(total, at: 4); p.putBE(total, at: 12)
            p.putBE(UInt64(entries.filter { !$0.directory }.count), at: 20)
            p.putBE(UInt64(entries.filter(\.directory).count), at: 36)
            return VNCFileMessage(kind: 100, session: session, payload: p).wire
        }
        if let handle, remaining > 0 {
            let count = Int(min(remaining, UInt64(VNCFileMessage.chunk)))
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else { throw VNCFileError.changed }
            remaining -= UInt64(count); copied += UInt64(count)
            return VNCFileMessage(kind: 102, session: session, argument: UInt32(count), payload: data).wire
        }
        if let handle {
            try handle.close(); self.handle = nil
            let entry = entries[index]
            if !resourceFork, entry.resource > 0 {
                resourceFork = true; remaining = entry.resource
                self.handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: entry.url.path + "/..namedfork/rsrc"))
                return try next()
            }
        }
        index += 1
        if index == entries.count {
            awaitingReply = true
            return VNCFileMessage(kind: 104, session: session).wire
        }
        let entry = entries[index]
        resourceFork = false
        if !entry.directory {
            let fd = Darwin.open(entry.url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { throw VNCFileError.changed }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size == entry.size else {
                close(fd); throw VNCFileError.changed
            }
            handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); remaining = entry.size
        }
        return try VNCFileMessage.item(session: session, name: entry.name, directory: entry.directory,
                                       level: entry.level, size: entry.size, resource: entry.resource, mode: entry.mode,
                                       modified: entry.modified).wire
    }
}

/// Only creates items under its own freshly-created 0700 staging directory.
/// Remote absolute paths, traversal, links, duplicate names and incomplete
/// forks are rejected before any URLs can reach the user's pasteboard.
final class VNCFileDownloadStream {
    let folder: URL
    private var directories: [URL] = []
    private var permissions: [(URL, UInt16, Date?)] = []
    private var seen = Set<String>()
    private var handle: FileHandle?
    private var resourceHandle: FileHandle?
    private var remaining: UInt64 = 0
    private var resourceRemaining: UInt64 = 0
    private(set) var top: [URL] = []
    private(set) var copied: UInt64 = 0
    private(set) var total: UInt64 = 0
    private(set) var done = false

    init(folder: URL) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
    }
    deinit { try? handle?.close(); try? resourceHandle?.close() }
    func accept(_ message: VNCFileMessage) throws {
        guard !done else { throw VNCFileError.invalid }
        let p = message.payload
        switch message.kind {
        case 100:
            guard p.count == 48, seen.isEmpty else { throw VNCFileError.invalid }
            let value = p.be64(4)
            guard value <= VNCFileMessage.limit else { throw VNCFileError.limit }
            total = value
        case 101:
            try closeItem()
            guard p.count >= 101, seen.count < 10_000 else { throw VNCFileError.invalid }
            let level = Int(p.be16(88)), n = Int(p.be16(96))
            guard level <= 64, level <= directories.count, n > 0, n <= 1023, n <= p.count - 100,
                  let name = String(data: p.subdata(in: 100..<100 + n), encoding: .utf8),
                  VNCFileMessage.safeName(name) else { throw VNCFileError.invalid }
            let type = message.argument >> 24
            guard type == 1 || type == 2 else { throw VNCFileError.unsupported }
            let size = p.be64(38), resource = p.be64(30)
            guard size <= VNCFileMessage.limit - copied, resource <= VNCFileMessage.limit - copied - size else {
                throw VNCFileError.limit
            }
            let parent = level == 0 ? folder : directories[level - 1]
            let url = parent.appendingPathComponent(name)
            guard seen.insert(url.path.lowercased()).inserted else { throw VNCFileError.invalid }
            if level == 0 { top.append(url) }
            directories = Array(directories.prefix(level))
            let seconds = p.be64(54) >> 16
            let modified = seconds > 0 ? Date(timeIntervalSince1970: Double(seconds) - 2_082_844_800) : nil
            permissions.append((url, p.be16(90) & 0o777, modified))
            if type == 2 {
                guard size == 0, resource == 0 else { throw VNCFileError.invalid }
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                         attributes: [.posixPermissions: 0o700])
                directories.append(url)
            } else {
                let fd = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw VNCFileError.invalid }
                handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                remaining = size; resourceRemaining = resource
                if resource > 0 {
                    let resourceFD = Darwin.open(url.path + "/..namedfork/rsrc", O_CREAT | O_WRONLY | O_CLOEXEC, 0o600)
                    guard resourceFD >= 0 else { throw VNCFileError.changed }
                    resourceHandle = FileHandle(fileDescriptor: resourceFD, closeOnDealloc: true)
                }
            }
        case 102:
            guard !p.isEmpty, p.count <= VNCFileMessage.chunk, message.argument == p.count else { throw VNCFileError.invalid }
            if remaining > 0, let handle {
                guard p.count <= remaining else { throw VNCFileError.invalid }
                try handle.write(contentsOf: p); remaining -= UInt64(p.count)
            } else if resourceRemaining > 0, let resourceHandle {
                guard p.count <= resourceRemaining else { throw VNCFileError.invalid }
                try resourceHandle.write(contentsOf: p); resourceRemaining -= UInt64(p.count)
            } else { throw VNCFileError.invalid }
            copied += UInt64(p.count)
        case 104:
            guard message.argument == 0, !top.isEmpty else { throw VNCFileError.invalid }
            try closeItem()
            for (url, mode, modified) in permissions.reversed() {
                var attributes: [FileAttributeKey: Any] = [.posixPermissions: Int(mode)]
                if let modified { attributes[.modificationDate] = modified }
                try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
            }
            done = true
        case 5: throw VNCFileError.remote(Int32(bitPattern: message.argument))
        default: throw VNCFileError.invalid
        }
    }
    private func closeItem() throws {
        guard remaining == 0, resourceRemaining == 0 else { throw VNCFileError.changed }
        try handle?.close(); handle = nil
        try resourceHandle?.close(); resourceHandle = nil
    }
}
