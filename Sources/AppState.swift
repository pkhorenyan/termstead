import SwiftUI

/// Whether a developer launched this copy: a Debug build, or any `-sb-*`
/// argument (`-sb-sample YES`, a route…). Only then is there a Debug menu —
/// it loads sample data and can clear every session without asking, which a
/// user must never meet.
enum DevelopmentLaunch {
    static var isActive: Bool {
        #if DEBUG
        return true
        #else
        return isActive(arguments: UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain))
        #endif
    }

    static func isActive(arguments: [String: Any]) -> Bool {
        arguments.keys.contains { $0.hasPrefix("sb-") }
    }
}

/// Window-level UI state: which form is up and the contents of the
/// quick-connect field. Open tabs live in `ConnectionStore`.
@MainActor
@Observable
final class AppState {
    enum Route: Identifiable {
        case newSession(parentGroupID: String?)
        case sessionSettings(id: String)
        case newGroup(parentGroupID: String?)
        case groupSettings(id: String)
        case quickConnect

        var id: String {
            switch self {
            case .newSession(let parent): "newSession:\(parent ?? "-")"
            case .sessionSettings(let id): "sessionSettings:\(id)"
            case .newGroup(let parent): "newGroup:\(parent ?? "-")"
            case .groupSettings(let id): "groupSettings:\(id)"
            case .quickConnect: "quickConnect"
            }
        }
    }

    var route: Route?
    /// A tab waiting for "Close the connection?" to be answered.
    var pendingClose: UUID?
    /// The Appearance window is up, and app-modal.
    var isAppearanceOpen = false
    /// Something modal is up; menu commands that would reach past it are off.
    var isModalOpen: Bool { route != nil || isAppearanceOpen }
    var quickConnect: String = ""
    /// Set when ⌘K should move focus into the quick-connect field.
    var quickConnectFocusToken: Int = 0

    /// Development hook: `open Termstead.app --args -sb-route newSession` lands
    /// straight on a screen that otherwise needs clicking to reach. Reads the
    /// argument domain, so no parsing is needed.
    func applyLaunchRoute() -> String? {
        guard let name = UserDefaults.standard.string(forKey: "sb-route") else { return nil }
        switch name {
        case "newSession": route = .newSession(parentGroupID: "web")
        case "newGroup": route = .newGroup(parentGroupID: "web")
        case "sessionSettings":
            // `-sb-session <name>` picks which one to open.
            let target = UserDefaults.standard.string(forKey: "sb-session") ?? "prod-web-01"
            route = .sessionSettings(id: target)
        case "quickConnect": route = .quickConnect
        case "groupSettings":
            // `-sb-group <id>` picks which one.
            route = .groupSettings(id: UserDefaults.standard.string(forKey: "sb-group") ?? "web")
        // `empty` needs nothing here: the store already started empty, see
        // `SessionStorage`.
        default: break
        }
        return name
    }

    func focusQuickConnect() { quickConnectFocusToken &+= 1 }

    /// What the sidebar shows: the session tree, or the active tab's files.
    enum SidebarTab: String, CaseIterable, Identifiable {
        case sessions, files
        var id: String { rawValue }
        /// MobaXterm's names, since the rail copies MobaXterm's.
        var label: String { self == .sessions ? "Sessions" : "SFTP" }
        var symbol: String { self == .sessions ? "server.rack" : "folder" }
    }

    var sidebarTab: SidebarTab = .sessions

    /// After a tab logs in the sidebar turns to its files, as MobaXterm's
    /// does — once the first folder has loaded, so it opens on folders, and
    /// not at all for a server without SFTP. Only for the tab in front, and
    /// only from Sessions: someone already in another tab's files keeps them.
    func showFiles(afterLoginOf connection: Connection, in store: ConnectionStore) async {
        guard sidebarTab == .sessions, store.active === connection else { return }
        guard await connection.fileBrowser.loadAfterLogin(),
              sidebarTab == .sessions, store.active === connection else { return }
        sidebarTab = .files
    }

    // MARK: - Import from ~/.ssh/config

    struct ImportReport: Equatable {
        var title: String
        var detail: String
    }

    var importReport: ImportReport?
    private(set) var isImporting = false

    /// `ssh -G` runs once per host, so the lookups happen off the main actor.
    func importSSHConfig(into store: SessionStore,
                         configPath: String = SSHConfigImport.defaultConfigPath) async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        let resolved = await Task.detached {
            SSHConfigImport.resolve(SSHConfigImport.aliases(configPath: configPath))
        }.value
        let result = store.importSessions(resolved.map(\.session))
        importReport = Self.report(found: resolved.count, added: result.added)
    }

    static func report(found: Int, added: Int) -> ImportReport {
        func hosts(_ count: Int) -> String { count == 1 ? "1 host" : "\(count) hosts" }
        if found == 0 {
            return ImportReport(title: "No hosts found in ~/.ssh/config",
                                detail: "Only Host entries with a plain name are imported; patterns such as * are not.")
        }
        if added == 0 {
            return ImportReport(title: "Nothing new to import",
                                detail: "All \(hosts(found)) in ~/.ssh/config are already in the sidebar.")
        }
        let skipped = found - added
        let rest = skipped == 0 ? "" : " \(hosts(skipped)) already in the sidebar \(skipped == 1 ? "was" : "were") left as they are."
        return ImportReport(title: "Imported \(hosts(added))",
                            detail: "They are in the “SSH config” group and connect with your ssh config’s own settings.\(rest)")
    }

    // MARK: - Find in the terminal

    enum FindStatus { case idle, found, notFound }

    var isFindOpen = false
    var findQuery = ""
    var findCaseSensitive = false
    var findStatus: FindStatus = .idle
    /// Bumped by ⌘F so the bar takes focus again when it is already open.
    var findFocusToken = 0
    /// The terminal the last search ran in, so switching tabs can clear its
    /// highlight instead of leaving a stale selection behind.
    @ObservationIgnored private weak var searchedTerminal: SSHTerminalView?

    func openFind() {
        isFindOpen = true
        findFocusToken &+= 1
    }

    /// `upward` searches toward older output, which is where anything worth
    /// finding in a terminal usually is — so it is what Return and ⌘G do.
    func find(in terminal: SSHTerminalView?, upward: Bool) {
        guard let terminal, !findQuery.isEmpty else { return }
        if let previous = searchedTerminal, previous !== terminal { previous.endFind() }
        searchedTerminal = terminal
        let found = terminal.find(findQuery, upward: upward, caseSensitive: findCaseSensitive)
        findStatus = found ? .found : .notFound
    }

    /// Another tab came forward: the query stays, the old tab's match goes.
    func activeTerminalChanged() {
        searchedTerminal?.endFind()
        searchedTerminal = nil
        findStatus = .idle
    }

    func closeFind() {
        isFindOpen = false
        findStatus = .idle
        searchedTerminal?.endFind()
        searchedTerminal = nil
    }

    /// Closes a tab, or asks first when it still has a live session.
    func requestClose(_ id: UUID, in connections: ConnectionStore, confirm: Bool) {
        if connections.needsCloseConfirmation(id, setting: confirm) {
            pendingClose = id
        } else {
            connections.close(id)
        }
    }
}
