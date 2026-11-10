import AppKit
import Security
import XCTest
@testable import PasswordPie
@testable import PasswordPieCore

/// The login keychain, in memory.
final class MemoryKeyFileKeychain: KeyFileKeychain {
    var items: [String: Data] = [:]
    var failSaves = false

    func save(secret: Data, account: String) -> OSStatus {
        guard !failSaves else { return errSecNotAvailable }
        items[account] = secret
        return errSecSuccess
    }

    func load(account: String) -> (status: OSStatus, secret: Data?) {
        guard let secret = items[account] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, secret)
    }

    func delete(account: String) -> OSStatus {
        items[account] = nil
        return errSecSuccess
    }
}

/// Answers the key file dialogs from a script.
@MainActor
final class ScriptedKeyFilePrompts: KeyFilePrompting {
    var choices: [Int] = []
    var saveLocations: [URL?] = []
    var existingFiles: [URL?] = []
    var passwordChange: MasterPasswordChange?
    private(set) var titles: [String] = []
    private(set) var texts: [String] = []

    func choose(title: String, text: String, buttons: [String]) -> Int {
        titles.append(title)
        texts.append(text)
        return choices.isEmpty ? buttons.count - 1 : choices.removeFirst()
    }

    func saveLocation(suggestedName: String, directory: URL?) -> URL? {
        saveLocations.isEmpty ? nil : saveLocations.removeFirst()
    }

    func existingKeyFile(message: String) -> URL? {
        existingFiles.isEmpty ? nil : existingFiles.removeFirst()
    }

    func masterPasswordChange() -> MasterPasswordChange? {
        passwordChange
    }
}

