import Security
import XCTest
@testable import PasswordPieCore

/// The direct build v0.1.0 shipped as `com.oldcai.passwordpie`. These cover what an upgrade to `com.passwordpie` brings
/// over (TECH_DESIGN: .agent/development/20261113/rename-com-passwordpie).
final class AppNamespaceTests: XCTestCase {
    func testTheNamespaceIsTheOwnDomain() {
        XCTAssertEqual(AppNamespace.id, "com.passwordpie")
        XCTAssertEqual(AppNamespace.legacyID, "com.oldcai.passwordpie")
    }

    func testEveryNameMapsToTheOneEarlierBuildsUsed() {
        XCTAssertEqual(AppNamespace.legacyName(for: "com.passwordpie"), "com.oldcai.passwordpie")
        XCTAssertEqual(AppNamespace.legacyName(for: "com.passwordpie.keyfile"), "com.oldcai.passwordpie.keyfile")
        XCTAssertEqual(AppNamespace.legacyName(for: "com.passwordpie.account.dev"), "com.oldcai.passwordpie.account.dev")
        XCTAssertNil(AppNamespace.legacyName(for: "com.passwordpiex"))
        XCTAssertNil(AppNamespace.legacyName(for: "org.example.passwordpie"))
    }

    func testTouchIDKeepsItsSecretUnderTheBundleID() {
        XCTAssertEqual(TouchIDSecretStore().service, "com.passwordpie")
    }

    func testProductIDsAreInTheNewNamespace() {
        XCTAssertEqual(PremiumPlan.yearly.productID, "com.passwordpie.premium.yearly")
    }
}

final class LegacyPreferencesTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "com.passwordpie.tests.migration.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testCopiesEveryKeyTheNewDomainLacks() {
        let legacy: [String: Any] = [
            "databasePath": "/Users/me/Vault.kdbx",
            "databasePaths": ["/Users/me/Vault.kdbx", "/Users/me/Work.kdbx"],
            "touchIDEnabled./Users/me/Vault.kdbx": true,
            "clipboardTimeout": 45
        ]
        let copied = LegacyMigration.migratePreferences(from: legacy, into: defaults)
        XCTAssertEqual(Set(copied), Set(legacy.keys))
        XCTAssertEqual(defaults.string(forKey: "databasePath"), "/Users/me/Vault.kdbx")
        XCTAssertEqual(defaults.stringArray(forKey: "databasePaths"), ["/Users/me/Vault.kdbx", "/Users/me/Work.kdbx"])
        XCTAssertTrue(defaults.bool(forKey: "touchIDEnabled./Users/me/Vault.kdbx"))
        XCTAssertEqual(defaults.integer(forKey: "clipboardTimeout"), 45)
    }

    func testNeverOverwritesWhatTheNewBuildAlreadyKeeps() {
        defaults.set("/Users/me/New.kdbx", forKey: "databasePath")
        let copied = LegacyMigration.migratePreferences(from: ["databasePath": "/Users/me/Old.kdbx", "searchAllFields": true], into: defaults)
        XCTAssertEqual(copied, ["searchAllFields"])
        XCTAssertEqual(defaults.string(forKey: "databasePath"), "/Users/me/New.kdbx")
    }

    func testNoEarlierBuildCopiesNothing() {
        XCTAssertEqual(LegacyMigration.migratePreferences(from: nil, into: defaults), [])
        XCTAssertEqual(LegacyMigration.migratePreferences(from: [:], into: defaults), [])
    }

    func testReadsAnotherDomainFromDisk() {
        let legacySuite = "com.passwordpie.tests.legacy.\(UUID().uuidString)"
        let legacy = UserDefaults(suiteName: legacySuite)!
        defer { legacy.removePersistentDomain(forName: legacySuite) }
        legacy.set("/Users/me/Vault.kdbx", forKey: "databasePath")
        XCTAssertEqual(LegacyMigration.preferences(domain: legacySuite)?["databasePath"] as? String, "/Users/me/Vault.kdbx")
    }
}

