import Foundation
import Observation

/// A command, or several lines of them, sent to a tab as if typed —
/// MobaXterm's macros.
struct Snippet: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var name: String
    var text: String
    /// Return after the last line, so the command runs; off leaves it on the
    /// prompt to finish by hand.
    var pressReturn = true

    /// What the shell gets: each line ended with Return, as typed. Not a
    /// bracketed paste — a shell holds a pasted line back until Return.
    var keystrokes: String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        while lines.last?.isEmpty == true { lines.removeLast() }
        let typed = lines.joined(separator: "\r")
        return pressReturn ? typed + "\r" : typed
    }

    var firstLine: String {
        text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
    }
}

/// The snippets, in the order the panel shows them, kept in
/// `snippets.json` beside `sessions.json`. A development launch or a test
/// run keeps them in memory, as it does the tree.
@MainActor
@Observable
final class SnippetStore {
    private(set) var snippets: [Snippet]
    var loadProblem: String?
    var saveProblem: String?
    private(set) var hasUnsavedChanges = false
    @ObservationIgnored private let url: URL?
    @ObservationIgnored private var needsRecoveryCopy = false

    static var defaultURL: URL {
        SessionPersistence.defaultURL.deletingLastPathComponent().appendingPathComponent("snippets.json")
    }

    init(url: URL?, snippets: [Snippet]? = nil) {
        self.url = url
        self.snippets = snippets ?? []
        if snippets == nil, url != nil { read() }
    }

    private func read() {
        guard let url else { return }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            guard !FileRecovery.isMissing(error) else { return }
            needsRecoveryCopy = true
            loadProblem = "Your snippets at \(url.path) could not be read. The original file will be kept until a recovery copy can be made. \(error.localizedDescription)"
            return
        }
        do {
            snippets = try JSONDecoder().decode([Snippet].self, from: data)
        } catch {
            do {
                let backup = try FileRecovery.backup(data, from: url, reason: "corrupt")
                loadProblem = "Your saved snippets could not be read. A copy was kept at \(backup.path), and Termstead started with an empty list."
            } catch {
                needsRecoveryCopy = true
                loadProblem = "Your snippets at \(url.path) could not be read or backed up. The original file will be kept until a recovery copy can be made."
            }
        }
    }

    /// The user's own file only when the tree is theirs too.
    static func forThisLaunch(_ storage: SessionStorage) -> SnippetStore {
        if storage.isTheUsersOwn { return SnippetStore(url: defaultURL) }
        return SnippetStore(url: nil, snippets: storage.startsWithSample ? sample : [])
    }

    static let sample = [
        Snippet(name: "Disk usage", text: "df -h"),
        Snippet(name: "Restart nginx", text: "sudo systemctl restart nginx && systemctl status nginx --no-pager"),
        Snippet(name: "Follow syslog", text: "sudo tail -f /var/log/syslog"),
        Snippet(name: "Update packages", text: "sudo apt update\nsudo apt list --upgradable"),
        Snippet(name: "Find large files", text: "du -ah . | sort -rh | head -20", pressReturn: false),
    ]

    func snippet(_ id: UUID) -> Snippet? { snippets.first { $0.id == id } }

    func save(_ snippet: Snippet) {
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[index] = snippet
        } else {
            snippets.append(snippet)
        }
        write()
    }

    @discardableResult
    func duplicate(_ id: UUID) -> Snippet? {
        guard let index = snippets.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = snippets[index]
        copy.id = UUID()
        copy.name += " copy"
        snippets.insert(copy, at: index + 1)
        write()
        return copy
    }

    func delete(_ id: UUID) {
        snippets.removeAll { $0.id == id }
        write()
    }

    /// `id` goes before the snippet at `index` (the end when it is past it).
    func move(_ id: UUID, to index: Int) {
        guard let from = snippets.firstIndex(where: { $0.id == id }) else { return }
        let moved = snippets.remove(at: from)
        let target = min(from < index ? index - 1 : index, snippets.count)
        snippets.insert(moved, at: target)
        write()
    }

    private func write() {
        guard let url else { return }
        hasUnsavedChanges = true
        do {
            // A failed backup must never become permission to overwrite the
            // unreadable original on the next edit or retry.
            if needsRecoveryCopy {
                do {
                    let original = try Data(contentsOf: url)
                    try FileRecovery.backup(original, from: url, reason: "recovery")
                } catch {
                    if !FileRecovery.isMissing(error) { throw error }
                }
                needsRecoveryCopy = false
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snippets).write(to: url, options: .atomic)
            hasUnsavedChanges = false
            saveProblem = nil
        } catch {
            saveProblem = "Your snippet changes have not been saved to \(url.path). \(error.localizedDescription)"
            NSLog("Termstead: could not save snippets to %@: %@", url.path, String(describing: error))
        }
    }

    func retrySave() {
        if hasUnsavedChanges { write() }
    }
}
