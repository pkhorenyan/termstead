import Foundation
import Testing
@testable import Termstead

/// The server's certificate and the login, as the tab asks about them.
struct RDPCertificateTests {
    /// A self-signed certificate made for this test, CN=termstead-test.
    private static let pem = """
    -----BEGIN CERTIFICATE-----
    MIIBqzCCARQCCQCXSYlS9TY2hjANBgkqhkiG9w0BAQsFADAZMRcwFQYDVQQDDA50
    ZXJtc3RlYWQtdGVzdDAgFw0yNjEwMjExNTUwNDdaGA8yMTI2MDkyNzE1NTA0N1ow
    GTEXMBUGA1UEAwwOdGVybXN0ZWFkLXRlc3QwgZ8wDQYJKoZIhvcNAQEBBQADgY0A
    MIGJAoGBAK1nr0g5/n8/HUOjnnSjYorKnvlQiShCPzhrgRyCMiQz2Qg7ObBTB5aP
    eHobKVelDfHkJxISj+JcI0K1rRpTa2N/3SMhLPH3eqNHsU64p+DK6dDVbg5U/vyO
    7Ey5ZXu8iXdDbIf+y7+XCxv6V8DItLw9+DTCfSUGQ3aewNX8NMkjAgMBAAEwDQYJ
    KoZIhvcNAQELBQADgYEADt8P0LIZSuEsHhyMu/tvRHLoRd/ao+BAdaV1Iimg2kwI
    5WxPVpoS38rVkMTKG1hpnf2TCYVzyUI1B53alUbG5kq/jDiIrKgxYS1HR5WH6eEo
    j1bdTiYO6jX3BG0WCFU+VQ21EesrXNEx3b909BnrqYNIUrZqZAEXHCbCrJSONJw=
    -----END CERTIFICATE-----
    """

    @Test func aChainIsReadFromPEM() throws {
        let certificate = try #require(RDPCertificate(pem: Self.pem + "\n" + Self.pem))
        #expect(certificate.chain.count == 2)
        // What `openssl x509 -fingerprint -sha256` says.
        #expect(certificate.fingerprint
                == "18:CF:7C:B4:51:9A:96:0F:91:1E:35:B2:EC:BD:91:94:74:9C:45:3C:7F:8B:B9:DB:9C:BC:F3:96:0B:44:31:3B")
        #expect(certificate.subject == "termstead-test")
        #expect(RDPCertificate(pem: "nothing here") == nil)
    }

    /// Self-signed: macOS does not trust it, and says why.
    @Test func macOSDoesNotTrustASelfSignedCertificate() async throws {
        let certificate = try #require(RDPCertificate(pem: Self.pem))
        let problem = await certificate.systemDistrust(for: "termstead-test")
        #expect(problem?.isEmpty == false)
    }

    @Test func trustedServersAreRemembered() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rdp-known-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let known = RDPKnownHosts(url: url)
        #expect(known.fingerprint(host: "win", port: 3389) == nil)
        known.trust("AA:BB", host: "Win", port: 3389)
        known.trust("CC:DD", host: "win", port: 3390)
        // Read back by a fresh instance: it is the file that keeps them.
        let again = RDPKnownHosts(url: url)
        #expect(again.fingerprint(host: "win", port: 3389) == "AA:BB")
        #expect(again.fingerprint(host: "win", port: 3390) == "CC:DD")
        known.trust("EE:FF", host: "win", port: 3389)
        #expect(again.fingerprint(host: "win", port: 3389) == "EE:FF")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    /// xrdp's "logged off" is also what a takeover by the same user looks like.
    @Test func theServersReasonsAreSaidPlainly() {
        #expect(RDPDesktop.explanation(code: 0x0001_000C, reason: "x").contains("connected again from elsewhere"))
        #expect(RDPDesktop.explanation(code: 0x0001_0005, reason: "x").contains("took the session over"))
        #expect(RDPDesktop.explanation(code: 0x0002_000D, reason: "transport failed") == "transport failed")
        #expect(RDPDesktop.explanation(code: 0, reason: "") == "The session ended.")
    }

    @Test func refusedLogins() {
        #expect(RDPDesktop.isRefusedLogin(0x0002_0014))   // logon failure
        #expect(RDPDesktop.isRefusedLogin(0x0002_0009))   // authentication failed
        #expect(!RDPDesktop.isRefusedLogin(0x0002_000B))  // cancelled
        #expect(!RDPDesktop.isRefusedLogin(0))
    }
}

