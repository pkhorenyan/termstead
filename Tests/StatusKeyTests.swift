import Testing
@testable import Termstead

/// The status bar says what the login uses, labelled.
@MainActor
struct StatusKeyTests {
    @Test func loginIsLabelled() {
        var session = Session(id: "s", user: "u", host: "h", port: 22, icon: .server,
                              auth: .key, keyPath: "~/.ssh/termstead-lab")
        #expect(ConnectionStore.keyDescription(for: session) == "key: termstead-lab")
        session.keyPath = ""
        #expect(ConnectionStore.keyDescription(for: session) == "key: ssh default")
        session.auth = .password
        #expect(ConnectionStore.keyDescription(for: session) == "password")
    }
}
