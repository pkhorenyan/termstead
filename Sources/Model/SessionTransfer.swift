import Foundation
import Security

protocol SessionSecretStore: Sendable {
    func readSecret(_ account: String) throws -> String?
    func insertSecret(_ secret: String, account: String) throws
    func removeSecret(_ account: String) throws
}

extension KeychainStore: SessionSecretStore {
    struct AccessError: LocalizedError {
        var status: OSStatus
        var errorDescription: String? {
            "Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? "Access failed (\(status)).")"
        }
    }
    func readSecret(_ account: String) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw AccessError(status: status) }
        return value
    }
    func insertSecret(_ secret: String, account: String) throws {
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Termstead — \(account)", kSecValueData as String: Data(secret.utf8)]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw AccessError(status: status) }
    }
    func removeSecret(_ account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AccessError(status: status) }
    }
}

enum SessionTransfer {
    enum Conflict: String, CaseIterable, Identifiable, Sendable {
        case keepBoth, skip
        var id: String { rawValue }
        var label: String { self == .keepBoth ? "Keep both (rename imported sessions)" : "Skip existing sessions" }
    }
    struct SecretWrite: Sendable { var account: String; var value: String }
    struct Plan: Sendable {
        var snapshot: SessionSnapshot
        var added: [Session]
        var skipped: Int
        var renamed: [(from: String, to: String)]
        var secrets: [SecretWrite]
    }

