import Foundation

/// Turns the hosts named in `~/.ssh/config` into sessions.
///
/// Only the names come from parsing; every value comes from `ssh -G`, so
/// `Include`, `Match`, `Host *` defaults and token expansion all resolve the
/// way ssh itself resolves them. An imported session's host is the alias, not
/// the address: the generated config includes `~/.ssh/config`, so ssh still
/// applies the user's own block at connect time — `ProxyJump`, `ProxyCommand`
/// and every option Termstead has no field for.
enum SSHConfigImport {
    static let defaultConfigPath = ("~/.ssh/config" as NSString).expandingTildeInPath

    struct ResolvedHost: Equatable, Sendable {
        var alias: String
        var hostName: String
        var user: String
        var port: Int
        /// Identity files the config names for this host itself, rather than
        /// ssh's built-in defaults or a `Host *` block.
        var identityFiles: [String]

        var session: Session {
            Session(id: alias, user: user, host: alias, port: port, icon: .server,
                    // An empty key path means "let ssh choose" (see
                    // `SSHLaunch.auth`): the agent and the config's own keys.
                    auth: .key, keyPath: identityFiles.first ?? "")
        }
    }

    // MARK: - Host names

    /// Concrete host names in the order they appear, `Include`s followed.
    /// Patterns (`*`, `?`, `!negated`) name no single host and are skipped.
    static func aliases(configPath: String = defaultConfigPath) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        collect(from: configPath, depth: 0, seen: &seen, into: &result)
        return result
    }

    private static func collect(from path: String, depth: Int,
                                seen: inout Set<String>, into result: inout [String]) {
        // ssh gives up at 16 levels too; this also stops an Include loop.
        guard depth < 16, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        for line in text.components(separatedBy: .newlines) {
            let words = tokens(line)
            guard let keyword = words.first?.lowercased() else { continue }
            let arguments = words.dropFirst()
            switch keyword {
            case "host":
                for name in arguments where isConcrete(name) && !seen.contains(name) {
                    seen.insert(name)
                    result.append(name)
                }
            case "include":
                for pattern in arguments {
                    for file in expandInclude(pattern) {
                        collect(from: file, depth: depth + 1, seen: &seen, into: &result)
                    }
                }
            default:
                continue
            }
        }
    }

    /// Splits a config line the way ssh does: whitespace or a single `=`
    /// between keyword and value, double quotes around arguments with spaces,
    /// `#` starting a comment.
    static func tokens(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inQuotes = false
        var sawKeyword = false
        func flush() {
            if !current.isEmpty { words.append(current) }
            current = ""
        }
        for character in line {
            if inQuotes {
                if character == "\"" { inQuotes = false; flush() } else { current.append(character) }
                continue
            }
            switch character {
            case "\"":
                flush()
                inQuotes = true
            case "#" where current.isEmpty:
                flush()
                return words
            case " ", "\t":
                flush()
            case "=" where !sawKeyword:
                flush()
                sawKeyword = true
            default:
                current.append(character)
            }
            if !words.isEmpty { sawKeyword = true }
        }
        flush()
        return words
    }

    private static func isConcrete(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("!") && !name.contains("*") && !name.contains("?")
    }

    /// A relative `Include` in a user config is relative to `~/.ssh`, as in ssh.
    private static func expandInclude(_ pattern: String) -> [String] {
        var path = (pattern as NSString).expandingTildeInPath
        if !path.hasPrefix("/") {
            path = (("~/.ssh" as NSString).expandingTildeInPath as NSString).appendingPathComponent(path)
        }
        var matches = glob_t()
        defer { globfree(&matches) }
        guard glob(path, 0, nil, &matches) == 0 else { return [] }
        return (0..<Int(matches.gl_pathc)).compactMap { index in
            matches.gl_pathv[index].map { String(cString: $0) }
        }.sorted()
    }

    // MARK: - Values

    /// What ssh would use for each alias. Runs `ssh -G`, which reads config
    /// only and never touches the network. Blocking: call it off the main actor.
    static func resolve(_ aliases: [String], configPath: String? = nil) -> [ResolvedHost] {
        // ssh lists its built-in identity files for every host; the ones a
        // made-up name also gets are defaults, not this host's own.
        let defaults = Set(sshG("termstead-import-probe-\(UUID().uuidString.prefix(8))",
                                configPath: configPath)?["identityfile"] ?? [])
        return aliases.compactMap { alias in
            guard let values = sshG(alias, configPath: configPath),
                  let hostName = values["hostname"]?.first,
                  let user = values["user"]?.first,
                  let port = values["port"]?.first.flatMap(Int.init) else { return nil }
            let own = (values["identityfile"] ?? []).filter { !defaults.contains($0) }
            return ResolvedHost(alias: alias, hostName: hostName, user: user, port: port,
                                identityFiles: own)
        }
    }

    private static func sshG(_ alias: String, configPath: String?) -> [String: [String]]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: SSHLaunch.executable)
        var arguments = ["-G"]
        if let configPath { arguments += ["-F", configPath] }
        // `--` so an alias that starts with a dash is never read as an option.
        process.arguments = arguments + ["--", alias]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        var values: [String: [String]] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            values[String(parts[0]), default: []].append(String(parts[1]))
        }
        return values
    }
}
