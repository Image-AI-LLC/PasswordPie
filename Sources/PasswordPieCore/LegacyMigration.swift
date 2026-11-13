import Foundation
import Security

/// One keychain item under its current service, and where an earlier build kept it.
public struct LegacyKeychainItem: Hashable, Sendable {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public var legacyService: String? { AppNamespace.legacyName(for: service) }
}

/// Reads and writes generic passwords. Reads must never show a keychain dialog: an item an earlier build wrote names that
/// build's code signature, and asking the user about it at every launch is what the migration must not do.
public protocol LegacyKeychain {
    func load(service: String, account: String) -> (status: OSStatus, secret: Data?)
    func save(_ secret: Data, service: String, account: String) -> OSStatus
}

/// The login keychain, through `TouchIDSecretStore`, which turns keychain UI off around every call.
public struct LoginKeychain: LegacyKeychain {
    public init() {}

    public func load(service: String, account: String) -> (status: OSStatus, secret: Data?) {
        TouchIDSecretStore(service: service).load(account: account)
    }

    public func save(_ secret: Data, service: String, account: String) -> OSStatus {
        TouchIDSecretStore(service: service).save(secret: secret, account: account)
    }
}

/// The first launch after the move from `AppNamespace.legacyID` to `AppNamespace.id` (direct build v0.1.0 and earlier
/// development builds) brings over what the earlier build kept, once:
///
/// - **Preferences** (database list, Touch ID flags, shortcuts…): every key the new domain does not have yet.
/// - **Keychain** (each database's Touch ID secret and key file, Premium's activation): copied when this build can read
///   the old item without a dialog. In practice the old item's access list names the old signature and the read fails
///   with `errSecInteractionNotAllowed`; then nothing is copied, the lock screen asks for the master password once (a
///   Touch ID flag with no secret turns itself off), and that unlock saves the secret again.
///
/// Old items and the old domain are left alone: the keychain items belong to the old signature, and nothing reads them
/// after this.
public enum LegacyMigration {
    /// Set in the new domain once the migration ran, whatever it found.
    public static let doneKey = "legacyNamespaceMigrated"

    public struct Services: Sendable {
        public var touchID: String
        public var keyFile: String
        public var premium: String
        public var premiumAccounts: [String]

        public init(touchID: String, keyFile: String, premium: String, premiumAccounts: [String]) {
            self.touchID = touchID
            self.keyFile = keyFile
            self.premium = premium
            self.premiumAccounts = premiumAccounts
        }
    }

    public enum Outcome: Equatable, Sendable {
        case copied
        /// The new item exists already; the old one was not read.
        case alreadyThere
        case absent
        case unreadable(OSStatus)
        case saveFailed(OSStatus)
    }

    /// Another app's preferences on disk. Nil when there are none (or a sandbox hides them).
    public static func preferences(domain: String) -> [String: Any]? {
        UserDefaults.standard.persistentDomain(forName: domain)
    }

    /// Copies every key `defaults` lacks. Returns the keys copied.
    @discardableResult
    public static func migratePreferences(from legacy: [String: Any]?, into defaults: UserDefaults) -> [String] {
        guard let legacy else { return [] }
        var copied: [String] = []
        for (key, value) in legacy.sorted(by: { $0.key < $1.key }) where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copied.append(key)
        }
        return copied
    }

    /// The current database first, then the remembered ones, each once.
    public static func databasePaths(current: String?, remembered: [String]?) -> [String] {
        var seen = Set<String>()
        return ([current].compactMap { $0 } + (remembered ?? [])).filter { seen.insert($0).inserted }
    }

    public static func keychainItems(databasePaths: [String], services: Services) -> [LegacyKeychainItem] {
        var seen = Set<String>()
        let paths = databasePaths.filter { seen.insert($0).inserted }
        return paths.flatMap { path in
            [LegacyKeychainItem(service: services.touchID, account: path), LegacyKeychainItem(service: services.keyFile, account: path)]
        } + services.premiumAccounts.map { LegacyKeychainItem(service: services.premium, account: $0) }
    }

    public static func migrateKeychain(_ items: [LegacyKeychainItem], keychain: LegacyKeychain) -> [LegacyKeychainItem: Outcome] {
        var outcomes: [LegacyKeychainItem: Outcome] = [:]
        for item in items {
            guard let legacyService = item.legacyService else { continue }
            if keychain.load(service: item.service, account: item.account).status == errSecSuccess {
                outcomes[item] = .alreadyThere
                continue
            }
            let old = keychain.load(service: legacyService, account: item.account)
            guard old.status == errSecSuccess, let secret = old.secret else {
                outcomes[item] = old.status == errSecItemNotFound ? .absent : .unreadable(old.status)
                continue
            }
            let saved = keychain.save(secret, service: item.service, account: item.account)
            outcomes[item] = saved == errSecSuccess ? .copied : .saveFailed(saved)
        }
        return outcomes
    }

    /// Preferences, then the keychain items of the databases those preferences name. False when it ran before.
    @discardableResult
    public static func runOnce(
        defaults: UserDefaults = .standard,
        legacyPreferences: [String: Any]?,
        keychain: LegacyKeychain = LoginKeychain(),
        services: Services
    ) -> Bool {
        guard !defaults.bool(forKey: doneKey) else { return false }
        migratePreferences(from: legacyPreferences, into: defaults)
        let paths = databasePaths(current: defaults.string(forKey: "databasePath"), remembered: defaults.stringArray(forKey: "databasePaths"))
        _ = migrateKeychain(keychainItems(databasePaths: paths, services: services), keychain: keychain)
        defaults.set(true, forKey: doneKey)
        return true
    }
}
