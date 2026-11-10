import Foundation

enum SessionReferences {
    /// Upgrade name-based links once, then keep their readable labels in step
    /// with renames. A missing UUID stays missing: reusing a deleted session's
    /// name must not silently redirect an existing jump chain.
    static func normalized(_ sessions: [String: Session]) -> [String: Session] {
        var result = sessions
        var used: Set<UUID> = []
        for name in result.keys.sorted() {
            var session = result[name]!
            if let id = session.persistentID, used.insert(id).inserted {
                continue
            }
            let id = UUID()
            session.persistentID = id
            used.insert(id)
            result[name] = session
        }
        let byIdentity = Dictionary(uniqueKeysWithValues: result.values.map { ($0.persistentID!, $0.id) })
        for name in result.keys.sorted() {
            var session = result[name]!
            session.jumps = session.jumps.map { hop in
                var linked = hop
                let target: Session?
                if let id = hop.sessionIdentity {
                    target = byIdentity[id].flatMap { result[$0] }
                } else {
                    target = result[hop.host.trimmingCharacters(in: .whitespaces)]
                }
                if let target {
                    linked.host = target.id
                    linked.sessionIdentity = target.persistentID
                }
                return linked
            }
            result[name] = session
        }
        return result
    }

    static func savedSession(for hop: JumpHost, in sessions: [String: Session]) throws -> Session? {
        if let id = hop.sessionIdentity {
            guard let saved = sessions.values.first(where: { $0.persistentID == id }) else {
                throw SSHLaunchError.missingSavedSession(hop.host)
            }
            return saved
        }
        return sessions[hop.host.trimmingCharacters(in: .whitespaces)]
    }
}
