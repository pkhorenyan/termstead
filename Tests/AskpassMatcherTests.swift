import Foundation
import Testing
@testable import Termstead

struct AskpassMatcherTests {
    private let matcher = AskpassMatcher(passwords: [
        .init(host: "10.0.1.13", user: "deploy", account: "session:web:password"),
        .init(host: "bastion-01", user: nil, account: "hop:A:password"),
    ])

    @Test func passwordPromptMatchesUserAndHost() {
        #expect(matcher.account(for: "deploy@10.0.1.13's password: ") == "session:web:password")
    }

    @Test func keyboardInteractivePromptMatchesToo() {
        #expect(matcher.account(for: "(deploy@10.0.1.13) Password: ") == "session:web:password")
    }

    @Test func aDifferentUserGetsNothing() {
        #expect(matcher.account(for: "root@10.0.1.13's password: ") == nil)
    }

    @Test func aHopWithoutAUserMatchesWhateverUserSshChose() {
        #expect(matcher.account(for: "pavel@bastion-01's password: ") == "hop:A:password")
    }

    @Test func anUnknownHostGetsNothing() {
        #expect(matcher.account(for: "deploy@10.0.1.99's password: ") == nil)
    }

    @Test func ambiguityGoesToTheTerminal() {
        let twice = AskpassMatcher(passwords: [
            .init(host: "h", user: nil, account: "a"),
            .init(host: "h", user: "u", account: "b"),
        ])
        #expect(twice.account(for: "u@h's password: ") == nil)
    }

    @Test func passphrasePromptNamesTheKey() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(matcher.account(for: "Enter passphrase for key '\(home)/.ssh/id_ed25519': ")
                == "key:\(home)/.ssh/id_ed25519:passphrase")
    }

    @Test func otherPromptsAreLeftAlone() {
        #expect(matcher.account(for: "Are you sure you want to continue connecting (yes/no/[fingerprint])? ") == nil)
        #expect(matcher.account(for: "Verification code: ") == nil)
        #expect(matcher.account(for: "Password: ") == nil)
    }

    @Test func confirmationsAreEchoedSecretsAreNot() {
        #expect(AskpassProtocol.isConfirmation("Are you sure you want to continue connecting (yes/no/[fingerprint])? "))
        #expect(!AskpassProtocol.isConfirmation("deploy@h's password: "))
        #expect(!AskpassProtocol.isConfirmation("Verification code: "))
    }

    @Test func planFeedsTheMatcher() throws {
        let hop = JumpHost(host: "jump@bastion", auth: .password)
        let session = Session(id: "t", user: "ops", host: "target", port: 22, icon: .server,
                              auth: .password, keyPath: "", jumps: [hop])
        let matcher = AskpassMatcher(plan: try SSHLaunch.plan(for: session, sessions: [:]))
        #expect(matcher.account(for: "jump@bastion's password:") == SSHLaunch.hopPasswordAccount(hop.id))
        #expect(matcher.account(for: "ops@target's password:") == "session:t:password")
    }

    @Test func aTruncatedKeyPathMatchesByPrefixWhenUnambiguous() {
        let long = "/var/folders/xy/abcdefghijklmnopqrstuvwx0000gn/T/termstead-sshd-3F22F322-F1FB-4D3F-9CDE-95D713E6C8B1/clientkey"
        let shown = String(long.prefix(AskpassMatcher.keyPathLimit))
        let one = AskpassMatcher(passwords: [], keyPaths: [long])
        #expect(one.account(for: "Enter passphrase for key '\(shown)': ") == SSHLaunch.passphraseAccount(forKey: long))

        let two = AskpassMatcher(passwords: [], keyPaths: [long, long + "2"])
        #expect(two.account(for: "Enter passphrase for key '\(shown)': ") == nil)
    }

    @Test func aTruncatedUserMatchesByPrefix() {
        let user = String(repeating: "u", count: 40)
        let matcher = AskpassMatcher(passwords: [.init(host: "h", user: user, account: "a")])
        #expect(matcher.account(for: "\(user.prefix(30))@h's password: ") == "a")
        #expect(matcher.account(for: "\(user.prefix(29))@h's password: ") == nil)
    }

    /// One passphrase-protected key on the bastion and the target is asked
    /// for twice, once by each ssh; a password belongs to one hop.
    @Test func aSecretIsAllowedOncePerHopThatUsesIt() {
        let key = "/Users/me/.ssh/id_ed25519"
        let account = SSHLaunch.passphraseAccount(forKey: key)
        let matcher = AskpassMatcher(passwords: [.init(host: "h", user: "u", account: "pw")],
                                     keyPaths: [key, key])
        #expect(matcher.uses(of: account) == 2)
        #expect(matcher.uses(of: "pw") == 1)
        #expect(matcher.uses(of: "unknown") == 1)
    }
}
