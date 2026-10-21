import AppKit
import Foundation

/// Files copied on the Mac, as a remote desktop is offered them: one flat
/// list, folders before what is in them, names relative to where they were
/// copied from. The server reads them by index as it pastes, so only these
/// files can ever be read through it — not anything else on the Mac, even
/// by an engine gone wrong.
final class RDPLocalFiles: @unchecked Sendable {
    struct Entry: Sendable {
        let url: URL
        /// `/` between folders, as the engine takes it.
        let name: String
        let size: Int64
        let isDirectory: Bool
        let modified: Int64
    }

    let entries: [Entry]
    /// What was left out: links (they would copy what they point at, or
    /// nothing), and names longer than Windows takes.
    let skipped: [String]

    /// The longest name, in UTF-16 units, a file list carries (260 with its
    /// terminating zero).
    static let longestName = 259

    private let lock = NSLock()
    /// The file read last, kept open: the server reads a file in pieces.
    private var open: (index: Int, handle: FileHandle)?

    private init(entries: [Entry], skipped: [String]) {
        self.entries = entries
        self.skipped = skipped
    }

    deinit {
        try? open?.handle.close()
    }

    var clipboardFiles: [RDPClipboardFile] {
        entries.map { RDPClipboardFile(name: $0.name, size: $0.size, isDirectory: $0.isDirectory, modified: $0.modified) }
    }

    /// Walks what was copied. Off the main thread: a folder can hold a lot.
    static func collect(_ urls: [URL]) -> RDPLocalFiles {
        var entries: [Entry] = []
        var skipped: [String] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey,
                                      .contentModificationDateKey]

        func add(_ url: URL, as name: String) {
            // Finder's own bookkeeping, which nobody means to copy.
            if url.lastPathComponent == ".DS_Store" { return }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return skipped.append(name) }
            if values.isSymbolicLink == true || name.utf16.count > longestName { return skipped.append(name) }
            let modified = Int64(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
            if values.isDirectory == true {
                entries.append(Entry(url: url, name: name, size: 0, isDirectory: true, modified: modified))
                let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys))
                    ?? []
                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    add(child, as: name + "/" + child.lastPathComponent)
                }
            } else if values.isRegularFile == true {
                entries.append(Entry(url: url, name: name, size: Int64(values.fileSize ?? 0), isDirectory: false,
                                     modified: modified))
            } else {
                skipped.append(name)
            }
        }

        for url in urls { add(url, as: url.lastPathComponent) }
        return RDPLocalFiles(entries: entries, skipped: skipped)
    }

    /// Up to `length` bytes of file `index` from `offset`: fewer at its
    /// end, `nil` for a folder or a file that cannot be read.
    func read(index: Int, offset: Int64, length: Int) -> Data? {
        guard entries.indices.contains(index), !entries[index].isDirectory, offset >= 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if open?.index != index {
            try? open?.handle.close()
            open = nil
            guard let handle = try? FileHandle(forReadingFrom: entries[index].url) else { return nil }
            open = (index, handle)
        }
        guard let handle = open?.handle else { return nil }
        do {
            try handle.seek(toOffset: UInt64(offset))
            // The server asks for pieces; one larger than this is not a
            // piece, and is not read into memory whole.
            return try handle.read(upToCount: min(length, 8 << 20)) ?? Data()
        } catch {
            return nil
        }
    }
}

/// The files a desktop offered last, read from the XPC queue the server's
/// requests arrive on — not the main thread, which may be busy.
final class RDPOfferedFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var files: RDPLocalFiles?

    var current: RDPLocalFiles? {
        get { lock.withLock { files } }
        set { lock.withLock { files = newValue } }
    }
}

/// Files copied on the server, fetched into a folder of their own so the
/// Mac's clipboard can hold them: Finder pastes files that exist, so they
/// are all here before the clipboard says so.
@MainActor
@Observable
final class RDPFileDownload {
    enum State: Equatable {
        case copying
        case done
        case failed(String)
        case cancelled
    }

    private(set) var state = State.copying
    private(set) var copied: Int64 = 0
    /// What the server said the files weigh; files it gave no size for are
    /// added as their size arrives.
    private(set) var total: Int64
    let fileCount: Int
    let folder: URL

    /// Part of file `index` from the server: (index, offset, length,
    /// size only).
    typealias Fetch = @MainActor (Int, Int64, Int, Bool) async -> Data?

    @ObservationIgnored private let files: [RDPClipboardFile]
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private var task: Task<Void, Never>?
    /// How much is asked for at a time: large enough that a slow link is
    /// not all round trips, small enough to show progress.
    static let chunk = 512 << 10

    init(files: [RDPClipboardFile], into folder: URL, fetch: @escaping Fetch) {
        self.files = files
        self.folder = folder
        self.fetch = fetch
        total = files.filter { !$0.isDirectory }.reduce(0) { $0 + max($1.size, 0) }
        fileCount = files.filter { !$0.isDirectory }.count
    }

    /// Fetches everything, then hands over what was copied at the top —
    /// the files and folders the user selected on the server.
    func start(then done: @escaping @MainActor ([URL]) -> Void) {
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let top = try await run()
                guard state == .copying else { return }
                state = .done
                done(top)
            } catch is CancellationError {
                state = .cancelled
            } catch {
                if state == .copying { state = .failed(String(describing: error)) }
            }
        }
    }

    func cancel() {
        task?.cancel()
        if state == .copying { state = .cancelled }
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    private func run() async throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // By name: a URL for a folder that exists ends in "/", one made
        // before it did does not, and the two would not compare equal.
        var top: [String] = []
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            guard let parts = Self.safeComponents(file.name) else {
                throw Failure(description: "The server sent a file name that is not safe to use: \(file.name)")
            }
            let url = parts.reduce(folder) { $0.appendingPathComponent($1) }
            if !top.contains(parts[0]) { top.append(parts[0]) }
            if file.isDirectory {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try await download(index, size: file.size, to: url)
            }
            if file.modified > 0 {
                try? FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: TimeInterval(file.modified))], ofItemAtPath: url.path)
            }
        }
        return top.map { folder.appendingPathComponent($0) }
    }

    private func download(_ index: Int, size given: Int64, to url: URL) async throws {
        var size = given
        if size < 0 {
            guard let data = await fetch(index, 0, 8, true), data.count >= 8 else {
                throw Failure(description: "The server did not say how big a file is.")
            }
            size = Int64(bitPattern: data.prefix(8).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) })
            total += size
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            throw Failure(description: "Could not write \(url.lastPathComponent).")
        }
        defer { try? handle.close() }
        var offset: Int64 = 0
        while offset < size {
            try Task.checkCancellation()
            let wanted = Int(min(Int64(Self.chunk), size - offset))
            guard let data = await fetch(index, offset, wanted, false), !data.isEmpty else {
                try Task.checkCancellation()
                throw Failure(description: "The server stopped sending \(url.lastPathComponent).")
            }
            let piece = data.prefix(wanted)
            try handle.write(contentsOf: piece)
            offset += Int64(piece.count)
            copied += Int64(piece.count)
        }
    }

    /// A name from the server as the parts of a path inside the download's
    /// folder — or `nil` for one that would leave it, or is not a name: an
    /// absolute path, `..`, an empty part. The server is not trusted with
    /// where files land on the Mac.
    nonisolated static func safeComponents(_ name: String) -> [String]? {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") })
        else { return nil }
        return parts
    }
}
