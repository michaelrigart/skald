import Foundation
import Security
import SkaldCore

/// One generic password in the login keychain. Failures are logged by status code only, never with the value.
nonisolated struct KeychainStore: Sendable {
    struct Failure: Error, Equatable {
        let status: OSStatus
    }

    static let claudeKey = KeychainStore(service: SkaldCore.bundleID, account: "claude-api-key")

    let service: String
    let account: String

    func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound { Log.app.notice("keychain read failed: \(status)") }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Asks for the item's attributes only, so it never needs the item's data or an access prompt.
    func containsValue() -> Bool {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func write(_ value: String) throws {
        let data = Data(value.utf8)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw failure(update, "update") }
        var item = baseQuery
        item[kSecValueData as String] = data
        let add = SecItemAdd(item as CFDictionary, nil)
        guard add == errSecSuccess else { throw failure(add, "add") }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status, "delete") }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func failure(_ status: OSStatus, _ operation: String) -> Failure {
        Log.app.notice("keychain \(operation, privacy: .public) failed: \(status)")
        return Failure(status: status)
    }
}
