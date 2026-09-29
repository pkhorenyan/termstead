import Foundation
import Testing
@testable import Termstead

struct SSHLaunchTests {
    private let allKeysExist: (String) -> Bool = { _ in true }
    private let noKeysExist: (String) -> Bool = { _ in false }

    private func session(_ id: String = "web", user: String = "deploy", host: String = "10.0.1.13",
                         port: Int = 22, auth: SessionAuth = .key,
                         keyPath: String = "~/.ssh/web_key", jumps: [JumpHost] = []) -> Session {
        Session(id: id, user: user, host: host, port: port, icon: .server,
                auth: auth, keyPath: keyPath, jumps: jumps)
    }

    @Test func directKeySession() throws {
        let plan = try SSHLaunch.plan(for: session(), sessions: [:], keyExists: allKeysExist)
        #expect(plan.hops.isEmpty)
        #expect(plan.target.alias == "10.0.1.13")
        #expect(plan.config.contains("""
        Host 10.0.1.13
          User deploy
          Port 22
          IdentityFile "~/.ssh/web_key"
          IdentitiesOnly yes
        """))
        #expect(!plan.config.contains("ProxyJump"))
        #expect(plan.arguments(configPath: "/tmp/c") == ["-F", "/tmp/c", "-o", "ServerAliveInterval=30", "10.0.1.13"])
    }

    @Test func userConfigIsIncludedAfterOurBlocks() throws {
        let config = try SSHLaunch.plan(for: session(), sessions: [:], keyExists: allKeysExist).config
        let ours = try #require(config.range(of: "Host 10.0.1.13"))
        let theirs = try #require(config.range(of: "Include ~/.ssh/config"))
        #expect(ours.lowerBound < theirs.lowerBound)
        #expect(config.contains("Include /etc/ssh/ssh_config"))
    }

    @Test func missingDefaultKeyFallsBackToSsh() throws {
        let plan = try SSHLaunch.plan(for: session(keyPath: Session.defaultKeyPath),
                                      sessions: [:], keyExists: noKeysExist)
        #expect(plan.target.auth == .automatic)
        #expect(!plan.config.contains("IdentityFile"))
    }

    @Test func explicitlyChosenKeyIsKeptEvenIfMissing() throws {
        // ssh says "no such identity" itself, which is more useful than
        // silently trying something else.
        let plan = try SSHLaunch.plan(for: session(keyPath: "~/.ssh/gone"), sessions: [:], keyExists: noKeysExist)
        #expect(plan.target.auth == .key("~/.ssh/gone"))
    }

    @Test func passwordSessionPrefersPassword() throws {
        let plan = try SSHLaunch.plan(for: session(auth: .password), sessions: [:], keyExists: allKeysExist)
        #expect(plan.config.contains("PreferredAuthentications password,keyboard-interactive"))
        #expect(!plan.config.contains("IdentityFile"))
        #expect(plan.target.passwordAccount == "session:web:password")
        #expect(plan.target.promptName == "deploy@10.0.1.13")
    }

    @Test func twoHopsEachWithTheirOwnAuth() throws {
        let bastion = JumpHost(host: "jump@bastion-01", auth: .key, keyPath: "~/.ssh/bastion")
        let nat = JumpHost(host: "ops@nat-gw:2200", auth: .password)
        let plan = try SSHLaunch.plan(for: session(jumps: [bastion, nat]), sessions: [:], keyExists: allKeysExist)

        #expect(plan.hops.map(\.alias) == ["bastion-01", "nat-gw"])
        #expect(plan.config.contains("""
        Host bastion-01
          User jump
          IdentityFile "~/.ssh/bastion"
          IdentitiesOnly yes
        """))
        #expect(plan.config.contains("""
        Host nat-gw
          User ops
          Port 2200
          PreferredAuthentications password,keyboard-interactive
          ProxyJump bastion-01
        """))
        #expect(plan.config.contains("  ProxyJump nat-gw\n"))
        #expect(plan.hops[1].passwordAccount == "hop:\(nat.id.uuidString):password")
    }

    @Test func hopUserAndPortFieldsAreUsed() throws {
        let hop = JumpHost(host: "bastion-01", user: "jump", port: 2201, auth: .key, keyPath: "~/.ssh/b")
        let plan = try SSHLaunch.plan(for: session(jumps: [hop]), sessions: [:], keyExists: allKeysExist)
        #expect(plan.hops[0].user == "jump")
        #expect(plan.hops[0].port == 2201)
        #expect(plan.config.contains("Host bastion-01\n  User jump\n  Port 2201\n"))
    }

    @Test func fieldsWinOverAPastedAddress() throws {
        let hop = JumpHost(host: "old@bastion-01:22", user: "new", port: 2222)
        let plan = try SSHLaunch.plan(for: session(jumps: [hop]), sessions: [:], keyExists: allKeysExist)
        #expect(plan.hops[0].host == "bastion-01")
        #expect(plan.hops[0].user == "new")
        #expect(plan.hops[0].port == 2222)
    }

    @Test func aPastedAddressStillWorksWithEmptyFields() throws {
        let hop = JumpHost(host: "ops@nat-gw:2200")
        let plan = try SSHLaunch.plan(for: session(jumps: [hop]), sessions: [:], keyExists: allKeysExist)
        #expect(plan.hops[0].user == "ops")
        #expect(plan.hops[0].port == 2200)
    }

    @Test func fieldsOverrideASavedSessionUsedAsAHop() throws {
        let saved = session("bastion", user: "admin", host: "203.0.113.7", port: 2222)
        let hop = JumpHost(host: "bastion", user: "other", port: 2022)
        let plan = try SSHLaunch.plan(for: session(jumps: [hop]), sessions: ["bastion": saved],
                                      keyExists: allKeysExist)
        #expect(plan.hops[0].host == "203.0.113.7")
        #expect(plan.hops[0].user == "other")
        #expect(plan.hops[0].port == 2022)
    }

    @Test func hopWithSessionAuthInheritsTheTargets() throws {
        let hop = JumpHost(host: "bastion-01")
        let plan = try SSHLaunch.plan(for: session(auth: .password, jumps: [hop]),
                                      sessions: [:], keyExists: allKeysExist)
        #expect(plan.hops[0].auth == .password)
        #expect(plan.hops[0].passwordAccount == "session:web:password")
        // No user typed: left to ssh and the user's config, not guessed.
        #expect(plan.hops[0].user == nil)
        #expect(plan.config.contains("Host bastion-01\n  PreferredAuthentications"))
    }

    @Test func hopNamedAfterASavedSessionUsesThatSession() throws {
        let saved = session("bastion", user: "admin", host: "203.0.113.7", port: 2222,
                            auth: .key, keyPath: "~/.ssh/admin")
        let target = session(jumps: [JumpHost(host: "bastion")])
        let plan = try SSHLaunch.plan(for: target, sessions: ["bastion": saved], keyExists: allKeysExist)

        #expect(plan.hops[0].host == "203.0.113.7")
        #expect(plan.hops[0].user == "admin")
        #expect(plan.hops[0].port == 2222)
        #expect(plan.hops[0].auth == .key("~/.ssh/admin"))
        #expect(plan.hops[0].passwordAccount == "session:bastion:password")
    }

    @Test func aSessionCannotJumpThroughItself() {
        let target = session(jumps: [JumpHost(host: "web")])
        #expect(throws: SSHLaunchError.jumpLoop("web")) {
            try SSHLaunch.plan(for: target, sessions: ["web": target], keyExists: allKeysExist)
        }
    }

    @Test func sameHostTwiceGetsAPrivateAlias() throws {
        let hop = JumpHost(host: "me@127.0.0.1:2222", auth: .key, keyPath: "~/.ssh/a")
        let plan = try SSHLaunch.plan(for: session(host: "127.0.0.1", port: 2223, jumps: [hop]),
                                      sessions: [:], keyExists: allKeysExist)
        #expect(plan.hops[0].alias == "127.0.0.1")
        #expect(plan.target.alias == "termstead-target")
        #expect(plan.config.contains("Host termstead-target\n  HostName 127.0.0.1\n"))
        #expect(plan.config.contains("  ProxyJump 127.0.0.1\n"))
        #expect(plan.arguments(configPath: "c").last == "termstead-target")
    }

    @Test func emptyHopIsAnError() {
        #expect(throws: SSHLaunchError.emptyHop(index: 0)) {
            try SSHLaunch.plan(for: session(jumps: [JumpHost(host: "  ")]), sessions: [:])
        }
    }

    @Test(arguments: ["bad host", "-oProxyCommand=x", "a#b", "a\"b", "h*st", "", "a\nb", "a,b"])
    func valuesThatWouldChangeTheConfigAreRejected(host: String) {
        #expect(throws: SSHLaunchError.self) {
            try SSHLaunch.plan(for: session(host: host), sessions: [:])
        }
    }

    @Test func keyPathWithAQuoteIsRejected() {
        #expect(throws: SSHLaunchError.self) {
            try SSHLaunch.plan(for: session(keyPath: "~/.ssh/a\"b"), sessions: [:], keyExists: allKeysExist)
        }
    }

    @Test func keyPathWithSpacesIsQuoted() throws {
        let plan = try SSHLaunch.plan(for: session(keyPath: "~/My Keys/id"), sessions: [:], keyExists: allKeysExist)
        #expect(plan.config.contains("IdentityFile \"~/My Keys/id\""))
    }

    @Test func addressParsing() throws {
        #expect(try SSHLaunch.parseAddress("host") == (nil, "host", nil))
        #expect(try SSHLaunch.parseAddress("u@host:2200") == ("u", "host", 2200))
        #expect(try SSHLaunch.parseAddress("[::1]:22") == (nil, "::1", 22))
        #expect(try SSHLaunch.parseAddress("fe80::1") == (nil, "fe80::1", nil))
        #expect(throws: SSHLaunchError.self) { try SSHLaunch.parseAddress("host:99999") }
        #expect(throws: SSHLaunchError.self) { try SSHLaunch.parseAddress("host:abc") }
    }

    @Test func quickConnectIsLeftToSsh() throws {
        let plan = try SSHLaunch.plan(forAddress: " root@192.168.1.40:2222 ")
        #expect(plan.target.auth == .automatic)
        #expect(plan.target.passwordAccount == nil)
        #expect(plan.config.contains("Host 192.168.1.40\n  User root\n  Port 2222\n"))
    }

    @Test func passphraseAccountBelongsToTheKey() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(SSHLaunch.passphraseAccount(forKey: "~/.ssh/id") == "key:\(home)/.ssh/id:passphrase")
    }
}

/// The generated file checked by OpenSSH itself: `ssh -G` resolves the config
/// for a host and prints it, without connecting to anything.
struct SSHConfigAcceptedByOpenSSHTests {
    private func resolve(_ plan: SSHLaunchPlan, host: String) throws -> [String: String] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("termstead-g-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config")
        try plan.config.write(to: file, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: SSHLaunch.executable)
        process.arguments = ["-G", "-F", file.path, host]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        var result: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, result[String(parts[0])] == nil else { continue }
            result[String(parts[0])] = String(parts[1])
        }
        return result
    }

    @Test func chainResolvesTheWayWeMeantIt() throws {
        let hop = JumpHost(host: "me@127.0.0.1:2222", auth: .key, keyPath: "~/.ssh/hop key")
        let session = Session(id: "t", user: "ops", host: "127.0.0.1", port: 2223, icon: .server,
                              auth: .password, keyPath: "", jumps: [hop])
        let plan = try SSHLaunch.plan(for: session, sessions: [:], keyExists: { _ in true })

        let target = try resolve(plan, host: plan.target.alias)
        #expect(target["hostname"] == "127.0.0.1")
        #expect(target["user"] == "ops")
        #expect(target["port"] == "2223")
        // ssh -G prints an address-literal jump host in brackets.
        #expect(target["proxyjump"] == "[127.0.0.1]")
        #expect(target["preferredauthentications"] == "password,keyboard-interactive")

        let first = try resolve(plan, host: plan.hops[0].alias)
        #expect(first["user"] == "me")
        #expect(first["port"] == "2222")
        #expect(first["identitiesonly"] == "yes")
        #expect(first["identityfile"]?.hasSuffix("/.ssh/hop key") == true)
    }
}

struct ExitStatusTests {
    @Test func waitStatusBecomesAShellStyleCode() {
        #expect(Connection.exitCode(fromWaitStatus: 0) == 0)
        #expect(Connection.exitCode(fromWaitStatus: 255 << 8) == 255)
        #expect(Connection.exitCode(fromWaitStatus: 1 << 8) == 1)
        #expect(Connection.exitCode(fromWaitStatus: SIGTERM) == 128 + SIGTERM)
    }
}
