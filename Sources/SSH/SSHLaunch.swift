import Foundation

/// One machine on the way to a session: a jump host or the target itself,
/// with everything the generated ssh_config needs to say about it.
struct SSHEndpoint: Equatable, Sendable {
    enum Auth: Equatable, Sendable {
        /// Use this key and only this key.
        case key(String)
        /// Ask for a password first.
        case password
        /// Whatever ssh would do on its own: the agent, the default keys, and
        /// the user's `~/.ssh/config`.
        case automatic
    }

    /// The name used in `Host` and `ProxyJump`. Normally the host as typed, so
    /// the user's own config still matches it; see `SSHLaunch.plan`.
    var alias: String
    var host: String
    var user: String?
    var port: Int?
    var auth: Auth
    /// The Keychain account holding this endpoint's password, if it may have one.
    var passwordAccount: String?

    /// How ssh names this endpoint in a password prompt: `user@host`.
    var promptName: String? {
        guard let user else { return nil }
        return "\(user)@\(host)"
    }
}

/// What it takes to start one connection.
struct SSHLaunchPlan: Equatable, Sendable {
    var hops: [SSHEndpoint]
    var target: SSHEndpoint
    /// The contents of the ssh_config file the connection runs with.
    var config: String

    /// Arguments for `/usr/bin/ssh`, given where `config` was written.
    ///
    /// With a `controlPath` the terminal's ssh becomes a connection master, and
    /// the Files panel's `sftp` runs over it: no second login, no second
    /// password, and the same jump chain. These go on the command line rather
    /// than into the config because ssh does not pass `-o` on to the ssh it
    /// starts for each `ProxyJump` hop, so only the target shares — and the
    /// config, which `sftp` reads too, cannot make `sftp` a master itself.
    func arguments(configPath: String, controlPath: String? = nil) -> [String] {
        var arguments = ["-F", configPath, "-o", "ServerAliveInterval=30"]
        if let controlPath {
            arguments += ["-o", "ControlMaster=auto", "-o", "ControlPath=\(controlPath)",
                          "-o", "ControlPersist=no"]
        }
        return arguments + [target.alias]
    }
}

enum SSHLaunchError: Error, Equatable, CustomStringConvertible {
    case invalid(field: String, value: String)
    case emptyHop(index: Int)
    case jumpLoop(String)

    var description: String {
        switch self {
        case .invalid(let field, let value):
            "The \(field) “\(value)” cannot be used. It must not be empty or contain spaces, quotes or any of # * ? ! ,"
        case .emptyHop(let index):
            "Jump host \(index + 1) has no address."
        case .jumpLoop(let name):
            "The jump chain goes through “\(name)” itself."
        }
    }
}

/// Turns a saved session into an ssh invocation.
///
/// Everything goes through a generated ssh_config rather than command-line
/// flags: `-J` cannot give each hop its own key, and a config can. The user's
/// `~/.ssh/config` and the system one are included at the end, so their
/// settings still apply to anything this file does not set — and because ssh
/// takes the *first* value it finds, the settings made in Termstead win.
enum SSHLaunch {
    static let executable = "/usr/bin/ssh"

    /// Keychain accounts. A key's passphrase belongs to the key, not to a
    /// session: the same key usually opens many servers.
    static func sessionPasswordAccount(_ sessionID: String) -> String { "session:\(sessionID):password" }
    static func hopPasswordAccount(_ hopID: UUID) -> String { "hop:\(hopID.uuidString):password" }
    static func passphraseAccount(forKey path: String) -> String {
        "key:\((path as NSString).expandingTildeInPath):passphrase"
    }

