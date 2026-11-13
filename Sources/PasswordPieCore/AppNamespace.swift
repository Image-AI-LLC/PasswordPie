import Foundation

/// The reverse-DNS namespace every PasswordPie identifier lives in: the bundle IDs, the App Group, the keychain services,
/// the in-app purchases. `com.passwordpie` since 2026-11-13; the direct build v0.1.0 shipped as `legacyID`.
public enum AppNamespace {
    public static let id = "com.passwordpie"
    /// Read once, by `LegacyMigration`, on the first launch after an upgrade. Nothing else may use it.
    public static let legacyID = "com.oldcai.passwordpie"

    /// The name an earlier build used for `name` (`com.passwordpie.keyfile` → its `legacyID` twin). Nil outside the namespace.
    public static func legacyName(for name: String) -> String? {
        if name == id { return legacyID }
        guard name.hasPrefix(id + ".") else { return nil }
        return legacyID + name.dropFirst(id.count)
    }
}
