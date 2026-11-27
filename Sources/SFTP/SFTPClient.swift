import Foundation
import CryptoKit
import Darwin

enum SFTPError: Error, Equatable, CustomStringConvertible {
    /// The terminal's ssh has not finished logging in, so there is no
    /// connection to share yet.
    case notReady
    case failed(String)

    var description: String {
        switch self {
        case .notReady: "Waiting for the terminal to finish logging in…"
        case .failed(let message): message
        }
    }
}

/// Runs `/usr/bin/sftp` in batch mode over a tab's ssh connection.
///
/// Every operation is one short `sftp -b` run through the terminal's
/// connection master (see `SSHLaunchPlan.arguments`), which costs a new
/// channel, not a new login. `BatchMode=yes` and `ControlMaster=no` make sure
/// it never logs in on its own: with no master to join it fails at once
/// instead of asking for a password nobody would see.
struct SFTPClient: Equatable, Sendable {
    var configPath: String
    var controlPath: String
    var alias: String
    var usesOnlySFTP = false
    var stageJournal: SFTPStageJournal?
    var requiresMaster = false

    static let executable = "/usr/bin/sftp"

    /// `RemoteCommand` and `RequestTTY` are for the terminal: a config that
    /// sets them — the user's own may — makes ssh refuse the `sftp`
    /// subsystem, or `rm` a command, with "Cannot execute command-line and
    /// remote command".
    private var sharedOptions: [String] {
        ["-F", configPath, "-o", "ControlPath=\(controlPath)", "-o", "ControlMaster=no",
         "-o", "BatchMode=yes", "-o", "RemoteCommand=none", "-o", "RequestTTY=no",
         // A user's config may name tunnels; a client joining the master
         // would ask it for them again.
         "-o", "ClearAllForwardings=yes"]
            // Reuse the socket or fail if it disappears during an operation.
            + (usesOnlySFTP || requiresMaster ? ["-o", "ProxyCommand=/usr/bin/false"] : [])
    }

    func requiringMaster() -> Self {
        var client = self
        client.requiresMaster = true
        return client
    }

    // MARK: - Operations

    /// The directory the server starts a session in, normally the home.
    func home() async throws -> String {
        let output = try await run(["pwd"])
        return try Self.workingDirectory(in: output)
    }

    /// Lists `path` and returns it resolved — through symlinks — with its entries.
    func list(_ path: String) async throws -> (path: String, files: [RemoteFile]) {
        let result = try await runReportingErrors(["cd \(Self.quote(path))", "pwd", "ls -la"])
        // A folder that may be entered but not read (`d-wx------`) fails the
        // `ls` alone, and sftp does not count that as failing the batch: it
        // still exits 0. Without this it would show as empty.
        if result.errors.contains(where: { $0.contains("readdir") || $0.hasPrefix("Can't ls") }) {
            throw Self.error(from: result.errors.joined(separator: "\n"))
        }
        let output = result.output
        let resolved = try Self.workingDirectory(in: output)
        return (resolved, SFTPListing.parse(output, in: resolved))
    }

    /// Whether `path` is a directory, following symlinks.
    func isDirectory(_ path: String) async -> Bool {
        (try? await run(["cd \(Self.quote(path))"])) != nil
    }

    func download(_ remote: String, recursive: Bool, to localDirectory: URL, as name: String) async throws {
        let target = localDirectory.appendingPathComponent(name).path
        try await transfer("get \(recursive ? "-r " : "")\(Self.quote(remote)) \(Self.quote(target))")
    }