    /// - Parameter keyExists: whether a key file is there. A session that still
    ///   carries the default key path, pointing at a key the user does not have,
    ///   falls back to ssh's own choice instead of pinning a missing file.
    static func plan(
        for session: Session,
        sessions: [String: Session],
        keyExists: (String) -> Bool = { FileManager.default.fileExists(atPath: ($0 as NSString).expandingTildeInPath) }
    ) throws -> SSHLaunchPlan {
        let targetAuth = try auth(session.auth, keyPath: session.keyPath, keyExists: keyExists)
        let targetPassword = sessionPasswordAccount(session.id)

        var hops: [SSHEndpoint] = []
        for (index, hop) in session.jumps.enumerated() {
            let typed = hop.host.trimmingCharacters(in: .whitespaces)
            guard !typed.isEmpty else { throw SSHLaunchError.emptyHop(index: index) }
            // Filled-in fields win over a saved session's values and over
            // anything pasted into the host field as `user@host:port`.
            let typedUser = hop.user.trimmingCharacters(in: .whitespaces)
            let explicitUser = typedUser.isEmpty ? nil : typedUser

            if let saved = sessions[typed] {
                // A hop named after a saved session connects the way that
                // session does, unless the hop says otherwise.
                guard saved.id != session.id else { throw SSHLaunchError.jumpLoop(saved.id) }
                let hopAuth: SSHEndpoint.Auth
                let account: String
                switch hop.auth {
                case .session:
                    hopAuth = try auth(saved.auth, keyPath: saved.keyPath, keyExists: keyExists)
                    account = sessionPasswordAccount(saved.id)
                case .key:
                    hopAuth = try auth(.key, keyPath: hop.keyPath, keyExists: keyExists)
                    account = hopPasswordAccount(hop.id)
                case .password:
                    hopAuth = .password
                    account = hopPasswordAccount(hop.id)
                }
                hops.append(try endpoint(user: explicitUser ?? saved.user, host: saved.host,
                                         port: hop.port ?? saved.port,
                                         auth: hopAuth, passwordAccount: account))
                continue
            }

            let parsed = try parseAddress(typed)
            let hopAuth: SSHEndpoint.Auth
            let account: String
            switch hop.auth {
            case .session:
                hopAuth = targetAuth
                account = targetPassword
            case .key:
                hopAuth = try auth(.key, keyPath: hop.keyPath, keyExists: keyExists)
                account = hopPasswordAccount(hop.id)
            case .password:
                hopAuth = .password
                account = hopPasswordAccount(hop.id)
            }
            hops.append(try endpoint(user: explicitUser ?? parsed.user, host: parsed.host,
                                     port: hop.port ?? parsed.port,
                                     auth: hopAuth, passwordAccount: account))
        }

        let target = try endpoint(user: session.user.isEmpty ? nil : session.user,
                                  host: session.host, port: session.port,
                                  auth: targetAuth, passwordAccount: targetPassword)
        return assemble(hops: hops, target: target)
    }

    /// A one-off connection typed into quick connect: nothing but an address,
    /// authenticated however ssh would on its own.
    static func plan(forAddress address: String) throws -> SSHLaunchPlan {
        let parsed = try parseAddress(address.trimmingCharacters(in: .whitespaces))
        let target = try endpoint(user: parsed.user, host: parsed.host, port: parsed.port,
                                  auth: .automatic, passwordAccount: nil)
        return assemble(hops: [], target: target)
    }

    // MARK: - Parsing

