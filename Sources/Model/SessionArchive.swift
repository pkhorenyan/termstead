import Foundation
import CommonCrypto
import CryptoKit
import Darwin

/// A transfer format independent of sessions.json. Each record has a string
/// protocol tag and an open JSON payload, so adding VNC needs no new envelope.
enum SessionArchive {
    static let format = "com.pavelkhorenyan.termstead.sessions"
    static let version = 1
    static let maxFileSize = 16 * 1024 * 1024
    static let rounds: UInt32 = 600_000

    enum Problem: LocalizedError {
        case invalid(String), newerVersion, passwordRequired, unlockFailed, cryptoFailed
        var errorDescription: String? {
            switch self {
            case .invalid(let detail): "Invalid session file. \(detail)"
            case .newerVersion: "This file needs a newer version of Termstead."
            case .passwordRequired: "Enter the password used to encrypt this file."
            case .unlockFailed: "The password is incorrect or the encrypted file has been damaged."
            case .cryptoFailed: "The session file could not be encrypted."
            }
        }
    }

    indirect enum JSON: Codable, Equatable, Sendable {
        case object([String: JSON]), array([JSON]), string(String), number(Double), bool(Bool), null
        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(String.self) { self = .string(v) }
            else if let v = try? c.decode(Double.self) { self = .number(v) }
            else if let v = try? c.decode([String: JSON].self) { self = .object(v) }
            else { self = .array(try c.decode([JSON].self)) }
        }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .object(let v): try c.encode(v)
            case .array(let v): try c.encode(v)
            case .string(let v): try c.encode(v)
            case .number(let v): try c.encode(v)
            case .bool(let v): try c.encode(v)
            case .null: try c.encodeNil()
            }
        }
    }

    struct Record: Codable, Sendable {
        var type: String
        var settings: JSON
    }
    /// Roles, rather than arbitrary Keychain account names supplied by a file.
    /// Unknown future roles are ignored; every known role is checked against
    /// its owning session before a Keychain write is possible.
    struct Credential: Codable, Sendable {
        var sessionID: UUID
        var hopID: UUID? = nil
        var role: String
        var value: String
    }
    struct Document: Codable, Sendable {
        var format = SessionArchive.format
        var version = SessionArchive.version
        var groups: [SessionGroup]
        var sessions: [Record]
        var pinnedIDs: [String]
        var collapsedGroupIDs: [String]
        var credentials: [Credential] = []
    }
    struct Envelope: Codable {
        var format = SessionArchive.format + ".encrypted"
        var version = SessionArchive.version
        var cipher = "AES-256-GCM"
        var kdf = "PBKDF2-HMAC-SHA256"
        var rounds = SessionArchive.rounds
        var salt: Data
        var sealed: Data
    }
    struct Contents: Sendable {
        var snapshot: SessionSnapshot
        var credentials: [Credential]
        var unsupportedTypes: [String]
        var unsupportedCount: Int
    }

    static func document(_ snapshot: SessionSnapshot, credentials: [Credential] = []) throws -> Document {
        let records = try snapshot.sessions.map { session in
            Record(type: session.kind.rawValue,
                   settings: try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(session)))
        }
        return Document(groups: snapshot.tree, sessions: records, pinnedIDs: snapshot.pinnedIDs,
                        collapsedGroupIDs: snapshot.collapsedGroupIDs, credentials: credentials)
    }

    static func encode(_ document: Document, password: String? = nil) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let plain = try encoder.encode(document)
        guard plain.count <= maxFileSize else { throw Problem.invalid("The file is too large.") }
        guard let password else {
            guard document.credentials.isEmpty else {
                throw Problem.invalid("Saved passwords require an encrypted export.")
            }
            return plain
        }
        guard !password.isEmpty else { throw Problem.passwordRequired }
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let key = try derive(password, salt: salt, rounds: rounds)
        let box = try AES.GCM.seal(plain, using: key, authenticating: Data(format.utf8))
        guard let sealed = box.combined else { throw Problem.cryptoFailed }
        let result = try encoder.encode(Envelope(salt: salt, sealed: sealed))
        guard result.count <= maxFileSize else { throw Problem.invalid("The file is too large.") }
        return result
    }

    static func isEncrypted(_ data: Data) throws -> Bool {
        guard data.count <= maxFileSize else { throw Problem.invalid("The file is too large.") }
        struct Header: Decodable { var format: String; var version: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data),
              header.format == format || header.format == format + ".encrypted" else {
            throw Problem.invalid("Choose a Termstead session export.")
        }
        guard header.version == version else { throw Problem.newerVersion }
        return header.format.hasSuffix(".encrypted")
    }

    static func decode(_ data: Data, password: String? = nil) throws -> Contents {
        let encrypted = try isEncrypted(data)
        let plain: Data
        if encrypted {
            guard let password, !password.isEmpty else { throw Problem.passwordRequired }
            guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
                  envelope.cipher == "AES-256-GCM", envelope.kdf == "PBKDF2-HMAC-SHA256",
                  envelope.rounds == rounds, envelope.salt.count == 32 else {
                throw Problem.invalid("Unsupported encryption settings.")
            }
            let key = try derive(password, salt: envelope.salt, rounds: envelope.rounds)
            do {
                plain = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed), using: key,
                                         authenticating: Data(format.utf8))
            } catch { throw Problem.unlockFailed }
        } else { plain = data }
        guard let doc = try? JSONDecoder().decode(Document.self, from: plain) else {
            throw Problem.invalid("The session data could not be read.")
        }
        guard doc.format == format, doc.version == version else { throw Problem.newerVersion }
        guard encrypted || doc.credentials.isEmpty else {
            throw Problem.invalid("Saved passwords must be in an encrypted file.")
        }
        return try contents(doc)
    }

    private static func derive(_ password: String, salt: Data, rounds: UInt32) throws -> SymmetricKey {
        let bytes = Array(password.utf8)
        var key = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeBytes { pass in
            salt.withUnsafeBytes { salt in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    pass.baseAddress!.assumingMemoryBound(to: Int8.self), bytes.count,
                    salt.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &key, 32)
            }
        }
        guard status == kCCSuccess else { throw Problem.cryptoFailed }
        defer { key.withUnsafeMutableBytes { _ = $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        return SymmetricKey(data: key)
    }

    static func contents(_ doc: Document) throws -> Contents {
        guard doc.sessions.count <= 10_000, doc.credentials.count <= 100_000 else {
            throw Problem.invalid("Too many sessions or saved passwords.")
        }
        var sessions: [Session] = []
        var unsupported: [String] = []
        var allNames: Set<String> = []
        var names: Set<String> = []
        var identities: Set<UUID> = []
        var hops: Set<UUID> = []
        for record in doc.sessions {
            guard case .object(let settings) = record.settings,
                  case .string(let name)? = settings["id"], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  allNames.insert(name).inserted else { throw Problem.invalid("Missing or duplicate session names.") }
            guard SessionKind(rawValue: record.type) != nil else {
                unsupported.append(record.type)
                continue
            }
            guard let session = try? JSONDecoder().decode(Session.self, from: JSONEncoder().encode(record.settings)),
                  session.kind.rawValue == record.type, (1...65535).contains(session.port),
                  let identity = session.persistentID, identities.insert(identity).inserted else {
                throw Problem.invalid("Invalid or duplicate session settings.")
            }
            for hop in session.jumps {
                guard hops.insert(hop.id).inserted, hop.port == nil || (1...65535).contains(hop.port!) else {
                    throw Problem.invalid("Invalid or duplicate jump host settings.")
                }
            }
            for forward in session.forwards {
                guard let port = forward.listenPort, (1...65535).contains(port),
                      forward.kind == .dynamic || forward.destinationPort.map({ (1...65535).contains($0) }) == true else {
                    throw Problem.invalid("Invalid tunnel ports.")
                }
            }
            names.insert(name)
            sessions.append(session)
        }
        var groupIDs: Set<String> = []
        var placed: Set<String> = []
        func clean(_ group: SessionGroup, depth: Int) throws -> SessionGroup {
            guard depth < 32, groupIDs.count < 10_000, groupIDs.insert(group.id).inserted else {
                throw Problem.invalid("Invalid folder structure.")
            }
            var result = group
            result.children = try group.children.compactMap { node in
                switch node {
                case .group(let child): return .group(try clean(child, depth: depth + 1))
                case .session(let name):
                    guard allNames.contains(name), placed.insert(name).inserted else {
                        throw Problem.invalid("Missing or duplicate sessions in folders.")
                    }
                    return names.contains(name) ? .session(name) : nil
                }
            }
            return result
        }
        let groups = try doc.groups.map { try clean($0, depth: 0) }
        guard placed == allNames else { throw Problem.invalid("Some sessions have no folder.") }
        let snapshot = SessionSnapshot(tree: groups, sessions: sessions,
            pinnedIDs: doc.pinnedIDs.filter { names.contains($0) },
            collapsedGroupIDs: doc.collapsedGroupIDs.filter { groupIDs.contains($0) })
        let known = Dictionary(uniqueKeysWithValues: sessions.map { ($0.persistentID!, $0) })
        var accounts: [String: String] = [:]
        let credentials = try doc.credentials.filter { credential in
            guard ["password", "keyPassphrase", "hopPassword", "hopKeyPassphrase"].contains(credential.role) else { return false }
            // Passwords belonging to an unsupported protocol are skipped too.
            guard let session = known[credential.sessionID] else {
                if !unsupported.isEmpty { return false }
                throw Problem.invalid("A saved password has no session.")
            }
            guard let account = credentialAccount(credential, session: session),
                  accounts[account] == nil || accounts[account] == credential.value else {
                throw Problem.invalid("Invalid or duplicate saved passwords.")
            }
            accounts[account] = credential.value
            return true
        }
        return Contents(snapshot: snapshot, credentials: credentials,
                        unsupportedTypes: Array(Set(unsupported)).sorted(), unsupportedCount: unsupported.count)
    }

    static func credentialAccount(_ credential: Credential, session: Session) -> String? {
        switch credential.role {
        case "password" where credential.hopID == nil:
            return SSHLaunch.sessionPasswordAccount(session.id)
        case "keyPassphrase" where credential.hopID == nil && !session.keyPath.isEmpty:
            return SSHLaunch.passphraseAccount(forKey: session.keyPath)
        case "hopPassword", "hopKeyPassphrase":
            guard let hop = session.jumps.first(where: { $0.id == credential.hopID }) else { return nil }
            return credential.role == "hopPassword" ? SSHLaunch.hopPasswordAccount(hop.id)
                : (hop.keyPath.isEmpty ? nil : SSHLaunch.passphraseAccount(forKey: hop.keyPath))
        default: return nil
        }
    }

    static func read(from url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, (size.fileSize ?? maxFileSize + 1) <= maxFileSize else {
            throw Problem.invalid("Choose a session file smaller than 16 MB.")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maxFileSize else { throw Problem.invalid("The file is too large.") }
        return data
    }

    static func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".termstead-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.close() }
        catch { try? handle.close(); throw error }
        // Same-directory rename publishes a complete private file atomically.
        guard rename(temporary.path, url.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}