/// Stands in for the login keychain: items an earlier build wrote may be unreadable to this one.
private final class FakeKeychain: LegacyKeychain {
    var items: [String: Data] = [:]
    var unreadable: [String: OSStatus] = [:]
    var saveStatus: OSStatus = errSecSuccess
    private(set) var reads: [String] = []

    private func key(_ service: String, _ account: String) -> String { "\(service)|\(account)" }

    func load(service: String, account: String) -> (status: OSStatus, secret: Data?) {
        reads.append(key(service, account))
        if let status = unreadable[key(service, account)] { return (status, nil) }
        guard let data = items[key(service, account)] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
    }

    func save(_ secret: Data, service: String, account: String) -> OSStatus {
        guard saveStatus == errSecSuccess else { return saveStatus }
        items[key(service, account)] = secret
        return errSecSuccess
    }

    func item(_ service: String, _ account: String) -> Data? { items[key(service, account)] }
    func put(_ service: String, _ account: String, _ value: String) { items[key(service, account)] = Data(value.utf8) }
}

final class LegacyKeychainTests: XCTestCase {
    private let services = LegacyMigration.Services(
        touchID: "com.passwordpie",
        keyFile: "com.passwordpie.keyfile",
        premium: "com.passwordpie.account",
        premiumAccounts: ["activation"]
    )

    func testItemsCoverEveryRememberedDatabaseAndPremium() {
        let items = LegacyMigration.keychainItems(databasePaths: ["/a.kdbx", "/b.kdbx", "/a.kdbx"], services: services)
        XCTAssertEqual(items, [
            LegacyKeychainItem(service: "com.passwordpie", account: "/a.kdbx"),
            LegacyKeychainItem(service: "com.passwordpie.keyfile", account: "/a.kdbx"),
            LegacyKeychainItem(service: "com.passwordpie", account: "/b.kdbx"),
            LegacyKeychainItem(service: "com.passwordpie.keyfile", account: "/b.kdbx"),
            LegacyKeychainItem(service: "com.passwordpie.account", account: "activation")
        ])
        XCTAssertEqual(items[1].legacyService, "com.oldcai.passwordpie.keyfile")
    }

    func testPathsComeFromTheCurrentAndTheRememberedDatabases() {
        XCTAssertEqual(LegacyMigration.databasePaths(current: "/c.kdbx", remembered: ["/a.kdbx", "/c.kdbx"]), ["/c.kdbx", "/a.kdbx"])
        XCTAssertEqual(LegacyMigration.databasePaths(current: nil, remembered: nil), [])
    }

    func testCopiesWhatItCanReadAndLeavesTheRest() {
        let keychain = FakeKeychain()
        keychain.put("com.oldcai.passwordpie", "/a.kdbx", "master")
        keychain.put("com.oldcai.passwordpie.keyfile", "/a.kdbx", "key")
        keychain.unreadable["com.oldcai.passwordpie|/b.kdbx"] = errSecInteractionNotAllowed
        let a = LegacyKeychainItem(service: "com.passwordpie", account: "/a.kdbx")
        let aKey = LegacyKeychainItem(service: "com.passwordpie.keyfile", account: "/a.kdbx")
        let b = LegacyKeychainItem(service: "com.passwordpie", account: "/b.kdbx")
        let none = LegacyKeychainItem(service: "com.passwordpie.account", account: "activation")

        let outcomes = LegacyMigration.migrateKeychain([a, aKey, b, none], keychain: keychain)

        XCTAssertEqual(outcomes[a], .copied)
        XCTAssertEqual(outcomes[aKey], .copied)
        XCTAssertEqual(outcomes[b], .unreadable(errSecInteractionNotAllowed))
        XCTAssertEqual(outcomes[none], .absent)
        XCTAssertEqual(keychain.item("com.passwordpie", "/a.kdbx"), Data("master".utf8))
        XCTAssertEqual(keychain.item("com.passwordpie.keyfile", "/a.kdbx"), Data("key".utf8))
        XCTAssertNil(keychain.item("com.passwordpie", "/b.kdbx"))
        // The earlier build's items stay: they belong to its signature, and this build cannot delete them.
        XCTAssertEqual(keychain.item("com.oldcai.passwordpie", "/a.kdbx"), Data("master".utf8))
    }