    static func exportSnapshot(_ snapshot: SessionSnapshot, groupID: String? = nil) -> SessionSnapshot {
        guard let groupID else { return snapshot }
        var names: Set<String> = []
        var selectedGroups: Set<String> = []
        func gather(_ group: SessionGroup, selected: Bool) {
            let selected = selected || group.id == groupID
            if selected { selectedGroups.insert(group.id) }
            for node in group.children {
                switch node {
                case .session(let name): if selected { names.insert(name) }
                case .group(let child): gather(child, selected: selected)
                }
            }
        }
        snapshot.tree.forEach { gather($0, selected: false) }
        let byName = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.id, $0) })
        let byID = Dictionary(uniqueKeysWithValues: snapshot.sessions.compactMap { session in
            session.persistentID.map { ($0, session) }
        })
        // Include the complete dependency closure, including a bastion in a
        // different folder. Cycles terminate in the set and remain explicit.
        var pending = Array(names)
        while let name = pending.popLast() {
            for hop in byName[name]?.jumps ?? [] {
                let target = hop.sessionIdentity.flatMap { byID[$0] }
                    ?? (hop.sessionIdentity == nil ? byName[hop.host.trimmingCharacters(in: .whitespaces)] : nil)
                if let target, names.insert(target.id).inserted { pending.append(target.id) }
            }
        }
        func prune(_ group: SessionGroup) -> SessionGroup? {
            var result = group
            result.children = group.children.compactMap {
                switch $0 {
                case .session(let name): names.contains(name) ? .session(name) : nil
                case .group(let child): prune(child).map(TreeNode.group)
                }
            }
            return result.children.isEmpty && !selectedGroups.contains(group.id) ? nil : result
        }
        return SessionSnapshot(tree: snapshot.tree.compactMap(prune),
            sessions: snapshot.sessions.filter { names.contains($0.id) },
            pinnedIDs: snapshot.pinnedIDs.filter { names.contains($0) }, collapsedGroupIDs: [])
    }

    static func credentials(for snapshot: SessionSnapshot, using keychain: any SessionSecretStore) throws -> [SessionArchive.Credential] {
        var result: [SessionArchive.Credential] = []
        var cached: [String: String] = [:]
        var missing: Set<String> = []
        for session in snapshot.sessions {
            guard let identity = session.persistentID else { continue }
            var wanted: [SessionArchive.Credential] = []
            if session.kind != .telnet {
                wanted.append(.init(sessionID: identity, role: "password", value: ""))
            }
            if session.kind == .ssh && session.auth == .key && !session.keyPath.isEmpty {
                wanted.append(.init(sessionID: identity, role: "keyPassphrase", value: ""))
            }
            for hop in session.jumps {
                if hop.auth == .password {
                    wanted.append(.init(sessionID: identity, hopID: hop.id, role: "hopPassword", value: ""))
                }
                if hop.auth == .key && !hop.keyPath.isEmpty {
                    wanted.append(.init(sessionID: identity, hopID: hop.id, role: "hopKeyPassphrase", value: ""))
                }
            }
            for var credential in wanted {
                guard let account = SessionArchive.credentialAccount(credential, session: session), !missing.contains(account) else { continue }
                guard let value = try cached[account] ?? keychain.readSecret(account) else { missing.insert(account); continue }
                cached[account] = value
                credential.value = value
                result.append(credential)
            }
        }
        return result
    }

    static func plan(_ contents: SessionArchive.Contents, into current: SessionSnapshot,
                     conflict: Conflict) throws -> Plan {
        let incoming = contents.snapshot.sessions
        let existingByName = Dictionary(uniqueKeysWithValues: current.sessions.map { ($0.id, $0) })
        let existingByID = Dictionary(uniqueKeysWithValues: current.sessions.compactMap { s in s.persistentID.map { ($0, s) } })
        let sourceByName = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })
        let sourceByID = Dictionary(uniqueKeysWithValues: incoming.map { ($0.persistentID!, $0) })
        var skipped: Set<UUID> = []
        if conflict == .skip {
            for session in incoming where existingByName[session.id] != nil || existingByID[session.persistentID!] != nil {
                skipped.insert(session.persistentID!)
            }
            // A same-name conflict is not proof that two hosts are the same.
            // Do not redirect an imported chain to an unrelated existing host.
            var changed = true
            while changed {
                changed = false
                for session in incoming where !skipped.contains(session.persistentID!) {
                    if session.jumps.contains(where: { hop in
                        let target = hop.sessionIdentity ?? sourceByName[hop.host]?.persistentID
                        return target.map { skipped.contains($0) && existingByID[$0] == nil } ?? false
                    }) { changed = skipped.insert(session.persistentID!).inserted || changed }
                }
            }
        }
        var usedNames = Set(existingByName.keys)
        // Reserve the file's other names before suffixing a conflicting one.
        usedNames.formUnion(incoming.map(\.id))
        usedNames.formUnion(incoming.flatMap(\.jumps).filter { $0.sessionIdentity == nil }.map(\.host))
        var renamed: [(from: String, to: String)] = []
        var copies: [UUID: Session] = [:]
        var hopIDs: [UUID: UUID] = [:]
        var identities: [UUID: UUID] = [:]
        for session in incoming {
            let identity = session.persistentID!
            if skipped.contains(identity) {
                if let existing = existingByID[identity] { identities[identity] = existing.persistentID }
                continue
            }
            var copy = session
            if existingByName[session.id] != nil {
                var suffix = 2
                while usedNames.contains("\(session.id) (\(suffix))") { suffix += 1 }
                copy.id = "\(session.id) (\(suffix))"
                usedNames.insert(copy.id)
                renamed.append((session.id, copy.id))
            }
            copy.persistentID = UUID()
            identities[identity] = copy.persistentID
            copy.jumps = copy.jumps.map { hop in
                var copy = hop
                copy.id = UUID()
                hopIDs[hop.id] = copy.id
                return copy
            }
            copies[identity] = copy
        }
        var missingIDs: [UUID: UUID] = [:]
        for identity in Array(copies.keys) {
            var copy = copies[identity]!
            copy.jumps = try copy.jumps.map { hop in
                var copy = hop
                let targetID = hop.sessionIdentity ?? sourceByName[hop.host.trimmingCharacters(in: .whitespaces)]?.persistentID
                if let targetID {
                    // Missing/deleted/unsupported targets must not attach to a
                    // local session just because its name or UUID is reused.
                    let mapped = identities[targetID] ?? missingIDs[targetID] ?? UUID()
                    missingIDs[targetID] = mapped
                    let label = sourceByID[targetID].flatMap { copies[$0.persistentID!]?.id }
                        ?? existingByID[targetID]?.id ?? hop.host
                    copy.host = label
                    copy.sessionIdentity = mapped
                } else if existingByName[hop.host.trimmingCharacters(in: .whitespaces)] != nil {
                    throw SessionArchive.Problem.invalid("The literal jump host “\(hop.host)” matches an existing session name. Rename that session before importing.")
                }
                return copy
            }
            copies[identity] = copy
        }
        let added = incoming.compactMap { copies[$0.persistentID!] }
        guard !added.isEmpty else {
            return Plan(snapshot: current, added: [], skipped: skipped.count, renamed: [], secrets: [])
        }
        var groupIDs: [String: String] = [:]
        func remap(_ group: SessionGroup) -> SessionGroup? {
            var copy = group
            copy.id = "import-\(UUID().uuidString)"
            groupIDs[group.id] = copy.id
            copy.children = group.children.compactMap {
                switch $0 {
                case .group(let child): remap(child).map(TreeNode.group)
                case .session(let name): sourceByName[name].flatMap { copies[$0.persistentID!] }.map { .session($0.id) }
                }
            }
            return copy.children.isEmpty && !group.children.isEmpty ? nil : copy
        }
        let groups = contents.snapshot.tree.compactMap(remap)
        func newName(_ name: String) -> String? { sourceByName[name].flatMap { copies[$0.persistentID!]?.id } }
        let snapshot = SessionSnapshot(tree: current.tree + groups, sessions: current.sessions + added,
            pinnedIDs: current.pinnedIDs + contents.snapshot.pinnedIDs.compactMap(newName),
            collapsedGroupIDs: current.collapsedGroupIDs + contents.snapshot.collapsedGroupIDs.compactMap { groupIDs[$0] })
        var writes: [String: String] = [:]
        for var credential in contents.credentials {
            guard let copy = copies[credential.sessionID] else { continue }
            if let id = credential.hopID { credential.hopID = hopIDs[id] }
            guard let account = SessionArchive.credentialAccount(credential, session: copy) else {
                throw SessionArchive.Problem.invalid("A saved password does not match its session.")
            }
            writes[account] = credential.value
        }
        return Plan(snapshot: snapshot, added: added, skipped: skipped.count, renamed: renamed,
                    secrets: writes.sorted { $0.key < $1.key }.map { SecretWrite(account: $0.key, value: $0.value) })
    }

    /// Only insert new accounts. Existing secrets (notably a shared key's
    /// passphrase) survive. Finish this before exposing the new session tree.
    static func installSecrets(_ plan: Plan, using keychain: any SessionSecretStore) throws -> [String] {
        var installed: [String] = []
        do {
            for secret in plan.secrets {
                if try keychain.readSecret(secret.account) != nil { continue }
                try keychain.insertSecret(secret.value, account: secret.account)
                installed.append(secret.account)
            }
        } catch {
            var rollbackFailed = false
            for account in installed.reversed() {
                do { try keychain.removeSecret(account) } catch { rollbackFailed = true }
            }
            if rollbackFailed {
                throw SessionArchive.Problem.invalid("Import stopped. Some newly added passwords could not be removed from Keychain. No sessions were added.")
            }
            throw error
        }
        return installed
    }

    @MainActor
    static func importSessions(_ contents: SessionArchive.Contents, into store: SessionStore,
                               conflict: Conflict, keychain: any SessionSecretStore = KeychainStore.shared) async throws -> (Plan, Int) {
        let before = store.snapshot
        let plan = try plan(contents, into: before, conflict: conflict)
        let installed = try await BlockingWork.run { try installSecrets(plan, using: keychain) }
        guard store.snapshot == before else {
            try await BlockingWork.run {
                for account in installed { try keychain.removeSecret(account) }
            }
            throw SessionArchive.Problem.invalid("The session list changed during import. Review it and try again.")
        }
        if !plan.added.isEmpty { store.apply(plan.snapshot) }
        return (plan, installed.count)
    }
}
