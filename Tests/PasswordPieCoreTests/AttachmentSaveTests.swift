import XCTest
@testable import PasswordPieCore

/// Attachments an import brings (1Password, KeePass 1, a folder of key files) are written into the KDBX file and read
/// back, on the first save of a new database and on a save into an existing one. Before this they were dropped: the
/// model carried them and neither writer wrote them.
final class AttachmentSaveTests: XCTestCase {
    private func id(_ text: String) -> String { base64UUID(UUID(uuidString: text)!) }

    private let pem = Data("-----BEGIN PRIVATE KEY-----\nMIIEvfake\n-----END PRIVATE KEY-----\n".utf8)
    private let json = Data(#"{"type":"service_account","private_key":"fake"}"#.utf8)

    /// A database KeePassXC could have written: one entry with an attachment, a history version, and a piece of the
    /// inner header this app does not know.
    private func existingDatabase() throws -> Data {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <KeePassFile><Meta><DatabaseName>Box</DatabaseName></Meta>
        <Root><Group><UUID>\(id("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))</UUID><Name>Root</Name>
        <Entry><UUID>\(id("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))</UUID>
        <Times><LastModificationTime>pVSf1Q4AAAA=</LastModificationTime></Times>
        <String><Key>Title</Key><Value>Old</Value></String>
        <String><Key>Password</Key><Value Protected="True">pw</Value></String>
        <Binary><Key>old.txt</Key><Value Ref="0"/></Binary>
        <History></History>
        </Entry></Group></Root></KeePassFile>
        """
        return try KDBX.testingDatabase(
            xml: xml, binaries: [Data("old bytes".utf8)], extraPieces: [.other(type: 6, payload: Data([9, 9]))], password: "secret"
        )
    }

    private func imported(_ title: String, _ attachments: [VaultAttachment], group: [String] = ["Keys"]) -> VaultEntry {
        var entry = VaultEntry(groupPath: group, attachments: attachments)
        entry.title = title
        return entry
    }

    // MARK: The first save of a new database

    func testAttachmentsSurviveTheFirstSaveOfANewDatabase() throws {
        var vault = Vault(name: "New", rootName: "New", entries: [
            imported("Apple", [VaultAttachment(name: "AuthKey.p8", data: pem)]),
            imported("Google", [VaultAttachment(name: "service-account.json", data: json), VaultAttachment(name: "empty.bin", data: Data())])
        ], kdf: .fastTest)
        let apple = vault.entries[0].id
        let google = vault.entries[1].id
        let saved = try KDBX.save(vault: &vault, password: "secret")
        let loaded = try KDBX.load(data: saved, password: "secret")
        XCTAssertEqual(loaded.attachmentNames(of: apple), ["AuthKey.p8"])
        XCTAssertEqual(loaded.attachment(named: "AuthKey.p8", of: apple), pem)
        XCTAssertEqual(loaded.attachmentNames(of: google), ["service-account.json", "empty.bin"])
        XCTAssertEqual(loaded.attachment(named: "service-account.json", of: google), json)
        XCTAssertEqual(loaded.attachment(named: "empty.bin", of: google), Data())
        // The model is what the file reads back as: the bytes live in the file, not a second time in memory.
        XCTAssertEqual(vault, loaded)
        XCTAssertTrue(vault.entries.allSatisfy { $0.attachments.isEmpty })
        XCTAssertEqual(vault.attachment(named: "AuthKey.p8", of: apple), pem)
    }

    func testANewDatabaseWithoutAttachmentsHasNoBinaries() throws {
        var vault = Vault(name: "New", rootName: "New", entries: [imported("Plain", [])], kdf: .fastTest)
        let loaded = try KDBX.load(data: try KDBX.save(vault: &vault, password: "secret"), password: "secret")
        XCTAssertEqual(loaded.preserve?.binaryPayloads, [])
    }

    // MARK: A save into an existing database

    func testAttachmentsOfAnImportedItemSurviveASaveIntoAnExistingDatabase() throws {
        var vault = try KDBX.load(data: try existingDatabase(), password: "secret")
        let old = try XCTUnwrap(vault.entries.first).id
        let fresh = imported("Apple", [VaultAttachment(name: "AuthKey.p8", data: pem)])
        vault.entries.append(fresh)
        let loaded = try KDBX.load(data: try KDBX.save(vault: &vault, password: "secret"), password: "secret")
        XCTAssertEqual(loaded.attachment(named: "AuthKey.p8", of: fresh.id), pem)
        XCTAssertEqual(loaded.attachment(named: "old.txt", of: old), Data("old bytes".utf8), "what was there keeps its place")
        XCTAssertEqual(loaded.preserve?.pieces, [
            .binary(flags: 0x01, data: Data("old bytes".utf8)), .other(type: 6, payload: Data([9, 9])), .binary(flags: 0x01, data: pem)
        ])
        XCTAssertEqual(vault, loaded)
        XCTAssertTrue(vault.entries.allSatisfy { $0.attachments.isEmpty })
    }

    func testAnImportThroughTheMergeKeepsItsAttachments() throws {
        var vault = try KDBX.load(data: try existingDatabase(), password: "secret")
        let placed = BrowserImport.place([imported("Apple", [VaultAttachment(name: "AuthKey.p8", data: pem)], group: ["Vault"])], source: .onePassword)
        vault.entries = BrowserImport.merge(placed, into: vault.entries, source: .onePassword).entries
        let loaded = try KDBX.load(data: try KDBX.save(vault: &vault, password: "secret"), password: "secret")
        let entry = try XCTUnwrap(loaded.entries.first { $0.title == "Apple" })
        XCTAssertEqual(entry.groupPath, ["1Password", "Vault"])
        XCTAssertEqual(loaded.attachment(named: "AuthKey.p8", of: entry.id), pem)
    }

    /// A save merges an imported login into the one already there (same site, username and password). The file it
    /// brought stays on the account that is left, not only on the copy in the Recycle Bin.
    func testAnImportedDuplicateLoginLeavesItsAttachmentOnTheAccountThatStays() throws {
        var vault = try KDBX.load(data: try existingDatabase(), password: "secret")
        vault.entries[0].url = "https://example.com/login"
        vault.entries[0].username = "ann"
        var copy = imported("Old", [VaultAttachment(name: "recovery-codes.txt", data: Data("codes".utf8))], group: ["1Password"])
        copy.url = "https://example.com/"
        copy.username = "ann"
        copy.password = "pw"
        vault.entries.append(copy)
        vault.entries = EntryMerge.merged(vault.entries)
        let loaded = try KDBX.load(data: try KDBX.save(vault: &vault, password: "secret"), password: "secret")
        let live = loaded.entries.filter { !$0.trashed }
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(loaded.attachment(named: "recovery-codes.txt", of: try XCTUnwrap(live.first).id), Data("codes".utf8))
    }

    func testSavingAgainAddsNoCopyAndNoVersion() throws {
        var vault = try KDBX.load(data: try existingDatabase(), password: "secret")
        var fresh = imported("Apple", [VaultAttachment(name: "AuthKey.p8", data: pem)])
        vault.entries.append(fresh)
        _ = try KDBX.save(vault: &vault, password: "secret")
        // The same attachment handed over again, as a second import of the same folder does.
        fresh.fields = vault.entries[1].fields
        vault.entries[1].attachments = fresh.attachments
        let again = try KDBX.load(data: try KDBX.save(vault: &vault, password: "secret"), password: "secret")
        XCTAssertEqual(again.preserve?.binaryPayloads, [Data("old bytes".utf8), pem])
        XCTAssertEqual(again.attachmentNames(of: fresh.id), ["AuthKey.p8"])
        XCTAssertFalse(try historyXML(of: again, title: "Apple").contains("<Entry>"), "an attachment that is already there is not an edit")
    }

    func testTheSameBytesAreStoredOnce() throws {
        var vault = try KDBX.load(data: try existingDatabase(), password: "secret")
        let first = imported("One", [VaultAttachment(name: "a.pem", data: pem)])
        let second = imported("Two", [VaultAttachment(name: "b.pem", data: pem), VaultAttachment(name: "same-as-old.txt", data: Data("old bytes".utf8))])
        vault.entries += [first, second]
        let loaded = try KDBX.load(data: try KDBX.save(vault: &vault, password: "secret"), password: "secret")
        XCTAssertEqual(loaded.preserve?.binaryPayloads, [Data("old bytes".utf8), pem])
        XCTAssertEqual(loaded.attachment(named: "a.pem", of: first.id), pem)
        XCTAssertEqual(loaded.attachment(named: "b.pem", of: second.id), pem)
        XCTAssertEqual(loaded.attachment(named: "same-as-old.txt", of: second.id), Data("old bytes".utf8))
    }

    /// KeePassXC keeps one attachment per name and lets the last one win without a word, so two files with one name
    /// would lose one.
    func testTwoAttachmentsWithOneNameBothSurvive() throws {
        for existing in [false, true] {
            var vault = existing
                ? try KDBX.load(data: try existingDatabase(), password: "secret")
                : Vault(name: "New", rootName: "New", entries: [], kdf: .fastTest)
            let entry = imported("Twins", [
                VaultAttachment(name: "key.pem", data: Data("one".utf8)),
                VaultAttachment(name: "key.pem", data: Data("two".utf8)),
                VaultAttachment(name: "key (2).pem", data: Data("three".utf8)),
                VaultAttachment(name: "", data: Data("no name".utf8))
            ])
            vault.entries.append(entry)
            let loaded = try KDBX.load(data: try KDBX.save(vault: &vault, password: "secret"), password: "secret")
            XCTAssertEqual(loaded.attachmentNames(of: entry.id), ["key.pem", "key (3).pem", "key (2).pem", "attachment"], "existing: \(existing)")
            XCTAssertEqual(loaded.attachment(named: "key.pem", of: entry.id), Data("one".utf8))
            XCTAssertEqual(loaded.attachment(named: "key (2).pem", of: entry.id), Data("three".utf8), "a name that was asked for is kept")
            XCTAssertEqual(loaded.attachment(named: "key (3).pem", of: entry.id), Data("two".utf8))
            XCTAssertEqual(loaded.attachment(named: "attachment", of: entry.id), Data("no name".utf8))
        }
    }

    func testANewVersionOfAnAttachmentKeepsTheOldOneInHistory() throws {
        var vault = try KDBX.load(data: try existingDatabase(), password: "secret")
        let old = try XCTUnwrap(vault.entries.first).id
        vault.entries[0].attachments = [VaultAttachment(name: "old.txt", data: Data("new bytes".utf8)), VaultAttachment(name: "more.pem", data: pem)]
        let loaded = try KDBX.load(data: try KDBX.save(vault: &vault, password: "secret"), password: "secret")
        XCTAssertEqual(loaded.attachmentNames(of: old), ["old.txt", "more.pem"])
        XCTAssertEqual(loaded.attachment(named: "old.txt", of: old), Data("new bytes".utf8))
        XCTAssertEqual(loaded.attachment(named: "more.pem", of: old), pem)
        // The version before the change still points at the bytes it had.
        let history = try historyXML(of: loaded, title: "Old")
        XCTAssertTrue(history.contains("<Binary><Key>old.txt</Key><Value Ref=\"0\"></Value></Binary>") || history.contains("<Value Ref=\"0\"/>"), history)
        XCTAssertFalse(history.contains("more.pem"))
        XCTAssertEqual(loaded.preserve?.binaryPayloads, [Data("old bytes".utf8), Data("new bytes".utf8), pem])
    }

    func testAnEntryInTheRecycleBinKeepsWhatItBrought() throws {
        var vault = try KDBX.load(data: try existingDatabase(), password: "secret")
        var gone = imported("Gone", [VaultAttachment(name: "gone.pem", data: pem)])
        gone.trashed = true
        vault.entries.append(gone)
        let loaded = try KDBX.load(data: try KDBX.save(vault: &vault, password: "secret"), password: "secret")
        XCTAssertEqual(loaded.preserve?.binaryPayloads, [Data("old bytes".utf8), pem])
        XCTAssertTrue(try XCTUnwrap(loaded.preserve).document.xmlString.contains("gone.pem"))
    }

    func testAFailedSaveLeavesTheModelAndTheDocument() throws {
        var vault = try KDBX.load(data: try existingDatabase(), password: "secret")
        vault.entries.append(imported("Apple", [VaultAttachment(name: "AuthKey.p8", data: pem)]))
        // A header the save cannot rewrite makes it throw after the attachment was placed in the copy.
        try XCTUnwrap(vault.preserve).kdfSaltRange = 0..<0
        let before = vault
        XCTAssertThrowsError(try KDBX.save(vault: &vault, password: "secret"))
        XCTAssertEqual(vault.preserve?.binaryPayloads, [Data("old bytes".utf8)])
        XCTAssertEqual(vault.entries.last?.attachments, before.entries.last?.attachments, "nothing was written, so nothing is forgotten")
    }

    // MARK: The file on disk

    func testTheReadBackCheckAcceptsAFileWithNewAttachments() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("attachments-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("box.kdbx")
        try existingDatabase().write(to: url)
        var vault = try KDBX.load(data: Data(contentsOf: url), password: "secret")
        let fresh = imported("Apple", [VaultAttachment(name: "AuthKey.p8", data: pem)])
        vault.entries.append(fresh)
        let data = try KDBX.save(vault: &vault, password: "secret")
        try VaultFile.replace(url, with: data, password: "secret", expecting: vault)
        let onDisk = try KDBX.load(data: Data(contentsOf: url), password: "secret")
        XCTAssertEqual(onDisk.attachment(named: "AuthKey.p8", of: fresh.id), pem)
        // The file from before the save is kept beside it.
        let snapshot = try KDBX.load(data: Data(contentsOf: VaultFile.snapshotURL(for: url)), password: "secret")
        XCTAssertEqual(snapshot.entries.map(\.title), ["Old"])
    }

    /// KeePassXC reads what was written, and what KeePassXC then saves still holds it.
    func testKeePassXCReadsTheAttachmentsAndKeepsThem() throws {
        let cli = "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: cli), "KeePassXC CLI is not installed")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("attachments-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("scratch.kdbx")

        // New database: the first save.
        let apple = imported("Apple", [VaultAttachment(name: "AuthKey.p8", data: pem)])
        var vault = Vault(name: "Scratch", rootName: "Passwords", entries: [apple], kdf: .fastTest)
        try KDBX.save(vault: &vault, password: "scratch").write(to: database, options: .atomic)
        XCTAssertEqual(try runCLI(cli, ["attachment-export", "-q", "--stdout", database.path, "Keys/Apple", "AuthKey.p8"]), pem)

        // KeePassXC edits and saves; then an import adds an item with two attachments to that file.
        let other = directory.appendingPathComponent("note.txt")
        try Data("from KeePassXC\n".utf8).write(to: other)
        try runCLI(cli, ["attachment-import", "-q", database.path, "Keys/Apple", "note.txt", other.path])
        vault = try KDBX.load(data: Data(contentsOf: database), password: "scratch")
        vault.entries.append(imported("Google", [VaultAttachment(name: "service-account.json", data: json), VaultAttachment(name: "copy.p8", data: pem)]))
        try KDBX.save(vault: &vault, password: "scratch").write(to: database, options: .atomic)
        XCTAssertEqual(try runCLI(cli, ["attachment-export", "-q", "--stdout", database.path, "Keys/Apple", "AuthKey.p8"]), pem)
        XCTAssertEqual(try runCLI(cli, ["attachment-export", "-q", "--stdout", database.path, "Keys/Apple", "note.txt"]), Data("from KeePassXC\n".utf8))
        XCTAssertEqual(try runCLI(cli, ["attachment-export", "-q", "--stdout", database.path, "Keys/Google", "service-account.json"]), json)
        XCTAssertEqual(try runCLI(cli, ["attachment-export", "-q", "--stdout", database.path, "Keys/Google", "copy.p8"]), pem)

        // KeePassXC saves once more (it rebuilds the binaries from the entries), and everything is still read here.
        try runCLI(cli, ["edit", "-q", "--notes", "touched", database.path, "Keys/Google"])
        let after = try KDBX.load(data: Data(contentsOf: database), password: "scratch")
        let google = try XCTUnwrap(after.entries.first { $0.title == "Google" })
        XCTAssertEqual(google.notes, "touched")
        XCTAssertEqual(after.attachment(named: "service-account.json", of: google.id), json)
        XCTAssertEqual(after.attachment(named: "copy.p8", of: google.id), pem)
        XCTAssertEqual(after.attachment(named: "AuthKey.p8", of: apple.id), pem)
        XCTAssertEqual(after.attachment(named: "note.txt", of: apple.id), Data("from KeePassXC\n".utf8))
    }

    // MARK: Helpers

    private func historyXML(of vault: Vault, title: String) throws -> String {
        let document = try XCTUnwrap(vault.preserve).document
        var found: String?
        walkElements(try XCTUnwrap(document.rootElement())) { element in
            guard found == nil, element.name == "Entry", element.parent?.name == "Group" else { return }
            let isIt = direct(element, "String").contains { direct($0, "Key").first?.stringValue == "Title" && direct($0, "Value").first?.stringValue == title }
            if isIt { found = direct(element, "History").first?.xmlString ?? "" }
        }
        return try XCTUnwrap(found, "no entry titled \(title)")
    }

    @discardableResult
    private func runCLI(_ cli: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = arguments
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        input.fileHandleForWriting.write(Data("scratch\n".utf8))
        try input.fileHandleForWriting.close()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            XCTFail("keepassxc-cli \(arguments.joined(separator: " ")) failed (\(process.terminationStatus)): \(String(decoding: stderr, as: UTF8.self))")
        }
        return stdout
    }
}
