import Foundation
import Observation

/// Everything about the session tree that outlives a launch. Selection and the
/// live state of connections are deliberately absent.
struct SessionSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = SessionSnapshot.currentVersion
    var tree: [SessionGroup]
    /// An array rather than the store's dictionary, sorted by id, so the file
    /// comes out byte-identical when nothing changed and diffs stay readable.
    var sessions: [Session]
    var pinnedIDs: [String]
    var collapsedGroupIDs: [String]

    static let empty = SessionSnapshot(tree: [], sessions: [], pinnedIDs: [], collapsedGroupIDs: [])
}

/// Reads and writes `sessions.json`.
enum SessionPersistence {
    enum LoadResult: Equatable {
        case missing
        case loaded(SessionSnapshot)
        /// The file was there and could not be read. It has been renamed out of
        /// the way rather than left to be overwritten by an empty tree.
        case corrupt(movedTo: URL?)
    }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Termstead", isDirectory: true)
            .appendingPathComponent("sessions.json")
    }

    static func load(from url: URL) -> LoadResult {
        guard let data = try? Data(contentsOf: url) else {
            return FileManager.default.fileExists(atPath: url.path) ? .corrupt(movedTo: nil) : .missing
        }
        if let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data),
           snapshot.version <= SessionSnapshot.currentVersion {
            return .loaded(snapshot)
        }
        return .corrupt(movedTo: moveAside(url))
    }

    static func save(_ snapshot: SessionSnapshot, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    private static func moveAside(_ url: URL) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let target = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)")
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return target
        } catch {
            return nil
        }
    }
}

extension SessionStore {
    var snapshot: SessionSnapshot {
        SessionSnapshot(
            tree: tree,
            sessions: sessions.values.sorted { $0.id < $1.id },
            pinnedIDs: pinnedIDs,
            collapsedGroupIDs: collapsedGroupIDs.sorted()
        )
    }

    convenience init(snapshot: SessionSnapshot) {
        self.init(tree: [], sessions: [:], selectedID: nil, pinnedIDs: [])
        apply(snapshot)
    }

    func apply(_ snapshot: SessionSnapshot) {
        tree = snapshot.tree
        sessions = Dictionary(snapshot.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // A pin for a session that no longer exists would render as a blank row.
        pinnedIDs = snapshot.pinnedIDs.filter { sessions[$0] != nil }
        collapsedGroupIDs = Set(snapshot.collapsedGroupIDs)
        selection = nil
        selectedItems = []
    }
}

/// Where the tree lives this launch, and whether it is written back at all.
///
/// Development and tests must never touch the real file: `-sb-sample YES`
/// loads the sample tree and keeps it in memory, and so does any `-sb-route`
/// (the routes name sample sessions; `empty` starts with nothing instead).
/// `-sb-store <path>` points at another file — with a route too — and a test
/// run keeps everything in memory.
@MainActor
@Observable
final class SessionStorage {
    /// `nil` when nothing is written back.
    let url: URL?
    let initialSnapshot: SessionSnapshot
    let startsWithSample: Bool
    /// Set when the saved file could not be read, for the one-time alert.
    var loadProblem: String?
    @ObservationIgnored private var lastSaved: SessionSnapshot?

    private init(url: URL?, snapshot: SessionSnapshot, sample: Bool, problem: String?) {
        self.url = url
        initialSnapshot = snapshot
        startsWithSample = sample
        loadProblem = problem
        lastSaved = snapshot
    }

    static func forThisLaunch(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SessionStorage {
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil {
            return SessionStorage(url: nil, snapshot: .empty, sample: false, problem: nil)
        }
        // An explicit `-sb-store` file wins over a route's sample tree: it is
        // never the real one, and a route can then open a form on it.
        if let route = defaults.string(forKey: "sb-route"), defaults.string(forKey: "sb-store") == nil {
            return SessionStorage(url: nil, snapshot: .empty, sample: route != "empty", problem: nil)
        }
        if defaults.bool(forKey: "sb-sample") {
            return SessionStorage(url: nil, snapshot: .empty, sample: true, problem: nil)
        }
        let url = defaults.string(forKey: "sb-store").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? SessionPersistence.defaultURL

        switch SessionPersistence.load(from: url) {
        case .missing:
            return SessionStorage(url: url, snapshot: .empty, sample: false, problem: nil)
        case .loaded(let snapshot):
            return SessionStorage(url: url, snapshot: snapshot, sample: false, problem: nil)
        case .corrupt(let movedTo):
            let problem = if let movedTo {
                "Your saved sessions could not be read. The file was kept as \(movedTo.lastPathComponent) in \(movedTo.deletingLastPathComponent().path), and Termstead started with an empty list."
            } else {
                "Your saved sessions at \(url.path) could not be read. Termstead started with an empty list and will not overwrite that file until you change something."
            }
            return SessionStorage(url: url, snapshot: .empty, sample: false, problem: problem)
        }
    }

    func makeStore() -> SessionStore {
        startsWithSample ? .sample() : SessionStore(snapshot: initialSnapshot)
    }

    func save(_ snapshot: SessionSnapshot) {
        guard let url, snapshot != lastSaved else { return }
        do {
            try SessionPersistence.save(snapshot, to: url)
            lastSaved = snapshot
        } catch {
            NSLog("Termstead: could not save sessions to %@: %@", url.path, String(describing: error))
        }
    }
}
