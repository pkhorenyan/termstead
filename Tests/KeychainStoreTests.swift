import Foundation
import Security
import Testing
@testable import Termstead

/// Uses the login keychain under a service of its own, removed afterwards.
struct KeychainStoreTests {
    private let store = KeychainStore(service: "com.pavelkhorenyan.termstead.tests.\(UUID().uuidString)")

    @Test func setReadReplaceDelete() {
        let account = "session:test:password"
        defer { store.delete(account) }

        #expect(!store.contains(account))
        #expect(store.set("first", for: account))
        #expect(store.contains(account))
        #expect(store.secret(for: account) == "first")
        #expect(store.set("second", for: account))
        #expect(store.secret(for: account) == "second")
        store.delete(account)
        #expect(!store.contains(account))
        #expect(store.secret(for: account) == nil)
    }

    @Test func moveFollowsARename() {
        defer { store.delete("new"); store.delete("old") }
        store.set("pw", for: "old")
        store.move("old", to: "new")
        #expect(store.secret(for: "new") == "pw")
        #expect(!store.contains("old"))
    }
}
