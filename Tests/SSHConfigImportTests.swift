import Foundation
import Testing
@testable import Termstead

struct SSHConfigImportTests {
    /// A config tree in a temporary directory: a main file that includes a
    /// glob, with patterns, `Match`, `Host=`, comments and quotes mixed in.
    private func makeConfig() throws -> (dir: URL, main: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-import-\(UUID().uuidString.prefix(8))")
        let conf = dir.appendingPathComponent("conf.d")
        try FileManager.default.createDirectory(at: conf, withIntermediateDirectories: true)
        let main = dir.appendingPathComponent("config").path
        try """
        # Personal servers. The Include goes first: inside a Host block ssh
        # would apply the included file to that host only.
        Include \(conf.path)/*.conf

        Host *
          ServerAliveInterval 60

        Host prod-web web-alias   # two names on one line
          HostName 10.0.0.5
          User deploy
          Port 2222
          IdentityFile ~/.ssh/prod_ed25519

        Host=staging
          HostName staging.example.com

        Host *.internal !secret db-?
          User ops

        Match host bastion
          User jump

        Host "with space"
          HostName spaced.example.com
        """.write(toFile: main, atomically: true, encoding: .utf8)
        try """
        Host lab-box
          HostName 192.168.1.20
          User pavel
        # A duplicate of a name already seen is imported once.
        Host prod-web
        """.write(to: conf.appendingPathComponent("lab.conf"), atomically: true, encoding: .utf8)
        return (dir, main)
    }

    @Test func tokensFollowSSHsRules() {
        #expect(SSHConfigImport.tokens("Host=staging") == ["Host", "staging"])
        #expect(SSHConfigImport.tokens("  Host a b   # comment") == ["Host", "a", "b"])
        #expect(SSHConfigImport.tokens("Host \"with space\" x") == ["Host", "with space", "x"])
        #expect(SSHConfigImport.tokens("HostName a=b") == ["HostName", "a=b"])
        #expect(SSHConfigImport.tokens("# only a comment").isEmpty)
    }

    @Test func aliasesAreConcreteNamesInOrderWithIncludes() throws {
        let (dir, main) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SSHConfigImport.aliases(configPath: main)
                == ["lab-box", "prod-web", "web-alias", "staging", "with space"])
    }

    @Test func missingConfigImportsNothing() {
        #expect(SSHConfigImport.aliases(configPath: "/nonexistent/sb-config").isEmpty)
    }

    @Test func resolveReadsWhatSSHWouldUse() throws {
        let (dir, main) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hosts = SSHConfigImport.resolve(["prod-web", "lab-box"], configPath: main)
        #expect(hosts.count == 2)

        let prod = try #require(hosts.first)
        #expect(prod.hostName == "10.0.0.5")
        #expect(prod.user == "deploy")
        #expect(prod.port == 2222)
        #expect(prod.identityFiles == ["~/.ssh/prod_ed25519"])

        let lab = hosts[1]
        #expect(lab.hostName == "192.168.1.20")
        #expect(lab.port == 22)
        // ssh's built-in key list is not the host's own.
        #expect(lab.identityFiles.isEmpty)
        #expect(lab.session.keyPath == "")
        #expect(lab.session.host == "lab-box")
    }

    /// The point of keeping the alias as the host: the generated config must
    /// still reach the user's block, which holds the real address.
    @Test func generatedConfigStillAppliesTheUsersBlock() throws {
        let (dir, main) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = try #require(SSHConfigImport.resolve(["prod-web"], configPath: main).first).session
        let plan = try SSHLaunch.plan(for: session, sessions: [:], keyExists: { _ in true })
        let config = plan.config.replacingOccurrences(of: "Include ~/.ssh/config", with: "Include \(main)")
        let file = dir.appendingPathComponent("generated").path
        try config.write(toFile: file, atomically: true, encoding: .utf8)

        let resolved = try #require(SSHConfigImport.resolve(["prod-web"], configPath: file).first)
        #expect(resolved.hostName == "10.0.0.5")
        #expect(resolved.user == "deploy")
        #expect(resolved.port == 2222)
    }

    @MainActor
    @Test func importAddsNewHostsOnceIntoTheirGroup() {
        let store = SessionStore(tree: [], sessions: [:], selectedID: nil, pinnedIDs: [])
        let first = store.importSessions([
            Session(id: "a", user: "u", host: "a", port: 22, icon: .server),
            Session(id: "b", user: "u", host: "b", port: 22, icon: .server),
        ])
        #expect(first.added == 2)
        #expect(store.tree.map(\.name) == ["SSH config"])

        let again = store.importSessions([
            Session(id: "b", user: "u", host: "b", port: 22, icon: .server),
            Session(id: "c", user: "u", host: "c", port: 22, icon: .server),
        ])
        #expect(again.added == 1)
        #expect(again.skipped == 1)
        #expect(store.tree.count == 1)
        #expect(store.session("c") != nil)
    }

    @MainActor
    @Test func reportWording() {
        #expect(AppState.report(found: 0, added: 0).title == "No hosts found in ~/.ssh/config")
        #expect(AppState.report(found: 3, added: 0).title == "Nothing new to import")
        #expect(AppState.report(found: 3, added: 1).title == "Imported 1 host")
        #expect(AppState.report(found: 3, added: 3).detail.contains("already") == false)
    }
}
