import Foundation
import LocalAuthentication
import Security

/// What to show after a Touch ID prompt. Cancel returns nil so the caller stays quiet.
public enum TouchIDPromptMessage {
    public static func message(for code: LAError.Code) -> String? {
        switch code {
        case .userCancel, .appCancel, .systemCancel, .userFallback:
            return nil
        case .biometryLockout:
            return "Touch ID is locked. Use the master password."
        case .biometryNotEnrolled:
            return "Set up Touch ID in System Settings, then try again."
        case .authenticationFailed:
            return "Touch ID didn't match."
        default:
            return "Touch ID is not available."
        }
    }
}

/// Decisions for one database's Touch ID flag. The keychain call stays in `TouchIDSecretStore`.
public enum TouchIDEnrollment: Sendable {
    /// Where an in-flight Enable may write after Touch ID returns.
    public enum Commit: Equatable, Sendable {
        /// `showOnCurrentDatabase` is false when the open database changed during the prompt.
        /// The secret still belongs to `account`, the database Enable started on.
        case write(account: String, showOnCurrentDatabase: Bool)
        /// The same file is open, but its master password is no longer the one Enable captured.
        case rejectChangedPassword
    }

    public static func commit(
        capturedAccount: String,
        currentAccount: String,
        capturedSecret: Data,
        currentSecret: Data
    ) -> Commit {
        if currentAccount == capturedAccount, !currentSecret.isEmpty, currentSecret != capturedSecret {
            return .rejectChangedPassword
        }
        return .write(account: capturedAccount, showOnCurrentDatabase: currentAccount == capturedAccount)
    }

    /// The enable flag and the 7-day stamp stay until the secret is actually gone.
    public static func keepsPersistedFlag(deleteStatus: OSStatus) -> Bool {
        deleteStatus != errSecSuccess
    }

    /// Whether the lock screen may offer Touch ID for a database whose window is still open.
    public enum Offer: Equatable, Sendable {
        case available
        case noHardware
        case missingSecret
        case unreadable
    }

    public static func offer(hardware: Bool, probe: OSStatus) -> Offer {
        if !hardware { return .noHardware }
        if probe == errSecSuccess { return .available }
        if probe == errSecItemNotFound { return .missingSecret }
        return .unreadable
    }

    /// A master-password unlock refreshes the saved secret. Only a successful save
    /// extends the 7-day window and clears the stale mark. A failure must not keep
    /// offering the password this unlock could not store.
    public enum Refresh: Equatable, Sendable {
        case refreshed
        case stale(OSStatus)
    }

    public static func refreshAfterMasterUnlock(saveStatus: OSStatus) -> Refresh {
        saveStatus == errSecSuccess ? .refreshed : .stale(saveStatus)
    }
}

/// Login-keychain copy of one database's master password.
///
/// Biometric keychain access control (`kSecAccessControlBiometryCurrentSet`) returns
/// errSecMissingEntitlement (-34018) here: it requires the data-protection keychain,
/// which requires a provisioning profile. Callers must run Touch ID themselves, then
/// read this item. The item follows the app's signing identity, so later builds can
/// read and replace it only when they are signed with the same certificate.
/// Delete stays owned by the binary that created the item; a later build clears the
/// secret by replacing it.
public struct TouchIDSecretStore: Sendable {
    public let service: String

    public init(service: String = "com.oldcai.passwordpie") {
        self.service = service
    }

    public func save(secret: Data, account: String) -> OSStatus {
        guard !secret.isEmpty else { return errSecParam }
        return withoutKeychainUI {
            let added = SecItemAdd(addQuery(secret: secret, account: account) as CFDictionary, nil)
            if added == errSecSuccess { return added }
            guard added == errSecDuplicateItem else { return added }
            let attrs = [kSecValueData as String: secret]
            return SecItemUpdate(lookup(account) as CFDictionary, attrs as CFDictionary)
        }
    }

    /// `errSecSuccess` when the secret is gone, including when it was already absent.
    public func delete(account: String) -> OSStatus {
        withoutKeychainUI {
            let deleted = SecItemDelete(lookup(account) as CFDictionary)
            if deleted == errSecSuccess || deleted == errSecItemNotFound { return errSecSuccess }
            let attrs = [kSecValueData as String: Data()]
            let updated = SecItemUpdate(lookup(account) as CFDictionary, attrs as CFDictionary)
            return updated == errSecSuccess ? errSecSuccess : deleted
        }
    }

    /// Whether a non-empty secret is stored. Does not return the secret.
    /// Reading the bytes is required: a blanked item (the delete fallback) must count as missing,
    /// and an existence-only query would still report that item as present.
    public func probe(account: String) -> OSStatus {
        load(account: account).status
    }

    public func load(account: String) -> (status: OSStatus, secret: Data?) {
        withoutKeychainUI {
            var query = lookup(account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            guard status == errSecSuccess, let secret = item as? Data, !secret.isEmpty else {
                if status == errSecSuccess { return (errSecItemNotFound, nil) }
                return (status, nil)
            }
            return (status, secret)
        }
    }

    private func lookup(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func addQuery(secret: Data, account: String) -> [String: Any] {
        var query = lookup(account)
        query[kSecAttrLabel as String] = "PasswordPie"
        query[kSecValueData as String] = secret
        return query
    }

    /// Legacy keychain items ignore `kSecUseAuthenticationUI` and would otherwise
    /// raise a dialog when this build is not the item's owner.
    private func withoutKeychainUI<T>(_ body: () -> T) -> T {
        _ = SecKeychainSetUserInteractionAllowed(false)
        defer { _ = SecKeychainSetUserInteractionAllowed(true) }
        return body()
    }
}
