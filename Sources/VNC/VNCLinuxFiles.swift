import Foundation
import Darwin

/// An explicitly selected, already authenticated SSH connection to the VNC
/// desktop's user account. GTK owns the file clipboard; SFTP moves contents.
/// The small Python bridge lives only in the SSH channel, never as a service.
@MainActor
final class VNCLinuxFiles {
    struct Selection: Decodable, Sendable {
        struct File: Decodable, Sendable { let path: String; let directory: Bool }
        let files: [File]
        let total: Int64
        let serial: Int
    }
    enum Failure: Error, LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let message) = self { message } else { nil } }
    }
    let title: String
    let client: SFTPClient
    var onSelection: ((Selection) -> Void)?
    var onText: ((String) -> Void)?
    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?
    var onReady: (() -> Void)?
    private(set) var isReady = false
    private var process: Process?
    private var input: FileHandle?
    private var reader: PipeReader?
    private var buffer = Data()
    private var nextID = 0
    private var requests: [Int: (Result<Data, any Error>) -> Void] = [:]
    private let writer = DispatchQueue(label: "com.pavelkhorenyan.Termstead.linux-clipboard")
    private var active = false
    private var generation = 0
    private static let disconnectedMessage = "The SSH connection for the Linux file clipboard closed. Reconnect File Clipboard from the VNC tab, or check the VNC session’s SSH settings."

    init(client: SFTPClient, title: String) { self.client = client; self.title = title }

    func start() throws {
        guard process == nil else { return }
        guard let url = Bundle.main.url(forResource: "linux-clipboard", withExtension: "py"),
              let script = try? String(contentsOf: url, encoding: .utf8) else {
            throw Failure.message("The Linux clipboard helper is missing from this build.")
        }
        let process = Process(), incoming = Pipe(), outgoing = Pipe()
        // EPIPE must become a recoverable write error, never SIGPIPE for the
        // whole app. try? alone cannot catch a POSIX signal.
        guard fcntl(outgoing.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw Failure.message("Could not protect the Linux clipboard connection against disconnects.")
        }
        generation += 1
        let current = generation
        process.executableURL = URL(fileURLWithPath: SSHLaunch.executable)
        process.arguments = client.shellArguments("exec python3 -u -c " + SFTPClient.shellQuote(script))
        process.standardInput = outgoing
        process.standardOutput = incoming
        // Only structured protocol errors enter the UI. SSH/GTK diagnostics
        // can include desktop paths; do not forward them to the clipboard.
        process.standardError = FileHandle.nullDevice
        input = outgoing.fileHandleForWriting
        reader = try PipeReader(handle: incoming.fileHandleForReading) { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self, generation == current else { return }
                receive(data)
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, generation == current, self.process != nil else { return }
                fail(Self.disconnectedMessage)
            }
        }
        self.process = process
        do { try process.run() } catch { close(); throw error }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, generation == current, !isReady, self.process != nil else { return }
            fail("The Linux clipboard helper did not start. Check DISPLAY, XAUTHORITY and the SSH connection.")
        }
    }
    func close() {
        generation += 1
        let running = process
        process = nil; isReady = false
        reader?.cancel(); reader = nil
        let outgoing = input
        input = nil
        // Finish queued writes before closing their descriptor. Late writes
        // fail with EPIPE if SSH has already gone; they cannot kill the app.
        writer.async { try? outgoing?.close() }
        buffer.removeAll()
        if running?.isRunning == true { running?.terminate() }
        let pending = requests.values
        requests.removeAll()
        for completion in pending { completion(.failure(CancellationError())) }
    }
    private func fail(_ message: String) { close(); onError?(message) }
    func setActive(_ value: Bool) {
        guard value != active else { return }
        active = value
        if isReady { send(["operation": "active", "active": value]) }
    }
    private func send(_ message: [String: Any]) {
        guard let input, var data = try? JSONSerialization.data(withJSONObject: message), data.count <= 128 * 1024 else { return }
        data.append(10)
        let bytes = data
        let current = generation
        writer.async { [weak self] in
            do { try input.write(contentsOf: bytes) } catch {
                Task { @MainActor [weak self] in
                    guard let self, generation == current, process != nil else { return }
                    fail(Self.disconnectedMessage)
                }
            }
        }
    }
    private func request(_ message: [String: Any]) async throws -> Data {
        guard isReady else { throw Failure.message("The Linux clipboard helper is not connected yet.") }
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                requests[id] = { continuation.resume(with: $0) }
                var message = message; message["id"] = id
                send(message)
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    self?.requests.removeValue(forKey: id)?(.failure(Failure.message("The Linux clipboard did not respond.")))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.requests.removeValue(forKey: id)?(.failure(CancellationError())) }
        }
    }
    private func receive(_ data: Data) {
        guard process != nil else { return }
        guard !data.isEmpty else { fail(Self.disconnectedMessage); return }
        buffer.append(data)
        guard buffer.count <= 8 * 1024 * 1024 else { fail("The Linux clipboard returned too much data."); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                fail("The Linux clipboard returned an invalid response."); return
            }
            if let id = value["id"] as? Int {
                if let error = value["error"] as? String {
                    requests.removeValue(forKey: id)?(.failure(Failure.message(error)))
                } else { requests.removeValue(forKey: id)?(.success(line)) }
            } else if let event = value["event"] as? String {
                switch event {
                case "ready":
                    isReady = true
                    send(["operation": "active", "active": active])
                    onReady?()
                case "files":
                    if active, let selection = try? JSONDecoder().decode(Selection.self, from: line) {
                        onSelection?(selection)
                    }
                case "text":
                    if active, let text = value["text"] as? String, text.utf8.count <= 1_048_576 { onText?(text) }
                case "changed": onChange?()
                case "copy-error": onError?(value["message"] as? String ?? "The Linux file selection cannot be copied.")
                case "error": fail(value["message"] as? String ?? "The Linux file clipboard failed.")
                default: break
                }
            }
        }
    }

    /// A successful response means GTK owns the clipboard, before Ctrl+V is
    /// sent. Uploads never write into the folder shown by the file manager.
    func upload(_ urls: [URL]) async throws {
        try await BlockingWork.run { try Self.validate(urls) }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        do {
            let data = try await request(["operation": "stage", "count": urls.count, "token": token])
            struct Stage: Decodable { let token: String; let path: String }
            let stage = try JSONDecoder().decode(Stage.self, from: data)
            guard stage.token == token, Self.validPath(stage.path) else {
                throw Failure.message("The Linux clipboard returned an invalid upload directory.")
            }
            for (index, url) in urls.enumerated() {
                try Task.checkCancellation()
                try await client.upload(url, to: RemotePath.join(stage.path, String(index)))
            }
            try Task.checkCancellation()
            _ = try await request(["operation": "publish", "token": token])
        } catch {
            // Cancelling the transfer does not cancel the shared SSH master.
            send(["operation": "discard", "token": token])
            throw error
        }
    }
    func download(_ selection: Selection) async throws -> [URL] {
        guard !selection.files.isEmpty, selection.files.count <= 64,
              (0...100 * 1024 * 1024 * 1024).contains(selection.total),
              selection.files.allSatisfy({ Self.validPath($0.path) }) else {
            throw Failure.message("The Linux clipboard contains invalid file paths.")
        }
        let folder = URL.temporaryDirectory.appendingPathComponent("termstead-linux-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            var urls: [URL] = []
            for (index, file) in selection.files.enumerated() {
                try Task.checkCancellation()
                let destination = folder.appendingPathComponent(String(index))
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let name = URL(fileURLWithPath: file.path).lastPathComponent
                try await client.download(file.path, recursive: file.directory, to: destination, as: name)
                urls.append(destination.appendingPathComponent(name))
            }
            try Task.checkCancellation()
            // Finder may paste after this VNC tab has closed.
            return urls
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
    nonisolated static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path != "/" && path.utf8.count <= 4096 &&
        !path.contains("\0") && !path.contains("\n") && !path.contains("\r") &&
        ![".", ".."].contains(URL(fileURLWithPath: path).lastPathComponent)
    }
    nonisolated static func validate(_ urls: [URL]) throws {
        guard !urls.isEmpty, urls.count <= 64, urls.allSatisfy({ $0.isFileURL && validPath($0.path) }) else {
            throw Failure.message("Select at most 64 files or folders. SFTP copies cannot contain names with newlines.")
        }
        var count = 0, bytes: Int64 = 0
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        func check(_ url: URL) throws {
            let value = try url.resourceValues(forKeys: keys)
            guard value.isSymbolicLink != true, value.isDirectory == true || value.isRegularFile == true,
                  validPath(url.path) else { throw Failure.message("Symbolic links, special files and names with newlines cannot be copied through SFTP clipboard.") }
            count += 1
            bytes += Int64(value.fileSize ?? 0)
            guard count <= 10000, bytes <= 100 * 1024 * 1024 * 1024 else {
                throw Failure.message("A clipboard copy can contain at most 10,000 items and 100 GB.")
            }
        }
        for url in urls {
            try check(url)
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                var enumerationError: (any Error)?
                guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in
                    enumerationError = error; return false
                }) else { throw Failure.message("The selected folder cannot be read.") }
                for case let child as URL in enumerator { try check(child) }
                if let enumerationError { throw enumerationError }
            }
        }
    }

    /// One nonblocking read per notification; the cancellation handler closes
    /// the descriptor only after pending reads finish. This avoids both a
    /// closed-handle exception and blocking until an entire buffer is full.
    private final class PipeReader: @unchecked Sendable {
        private let handle: FileHandle
        private let source: any DispatchSourceRead
        private let receive: @Sendable (Data) -> Void
        init(handle: FileHandle, receive: @escaping @Sendable (Data) -> Void) throws {
            let descriptor = handle.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw Failure.message("Could not open the Linux clipboard response channel.")
            }
            self.handle = handle
            self.receive = receive
            source = DispatchSource.makeReadSource(fileDescriptor: descriptor,
                queue: DispatchQueue(label: "com.pavelkhorenyan.Termstead.linux-clipboard-reader"))
            source.setEventHandler { [weak self] in self?.read() }
            source.setCancelHandler { try? handle.close() }
            source.resume()
        }
        func cancel() { source.cancel() }
        deinit { source.cancel() }
        private func read() {
            var data = Data(count: 16384)
            let count = data.withUnsafeMutableBytes { bytes in Darwin.read(handle.fileDescriptor, bytes.baseAddress, bytes.count) }
            if count < 0, errno == EAGAIN || errno == EINTR { return }
            if count > 0 {
                data.count = count
                receive(data)
            } else {
                source.cancel()
                receive(Data())
            }
        }
    }
}