    func testANewerItemIsNeverReplaced() {
        let keychain = FakeKeychain()
        keychain.put("com.oldcai.passwordpie", "/a.kdbx", "old")
        keychain.put("com.passwordpie", "/a.kdbx", "new")
        let a = LegacyKeychainItem(service: "com.passwordpie", account: "/a.kdbx")
        XCTAssertEqual(LegacyMigration.migrateKeychain([a], keychain: keychain)[a], .alreadyThere)
        XCTAssertEqual(keychain.item("com.passwordpie", "/a.kdbx"), Data("new".utf8))
        XCTAssertFalse(keychain.reads.contains("com.oldcai.passwordpie|/a.kdbx"), "no need to touch the old item")
    }

    func testAFailedSaveIsReported() {
        let keychain = FakeKeychain()
        keychain.put("com.oldcai.passwordpie", "/a.kdbx", "old")
        keychain.saveStatus = errSecWrPerm
        let a = LegacyKeychainItem(service: "com.passwordpie", account: "/a.kdbx")
        XCTAssertEqual(LegacyMigration.migrateKeychain([a], keychain: keychain)[a], .saveFailed(errSecWrPerm))
    }
}

final class LegacyMigrationRunTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private let services = LegacyMigration.Services(
        touchID: "com.passwordpie",
        keyFile: "com.passwordpie.keyfile",
        premium: "com.passwordpie.account",
        premiumAccounts: ["activation"]
    )

    override func setUp() {
        suite = "com.passwordpie.tests.run.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testRunsOnceAndUsesThePathsItJustCopied() {
        let keychain = FakeKeychain()
        keychain.put("com.oldcai.passwordpie", "/a.kdbx", "master")
        keychain.put("com.oldcai.passwordpie.account", "activation", "token")
        let legacy: [String: Any] = ["databasePath": "/a.kdbx", "databasePaths": ["/a.kdbx"]]

        XCTAssertTrue(LegacyMigration.runOnce(defaults: defaults, legacyPreferences: legacy, keychain: keychain, services: services))
        XCTAssertEqual(defaults.string(forKey: "databasePath"), "/a.kdbx")
        XCTAssertEqual(keychain.item("com.passwordpie", "/a.kdbx"), Data("master".utf8))
        XCTAssertEqual(keychain.item("com.passwordpie.account", "activation"), Data("token".utf8))

        // A second launch reads nothing old, even after the user changed things.
        defaults.removeObject(forKey: "databasePath")
        let readsBefore = keychain.reads.count
        XCTAssertFalse(LegacyMigration.runOnce(defaults: defaults, legacyPreferences: legacy, keychain: keychain, services: services))
        XCTAssertNil(defaults.string(forKey: "databasePath"))
        XCTAssertEqual(keychain.reads.count, readsBefore)
    }

    func testTheDefaultDatabaseCountsWhenNoneWasEverChosen() {
        let keychain = FakeKeychain()
        keychain.put("com.oldcai.passwordpie", "/default.kdbx", "master")
        LegacyMigration.runOnce(defaults: defaults, legacyPreferences: ["searchAllFields": true], keychain: keychain, services: services, defaultDatabasePath: "/default.kdbx")
        XCTAssertEqual(keychain.item("com.passwordpie", "/default.kdbx"), Data("master".utf8))
    }

    func testAnUnreadableKeychainStillFinishesAndIsNotRetried() {
        let keychain = FakeKeychain()
        keychain.unreadable["com.oldcai.passwordpie|/a.kdbx"] = errSecInteractionNotAllowed
        XCTAssertTrue(LegacyMigration.runOnce(defaults: defaults, legacyPreferences: ["databasePath": "/a.kdbx"], keychain: keychain, services: services))
        XCTAssertTrue(defaults.bool(forKey: LegacyMigration.doneKey))
        XCTAssertFalse(LegacyMigration.runOnce(defaults: defaults, legacyPreferences: ["databasePath": "/a.kdbx"], keychain: keychain, services: services))
    }

    func testAFreshInstallOnlyMarksItself() {
        let keychain = FakeKeychain()
        XCTAssertTrue(LegacyMigration.runOnce(defaults: defaults, legacyPreferences: nil, keychain: keychain, services: services))
        XCTAssertEqual(Set(defaults.persistentDomain(forName: suite)?.keys.map { $0 } ?? []), [LegacyMigration.doneKey])
    }
}

