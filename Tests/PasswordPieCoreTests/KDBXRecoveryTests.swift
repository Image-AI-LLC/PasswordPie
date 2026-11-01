import XCTest
@testable import PasswordPieCore

private let legacyParseOptions = KDBXXMLRepair.legacyXMLOptions

final class KDBXRecoveryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("kdbx-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: The writer no longer damages text

    func testCRLFAndAmpersandInOneKeePassXCNoteSurviveASave() throws {
        let note = "T&C #1&#13;\nsee x?a=1&amp;#top&#13;\nlast &lt;line&gt;".replacingOccurrences(of: "T&C", with: "T&amp;C")
        let data = try KDBX.testingDatabase(xml: database(notes: note, password: "hunter2"), password: "secret")
        var vault = try KDBX.load(data: data, password: "secret")
        let expected = "T&C #1\r\nsee x?a=1&#top\r\nlast <line>"
        XCTAssertEqual(vault.entries.first?.notes, expected)
        XCTAssertEqual(vault.entries.first?.password, "hunter2")
        let saved = try KDBX.save(vault: &vault, password: "secret")
        let reloaded = try KDBX.load(data: saved, password: "secret")
        XCTAssertEqual(reloaded.entries.first?.notes, expected)
        XCTAssertEqual(reloaded.entries.first?.password, "hunter2")
    }

    func testEveryAwkwardValueRoundTripsThroughBothWriters() throws {
        let values = ["a&b", "a&#b", "a&#65;b", "a&amp;b", "a<b>c", "a]]>b", "a\rb", "a\r\nb", "  spaced  ", "é中文😀", "&#13;&amp;", "x#y&z", "https://x/#/a?b=1&c=2", "\r\nleading", "trailing\r\n"]
        for value in values {
            var entry = VaultEntry()
            entry.title = "T"
            entry.setValue(value, for: "Notes")
            entry.setValue(value, for: "Secret", protected: true)
            var generated = Vault(name: "G", entries: [entry], kdf: .fastTest)
            let first = try KDBX.save(vault: &generated, password: "s")
            var loaded = try KDBX.load(data: first, password: "s")
            XCTAssertEqual(loaded.entries.first?.notes, value, "generated \(value.debugDescription)")
            XCTAssertEqual(loaded.entries.first?.value(for: "Secret"), value, "generated secret \(value.debugDescription)")

            loaded.entries[0].setValue(value + "2", for: "Notes")
            let second = try KDBX.save(vault: &loaded, password: "s")
            let again = try KDBX.load(data: second, password: "s")
            XCTAssertEqual(again.entries.first?.notes, value + "2", "preserved \(value.debugDescription)")
            XCTAssertEqual(again.entries.first?.value(for: "Secret"), value, "preserved secret \(value.debugDescription)")
        }
    }

    func testWhitespaceOnlyTextIsStoredEmptyAndPasswordsKeepIt() throws {
        let url = directory.appendingPathComponent("Passwords.kdbx")
        for value in ["\r", "   ", "\n", "\r\n", "\t"] {
            var entry = VaultEntry()
            entry.title = "T"
            entry.setValue(value, for: "Notes")
            entry.setValue(value, for: "Secret", protected: true)
            var vault = Vault(name: "G", entries: [entry], kdf: .fastTest)
            try VaultFile.replace(url, with: try KDBX.save(vault: &vault, password: "s"), password: "s", expecting: vault)
            XCTAssertEqual(vault.entries[0].notes, "")

            var opened = try KDBX.load(data: Data(contentsOf: url), password: "s")
            XCTAssertEqual(opened.entries[0].value(for: "Secret"), value)
            opened.entries[0].setValue(value, for: "Notes")
            opened.entries[0].title = "T2"
            try VaultFile.replace(url, with: try KDBX.save(vault: &opened, password: "s"), password: "s", expecting: opened)
            let again = try KDBX.load(data: Data(contentsOf: url), password: "s")
            XCTAssertEqual(again.entries[0].title, "T2")
            XCTAssertEqual(again.entries[0].value(for: "Secret"), value)
            try FileManager.default.removeItem(at: url)
        }
    }

    func testControlCharactersDoNotBlockASaveAndPasswordsKeepThem() throws {
        var entry = VaultEntry()
        entry.title = "Bad\u{01}Title"
        entry.notes = "a\u{0}b\u{0B}c\u{FFFE}d"
        entry.setValue("p\u{01}w", for: "Password", protected: true)
        var vault = Vault(name: "G", entries: [entry], kdf: .fastTest)
        let first = try KDBX.save(vault: &vault, password: "s")
        var loaded = try KDBX.load(data: first, password: "s")
        XCTAssertEqual(loaded.entries.first?.title, "BadTitle")
        XCTAssertEqual(loaded.entries.first?.notes, "abcd")
        XCTAssertEqual(loaded.entries.first?.password, "p\u{01}w")

        loaded.entries[0].notes = "x\u{01}y"
        loaded.entries[0].setValue("k\u{01}", for: "Custom\u{02}Key")
        let second = try KDBX.save(vault: &loaded, password: "s")
        XCTAssertEqual(loaded.entries[0].notes, "xy", "the model matches what was written")
        let again = try KDBX.load(data: second, password: "s")
        XCTAssertEqual(again.entries.first?.notes, "xy")
        XCTAssertEqual(again.entries.first?.value(for: "CustomKey"), "k")
    }

    func testGeneratedAndPreservedSavesPassTheFullReadBack() throws {
        let url = directory.appendingPathComponent("Passwords.kdbx")
        var entry = VaultEntry(groupPath: ["Work", "Sub"], tags: "a,b")
        entry.title = "One & two"
        entry.notes = "line\r\nnext &#13; &amp;"
        entry.password = "pw"
        var vault = Vault(name: "G", entries: [entry], kdf: .fastTest)
        let data = try KDBX.save(vault: &vault, password: "s")
        try VaultFile.replace(url, with: data, password: "s", expecting: vault)

        var opened = try VaultFormat.load(url: url, password: "s")
        opened.entries[0].notes = "edited\r\n&"
        opened.entries[0].groupPath = ["Work"]
        opened.entries.append(VaultEntry(fields: [VaultField(key: "Title", value: "New")]))
        let next = try KDBX.save(vault: &opened, password: "s")
        try VaultFile.replace(url, with: next, password: "s", expecting: opened)
        XCTAssertEqual(try KDBX.load(data: Data(contentsOf: url), password: "s").entries.first?.notes, "edited\r\n&")

        opened.entries.removeLast()
        let trashed = try KDBX.save(vault: &opened, password: "s")
        try VaultFile.replace(url, with: trashed, password: "s", expecting: opened)
    }

    // MARK: Read-back catches more than a parse failure

    func testReadBackRefusesAFileThatOpensWithDifferentContent() throws {
        let url = directory.appendingPathComponent("Passwords.kdbx")
        let original = Data("original".utf8)
        try original.write(to: url)
        var entry = VaultEntry()
        entry.title = "T"
        entry.notes = "real note"
        var vault = Vault(name: "G", entries: [entry], kdf: .fastTest)
        _ = try KDBX.save(vault: &vault, password: "s")

        var altered = vault
        altered.entries[0].notes = "silently changed"
        let wrong = try KDBX.save(vault: &altered, password: "s")
        XCTAssertThrowsError(try VaultFile.replace(url, with: wrong, password: "s", expecting: vault))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testReadBackRefusesAFileThatOnlyOpensThroughRepair() throws {
        let url = directory.appendingPathComponent("Passwords.kdbx")
        let original = Data("original".utf8)
        try original.write(to: url)
        let damaged = try damagedDatabase(notes: "A&amp;#B&#13;C", password: "pw")
        let vault = try KDBX.loadRecovering(data: damaged, password: "s")
        XCTAssertThrowsError(try VaultFile.replace(url, with: damaged, password: "s", expecting: vault))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    // MARK: Opening a file the old writer damaged

    func testTheReportedErrorIsReproducedAndRepaired() throws {
        let damaged = try damagedDatabase(notes: "A&amp;#B&#13;C", password: "hunter2")
        XCTAssertThrowsError(try KDBX.load(data: damaged, password: "s")) { error in
            XCTAssertTrue(String(describing: error).contains("CharRef: invalid decimal value"), "\(error)")
        }
        let vault = try VaultFormat.load(data: damaged, password: "s")
        XCTAssertEqual(vault.entries.first?.notes, "A&#B\rC")
        XCTAssertEqual(vault.entries.first?.password, "hunter2")
        XCTAssertEqual(vault.entries.first?.title, "Site")
        let recovery = try XCTUnwrap(vault.recovery)
        XCTAssertEqual(recovery.repairedFields, [KDBXRecovery.Location(entryTitle: "Site", fieldKey: "Notes", inHistory: false)])
        XCTAssertEqual(recovery.unreadableProtectedFields, [])
    }

    func testAWrongPasswordIsStillWrongOnADamagedFile() throws {
        let damaged = try damagedDatabase(notes: "A&amp;#B&#13;C", password: "hunter2")
        XCTAssertThrowsError(try VaultFormat.load(data: damaged, password: "nope")) { error in
            XCTAssertEqual(error as? KDBXError, .wrongPassword)
        }
    }

    func testCleanFilesAreNotMarkedRecovered() throws {
        let data = try KDBX.testingDatabase(xml: database(notes: "plain &amp; simple&#13;\nline", password: "pw"), password: "s")
        XCTAssertNil(try VaultFormat.load(data: data, password: "s").recovery)
    }

    func testAURLWithAHashBeforeAQueryIsTheReportedFailureAndIsRepaired() throws {
        let damaged = try damagedDatabase(notes: "https://x.test/#/login?a=1&amp;b=2", password: "hunter2")
        XCTAssertThrowsError(try KDBX.load(data: damaged, password: "s")) { error in
            XCTAssertTrue(String(describing: error).contains("CharRef: invalid decimal value"), "\(error)")
        }
        let vault = try VaultFormat.load(data: damaged, password: "s")
        XCTAssertEqual(vault.entries.first?.notes, "https://x.test/#/login?a=1&b=2")
        XCTAssertEqual(vault.recovery?.uncertainFields, [])
    }

    func testRepairUndoesEveryDamageTheOldWriterProduces() throws {
        // A sample of every sequence of these tokens, up to five long, plus long text past libxml2's chunk size.
        let tokens = ["a", "B", " ", "\n", "&amp;", "&lt;", "&gt;", "&#13;", "&#13;\n", "#", "x;", "/?="]
        var sequences: [[String]] = [[]]
        for _ in 0..<5 {
            sequences = sequences.flatMap { base in tokens.map { base + [$0] } }
        }
        let long = String(repeating: "y", count: 400)
        var sources = stride(from: 0, to: sequences.count, by: 5).map { sequences[$0].joined() }.filter { $0.contains("&") }
        sources += ["\(long)#b&amp;c", "#\(long)&amp;c", "a#b\(long)&amp;c\(long)&amp;d", "\(long)&amp;\(long)&#13;\(long)&amp;z"]
        var whitespaceOnly = 0
        var unproven: [String] = []
        var wrong: [String] = []
        var checked = 0
        for source in sources {
            let xml = Data("<Value>\(source)</Value>".utf8)
            let truth = try parseKDBXDocument(xml).rootElement()?.stringValue ?? ""
            let damaged = try XMLDocument(data: xml, options: legacyParseOptions).xmlData(options: .nodePreserveAll)
            let repaired = KDBXXMLRepair.repair(damaged)
            let value = try parseKDBXDocument(repaired.xml).rootElement()?.stringValue ?? ""
            checked += 1
            if value == truth { continue }
            // The old writer moved or dropped whitespace runs and left nothing to restore them from. Words must match.
            if onlyWhitespaceDiffers(value, truth) {
                whitespaceOnly += 1
                continue
            }
            if repaired.uncertainTexts.contains(value) {
                unproven.append("\(source.debugDescription) wrote \(String(decoding: damaged, as: UTF8.self).debugDescription) -> \(value.debugDescription)")
            } else {
                wrong.append("\(source.debugDescription) wrote \(String(decoding: damaged, as: UTF8.self).debugDescription) -> \(value.debugDescription), wanted \(truth.debugDescription)")
            }
        }
        XCTAssertGreaterThan(checked, 10_000)
        print("REPAIRFUZZ checked=\(checked) whitespaceOnly=\(whitespaceOnly) unproven=\(unproven.count) wrong=\(wrong.count)")
        XCTAssertEqual(wrong.count, 0, wrong.prefix(15).joined(separator: "\n"))
        XCTAssertLessThan(Double(unproven.count) / Double(checked), 0.01, unproven.prefix(15).joined(separator: "\n"))
    }

    func testRepairLeavesHistoryAndOtherEntriesIntact() throws {
        let xml = wrap("""
        <Entry><UUID>\(base64UUID(UUID()))</UUID>
        <String><Key>Title</Key><Value>Kept &amp; fine</Value></String>
        <String><Key>Password</Key><Value Protected="True">one</Value></String>
        <String><Key>Notes</Key><Value>A&amp;B&#13;\nC</Value></String>
        <History><Entry><UUID>\(base64UUID(UUID()))</UUID>
        <String><Key>Title</Key><Value>Old</Value></String>
        <String><Key>Password</Key><Value Protected="True">two</Value></String>
        <String><Key>Notes</Key><Value>X&#13;\nY&amp;Z</Value></String>
        </Entry></History></Entry>
        """)
        let damaged = try damagedDatabase(xml: xml)
        let vault = try VaultFormat.load(data: damaged, password: "s")
        let entry = try XCTUnwrap(vault.entries.first)
        XCTAssertEqual(entry.title, "Kept & fine")
        XCTAssertEqual(entry.password, "one")
        XCTAssertEqual(entry.notes, "A&B\r\nC")
        let recovery = try XCTUnwrap(vault.recovery)
        XCTAssertTrue(recovery.repairedFields.contains(.init(entryTitle: "Old", fieldKey: "Notes", inHistory: true)))
        let document = try XCTUnwrap(vault.preserve?.document)
        let history = try document.nodes(forXPath: "//History/Entry/String[Key='Notes']/Value").first?.stringValue
        XCTAssertEqual(history, "X\r\nY&Z")
        let oldPassword = try document.nodes(forXPath: "//History/Entry/String[Key='Password']/Value").first?.stringValue
        XCTAssertEqual(oldPassword, "two")
    }

    // MARK: Healing the file on disk

    func testOpeningADamagedFileKeepsTheOriginalAndWritesAVerifiedFile() throws {
        let url = directory.appendingPathComponent("Passwords.kdbx")
        let damaged = try damagedDatabase(notes: "A&amp;#B&#13;C", password: "hunter2")
        try damaged.write(to: url)

        let vault = try VaultFile.openRecovering(url: url, password: "s")

        XCTAssertEqual(vault.entries.first?.notes, "A&#B\rC")
        XCTAssertNil(vault.recovery, "the file on disk is clean now")
        let notice = try XCTUnwrap(vault.recoveryNotice)
        XCTAssertTrue(notice.contains(".damaged-"))
        XCTAssertTrue(notice.contains("Site / Notes"))
        XCTAssertFalse(notice.contains("hunter2"))
        XCTAssertFalse(notice.contains("A&#B"), "the notice names fields, never their values")
        let healed = try KDBX.load(data: Data(contentsOf: url), password: "s")
        XCTAssertEqual(healed.entries.first?.notes, "A&#B\rC")
        XCTAssertEqual(healed.entries.first?.password, "hunter2")

        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains(".damaged-") }
        XCTAssertEqual(backups.count, 1)
        let backup = directory.appendingPathComponent(backups[0])
        XCTAssertEqual(try Data(contentsOf: backup), damaged)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int, 0o600)

        // A second open has nothing to do.
        let second = try VaultFile.openRecovering(url: url, password: "s")
        XCTAssertNil(second.recoveryNotice)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains(".damaged-") }.count, 1)
    }

    func testAHealLeavesAnOlderSnapshotAlone() throws {
        let url = directory.appendingPathComponent("Passwords.kdbx")
        try damagedDatabase(notes: "A&amp;#B&#13;C", password: "pw").write(to: url)
        let older = Data("the last copy from before the damage".utf8)
        try older.write(to: VaultFile.snapshotURL(for: url))
        _ = try VaultFile.openRecovering(url: url, password: "s")
        XCTAssertEqual(try Data(contentsOf: VaultFile.snapshotURL(for: url)), older)
    }

    func testAHealDoesNotOverwriteANewerFileThatArrivedMeanwhile() throws {
        let url = directory.appendingPathComponent("Passwords.kdbx")
        let damaged = try damagedDatabase(notes: "A&amp;#B&#13;C", password: "pw")
        try damaged.write(to: url)
        let newer = Data("synced from another computer".utf8)

        let vault = try VaultFile.openRecovering(url: url, password: "s", beforeReplace: {
            try newer.write(to: url, options: .atomic)
        })

        XCTAssertEqual(try Data(contentsOf: url), newer)
        XCTAssertTrue(try XCTUnwrap(vault.recoveryNotice).contains("not changed"))
        XCTAssertEqual(vault.entries.first?.notes, "A&#B\rC")
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains(".damaged-") }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(backups[0])), damaged)
    }

    func testACopyWithAnotherFileNameIsRepairedInMemoryOnly() throws {
        for name in ["old.bak", "Passwords.kdbx.snapshot", "Passwords.kdbx.damaged-20261102-000000"] {
            let url = directory.appendingPathComponent(name)
            let damaged = try damagedDatabase(notes: "A&amp;#B&#13;C", password: "pw")
            try damaged.write(to: url)
            let vault = try VaultFile.openRecovering(url: url, password: "s")
            XCTAssertEqual(vault.entries.first?.notes, "A&#B\rC")
            XCTAssertTrue(try XCTUnwrap(vault.recoveryNotice).contains("not changed"))
            XCTAssertEqual(try Data(contentsOf: url), damaged)
            try FileManager.default.removeItem(at: url)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testAProtectedTitleStaysOutOfTheNotice() throws {
        let xml = wrap("""
        <Entry><UUID>\(base64UUID(UUID()))</UUID>
        <String><Key>Title</Key><Value Protected="True">SECRETTITLE</Value></String>
        <String><Key>Notes</Key><Value>A&amp;#B&#13;C</Value></String>
        </Entry>
        """)
        let vault = try VaultFormat.load(data: damagedDatabase(xml: xml), password: "s")
        let summary = try XCTUnwrap(vault.recovery).summary
        XCTAssertFalse(summary.contains("SECRETTITLE"))
        XCTAssertTrue(summary.contains("(protected title) / Notes"))
    }

    func testRepairsOutsideEntryFieldsAreCounted() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <KeePassFile><Root><Group><UUID>\(base64UUID(UUID()))</UUID><Name>Root</Name><Notes>G#1&amp;x</Notes></Group></Root></KeePassFile>
        """
        let vault = try VaultFormat.load(data: damagedDatabase(xml: xml), password: "s")
        XCTAssertEqual(vault.recovery?.otherRepairedTexts, 1)
    }

    func testAMarkupNoteTheOldWriterTurnedIntoElementsIsDamageNotData() throws {
        // A note quoting XML, written by the old code as real elements. It parses, and a nested protected value
        // would shift the stream for the next password.
        let streamKey = Data((0..<64).map { UInt8($0) })
        let quoted = #"see <Value Protected="True">QUJD</Value> now"#
        let xml = wrap("""
        <Entry><UUID>\(base64UUID(UUID()))</UUID>
        <String><Key>Title</Key><Value>First</Value></String>
        <String><Key>Notes</Key><Value>\(quoted)</Value></String>
        </Entry>
        <Entry><UUID>\(base64UUID(UUID()))</UUID>
        <String><Key>Title</Key><Value>Second</Value></String>
        <String><Key>Password</Key><Value Protected="True">SECOND</Value></String>
        </Entry>
        """)
        let document = try XMLDocument(xmlString: xml, options: legacyParseOptions)
        var stream = ChaCha20(key: sha512SplitKey(protectedStreamKey: streamKey).key, nonce: sha512SplitKey(protectedStreamKey: streamKey).nonce, counter: 0)
        let password = try XCTUnwrap(document.nodes(forXPath: "//String[Key='Password']/Value").first as? XMLElement)
        password.stringValue = stream.xor(Data("SECOND".utf8)).base64EncodedString()
        let data = try KDBX.testingDatabase(rawXML: document.xmlData(options: .nodePreserveAll), streamKey: streamKey, password: "s")

        XCTAssertThrowsError(try KDBX.load(data: data, password: "s"), "a strict load and a save's read-back refuse it")
        let vault = try VaultFormat.load(data: data, password: "s")
        XCTAssertEqual(vault.entries.first?.notes, quoted)
        XCTAssertEqual(vault.entries.last?.password, "SECOND")
    }

    func testKeysThatCleaningEmptiesOrCollidesKeepTheirValues() throws {
        var entry = VaultEntry()
        entry.title = "T"
        entry.fields.append(VaultField(key: "\u{01}", value: "SECRET", protected: true))
        entry.fields.append(VaultField(key: "Ref", value: "one"))
        entry.fields.append(VaultField(key: "Ref\u{01}", value: "two"))
        var vault = Vault(name: "G", entries: [entry], kdf: .fastTest)
        let data = try KDBX.save(vault: &vault, password: "s")
        let loaded = try KDBX.load(data: data, password: "s")
        XCTAssertEqual(loaded.entries[0].value(for: "Field"), "SECRET")
        XCTAssertEqual(loaded.entries[0].value(for: "Ref"), "one")
        XCTAssertEqual(loaded.entries[0].value(for: "Ref 2"), "two")
        let url = directory.appendingPathComponent("Passwords.kdbx")
        try VaultFile.replace(url, with: data, password: "s", expecting: vault)
    }

    func testACRLFNoteWithABlankLineComesBackExactly() throws {
        let vault = try VaultFormat.load(
            data: damagedDatabase(notes: "line one&#13;\nline #2 &amp; more&#13;\n&#13;\nend", password: "pw"),
            password: "s"
        )
        XCTAssertEqual(vault.entries.first?.notes, "line one\r\nline #2 & more\r\n\r\nend")
    }

    func testKeePassXCOpensAHealedFile() throws {
        let cli = "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: cli), "KeePassXC CLI is not installed")
        let url = directory.appendingPathComponent("Passwords.kdbx")
        try damagedDatabase(notes: "https://x.test/#/login?a=1&amp;b=2&#13;\nT&amp;C", password: "hunter2").write(to: url)
        _ = try VaultFile.openRecovering(url: url, password: "s")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["show", "-q", "-s", url.path, "Site"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(Data("s\n".utf8))
        try input.fileHandleForWriting.close()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertTrue(text.contains("hunter2"), text)
        XCTAssertTrue(text.contains("https://x.test/#/login?a=1&b=2"), text)
        XCTAssertTrue(text.contains("T&C"), text)
    }

    func testAHealThatCannotKeepABackupLeavesTheFileAlone() throws {
        let url = directory.appendingPathComponent("Passwords.kdbx")
        let damaged = try damagedDatabase(notes: "A&amp;#B&#13;C", password: "pw")
        try damaged.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        let vault = try VaultFile.openRecovering(url: url, password: "s")

        XCTAssertEqual(vault.entries.first?.notes, "A&#B\rC", "the accounts are still usable")
        XCTAssertNotNil(vault.recovery)
        XCTAssertTrue(try XCTUnwrap(vault.recoveryNotice).contains("not changed"))
        XCTAssertEqual(try Data(contentsOf: url), damaged)
    }

    private func onlyWhitespaceDiffers(_ a: String, _ b: String) -> Bool {
        func words(_ text: String) -> [Unicode.Scalar] {
            text.unicodeScalars.filter { ![0x0A, 0x0D, 0x20, 0x09].contains($0.value) }
        }
        return words(a) == words(b)
    }

    // MARK: Fixtures

    /// A database whose XML went through the old parse and write path, byte for byte.
    private func damagedDatabase(notes: String, password: String) throws -> Data {
        try damagedDatabase(xml: database(notes: notes, password: password))
    }

    private func damagedDatabase(xml: String) throws -> Data {
        let document = try XMLDocument(xmlString: xml, options: legacyParseOptions)
        let streamKey = Data((0..<64).map { UInt8($0) })
        try cryptProtectedValues(in: document, streamKey: streamKey, encrypting: true)
        return try KDBX.testingDatabase(rawXML: document.xmlData(options: .nodePreserveAll), streamKey: streamKey, password: "s")
    }

    private func database(notes: String, password: String) -> String {
        wrap("""
        <Entry><UUID>\(base64UUID(UUID()))</UUID>
        <String><Key>Title</Key><Value>Site</Value></String>
        <String><Key>Password</Key><Value Protected="True">\(password)</Value></String>
        <String><Key>Notes</Key><Value>\(notes)</Value></String>
        </Entry>
        """)
    }

    private func wrap(_ entries: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <KeePassFile><Meta><DatabaseName>D</DatabaseName></Meta><Root><Group><UUID>\(base64UUID(UUID()))</UUID><Name>Root</Name>
        \(entries)
        </Group></Root></KeePassFile>
        """
    }
}
