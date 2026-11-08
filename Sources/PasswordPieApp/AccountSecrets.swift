import Foundation
import Security

/// What is kept for Premium, all in the keychain. None of it is ever logged.
enum AccountSecret: String, CaseIterable {
    /// The Better Auth session token (`Authorization: Bearer`).
    case session
    /// The last signed pass from passwordpie.com. It turns Premium on only while its signature checks and it has not run out.
    case pass
    /// The account's email, to show who is signed in.
    case email
    /// App Store channel: the token from the last activation link. Unlocks only while its signature checks and it has not run out.
    case activation
}

@MainActor
protocol AccountSecretStore: AnyObject {
    func read(_ secret: AccountSecret) -> String?
    func write(_ value: String, for secret: AccountSecret)
    func delete(_ secret: AccountSecret)
}

/// The legacy login keychain: it works inside the App Store sandbox without a provisioning profile (docs/CHANNELS.md).
@MainActor
final class KeychainAccountSecrets: AccountSecretStore {
    private let service: String

    init(service: String) {
        self.service = service
    }

    private func query(_ secret: AccountSecret) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: secret.rawValue]
    }

    func read(_ secret: AccountSecret) -> String? {
        var query = query(secret)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String, for secret: AccountSecret) {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(secret) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var add = query(secret)
        add[kSecAttrLabel as String] = "PasswordPie account"
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    func delete(_ secret: AccountSecret) {
        SecItemDelete(query(secret) as CFDictionary)
    }
}