/// The questions against the lab's xrdp, whose certificate is self-signed.
@MainActor
@Suite(.serialized, .enabled(if: TestLabRDP.isUp, "the lab's RDP server is not running (TestLab/lab.sh up)"))
final class RDPQuestionTests {
    private let known: RDPKnownHosts
    private let knownURL: URL
    private let keychain = KeychainStore(service: "com.pavelkhorenyan.termstead.tests.\(UUID().uuidString)")
    private let account = "session:lab-rdp-test:password"

    init() {
        knownURL = FileManager.default.temporaryDirectory.appendingPathComponent("rdp-known-\(UUID().uuidString)")
        known = RDPKnownHosts(url: knownURL)
    }

    deinit {
        keychain.delete(account)
        try? FileManager.default.removeItem(at: knownURL)
    }

    private func desktop(password: String = "lab") -> RDPDesktop {
        let desktop = RDPDesktop()
        desktop.knownHosts = known
        desktop.keychain = keychain
        desktop.availableSize = { (CGSize(width: 800, height: 600), 1) }
        var launch = RDPLaunch(session: SessionStore.sample().session("lab-rdp")!, password: password)
        launch.options.sound = false
        launch.passwordAccount = account
        desktop.start(launch) { try await RDPSocket.connect(host: "127.0.0.1", port: 3390) }
        return desktop
    }

    private func wait(upTo seconds: Double, until done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func anUnknownCertificateIsAskedAboutOnceTrusted() async throws {
        let first = desktop()
        await wait(upTo: 20) { first.certificateQuestion != nil }
        let question = try #require(first.certificateQuestion)
        #expect(question.host == "127.0.0.1" && question.port == 3390)
        #expect(!question.changed)
        #expect(!question.problem.isEmpty)
        first.answerCertificate(trust: true)
        await wait(upTo: 20) { first.phase == .showing }
        #expect(first.phase == .showing)
        #expect(known.fingerprint(host: "127.0.0.1", port: 3390) == question.fingerprint)
        first.stop()

        // Trusted now: the next connection goes straight in.
        let second = desktop()
        var asked = false
        let deadline = Date().addingTimeInterval(20)
        while second.phase != .showing, Date() < deadline {
            if second.certificateQuestion != nil { asked = true }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!asked)
        #expect(second.phase == .showing)
        second.stop()
    }

    /// Another certificate trusted for the server before: asked again, as
    /// a change.
    @Test func aChangedCertificateIsAskedAboutAsAChange() async throws {
        known.trust("00:11:22", host: "127.0.0.1", port: 3390)
        let tab = desktop()
        await wait(upTo: 20) { tab.certificateQuestion != nil }
        let question = try #require(tab.certificateQuestion)
        #expect(question.changed)
        tab.answerCertificate(trust: false)
        await wait(upTo: 20) { tab.phase != .connecting }
        #expect(tab.phase == .ended("The server's certificate was not trusted."))
        #expect(known.fingerprint(host: "127.0.0.1", port: 3390) == "00:11:22")
    }

    /// No password saved: the tab asks, and saves it when told to.
    @Test func aMissingPasswordIsAskedFor() async throws {
        let tab = desktop(password: "")
        // Over TLS FreeRDP asks for the login before it has the certificate.
        await wait(upTo: 20) { tab.loginQuestion != nil }
        let question = try #require(tab.loginQuestion)
        #expect(question.user == "lab")
        #expect(question.canSave)
        tab.answerLogin(RDPLogin(user: "lab", domain: "", password: "lab"), save: true)
        await wait(upTo: 20) { tab.certificateQuestion != nil || tab.phase == .showing }
        tab.answerCertificate(trust: true)
        await wait(upTo: 20) { tab.phase == .showing }
        #expect(tab.phase == .showing)
        #expect(keychain.secret(for: account) == "lab")
        tab.stop()
    }

    @Test func aCancelledLoginEndsTheSession() async throws {
        let tab = desktop(password: "")
        await wait(upTo: 20) { tab.loginQuestion != nil }
        tab.answerLogin(nil, save: false)
        await wait(upTo: 20) { tab.phase != .connecting }
        #expect(tab.phase == .ended("Login cancelled."))
        #expect(keychain.secret(for: account) == nil)
    }
}
