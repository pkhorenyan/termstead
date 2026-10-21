import CryptoKit
import Foundation
import Security

/// A server's certificate, as FreeRDP hands it over: the chain in PEM.
struct RDPCertificate: Equatable, Sendable {
    /// DER, the server's own certificate first.
    var chain: [Data]

    var leaf: Data { chain.first ?? Data() }

    /// SHA-256 of the server's certificate, as Windows and mstsc show it.
    var fingerprint: String {
        SHA256.hash(data: leaf).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// What the certificate says it is for: its common name, mostly.
    var subject: String {
        guard let certificate = SecCertificateCreateWithData(nil, leaf as CFData) else { return "" }
        return SecCertificateCopySubjectSummary(certificate) as String? ?? ""
    }

    init?(pem: String) {
        var chain: [Data] = []
        var body: String?
        for line in pem.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("-----BEGIN CERTIFICATE") {
                body = ""
            } else if line.hasPrefix("-----END CERTIFICATE") {
                if let text = body, let der = Data(base64Encoded: text) { chain.append(der) }
                body = nil
            } else if body != nil {
                body! += line
            }
        }
        guard !chain.isEmpty else { return nil }
        self.chain = chain
    }

    /// Whether macOS trusts it for `host` — a certificate from a CA in the
    /// Keychain or the system's roots, for that name and still valid. Off
    /// the main thread: an evaluation may fetch intermediates or revocation.
    /// `nil` when trusted, else why not, in macOS's words.
    func systemDistrust(for host: String) async -> String? {
        let chain = chain
        return await Task.detached {
            let certificates = chain.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
            var trust: SecTrust?
            guard !certificates.isEmpty,
                  SecTrustCreateWithCertificates(certificates as CFArray,
                                                 SecPolicyCreateSSL(true, host as CFString),
                                                 &trust) == errSecSuccess,
                  let trust else { return "The certificate could not be read." }
            var error: CFError?
            if SecTrustEvaluateWithError(trust, &error) { return nil }
            return (error as (any Error)?)?.localizedDescription ?? "macOS does not trust it."
        }.value
    }
}

/// Certificates the user chose to trust, one per server: what known_hosts is
/// to ssh. `~/Library/Application Support/Termstead/rdp_known_hosts`, a line
/// per server, `host:port fingerprint`.
final class RDPKnownHosts: @unchecked Sendable {
    static let shared = RDPKnownHosts(url: URL.applicationSupportDirectory
        .appendingPathComponent("Termstead", isDirectory: true)
        .appendingPathComponent("rdp_known_hosts"))

    let url: URL
    private let lock = NSLock()

    init(url: URL) {
        self.url = url
    }

    func fingerprint(host: String, port: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return entries()[Self.key(host, port)]
    }

    func trust(_ fingerprint: String, host: String, port: Int) {
        lock.lock()
        defer { lock.unlock() }
        var all = entries()
        all[Self.key(host, port)] = fingerprint
        let text = all.keys.sorted().map { "\($0) \(all[$0]!)\n" }.joined()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // Not a secret, but nobody else's to change.
        FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8),
                                       attributes: [.posixPermissions: 0o600])
    }

    private static func key(_ host: String, _ port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }

    private func entries() -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            out[String(parts[0])] = String(parts[1])
        }
        return out
    }
}