    func upload(_ local: URL, to remoteDirectory: String) async throws {
        let recursive = (try? local.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let target = RemotePath.join(remoteDirectory, local.lastPathComponent)
        try await transfer("put \(recursive ? "-r " : "")\(Self.quote(local.path)) \(Self.quote(target))")
    }

    /// Writes a local file over a remote one, for Open and Edit.
    func replace(_ remote: String, with local: URL, matching expectedContents: SHA256Digest?) async throws {
        let folder = RemotePath.parent(of: remote)
        let name = RemotePath.name(of: remote)
        let listing = try await list(folder)
        let destination = RemotePath.join(listing.path, name)
        guard let original = listing.files.first(where: { $0.name == name }), original.kind == .file else {
            throw SFTPError.failed("The original file is missing or is no longer a regular file.")
        }
        try await withTransferStage(in: listing.path) { stage in
            let staged = RemotePath.join(stage, name)
            try await transfer("put \(Self.quote(local.path)) \(Self.quote(staged))")
            let uploaded = try await list(stage).files.first { $0.name == name }
            guard let uploaded, uploaded.owner == original.owner, uploaded.group == original.group else {
                throw SFTPError.failed("Cannot save without changing the file’s owner or group.")
            }
            guard original.permissions.dropFirst().first == "w" else {
                throw SFTPError.failed("The original file is read-only.")
            }
            let mode = original.permissions.prefix(9).reduce(0) { mode, bit in
                (mode << 1) | ("rwxst".contains(bit) ? 1 : 0)
            }
            try await run(["chmod \(String(mode, radix: 8)) \(Self.quote(staged))"])
            if let expectedContents {
                let check = local.deletingLastPathComponent().appendingPathComponent(".verify-\(UUID())")
                defer { try? FileManager.default.removeItem(at: check) }
                try await download(destination, recursive: false, to: check.deletingLastPathComponent(),
                                   as: check.lastPathComponent)
                guard try await Self.contentDigest(of: check) == expectedContents else {
                    throw SFTPError.failed("The file on the server changed. Your edits are still in the open local copy.")
                }
            }
            guard try await list(listing.path).files.first(where: { $0.name == name }) == original else {
                throw SFTPError.failed("The file on the server changed during the save. Your edits are still in the open local copy.")
            }
            try Task.checkCancellation()
            try await Task { try await finishTransfer(staged, at: destination, replacing: true) }.value
        }
    }

    static func contentDigest(of file: URL) async throws -> SHA256Digest {
        try await BlockingWork.run {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var digest = SHA256()
            while let bytes = try handle.read(upToCount: 256 * 1024), !bytes.isEmpty {
                digest.update(data: bytes)
            }
            return digest.finalize()
        }
    }

    func makeDirectory(_ path: String) async throws {
        try await run(["mkdir \(Self.quote(path))"])
    }

    func rename(_ path: String, to newPath: String) async throws {
        do {
            try await finishTransfer(path, at: newPath, replacing: false)
        } catch {
            if let listing = try? await list(RemotePath.parent(of: newPath)),
               listing.files.contains(where: { $0.name == RemotePath.name(of: newPath) }) {
                throw SFTPError.failed("An item named “\(RemotePath.name(of: newPath))” already exists.")
            }
            throw error
        }
    }

    func finishTransfer(_ path: String, at destination: String, replacing: Bool) async throws {
        // Legacy SFTP rename refuses an existing destination. The POSIX
        // extension can atomically replace a file when the user asks for it.
        try await run(["rename \(replacing ? "" : "-l ")\(Self.quote(path)) \(Self.quote(destination))"])
    }

    func makeTransferStage(_ path: String) async throws {
        let quoted = Self.quote(path)
        try await run(["mkdir \(quoted)", "chmod 700 \(quoted)"])
    }

    func removeFile(_ path: String) async throws {
        try await run(["rm \(Self.quote(path))"])
    }

    /// A standalone session removes children over SFTP before `rmdir`.
    /// Terminal sessions can remove the whole tree in one remote shell command.
    func removeDirectory(_ path: String) async throws {
        if usesOnlySFTP {
            try await discardTransferStage(path)
            return
        }
        _ = try await Self.execute(executable: SSHLaunch.executable,
                               arguments: sharedOptions + [alias, "--", "rm", "-rf", "--", Self.shellQuote(path)],
                               input: nil)
    }

    func discardTransferStage(_ path: String) async throws {
        let listing = try await list(path)
        guard path != "/", listing.path == path,
              listing.files.allSatisfy({ !$0.name.contains("/") }) else {
            throw SFTPError.failed("The directory changed. Refresh the file list and try again.")
        }
        for file in listing.files {
            if file.kind == .directory { try await discardTransferStage(file.path) }
            else { try await removeFile(file.path) }
        }
        try await run(["rmdir \(Self.quote(path))"])
    }

    /// The folder the tab's shell is in, for "follow the terminal".
    ///
    /// Asked of the server rather than read off the screen: prompts differ,
    /// and a shell reports nothing on its own unless it was set up to (OSC 7).
    /// Every channel over the connection is a child of one `sshd` session
    /// process, this command included, so the script climbs to it and reads
    /// the working directory of its child that has a terminal — the shell.
    /// Linux only (`/proc`); elsewhere it answers nothing and the panel stays put.
    func terminalDirectory() async -> String? {
        // Shell builtins only, apart from the one `readlink`: the first version
        // ran `$(cat …)` per /proc entry — two forks for every process on the
        // server, on every Return. `read` takes the fields straight from
        // /proc/<pid>/stat: 4 is the parent, 7 the controlling terminal.
        let script = """
        p=$$
        while [ "$p" -gt 1 ]; do
          read -r c 2>/dev/null < /proc/$p/comm || break
          case "$c" in sshd*) break;; esac
          read -r _ _ _ p _ 2>/dev/null < /proc/$p/stat || break
        done
        for d in /proc/[0-9]*; do
          read -r _ _ _ pp _ _ tty _ 2>/dev/null < $d/stat || continue
          [ "$pp" = "$p" ] && [ "$tty" != 0 ] && readlink $d/cwd && break
        done
        """
        let output = try? await Self.execute(executable: SSHLaunch.executable,
                                             arguments: shellArguments(script), input: nil)
        let path = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.hasPrefix("/") ? path : nil
    }

    /// ssh's arguments for running `script` over the tab's connection.
    /// `sh -c`, so a login shell such as fish never has to parse it.
    func shellArguments(_ script: String) -> [String] {
        sharedOptions + [alias, "--", "sh", "-c", Self.shellQuote(script)]
    }

    // MARK: - Running

    @discardableResult
    func run(_ commands: [String]) async throws -> String {
        try await runReportingErrors(commands).output
    }

    private func transfer(_ command: String) async throws {
        let result = try await runReportingErrors([command])
        // OpenSSH reports skipped links and special files on stderr even when
        // the recursive operation exits successfully.
        if let skipped = result.errors.first(where: {
            $0.hasSuffix(": not a regular file") || $0.hasSuffix(" is not a regular file")
        }) {
            throw SFTPError.failed(skipped)
        }
    }

    /// The output, and what sftp said on stderr even when it exited 0.
    private func runReportingErrors(_ commands: [String]) async throws -> (output: String, errors: [String]) {
        guard commands.allSatisfy({ !$0.utf8.contains(10) && !$0.utf8.contains(13) }) else {
            throw SFTPError.failed("SFTP paths containing line breaks are unsupported.")
        }
        let batch = commands.joined(separator: "\n") + "\n"
        return try await Self.executeReportingErrors(executable: Self.executable,
                                                     arguments: sharedOptions + ["-b", "-", alias],
                                                     input: batch)
    }

    /// Runs off the main actor: a listing is quick, but a transfer is not.
    private static func execute(executable: String, arguments: [String], input: String?) async throws -> String {
        try await executeReportingErrors(executable: executable, arguments: arguments, input: input).output
    }

    private static func executeReportingErrors(executable: String, arguments: [String],
                                               input: String?) async throws -> (output: String, errors: [String]) {
        let cancellation = ProcessCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            // A transfer can run for minutes; see `BlockingWork`.
            return try await BlockingWork.run {
                try runBlocking(executable: executable, arguments: arguments, input: input,
                                cancellation: cancellation)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func runBlocking(executable: String, arguments: [String],
                                    input: String?, cancellation: ProcessCancellation) throws -> (output: String, errors: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // Without a UTF-8 locale sftp prints every byte outside ASCII as an
        // octal escape: `кириллица.txt` came back as `\320\272…`. An app
        // started from Finder has no LANG of its own.
        environment["LC_CTYPE"] = "UTF-8"
        process.environment = environment
        let output = Pipe(), errors = Pipe(), stdin = Pipe()
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        try cancellation.start(process)
        defer { cancellation.finished() }

        if let input {
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        // Both pipes are drained at once: a big listing fills stdout's buffer
        // while sftp is still writing, and waiting on one would stall it.
        let errorData = LockedData()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errorData.set(errors.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        try cancellation.check()

        let text = String(decoding: outputData, as: UTF8.self)
        let errorText = String(decoding: errorData.get(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw error(from: errorText) }
        let errorLines = errorText.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.hasPrefix("sftp>") && !$0.isEmpty }
        return (text, errorLines)
    }

    /// Cancelling a clipboard copy stops its sftp process, never the shared
    /// SSH master. Starting and cancelling share a lock so an early cancel
    /// cannot leave a process running after its tab has closed.
    private final class ProcessCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        func start(_ process: Process) throws {
            try lock.withLock {
                if cancelled { throw CancellationError() }
                try process.run()
                self.process = process
            }
        }
        func cancel() {
            lock.withLock {
                cancelled = true
                if let process, process.isRunning { process.terminate() }
            }
        }
        func check() throws { try lock.withLock { if cancelled { throw CancellationError() } } }
        func finished() { lock.withLock { process = nil } }
    }

    static func error(from stderr: String) -> SFTPError {
        let lines = stderr.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.hasPrefix("sftp>") && !$0.isEmpty }
        if lines.contains(where: { $0.contains("Control socket connect") }) { return .notReady }
        return .failed(lines.last ?? "The server refused the request.")
    }

    private final class LockedData: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        func set(_ value: Data) { lock.withLock { data = value } }
        func get() -> Data { lock.withLock { data } }
    }

    // MARK: - Quoting

    /// A path as one `sftp` batch argument. Inside double quotes `sftp`
    /// already takes `*`, `?` and `[` literally — escaping them as well left a
    /// real backslash in the name — so only `\` and `"` need one.
    static func quote(_ path: String) -> String {
        var escaped = ""
        for character in path {
            if character == "\\" || character == "\"" { escaped.append("\\") }
            escaped.append(character)
        }
        return "\"\(escaped)\""
    }

    /// For the remote shell: single quotes, with each `'` and `\` closed,
    /// escaped and reopened. Inside single quotes fish, unlike `sh`, reads
    /// `\\` as one backslash and `\'` as a quote, so a name with a backslash
    /// was a different name there, or no command at all.
    static func shellQuote(_ text: String) -> String {
        "'" + text.map { $0 == "'" ? "'\\''" : $0 == "\\" ? "'\\\\'" : String($0) }.joined() + "'"
    }

    static func workingDirectory(in output: String) throws -> String {
        let prefix = "Remote working directory: "
        guard let line = output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix(prefix) }) else {
            throw SFTPError.failed("The server did not say which directory it is in.")
        }
        return String(line.dropFirst(prefix.count))
    }
}