/// The real login keychain, under test-only services, read with keychain UI turned off like the app does. An item this
/// process wrote is readable and copied; one another program wrote (here `/usr/bin/security`, the only app on its access
/// list) is what an upgrade meets in practice: unreadable, no dialog, nothing copied.
final class LoginKeychainMigrationTests: XCTestCase {
    private var newService = ""
    private var account = ""

    override func setUp() {
        newService = "com.passwordpie.tests.keychain-migration.\(UUID().uuidString)"
        account = "account-\(UUID().uuidString)"
    }

    override func tearDown() {
        for service in [newService, AppNamespace.legacyName(for: newService)!] {
            _ = TouchIDSecretStore(service: service).delete(account: account)
        }
    }

    private func requireKeychain() throws {
        let status = TouchIDSecretStore(service: newService).probe(account: account)
        try XCTSkipIf(status != errSecItemNotFound, "Login keychain is not available to this test process (\(status)).")
    }

    func testCopiesAnItemThisProcessCanRead() throws {
        try requireKeychain()
        let legacyService = try XCTUnwrap(AppNamespace.legacyName(for: newService))
        XCTAssertEqual(TouchIDSecretStore(service: legacyService).save(secret: Data("päss".utf8), account: account), errSecSuccess)
        let item = LegacyKeychainItem(service: newService, account: account)

        XCTAssertEqual(LegacyMigration.migrateKeychain([item], keychain: LoginKeychain())[item], .copied)
        XCTAssertEqual(TouchIDSecretStore(service: newService).load(account: account).secret, Data("päss".utf8))
    }

    func testAnItemOfAnotherProgramIsLeftWithoutADialog() throws {
        try requireKeychain()
        let legacyService = try XCTUnwrap(AppNamespace.legacyName(for: newService))
        try security(["add-generic-password", "-s", legacyService, "-a", account, "-w", "not-a-secret"])
        defer { try? security(["delete-generic-password", "-s", legacyService, "-a", account]) }
        let item = LegacyKeychainItem(service: newService, account: account)

        guard case .unreadable = LegacyMigration.migrateKeychain([item], keychain: LoginKeychain())[item] else {
            return XCTFail("an item on another program's access list must read as unreadable")
        }
        XCTAssertEqual(TouchIDSecretStore(service: newService).load(account: account).status, errSecItemNotFound)
    }

    private func security(_ arguments: [String]) throws {
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        tool.arguments = arguments
        tool.standardOutput = FileHandle.nullDevice
        tool.standardError = FileHandle.nullDevice
        try tool.run()
        tool.waitUntilExit()
        guard tool.terminationStatus == 0 else { throw XCTSkip("security \(arguments[0]) failed (\(tool.terminationStatus))") }
    }

    func testAMissingItemIsAbsent() throws {
        try requireKeychain()
        let item = LegacyKeychainItem(service: newService, account: account)
        XCTAssertEqual(LegacyMigration.migrateKeychain([item], keychain: LoginKeychain())[item], .absent)
    }
}
