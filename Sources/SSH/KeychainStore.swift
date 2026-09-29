import Foundation
import Security

/// Secrets for ssh, as generic passwords in the login keychain. Accounts are
/// named by `SSHLaunch`: `session:<id>:password`, `hop:<uuid>:password`,
/// `key:<path>:passphrase`.
///
/// Thread-safe (Security framework calls only), so the askpass server can read
/// from its own queue.
struct KeychainStore: Sendable {
    let service: String

    static let shared = KeychainStore(service: "com.pavelkhorenyan.Termstead")

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func secret(for account: String) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Asks only for the item's attributes, never its data, so checking does
    /// not trigger a Keychain access dialog.
    func contains(_ account: String) -> Bool {
        var query = query(account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    @discardableResult
    func set(_ secret: String, for account: String) -> Bool {
        let data = Data(secret.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query(account) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }

        var item = query(account)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Termstead — \(account)"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }

    /// For a renamed session. Reading the old item may ask for Keychain access
    /// once; that is the price of keeping the password.
    func move(_ oldAccount: String, to newAccount: String) {
        guard oldAccount != newAccount, let secret = secret(for: oldAccount) else { return }
        if set(secret, for: newAccount) { delete(oldAccount) }
    }
}
