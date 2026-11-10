import CryptoKit
import XCTest
@testable import PasswordPieCore

/// Key files for KDBX databases: the five KeePass formats, the composite key, saving, and changing keys.
final class KeyFileTests: XCTestCase {
    private var directory: URL!
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/KeyFiles", isDirectory: true)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("key-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    // MARK: Formats

    private let thirtyTwo = Data((0..<32).map { UInt8(($0 * 7 + 3) % 256) })

    func testXMLVersion1IsBase64() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <KeyFile><Meta><Version>1.00</Version></Meta><Key><Data>\(thirtyTwo.base64EncodedString())</Data></Key></KeyFile>
        """
        XCTAssertEqual(try KeyFile.key(from: Data(xml.utf8)), thirtyTwo)
    }

    func testXMLVersion2IsHexWithACheckedHash() throws {
        let hex = thirtyTwo.map { String(format: "%02X", $0) }.joined()
        let hash = Data(SHA256.hash(data: thirtyTwo)).prefix(4).map { String(format: "%02X", $0) }.joined()
        let grouped = stride(from: 0, to: hex.count, by: 8).map { offset -> String in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return String(hex[start..<hex.index(start, offsetBy: 8)])
        }.joined(separator: " ")
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <KeyFile>
            <Meta><Version>2.0</Version></Meta>
            <Key>
                <Data Hash="\(hash)">
                    \(grouped)
                </Data>
            </Key>
        </KeyFile>
        """
        XCTAssertEqual(try KeyFile.key(from: Data(xml.utf8)), thirtyTwo)
    }

    func testXMLVersion2WithAWrongHashIsRefused() {
        let hex = thirtyTwo.map { String(format: "%02X", $0) }.joined()
        let xml = "<KeyFile><Meta><Version>2.0</Version></Meta><Key><Data Hash=\"00000000\">\(hex)</Data></Key></KeyFile>"
        XCTAssertThrowsError(try KeyFile.key(from: Data(xml.utf8))) { error in
            XCTAssertEqual(error as? KeyFileError, .hashMismatch)
        }
    }

    func testXMLVersion2WithoutAHashIsRefused() {
        let hex = thirtyTwo.map { String(format: "%02X", $0) }.joined()
        let xml = "<KeyFile><Meta><Version>2.0</Version></Meta><Key><Data>\(hex)</Data></Key></KeyFile>"
        XCTAssertThrowsError(try KeyFile.key(from: Data(xml.utf8))) { error in
            XCTAssertEqual(error as? KeyFileError, .hashMismatch)
        }
    }

    func testAnUnknownKeyFileVersionIsRefused() {
        let xml = "<KeyFile><Meta><Version>3.0</Version></Meta><Key><Data>AAAA</Data></Key></KeyFile>"
        XCTAssertThrowsError(try KeyFile.key(from: Data(xml.utf8))) { error in
            XCTAssertEqual(error as? KeyFileError, .unsupportedVersion("3.0"))
        }
    }

    func testThirtyTwoBytesAreTheKey() throws {
        XCTAssertEqual(try KeyFile.key(from: thirtyTwo), thirtyTwo)
    }

    func testSixtyFourHexCharactersAreDecoded() throws {
        let hex = Data(thirtyTwo.map { String(format: "%02x", $0) }.joined().utf8)
        XCTAssertEqual(hex.count, 64)
        XCTAssertEqual(try KeyFile.key(from: hex), thirtyTwo)
    }

    func testAnyOtherFileIsHashed() throws {
        let contents = Data("Any file can be a key file.\n".utf8)
        XCTAssertEqual(try KeyFile.key(from: contents), Data(SHA256.hash(data: contents)))
        // 64 bytes that are not all hex are hashed, not decoded.
        let notHex = Data(String(repeating: "g", count: 64).utf8)
        XCTAssertEqual(try KeyFile.key(from: notHex), Data(SHA256.hash(data: notHex)))
        // XML that is not a KeePass key file is just a file.
        let other = Data("<?xml version=\"1.0\"?><Notes>hello</Notes>".utf8)
        XCTAssertEqual(try KeyFile.key(from: other), Data(SHA256.hash(data: other)))
    }

    func testAnEmptyFileIsRefused() {
        XCTAssertThrowsError(try KeyFile.key(from: Data())) { error in
            XCTAssertEqual(error as? KeyFileError, .empty)
        }
    }

    func testAGeneratedKeyFileIsVersion2AndRandom() throws {
        let first = try KeyFile.generate()
        let second = try KeyFile.generate()
        XCTAssertNotEqual(first, second)
        let text = try XCTUnwrap(String(data: first, encoding: .utf8))
        XCTAssertTrue(text.contains("<Version>2.0</Version>"))
        XCTAssertTrue(text.contains("Hash=\""))
        XCTAssertEqual(try KeyFile.key(from: first).count, 32)
        XCTAssertNotEqual(try KeyFile.key(from: first), try KeyFile.key(from: second))
    }

    // MARK: Composite key

    func testPasswordAndKeyFileOpenOnlyTogether() throws {
        let key = try KeyFile.generate()
        var vault = Vault(entries: [account("Both")], kdf: .fastTest)
        let data = try KDBX.save(vault: &vault, password: "secret", keyFile: key)

        XCTAssertEqual(try KDBX.load(data: data, password: "secret", keyFile: key).entries.map(\.title), ["Both"])
        assertWrongKey(try KDBX.load(data: data, password: "secret", keyFile: nil))
        assertWrongKey(try KDBX.load(data: data, password: "secret", keyFile: try KeyFile.generate()))
        assertWrongKey(try KDBX.load(data: data, password: "other", keyFile: key))
        assertWrongKey(try KDBX.load(data: data, password: "", keyFile: key))
    }

    func testAKeyFileAloneOpensWithoutAPassword() throws {
        let key = try KeyFile.generate()
        var vault = Vault(entries: [account("Key only")], kdf: .fastTest)
        let data = try KDBX.save(vault: &vault, password: "", keyFile: key)
        XCTAssertEqual(try KDBX.load(data: data, password: "", keyFile: key).entries.map(\.title), ["Key only"])
        assertWrongKey(try KDBX.load(data: data, password: "", keyFile: nil))
        assertWrongKey(try KDBX.load(data: data, password: "secret", keyFile: key))
    }

    func testTheCompositeKeyFollowsTheKeePassFormula() throws {
        let key = thirtyTwo
        let password = Data("secret".utf8)
        let expected = Data(SHA256.hash(data: Data(SHA256.hash(data: password)) + key))
        XCTAssertEqual(try compositeKey(password: "secret", keyFile: key), expected)
        XCTAssertEqual(try compositeKey(password: "", keyFile: key), Data(SHA256.hash(data: key)))
        XCTAssertEqual(try compositeKey(password: "secret", keyFile: nil),
                       Data(SHA256.hash(data: Data(SHA256.hash(data: password)))))
    }

    func testAPasswordOnlyDatabaseIgnoresNoKeyFile() throws {
        var vault = Vault(entries: [account("Password")], kdf: .fastTest)
        let data = try KDBX.save(vault: &vault, password: "secret", keyFile: nil)
        XCTAssertEqual(try KDBX.load(data: data, password: "secret").entries.map(\.title), ["Password"])
        assertWrongKey(try KDBX.load(data: data, password: "secret", keyFile: thirtyTwo))
    }

    func testADamagedKeyFileSaysSoInsteadOfWrongPassword() throws {
        var vault = Vault(entries: [account("x")], kdf: .fastTest)
        let data = try KDBX.save(vault: &vault, password: "secret", keyFile: nil)
        let bad = Data("<KeyFile><Meta><Version>2.0</Version></Meta><Key><Data Hash=\"00000000\">00</Data></Key></KeyFile>".utf8)
        XCTAssertThrowsError(try KDBX.load(data: data, password: "secret", keyFile: bad)) { error in
            XCTAssertEqual(error as? KeyFileError, .hashMismatch)
        }
    }

    // MARK: Saving

    func testSavingAKeyFileDatabaseKeepsBothKeys() throws {
        let url = directory.appendingPathComponent("Keys.kdbx")
        let key = try KeyFile.generate()
        var vault = Vault(entries: [account("First")], kdf: .fastTest)
        let first = try KDBX.save(vault: &vault, password: "secret", keyFile: key)
        try VaultFile.replace(url, with: first, password: "secret", keyFile: key, expecting: vault)

        var opened = try VaultFile.openRecovering(url: url, password: "secret", keyFile: key)
        opened.entries.append(account("Second"))
        let second = try KDBX.save(vault: &opened, password: "secret", keyFile: key)
        try VaultFile.replace(url, with: second, password: "secret", keyFile: key, expecting: opened)

        let reread = try Data(contentsOf: url)
        XCTAssertEqual(try KDBX.load(data: reread, password: "secret", keyFile: key).entries.map(\.title).sorted(), ["First", "Second"])
        assertWrongKey(try KDBX.load(data: reread, password: "secret", keyFile: nil))
    }

    func testASaveWithTheWrongKeyFileIsNotWritten() throws {
        let url = directory.appendingPathComponent("Keys.kdbx")
        let key = try KeyFile.generate()
        var vault = Vault(entries: [account("Kept")], kdf: .fastTest)
        let original = try KDBX.save(vault: &vault, password: "secret", keyFile: key)
        try original.write(to: url)
        // The bytes were made without the key file, but the read-back uses it: refused before replacing.
        var other = Vault(entries: [account("Other")], kdf: .fastTest)
        let wrong = try KDBX.save(vault: &other, password: "secret", keyFile: nil)
        XCTAssertThrowsError(try VaultFile.replace(url, with: wrong, password: "secret", keyFile: key, expecting: other))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testARepairedDatabaseIsRewrittenWithItsKeyFile() throws {
        let url = directory.appendingPathComponent("Damaged.kdbx")
        let key = try KeyFile.generate()
        let streamKey = Data(repeating: 7, count: 64)
        let xml = """
        <?xml version="1.0" encoding="utf-8" standalone="yes"?>
        <KeePassFile><Meta><DatabaseName>Damaged</DatabaseName></Meta><Root><Group><UUID>AAAAAAAAAAAAAAAAAAAAAA==</UUID><Name>Root</Name>\
        <Entry><UUID>AQEBAQEBAQEBAQEBAQEBAQ==</UUID><String><Key>Title</Key><Value>Site</Value></String>\
        <String><Key>Notes</Key><Value>A&amp;#B&#13;C</Value></String></Entry>\
        </Group></Root></KeePassFile>
        """
        // The old writer's damage: parsed and written back the way it used to be.
        let damaged = try XMLDocument(xmlString: xml, options: KDBXXMLRepair.legacyXMLOptions).xmlData(options: .nodePreserveAll)
        try KDBX.testingDatabase(rawXML: damaged, streamKey: streamKey, password: "secret", keyFile: key).write(to: url)

        let opened = try VaultFile.openRecovering(url: url, password: "secret", keyFile: key)
        XCTAssertNotNil(opened.recoveryNotice)
        XCTAssertTrue(opened.recoveryNotice?.hasPrefix("Repaired") == true, opened.recoveryNotice ?? "")
        let rewritten = try Data(contentsOf: url)
        XCTAssertNoThrow(try KDBX.load(data: rewritten, password: "secret", keyFile: key))
        assertWrongKey(try KDBX.load(data: rewritten, password: "secret", keyFile: nil))
    }

    // MARK: Changing keys

    func testAddingAKeyFileReplacesTheDatabaseAndItsSnapshot() throws {
        let url = directory.appendingPathComponent("Rekey.kdbx")
        var vault = try openedDatabase(at: url, password: "secret", keyFile: nil)
        let key = try KeyFile.generate()
        let result = try VaultFile.rekey(url, vault: &vault, password: "secret", keyFile: key, baseline: XCTUnwrap(vault.fileBaseline))
        let written = result.data
        XCTAssertTrue(result.snapshotRefreshed)

        XCTAssertEqual(try Data(contentsOf: url), written)
        XCTAssertEqual(vault.fileBaseline, written)
        XCTAssertNoThrow(try KDBX.load(data: written, password: "secret", keyFile: key))
        assertWrongKey(try KDBX.load(data: written, password: "secret", keyFile: nil))
        // No copy beside the database still opens with the password alone.
        let snapshot = try Data(contentsOf: VaultFile.snapshotURL(for: url))
        assertWrongKey(try KDBX.load(data: snapshot, password: "secret", keyFile: nil))
        XCTAssertNoThrow(try KDBX.load(data: snapshot, password: "secret", keyFile: key))
    }

    func testRemovingAKeyFileAndChangingThePassword() throws {
        let url = directory.appendingPathComponent("Rekey.kdbx")
        let key = try KeyFile.generate()
        var vault = try openedDatabase(at: url, password: "secret", keyFile: key)

        _ = try VaultFile.rekey(url, vault: &vault, password: "new secret", keyFile: key, baseline: XCTUnwrap(vault.fileBaseline))
        let changed = try Data(contentsOf: url)
        XCTAssertNoThrow(try KDBX.load(data: changed, password: "new secret", keyFile: key))
        assertWrongKey(try KDBX.load(data: changed, password: "new secret", keyFile: nil))
        assertWrongKey(try KDBX.load(data: changed, password: "secret", keyFile: key))

        _ = try VaultFile.rekey(url, vault: &vault, password: "new secret", keyFile: nil, baseline: XCTUnwrap(vault.fileBaseline))
        let removed = try Data(contentsOf: url)
        XCTAssertEqual(try KDBX.load(data: removed, password: "new secret", keyFile: nil).entries.map(\.title), ["Rekeyed"])
    }

    func testAFailedKeyChangeLeavesTheOriginalFile() throws {
        let url = directory.appendingPathComponent("Rekey.kdbx")
        var vault = try openedDatabase(at: url, password: "secret", keyFile: nil)
        let original = try Data(contentsOf: url)
        let snapshotBefore = try? Data(contentsOf: VaultFile.snapshotURL(for: url))
        let key = try KeyFile.generate()

        struct Interrupted: Error {}
        XCTAssertThrowsError(try VaultFile.rekey(url, vault: &vault, password: "secret", keyFile: key, baseline: original,
                                                 beforeReplace: { throw Interrupted() }))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(vault.fileBaseline, original)
        XCTAssertNoThrow(try KDBX.load(data: original, password: "secret", keyFile: nil))
        let snapshotAfter = try? Data(contentsOf: VaultFile.snapshotURL(for: url))
        if let snapshotAfter {
            // The snapshot may have been refreshed with the file as it was; it never holds the new keys.
            XCTAssertTrue(snapshotAfter == original || snapshotAfter == snapshotBefore)
        }
    }

    func testAKeyChangeIsRefusedWhenTheFileChangedOnDisk() throws {
        let url = directory.appendingPathComponent("Rekey.kdbx")
        var vault = try openedDatabase(at: url, password: "secret", keyFile: nil)
        let stale = try XCTUnwrap(vault.fileBaseline)
        var newer = Vault(entries: [account("Synced")], kdf: .fastTest)
        let synced = try KDBX.save(vault: &newer, password: "secret", keyFile: nil)
        try synced.write(to: url)

        XCTAssertThrowsError(try VaultFile.rekey(url, vault: &vault, password: "secret", keyFile: try KeyFile.generate(), baseline: stale))
        XCTAssertEqual(try Data(contentsOf: url), synced)
    }

    // MARK: KeePassXC

    func testKeePassXCDatabasesOpenWithEveryKeyFileFormat() throws {
        let cases = [("v2", "v2.keyx"), ("v1", "v1.key"), ("binary32", "binary32.key"), ("hex64", "hex64.key"), ("any", "any.key")]
        for (name, keyName) in cases {
            let key = try Data(contentsOf: fixtures.appendingPathComponent(keyName))
            let data = try Data(contentsOf: fixtures.appendingPathComponent("\(name).kdbx"))
            let vault = try KDBX.load(data: data, password: "pie-test", keyFile: key)
            XCTAssertEqual(vault.entries.filter { !$0.trashed }.map(\.title), ["Example \(name)"], name)
            XCTAssertEqual(vault.entries.first?.password, "hunter2-\(name)", name)
            assertWrongKey(try KDBX.load(data: data, password: "pie-test", keyFile: nil))
        }
    }

    func testAKeePassXCKeyFileOnlyDatabaseOpens() throws {
        let key = try Data(contentsOf: fixtures.appendingPathComponent("v2.keyx"))
        let data = try Data(contentsOf: fixtures.appendingPathComponent("keyfile-only.kdbx"))
        let vault = try KDBX.load(data: data, password: "", keyFile: key)
        XCTAssertEqual(vault.entries.filter { !$0.trashed }.map(\.title), ["Example keyfile-only"])
    }

    func testAKeePassXCDatabaseSavedHereStillNeedsItsKeyFile() throws {
        let key = try Data(contentsOf: fixtures.appendingPathComponent("v2.keyx"))
        let url = directory.appendingPathComponent("v2.kdbx")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("v2.kdbx"), to: url)

        var vault = try VaultFile.openRecovering(url: url, password: "pie-test", keyFile: key)
        vault.entries.append(account("Added by PasswordPie"))
        let data = try KDBX.save(vault: &vault, password: "pie-test", keyFile: key)
        try VaultFile.replace(url, with: data, password: "pie-test", keyFile: key, expecting: vault)

        let reread = try Data(contentsOf: url)
        XCTAssertEqual(try KDBX.load(data: reread, password: "pie-test", keyFile: key).entries.filter { !$0.trashed }.map(\.title).sorted(),
                       ["Added by PasswordPie", "Example v2"])
        assertWrongKey(try KDBX.load(data: reread, password: "pie-test", keyFile: nil))
    }

    /// Runs only where KeePassXC is installed (`brew install --cask keepassxc`); CI skips it.
    func testKeePassXCOpensWhatPasswordPieWrites() throws {
        let cli = ["/opt/homebrew/bin/keepassxc-cli", "/usr/local/bin/keepassxc-cli",
                   "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let tool = cli else { throw XCTSkip("keepassxc-cli is not installed") }

        let keyURL = directory.appendingPathComponent("PasswordPie.keyx")
        let key = try KeyFile.generate()
        try key.write(to: keyURL)
        let both = directory.appendingPathComponent("both.kdbx")
        var vault = Vault(entries: [account("Written by PasswordPie")], kdf: .default)
        try KDBX.save(vault: &vault, password: "pie-test", keyFile: key).write(to: both)
        let keyOnly = directory.appendingPathComponent("key-only.kdbx")
        var second = Vault(entries: [account("Key only")], kdf: .default)
        try KDBX.save(vault: &second, password: "", keyFile: key).write(to: keyOnly)

        XCTAssertEqual(try run(tool, ["ls", "-q", "-k", keyURL.path, both.path], input: "pie-test\n").output, "Written by PasswordPie\n")
        XCTAssertNotEqual(try run(tool, ["ls", "-q", both.path], input: "pie-test\n").status, 0, "the key file is required")
        XCTAssertEqual(try run(tool, ["ls", "-q", "--no-password", "-k", keyURL.path, keyOnly.path], input: "").output, "Key only\n")
    }

    private func run(_ tool: String, _ arguments: [String], input: String) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    // MARK: Remembered key file

    func testARememberedKeyFileRoundTripsItsNameAndBytes() throws {
        let key = try KeyFile.generate()
        let remembered = RememberedKeyFile(name: "Passwords.keyx", data: key)
        XCTAssertEqual(RememberedKeyFile(stored: remembered.encoded), remembered)
        var damaged = remembered.encoded
        damaged[damaged.count - 1] ^= 0xFF
        XCTAssertNil(RememberedKeyFile(stored: damaged))
        XCTAssertNil(RememberedKeyFile(stored: Data("plain".utf8)))
        XCTAssertNil(RememberedKeyFile(stored: RememberedKeyFile(name: "x", data: Data()).encoded))
    }

    // MARK: Helpers

    private func account(_ title: String) -> VaultEntry {
        var entry = VaultEntry()
        entry.title = title
        entry.username = "ada"
        entry.password = "pw-\(title)"
        return entry
    }

    private func openedDatabase(at url: URL, password: String, keyFile: Data?) throws -> Vault {
        var vault = Vault(entries: [account("Rekeyed")], kdf: .fastTest)
        let data = try KDBX.save(vault: &vault, password: password, keyFile: keyFile)
        try VaultFile.replace(url, with: data, password: password, keyFile: keyFile, expecting: vault)
        return try VaultFile.openRecovering(url: url, password: password, keyFile: keyFile)
    }

    private func assertWrongKey<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(error as? KDBXError, .wrongPassword, file: file, line: line)
        }
    }
}