@MainActor
final class KeyFileSessionTests: XCTestCase {
    private var directory: URL!
    private var keys: URL!
    private var database: URL!
    private var keychain: MemoryKeyFileKeychain!
    private var prompts: ScriptedKeyFilePrompts!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("keyfile-\(UUID().uuidString)", isDirectory: true)
        keys = directory.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
        database = directory.appendingPathComponent("test.kdbx")
        setenv("PASSWORDPIE_DB", database.path, 1)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
        // Never store a Touch ID secret in the real login keychain from a test.
        UserDefaults.standard.set(true, forKey: "touchIDDeclined.\(database.path)")
        keychain = MemoryKeyFileKeychain()
        prompts = ScriptedKeyFilePrompts()
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: "touchIDDeclined.\(database.path)")
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: Lock screen

    func testTheLockScreenOffersAKeyFileForKeePassDatabases() {
        let session = makeSession()
        for (name, shows) in [("a.kdbx", true), ("a.KDBX", true), ("a.kdb", true), ("a.csv", false), ("a.json", false)] {
            session.databaseURL = directory.appendingPathComponent(name)
            XCTAssertEqual(session.showsKeyFile, shows, name)
            XCTAssertEqual(LockScreenPresentation(session: session, locking: false).showsKeyFile, shows, name)
        }
    }

    func testANewDatabaseCanStartWithAKeyFile() throws {
        let session = makeSession()
        XCTAssertTrue(session.creating)
        XCTAssertTrue(LockScreenPresentation(session: session, locking: false).showsKeyFile)
        let keyURL = keys.appendingPathComponent("New.keyx")
        prompts.choices = [0]
        prompts.saveLocations = [keyURL]
        session.chooseKeyFile()
        XCTAssertEqual(session.keyFileName, "New.keyx")
        XCTAssertTrue(prompts.texts.first?.contains("PasswordPie cannot recover it") == true)

        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        XCTAssertFalse(session.locked)
        let key = try Data(contentsOf: keyURL)
        try assertOpens(password: "pw", keyFile: key)
        try assertRefuses(password: "pw", keyFile: nil)
        XCTAssertTrue(session.databaseUsesKeyFile)
        XCTAssertEqual(RememberedKeyFile(stored: try XCTUnwrap(keychain.items[database.path]))?.data, key)
    }

    func testANewDatabaseStillNeedsAPassword() {
        let session = makeSession()
        prompts.choices = [0]
        prompts.saveLocations = [keys.appendingPathComponent("New.keyx")]
        session.chooseKeyFile()
        session.unlock()
        XCTAssertTrue(session.locked)
        XCTAssertEqual(session.message, "Enter the master password.")
    }

    // MARK: Add, remember, forget

    func testAddKeyFileThenUnlockWithThePasswordAlone() async throws {
        let session = try await createdSession()
        let keyURL = keys.appendingPathComponent("test.keyx")
        prompts.choices = [0]
        prompts.saveLocations = [keyURL]
        session.addKeyFile()

        XCTAssertTrue(prompts.texts.first?.contains("not in the database's folder, and not in the same cloud storage") == true)
        XCTAssertFalse(session.keyFileStatusIsError, session.keyFileStatus)
        let key = try Data(contentsOf: keyURL)
        XCTAssertTrue(String(decoding: key, as: UTF8.self).contains("<Version>2.0</Version>"))
        try assertOpens(password: "pw", keyFile: key)
        try assertRefuses(password: "pw", keyFile: nil)
        // The snapshot beside the database does not open with the password alone either.
        let snapshot = try Data(contentsOf: VaultFile.snapshotURL(for: database))
        XCTAssertThrowsError(try KDBX.load(data: snapshot, password: "pw", keyFile: nil))
        XCTAssertTrue(session.databaseUsesKeyFile)

        session.lock()
        XCTAssertEqual(session.keyFileName, "test.keyx")
        XCTAssertTrue(session.keyFileRemembered)
        try await unlock(session, password: "pw")
        XCTAssertFalse(session.locked, session.message)

        // A fresh launch reads it from the keychain too.
        let next = makeSession()
        XCTAssertEqual(next.keyFileName, "test.keyx")
        try await unlock(next, password: "pw")
        XCTAssertFalse(next.locked, next.message)
    }

    func testForgetKeyFileThenThePasswordAloneFailsAndChoosingItAgainWorks() async throws {
        let session = try await createdSession()
        let keyURL = keys.appendingPathComponent("test.keyx")
        prompts.choices = [0]
        prompts.saveLocations = [keyURL]
        session.addKeyFile()
        session.lock()

        XCTAssertTrue(session.forgetKeyFile())
        XCTAssertEqual(session.keyFileName, "")
        XCTAssertNil(keychain.items[database.path])
        try await unlock(session, password: "pw")
        XCTAssertTrue(session.locked)

        prompts.existingFiles = [keyURL]
        session.chooseKeyFile()
        XCTAssertEqual(session.keyFileName, "test.keyx")
        XCTAssertFalse(session.keyFileRemembered)
        try await unlock(session, password: "pw")
        XCTAssertFalse(session.locked, session.message)
        XCTAssertNotNil(keychain.items[database.path], "remembered again after it opened")
    }

    func testAKeyFileOnlyDatabaseIsNotRememberedWithoutAPassword() async throws {
        let key = try KeyFile.generate()
        let keyURL = keys.appendingPathComponent("only.keyx")
        try key.write(to: keyURL)
        var vault = Vault(entries: [], kdf: .fastTest)
        try KDBX.save(vault: &vault, password: "", keyFile: key).write(to: database)
        let session = makeSession()
        prompts.existingFiles = [keyURL]
        session.chooseKeyFile()
        try await unlock(session, password: "")
        XCTAssertFalse(session.locked, session.message)
        XCTAssertTrue(session.databaseUsesKeyFile)
        XCTAssertNil(keychain.items[database.path], "a remembered key would open it with nothing typed")
        XCTAssertFalse(makeSession().keyFileRemembered)
    }

    func testAKeyFileOnlyDatabaseNeedsItsKeyFileAgainAfterLock() async throws {
        let session = try await keyOnlySession()
        session.lock()
        XCTAssertEqual(session.keyFileName, "")
        session.passwordDraft = ""
        session.unlock()
        XCTAssertTrue(session.locked)
        XCTAssertEqual(session.message, "Enter the master password.")
    }

    func testARememberedKeyFileNeverOpensADatabaseWithAnEmptyPassword() async throws {
        let key = try KeyFile.generate()
        var vault = Vault(entries: [], kdf: .fastTest)
        try KDBX.save(vault: &vault, password: "", keyFile: key).write(to: database)
        // Remembered while the database still had a password; the password was later removed elsewhere.
        keychain.items[database.path] = RememberedKeyFile(name: "old.keyx", data: key).encoded
        let session = makeSession()
        XCTAssertTrue(session.keyFileRemembered)
        session.passwordDraft = ""
        session.unlock()
        XCTAssertTrue(session.locked)
        XCTAssertEqual(session.message, "Enter the master password.")
    }

    func testRemovingTheKeyFileOfADatabaseWithNoPasswordIsRefused() async throws {
        let session = try await keyOnlySession()
        let original = try Data(contentsOf: database)
        prompts.choices = [0]
        session.removeKeyFile()
        XCTAssertTrue(session.keyFileStatusIsError)
        XCTAssertEqual(try Data(contentsOf: database), original)
    }

    func testAPasswordChangeAfterForgetKeyFileDoesNotRememberItAgain() async throws {
        let session = try await createdSession()
        let keyURL = keys.appendingPathComponent("test.keyx")
        prompts.choices = [0]
        prompts.saveLocations = [keyURL]
        session.addKeyFile()
        XCTAssertTrue(session.forgetKeyFile())
        prompts.passwordChange = MasterPasswordChange(current: "pw", new: "new pw", repeated: "new pw")
        session.changeMasterPassword()
        XCTAssertFalse(session.keyFileStatusIsError, session.keyFileStatus)
        XCTAssertNil(keychain.items[database.path])
        try assertOpens(password: "new pw", keyFile: try Data(contentsOf: keyURL))
    }

    func testAFirstPasswordOnAKeyFileOnlyDatabaseKeepsTheKeyOnThisMac() async throws {
        let session = try await keyOnlySession()
        prompts.passwordChange = MasterPasswordChange(current: "", new: "pw", repeated: "pw")
        session.changeMasterPassword()
        XCTAssertFalse(session.keyFileStatusIsError, session.keyFileStatus)
        XCTAssertNotNil(keychain.items[database.path])
        session.lock()
        try await unlock(session, password: "pw")
        XCTAssertFalse(session.locked, session.message)
    }

    func testAWrongPasswordWithAKeyFileNamesBoth() async throws {
        let session = try await createdSession()
        prompts.choices = [0]
        prompts.saveLocations = [keys.appendingPathComponent("test.keyx")]
        session.addKeyFile()
        session.lock()
        try await unlock(session, password: "wrong")
        XCTAssertTrue(session.locked)
        XCTAssertEqual(session.message, "Incorrect password or key file. Please try again.")
    }

    func testAKeyFileInTheDatabaseFolderAsksAgain() async throws {
        let session = try await createdSession()
        let original = try Data(contentsOf: database)
        prompts.choices = [0, 2]
        prompts.saveLocations = [directory.appendingPathComponent("test.keyx")]
        session.addKeyFile()
        XCTAssertEqual(prompts.titles.last, "Keep the key file in the database's folder?")
        XCTAssertEqual(try Data(contentsOf: database), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("test.keyx").path))
        XCTAssertFalse(session.databaseUsesKeyFile)
    }

    func testTheDatabaseCannotBeItsOwnKeyFile() async throws {
        let session = try await createdSession()
        let original = try Data(contentsOf: database)
        prompts.choices = [0, 1]
        prompts.saveLocations = [database]
        session.addKeyFile()
        XCTAssertTrue(session.keyFileStatusIsError)
        XCTAssertEqual(try Data(contentsOf: database), original)
    }

    func testCancellingTheWarningChangesNothing() async throws {
        let session = try await createdSession()
        let original = try Data(contentsOf: database)
        prompts.choices = [1]
        session.addKeyFile()
        XCTAssertEqual(try Data(contentsOf: database), original)
        XCTAssertTrue(keychain.items.isEmpty)
    }

    // MARK: Use existing, remove

    func testUseExistingKeyFile() async throws {
        let session = try await createdSession()
        let keyURL = keys.appendingPathComponent("photo.jpg")
        let key = Data("any file at all".utf8)
        try key.write(to: keyURL)
        prompts.choices = [0]
        prompts.existingFiles = [keyURL]
        session.useExistingKeyFile()
        XCTAssertFalse(session.keyFileStatusIsError, session.keyFileStatus)
        try assertOpens(password: "pw", keyFile: key)
        try assertRefuses(password: "pw", keyFile: nil)
        XCTAssertEqual(session.keyFileName, "photo.jpg")
    }

    func testADamagedKeyFileIsRefusedBeforeAnythingChanges() async throws {
        let session = try await createdSession()
        let original = try Data(contentsOf: database)
        let keyURL = keys.appendingPathComponent("broken.keyx")
        try Data("<KeyFile><Meta><Version>2.0</Version></Meta><Key><Data Hash=\"00000000\">AA</Data></Key></KeyFile>".utf8).write(to: keyURL)
        prompts.choices = [0]
        prompts.existingFiles = [keyURL]
        session.useExistingKeyFile()
        XCTAssertTrue(session.keyFileStatusIsError)
        XCTAssertTrue(session.keyFileStatus.contains("checksum"), session.keyFileStatus)
        XCTAssertEqual(try Data(contentsOf: database), original)
    }

    func testRemoveKeyFile() async throws {
        let session = try await createdSession()
        prompts.choices = [0]
        prompts.saveLocations = [keys.appendingPathComponent("test.keyx")]
        session.addKeyFile()
        XCTAssertNotNil(keychain.items[database.path])

        prompts.choices = [0]
        session.removeKeyFile()
        XCTAssertFalse(session.keyFileStatusIsError, session.keyFileStatus)
        try assertOpens(password: "pw", keyFile: nil)
        XCTAssertFalse(session.databaseUsesKeyFile)
        XCTAssertNil(keychain.items[database.path])
        XCTAssertEqual(session.keyFileName, "")
    }

    // MARK: Master password

    func testChangingTheMasterPasswordKeepsTheKeyFile() async throws {
        let session = try await createdSession()
        let keyURL = keys.appendingPathComponent("test.keyx")
        prompts.choices = [0]
        prompts.saveLocations = [keyURL]
        session.addKeyFile()
        let key = try Data(contentsOf: keyURL)

        prompts.passwordChange = MasterPasswordChange(current: "pw", new: "new pw", repeated: "new pw")
        session.changeMasterPassword()
        XCTAssertFalse(session.keyFileStatusIsError, session.keyFileStatus)
        try assertOpens(password: "new pw", keyFile: key)
        try assertRefuses(password: "new pw", keyFile: nil)
        try assertRefuses(password: "pw", keyFile: key)

        // Later saves keep both.
        var entry = VaultEntry()
        entry.title = "After"
        session.saveEditing(entry)
        try assertOpens(password: "new pw", keyFile: key)
        try assertRefuses(password: "new pw", keyFile: nil)
    }

    func testAWrongCurrentPasswordChangesNothing() async throws {
        let session = try await createdSession()
        let original = try Data(contentsOf: database)
        prompts.passwordChange = MasterPasswordChange(current: "nope", new: "new pw", repeated: "new pw")
        session.changeMasterPassword()
        XCTAssertTrue(session.keyFileStatusIsError)
        XCTAssertEqual(try Data(contentsOf: database), original)

        prompts.passwordChange = MasterPasswordChange(current: "pw", new: "new pw", repeated: "other")
        session.changeMasterPassword()
        XCTAssertTrue(session.keyFileStatusIsError)
        XCTAssertEqual(try Data(contentsOf: database), original)
    }

    func testKeysCannotChangeWhileLocked() async throws {
        let session = try await createdSession()
        session.lock()
        prompts.choices = [0]
        session.addKeyFile()
        XCTAssertTrue(prompts.titles.isEmpty)
        XCTAssertEqual(session.keyFileStatus, "Unlock the database first.")
    }

    // MARK: Helpers

    private func makeSession() -> VaultSession {
        let session = VaultSession(keyFileMemory: keychain)
        session.keyFilePrompts = prompts
        session.restore()
        return session
    }

    /// A new database with the password "pw" and one entry, unlocked. The KDF is the quick one tests use.
    private func createdSession() async throws -> VaultSession {
        var vault = Vault(entries: [], kdf: .fastTest)
        var entry = VaultEntry()
        entry.title = "Kept"
        vault.entries = [entry]
        try KDBX.save(vault: &vault, password: "pw", keyFile: nil).write(to: database)
        let session = makeSession()
        try await unlock(session, password: "pw")
        XCTAssertFalse(session.locked, session.message)
        return session
    }

    /// A database with a key file and no password, opened with the file chosen on the lock screen.
    private func keyOnlySession() async throws -> VaultSession {
        let key = try KeyFile.generate()
        let keyURL = keys.appendingPathComponent("only.keyx")
        try key.write(to: keyURL)
        var vault = Vault(entries: [], kdf: .fastTest)
        try KDBX.save(vault: &vault, password: "", keyFile: key).write(to: database)
        let session = makeSession()
        prompts.existingFiles = [keyURL]
        session.chooseKeyFile()
        try await unlock(session, password: "")
        XCTAssertFalse(session.locked, session.message)
        return session
    }

    private func unlock(_ session: VaultSession, password: String) async throws {
        session.passwordDraft = password
        session.unlock()
        for _ in 0..<1000 where session.unlocking {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func assertOpens(password: String, keyFile: Data?, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertNoThrow(try KDBX.load(data: Data(contentsOf: database), password: password, keyFile: keyFile), file: file, line: line)
    }

    private func assertRefuses(password: String, keyFile: Data?, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertThrowsError(try KDBX.load(data: Data(contentsOf: database), password: password, keyFile: keyFile), file: file, line: line)
    }
}