    /// `[user@]host[:port]`, with IPv6 literals in brackets: `[::1]:2222`.
    static func parseAddress(_ address: String) throws -> (user: String?, host: String, port: Int?) {
        var rest = Substring(address)
        var user: String?
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at])
            rest = rest[rest.index(after: at)...]
        }

        var host: String
        var port: Int?
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { throw SSHLaunchError.invalid(field: "host", value: String(rest)) }
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            if after.hasPrefix(":") { port = try parsePort(after.dropFirst()) }
            else if !after.isEmpty { throw SSHLaunchError.invalid(field: "host", value: String(rest)) }
        } else if rest.filter({ $0 == ":" }).count == 1, let colon = rest.firstIndex(of: ":") {
            host = String(rest[..<colon])
            port = try parsePort(rest[rest.index(after: colon)...])
        } else {
            // No colon, or a bare IPv6 address with several.
            host = String(rest)
        }
        try validate(host, field: "host")
        if let user { try validate(user, field: "user") }
        return (user, host, port)
    }

    private static func parsePort(_ text: Substring) throws -> Int {
        guard let port = Int(text), (1...65535).contains(port) else {
            throw SSHLaunchError.invalid(field: "port", value: String(text))
        }
        return port
    }

    // MARK: - Building

    private static func auth(_ auth: SessionAuth, keyPath: String,
                             keyExists: (String) -> Bool) throws -> SSHEndpoint.Auth {
        switch auth {
        case .password:
            return .password
        case .key:
            let path = keyPath.trimmingCharacters(in: .whitespaces)
            if path.isEmpty || (path == Session.defaultKeyPath && !keyExists(path)) { return .automatic }
            guard !path.contains("\""), !path.contains(where: \.isNewline) else {
                throw SSHLaunchError.invalid(field: "key file", value: path)
            }
            return .key(path)
        }
    }

    private static func endpoint(user: String?, host: String, port: Int?,
                                 auth: SSHEndpoint.Auth, passwordAccount: String?) throws -> SSHEndpoint {
        try validate(host, field: "host")
        if let user { try validate(user, field: "user") }
        if let port, !(1...65535).contains(port) {
            throw SSHLaunchError.invalid(field: "port", value: String(port))
        }
        return SSHEndpoint(alias: host, host: host, user: user, port: port,
                           auth: auth, passwordAccount: passwordAccount)
    }

    /// Characters that would change the meaning of a line in ssh_config, turn a
    /// value into a pattern, or read as a command-line option.
    static func validate(_ value: String, field: String) throws {
        let forbidden = CharacterSet(charactersIn: "\"'#*?!,\\")
            .union(.whitespacesAndNewlines)
            .union(.controlCharacters)
        guard !value.isEmpty, !value.hasPrefix("-"),
              value.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else {
            throw SSHLaunchError.invalid(field: field, value: value)
        }
    }

    /// Picks each endpoint's `Host` name and writes the file.
    ///
    /// The host as typed is used wherever possible, because that is what the
    /// user's own `Host` blocks match: a hop typed as `bastion-01` must still
    /// pick up the `HostName` their config gives it. When a host comes up a
    /// second time in one chain — the same machine on another port, say — the
    /// later one gets a private alias and an explicit `HostName`: ssh applies
    /// the first matching block, so sharing a name would give both its settings
    /// and point the chain's `ProxyJump` back at itself.
    private static func assemble(hops: [SSHEndpoint], target: SSHEndpoint) -> SSHLaunchPlan {
        var all = hops + [target]
        var used: Set<String> = []
        for index in all.indices {
            if used.contains(all[index].alias) {
                all[index].alias = index == all.count - 1 ? "termstead-target" : "termstead-hop-\(index)"
            }
            used.insert(all[index].alias)
        }

        var lines = ["# Written by Termstead for one connection and deleted when it closes."]
        for (index, endpoint) in all.enumerated() {
            lines.append("")
            lines.append("Host \(endpoint.alias)")
            if endpoint.alias != endpoint.host { lines.append("  HostName \(endpoint.host)") }
            if let user = endpoint.user { lines.append("  User \(user)") }
            if let port = endpoint.port { lines.append("  Port \(port)") }
            switch endpoint.auth {
            case .key(let path):
                lines.append("  IdentityFile \"\(path)\"")
                // Without this ssh offers every key in the agent first, and a
                // server that allows five attempts may never see this one.
                lines.append("  IdentitiesOnly yes")
            case .password:
                lines.append("  PreferredAuthentications password,keyboard-interactive")
            case .automatic:
                break
            }
            if index > 0 { lines.append("  ProxyJump \(all[index - 1].alias)") }
        }
        lines.append("")
        lines.append("Host *")
        lines.append("  Include ~/.ssh/config")
        lines.append("  Include /etc/ssh/ssh_config")
        lines.append("")

        return SSHLaunchPlan(hops: Array(all.dropLast()), target: all[all.count - 1],
                             config: lines.joined(separator: "\n"))
    }
}
