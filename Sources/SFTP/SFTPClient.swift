import Foundation

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

    static let executable = "/usr/bin/sftp"

    /// `RemoteCommand` and `RequestTTY` are for the terminal: a config that
    /// sets them — the user's own may — makes ssh refuse the `sftp`
    /// subsystem, or `rm` a command, with "Cannot execute command-line and
    /// remote command".
    private var sharedOptions: [String] {
        ["-F", configPath, "-o", "ControlPath=\(controlPath)", "-o", "ControlMaster=no",
         "-o", "BatchMode=yes", "-o", "RemoteCommand=none", "-o", "RequestTTY=no"]
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
        try await run(["get \(recursive ? "-r " : "")\(Self.quote(remote)) \(Self.quote(target))"])
    }

    func upload(_ local: URL, to remoteDirectory: String) async throws {
        let recursive = (try? local.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let target = RemotePath.join(remoteDirectory, local.lastPathComponent)
        try await run(["put \(recursive ? "-r " : "")\(Self.quote(local.path)) \(Self.quote(target))"])
    }

    /// Writes a local file over a remote one, for Open and Edit.
    func replace(_ remote: String, with local: URL) async throws {
        try await run(["put \(Self.quote(local.path)) \(Self.quote(remote))"])
    }

    func makeDirectory(_ path: String) async throws {
        try await run(["mkdir \(Self.quote(path))"])
    }

    func rename(_ path: String, to newPath: String) async throws {
        try await run(["rename \(Self.quote(path)) \(Self.quote(newPath))"])
    }

    func removeFile(_ path: String) async throws {
        try await run(["rm \(Self.quote(path))"])
    }

    /// The SFTP protocol only removes empty directories, so a folder goes with
    /// `rm -rf` over the same connection instead of one request per file.
    func removeDirectory(_ path: String) async throws {
        _ = try await Self.execute(executable: SSHLaunch.executable,
                               arguments: sharedOptions + [alias, "--", "rm", "-rf", "--", Self.shellQuote(path)],
                               input: nil)
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
        // `sh -c`, so a login shell such as fish never has to parse it.
        let output = try? await Self.execute(executable: SSHLaunch.executable,
                                             arguments: sharedOptions + [alias, "--", "sh", "-c", Self.shellQuote(script)],
                                             input: nil)
        let path = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.hasPrefix("/") ? path : nil
    }

    // MARK: - Running

    @discardableResult
    func run(_ commands: [String]) async throws -> String {
        try await runReportingErrors(commands).output
    }

    /// The output, and what sftp said on stderr even when it exited 0.
    private func runReportingErrors(_ commands: [String]) async throws -> (output: String, errors: [String]) {
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
        try await Task.detached(priority: .userInitiated) {
            try runBlocking(executable: executable, arguments: arguments, input: input)
        }.value
    }

    private static func runBlocking(executable: String, arguments: [String],
                                    input: String?) throws -> (output: String, errors: [String]) {
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
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        do { try process.run() } catch { throw SFTPError.failed("Could not start \(executable).") }

        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
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

        let text = String(decoding: outputData, as: UTF8.self)
        let errorText = String(decoding: errorData.get(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw error(from: errorText) }
        let errorLines = errorText.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.hasPrefix("sftp>") && !$0.isEmpty }
        return (text, errorLines)
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

    /// For the remote shell: single quotes, with each `'` closed, escaped and reopened.
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func workingDirectory(in output: String) throws -> String {
        let prefix = "Remote working directory: "
        guard let line = output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix(prefix) }) else {
            throw SFTPError.failed("The server did not say which directory it is in.")
        }
        return String(line.dropFirst(prefix.count))
    }
}
