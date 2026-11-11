import Foundation
import Security

/// What is kept for Premium, all in the keychain under one service. None of it is ever logged.
enum PremiumSecret: String, CaseIterable {
    /// The token from the last activation link, in both channels. Unlocks only while its signature checks and it has not run out.
    case activation
    /// An earlier direct build's sign-in session and email. Deleted at launch, never read.
    case legacySession = "session"
    case legacyEmail = "email"
    /// The passes a browser extension, or an earlier build's own sign-in, handed over until 2026-11-11. Deleted at launch,
    /// never read: only an activation unlocks now.
    case legacyChromePass = "pass.chrome"
    case legacySafariPass = "pass.safari"
    case legacyAppPass = "pass"

    /// What earlier builds kept and this one deletes unread.
    static let legacy: [PremiumSecret] = [.legacySession, .legacyEmail, .legacyChromePass, .legacySafariPass, .legacyAppPass]
}

@MainActor
protocol SecretStore: AnyObject {
    func read(_ secret: PremiumSecret) -> String?
    func write(_ value: String, for secret: PremiumSecret)
    func delete(_ secret: PremiumSecret)
}

/// The legacy login keychain: it works inside the App Store sandbox without a provisioning profile (docs/CHANNELS.md).
@MainActor
final class KeychainSecrets: SecretStore {
    private let service: String

    init(service: String) {
        self.service = service
    }

    private func query(_ secret: PremiumSecret) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: secret.rawValue]
    }

    func read(_ secret: PremiumSecret) -> String? {
        var query = query(secret)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String, for secret: PremiumSecret) {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(secret) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var add = query(secret)
        add[kSecAttrLabel as String] = "PasswordPie Premium"
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    func delete(_ secret: PremiumSecret) {
        SecItemDelete(query(secret) as CFDictionary)
    }
}
