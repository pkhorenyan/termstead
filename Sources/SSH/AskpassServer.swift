import Foundation

/// Decides which stored secret, if any, answers a prompt ssh shows.
///
/// Strict on purpose: a password is only ever handed over for the exact
/// `user@host` it was saved for. Sending the wrong one would give it to a
/// server that was never meant to have it, so anything ambiguous goes to the
/// terminal instead.
struct AskpassMatcher: Sendable {
    struct Candidate: Sendable, Equatable {
        var host: String
        /// `nil` when the user name was left to ssh; any user then matches.
        var user: String?
        var account: String
    }

    var passwords: [Candidate]
    /// Key files the chain names, tilde-expanded.
    var keyPaths: [String]

    /// ssh cuts names short in its prompts (`%.100s` for a key file, `%.30s`
    /// for a user name), so a name that reaches the limit is matched as a
    /// prefix — and still only when exactly one candidate fits.
    static let keyPathLimit = 100
    static let userLimit = 30

    init(plan: SSHLaunchPlan) {
        let endpoints = plan.hops + [plan.target]
        passwords = endpoints.compactMap { endpoint in
            endpoint.passwordAccount.map { Candidate(host: endpoint.host, user: endpoint.user, account: $0) }
        }
        keyPaths = endpoints.compactMap { endpoint in
            if case .key(let path) = endpoint.auth { return (path as NSString).expandingTildeInPath }
            return nil
        }
    }

    init(passwords: [Candidate], keyPaths: [String] = []) {
        self.passwords = passwords
        self.keyPaths = keyPaths
    }

    /// How many hops in the chain use `account`. One key with a passphrase on
    /// both the bastion and the target is asked for twice — by the jump's ssh
    /// and by the target's — and each ask is legitimate.
    func uses(of account: String) -> Int {
        let passwordUses = passwords.filter { $0.account == account }.count
        let keyUses = keyPaths.filter { SSHLaunch.passphraseAccount(forKey: $0) == account }.count
        return max(1, passwordUses + keyUses)
    }

    /// The Keychain account that answers `prompt`, if exactly one does.
    func account(for prompt: String) -> String? {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        if let shown = Self.capture(text, prefix: "Enter passphrase for key '", suffix: "':") {
            guard shown.count >= Self.keyPathLimit else { return SSHLaunch.passphraseAccount(forKey: shown) }
            let fits = Set(keyPaths.filter { $0.hasPrefix(shown) })
            return fits.count == 1 ? fits.first.map(SSHLaunch.passphraseAccount(forKey:)) : nil
        }

        // "user@host's password:" (password auth) and
        // "(user@host) Password:" (keyboard-interactive, OpenSSH 8.9+).
        let name = Self.capture(text, prefix: "", suffix: "'s password:")
            ?? Self.capture(text, prefix: "(", suffix: ") Password:")
        guard let name, let at = name.lastIndex(of: "@") else { return nil }
        let user = String(name[..<at])
        let host = String(name[name.index(after: at)...])

        let matches = Set(passwords
            .filter { candidate in
                guard candidate.host == host else { return false }
                guard let expected = candidate.user else { return true }
                return expected == user || (user.count >= Self.userLimit && expected.hasPrefix(user))
            }
            .map(\.account))
        return matches.count == 1 ? matches.first : nil
    }

    private static func capture(_ text: String, prefix: String, suffix: String) -> String? {
        guard text.hasPrefix(prefix), text.hasSuffix(suffix),
              text.count > prefix.count + suffix.count else { return nil }
        return String(text.dropFirst(prefix.count).dropLast(suffix.count))
    }
}

/// Listens on a Unix socket in the connection's private directory and answers
/// `termstead-askpass` from the Keychain.
///
/// Each stored secret is given once for every hop that uses it. If ssh asks
/// for it more often than that, the stored value was refused, and the terminal
/// takes over — so a wrong password costs one attempt, not a lockout.
final class AskpassServer: @unchecked Sendable {
    let socketPath: String
    let token = UUID().uuidString

    private let matcher: AskpassMatcher
    private let keychain: KeychainStore
    private let queue = DispatchQueue(label: "termstead.askpass")
    private var listener: Int32 = -1
    private var source: (any DispatchSourceRead)?
    /// Touched only on `queue`.
    private var answered: [String: Int] = [:]

    init?(directory: URL, matcher: AskpassMatcher, keychain: KeychainStore = .shared) {
        socketPath = directory.appendingPathComponent("askpass").path
        self.matcher = matcher
        self.keychain = keychain
        guard var address = AskpassProtocol.address(for: socketPath) else { return nil }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(socketPath, 0o600) == 0, listen(fd, 4) == 0 else {
            close(fd)
            return nil
        }
        listener = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    var environment: [String: String] {
        ["SSH_ASKPASS": Self.helperPath,
         "SSH_ASKPASS_REQUIRE": "force",
         AskpassProtocol.socketVariable: socketPath,
         AskpassProtocol.tokenVariable: token]
    }

    static var helperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/termstead-askpass").path
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit { source?.cancel() }

    private func acceptOne() {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !data.contains(0x0A), data.count < 65536 {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
        }
        guard let request = try? JSONDecoder().decode(AskpassProtocol.Request.self,
                                                      from: data.prefix { $0 != 0x0A }),
              request.token == token else { return }

        var secret: String?
        if let account = matcher.account(for: request.prompt),
           answered[account, default: 0] < matcher.uses(of: account) {
            secret = keychain.secret(for: account)
            if secret != nil { answered[account, default: 0] += 1 }
        }

        guard var reply = try? JSONEncoder().encode(AskpassProtocol.Reply(secret: secret)) else { return }
        reply.append(0x0A)
        _ = reply.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
    }

    /// Whether anything in this chain has a secret stored — if not, ssh is
    /// left to prompt on its own and the helper is not involved at all.
    static func hasStoredSecrets(for plan: SSHLaunchPlan, keychain: KeychainStore = .shared) -> Bool {
        let endpoints = plan.hops + [plan.target]
        let passwords = endpoints.compactMap(\.passwordAccount)
        let passphrases = endpoints.compactMap { endpoint -> String? in
            if case .key(let path) = endpoint.auth { return SSHLaunch.passphraseAccount(forKey: path) }
            return nil
        }
        return (passwords + passphrases).contains { keychain.contains($0) }
    }
}
