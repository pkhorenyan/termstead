import Foundation

/// One hop in a session's ProxyJump chain.
///
/// Each hop authenticates on its own terms: a bastion often takes a different
/// key from the host behind it. `.session` means "whatever the session itself
/// uses", which is the common case and so the default.
struct JumpHost: Identifiable, Hashable, Codable, Sendable {
    enum Auth: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
        case session, key, password

        var id: String { rawValue }

        var label: String {
            switch self {
            case .session: "Same as session"
            case .key: "Key"
            case .password: "Password"
            }
        }

        /// For the segmented control on a hop's row, where "Same as session"
        /// does not fit beside the reordering buttons.
        var shortLabel: String {
            self == .session ? "Session" : label
        }
    }

    /// Saved with the session: it names the hop's Keychain entry, so a hop keeps
    /// its password when the chain is reordered.
    var id = UUID()
    /// A host name or address, or the name of a saved session. A pasted
    /// `user@host:port` still works: `SSHLaunch` splits it, and the fields
    /// below win over whatever it contained.
    var host: String
    /// Empty leaves the user name to ssh and `~/.ssh/config`; for a hop named
    /// after a saved session, to that session.
    var user: String = ""
    /// `nil` works the same way: ssh's default, or the saved session's.
    var port: Int?
    var auth: Auth = .session
    /// Only meaningful while `auth` is `.key`.
    var keyPath: String = Session.defaultKeyPath

    /// The host on its own, for the chain summary and the route chips.
    var hostPart: String {
        let typed = host.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return "…" }
        let afterUser = typed.split(separator: "@").last.map(String.init) ?? typed
        return afterUser.split(separator: ":").first.map(String.init) ?? "…"
    }
}

/// How a session proves who it is to the server.
enum SessionAuth: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    case password, key

    var id: String { rawValue }
    var label: String { self == .password ? "Password" : "Key" }
}

/// A saved server. `id` doubles as the display name, matching the mockup where
/// sessions are keyed by their name.
struct Session: Identifiable, Hashable, Codable, Sendable {
    /// What the key-file field starts out showing for a new session.
    static let defaultKeyPath = "~/.ssh/id_ed25519"

    var id: String
    var user: String
    var host: String
    var port: Int
    var icon: SessionIcon
    var auth: SessionAuth = .key
    /// Only meaningful while `auth` is `.key`.
    var keyPath: String = Session.defaultKeyPath
    /// The ProxyJump chain, in order. Hops carry their own auth settings, which
    /// is why this is a list of values and not the summary string it used to be
    /// — that summary could not survive a round trip through the settings sheet.
    var jumps: [JumpHost] = []
    /// The session's own color: `nil` for none of its own, `"none"`, a palette
    /// id or a custom `#RRGGBB` (see `GroupColor`). Shown only outside colored
    /// groups — inside one the group's wins (`GroupColor.sessionColorID`).
    /// Optional, so files written before sessions had colors still read.
    var colorID: String? = nil

    var address: String {
        port == 22 ? "\(user)@\(host)" : "\(user)@\(host):\(port)"
    }

    /// Rendered after the address, e.g. "via bastion-01 → nat-gw". Derived, so
    /// the sidebar, tabs and status bar all follow the chain automatically.
    var jumpSummary: String? {
        let hosts = jumps.map(\.hostPart).filter { $0 != "…" }
        guard !hosts.isEmpty else { return nil }
        return "via " + hosts.joined(separator: " → ")
    }

    /// Sidebar subtitle: address plus the jump chain when there is one.
    var subtitle: String {
        guard let jumpSummary else { return address }
        return "\(address) · \(jumpSummary)"
    }

    /// Status bar form, which always shows the port and the key type.
    var statusAddress: String {
        let base = "\(user)@\(host):\(port)"
        guard let jumpSummary else { return base }
        return "\(base) · \(jumpSummary.replacingOccurrences(of: "via ", with: "via "))"
    }
}

/// A folder in the session tree. Top-level groups are plain folders with no
/// color; anything nested may carry one and passes it down.
struct SessionGroup: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    var colorID: String?
    var children: [TreeNode]

    var color: RGB? { GroupColor.rgb(for: colorID) }
}

indirect enum TreeNode: Identifiable, Hashable, Codable, Sendable {
    case group(SessionGroup)
    case session(String)

    var id: String {
        switch self {
        case .group(let group): "group:\(group.id)"
        case .session(let id): "session:\(id)"
        }
    }

    /// Sessions underneath this node, counted recursively and regardless of
    /// whether the branch is collapsed.
    var sessionCount: Int {
        switch self {
        case .session: 1
        case .group(let group): group.children.reduce(0) { $0 + $1.sessionCount }
        }
    }
}
