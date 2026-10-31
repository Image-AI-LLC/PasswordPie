import XCTest
@testable import PasswordPieCore

final class KDBXLosslessTests: XCTestCase {
    func testKeePassTimeUsesTheYearOneEpoch() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2020-01-02T03:04:05Z"))
        XCTAssertEqual(formatTime(date, like: "pVSf1Q4AAAA="), "pVSf1Q4AAAA=")
        XCTAssertEqual(formatTime(date, like: "2020-01-02T03:04:05Z"), "2020-01-02T03:04:05Z")
    }

    func testNoEditRoundTripKeepsTheXMLTree() throws {
        let attachment = Data("hello attachment".utf8)
        let extra = Data("inner-extra".utf8)
        let publicHeader = Data("public-custom".utf8)
        let original = try parseKDBXDocument(xml: richXML())
        let data = try KDBX.testingDatabase(
            xml: richXML(),
            binaries: [attachment],
            extraPieces: [.other(type: 6, payload: extra)],
            password: "secret",
            version: 0x00040001,
            extraHeader: [HeaderField(type: 12, payload: publicHeader)]
        )
        let loaded = try KDBX.load(data: data, password: "secret")
        let preserve = try XCTUnwrap(loaded.preserve)
        XCTAssertEqual(fingerprint(preserve.document.rootElement()!), fingerprint(original.rootElement()!))
        XCTAssertEqual(preserve.pieces, [.binary(flags: 0x01, data: attachment), .other(type: 6, payload: extra)])
        XCTAssertEqual(preserve.version, 0x00040001)
        XCTAssertEqual(preserve.headerFields.first { $0.type == 12 }?.payload, publicHeader)
        XCTAssertEqual(preserve.compressed, true)
        XCTAssertEqual(loaded.name, "Fixture")
        XCTAssertEqual(loaded.rootName, "Passwords")
        XCTAssertEqual(loaded.entries.map(\.title).sorted(), ["Cafe", "Gone", "Untouched"])
        XCTAssertEqual(loaded.entries.first { $0.title == "Cafe" }?.groupPath, ["Work", "Domains"])
        XCTAssertEqual(loaded.entries.first { $0.title == "Cafe" }?.password, "live-secret")
        XCTAssertEqual(loaded.entries.first { $0.title == "Untouched" }?.groupPath, [])
        XCTAssertEqual(loaded.entries.first { $0.title == "Gone" }?.trashed, true)
        XCTAssertFalse(loaded.entries.first { $0.title == "Untouched" }?.trashed ?? true)
        if case .aes(let rounds) = loaded.kdf.kind {
            XCTAssertEqual(rounds, 100)
        } else {
            XCTFail("expected AES-KDF")
        }

        var again = loaded
        let seedBefore = preserve.headerFields.first { $0.type == 4 }?.payload
        let resaved = try KDBX.save(vault: &again, password: "secret")
        XCTAssertNotEqual(resaved, data)
        let second = try KDBX.load(data: resaved, password: "secret")
        XCTAssertEqual(fingerprint(second.preserve!.document.rootElement()!), fingerprint(original.rootElement()!))
        XCTAssertNotEqual(second.preserve?.headerFields.first { $0.type == 4 }?.payload, seedBefore)
        XCTAssertEqual(second.preserve?.headerFields.first { $0.type == 2 }?.payload, preserve.headerFields.first { $0.type == 2 }?.payload)
        XCTAssertEqual(second.preserve?.headerFields.first { $0.type == 3 }?.payload, preserve.headerFields.first { $0.type == 3 }?.payload)
    }

    func testUncompressedHeaderRoundTrips() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <KeePassFile><Meta><DatabaseName>Plain</DatabaseName></Meta><Root><Group><UUID>\(id("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))</UUID><Name>Root</Name><Entry><UUID>\(id("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))</UUID><String><Key>Title</Key><Value>One</Value></String><String><Key>Password</Key><Value Protected="True">pw</Value></String></Entry></Group></Root></KeePassFile>
        """
        let data = try KDBX.testingDatabase(xml: xml, password: "secret", compressed: false)
        let loaded = try KDBX.load(data: data, password: "secret")
        XCTAssertEqual(loaded.preserve?.compressed, false)
        XCTAssertEqual(loaded.entries.first?.password, "pw")
    }

    func testEditingOneEntryWritesOneHistoryItem() throws {
        let original = try KDBX.load(data: try KDBX.testingDatabase(xml: richXML(), binaries: [Data("hello attachment".utf8)], password: "secret"), password: "secret")
        let before = fingerprints(original)
        var vault = original
        let index = try XCTUnwrap(vault.entries.firstIndex { $0.title == "Cafe" })
        vault.entries[index].password = "new-secret"
        let once = try KDBX.save(vault: &vault, password: "secret")
        let edited = try entry(vault, title: "Cafe")
        XCTAssertEqual(history(edited).count, 2)
        XCTAssertEqual(field(history(edited).last!, "Password"), "live-secret")
        XCTAssertEqual(field(edited, "Password"), "new-secret")
        let twice = try KDBX.save(vault: &vault, password: "secret")
        XCTAssertEqual(history(try entry(vault, title: "Cafe")).count, 2)
        let loaded = try KDBX.load(data: twice, password: "secret")
        XCTAssertNotEqual(once, twice)
        let cafe = try entry(loaded, title: "Cafe")
        XCTAssertEqual(field(cafe, "Password"), "new-secret")
        XCTAssertEqual(time(cafe, "CreationTime"), "pVSf1Q4AAAA=")
        XCTAssertNotEqual(time(cafe, "LastModificationTime"), "pVSf1Q4AAAA=")
        XCTAssertEqual(time(cafe, "LocationChanged"), "pVSf1Q4AAAA=")
        XCTAssertEqual(time(cafe, "LastAccessTime"), "pVSf1Q4AAAA=")
        XCTAssertEqual(history(cafe).count, 2)
        XCTAssertEqual(field(history(cafe).last!, "Password"), "live-secret")
        let after = fingerprints(loaded)
        XCTAssertEqual(after["Untouched"], before["Untouched"])
        XCTAssertEqual(after["Gone"], before["Gone"])
        XCTAssertEqual(loaded.entries.first { $0.title == "Untouched" }?.password, "other-secret")
    }

    func testRemovingAFieldDeletesItAndAFailedSaveLeavesTheDocument() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <KeePassFile>
        <Meta><DatabaseName>Box</DatabaseName><HistoryMaxItems>10</HistoryMaxItems></Meta>
        <Root><Group><Name>Passwords</Name>
        <Entry><UUID>\(id("50505050-5050-5050-5050-505050505050"))</UUID>
        <Times><LastModificationTime>pVSf1Q4AAAA=</LastModificationTime></Times>
        <String><Key>Title</Key><Value>One</Value></String>
        <String><Key>UserName</Key><Value>ada</Value></String>
        <String><Key>Password</Key><Value Protected="True">pw</Value></String>
        <Binary><Key>note.txt</Key><Value Ref="0"/></Binary>
        </Entry>
        </Group></Root></KeePassFile>
        """
        var vault = try KDBX.load(data: try KDBX.testingDatabase(xml: xml, password: "secret"), password: "secret")
        let before = fingerprints(vault)
        let salt = try XCTUnwrap(vault.preserve).kdfSaltRange
        vault.preserve?.kdfSaltRange = 0..<0
        let index = try XCTUnwrap(vault.entries.firstIndex { $0.title == "One" })
        vault.entries[index].password = "changed"
        vault.entries[index].fields.removeAll { $0.key == "UserName" }
        vault.entries[index].fields.append(VaultField(key: "Extra", value: "added"))
        XCTAssertThrowsError(try KDBX.save(vault: &vault, password: "secret"))
        XCTAssertEqual(fingerprints(vault), before)
        vault.preserve?.kdfSaltRange = salt
        let loaded = try KDBX.load(data: try KDBX.save(vault: &vault, password: "secret"), password: "secret")
        let live = try entry(loaded, title: "One")
        XCTAssertNil(field(live, "UserName"))
        XCTAssertEqual(field(live, "Password"), "changed")
        XCTAssertEqual(field(live, "Extra"), "added")
        XCTAssertEqual(history(live).count, 1)
        XCTAssertEqual(field(history(live)[0], "UserName"), "ada")
        XCTAssertEqual(field(history(live)[0], "Password"), "pw")
        let names = (live.children ?? []).compactMap { $0 as? XMLElement }.map { $0.name ?? "" }
        let lastString = try XCTUnwrap(names.lastIndex(of: "String"))
        let binary = try XCTUnwrap(names.firstIndex(of: "Binary"))
        XCTAssertLessThan(lastString, binary)
    }

    func testHistoryRespectsItemAndSizeLimits() throws {
        var one = try loadSmall(maxItems: 1, maxBytes: -1, password: "A")
        try setPassword("B", on: &one)
        try setPassword("C", on: &one)
        let kept = try KDBX.load(data: try KDBX.save(vault: &one, password: "secret"), password: "secret")
        let entryC = try entry(kept, title: "Item")
        XCTAssertEqual(field(entryC, "Password"), "C")
        XCTAssertEqual(history(entryC).count, 1)
        XCTAssertEqual(field(history(entryC)[0], "Password"), "B")

        var none = try loadSmall(maxItems: 0, maxBytes: -1, password: "A")
        try setPassword("B", on: &none)
        let cleared = try KDBX.load(data: try KDBX.save(vault: &none, password: "secret"), password: "secret")
        XCTAssertEqual(history(try entry(cleared, title: "Item")).count, 0)
        XCTAssertEqual(cleared.entries.first?.password, "B")

        var tiny = try loadSmall(maxItems: -1, maxBytes: 1, password: "A")
        try setPassword("B", on: &tiny)
        let sized = try KDBX.load(data: try KDBX.save(vault: &tiny, password: "secret"), password: "secret")
        XCTAssertEqual(history(try entry(sized, title: "Item")).count, 0)
    }

    func testDeleteMovesToTheRecycleBinAndNewEntriesKeepTheirGroup() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <KeePassFile>
        <Meta><DatabaseName>Box</DatabaseName><RecycleBinUUID>\(id("00000000-0000-0000-0000-000000000000"))</RecycleBinUUID><HistoryMaxItems>10</HistoryMaxItems></Meta>
        <Root><Group><UUID>\(id("10101010-1010-1010-1010-101010101010"))</UUID><Name>Passwords</Name>
        <Notes>stay</Notes>
        <Group><UUID>\(id("20202020-2020-2020-2020-202020202020"))</UUID><Name>Empty</Name></Group>
        <Entry><UUID>\(id("30303030-3030-3030-3030-303030303030"))</UUID><Tags></Tags>
        <Times><CreationTime>pVSf1Q4AAAA=</CreationTime><LastModificationTime>pVSf1Q4AAAA=</LastModificationTime><LastAccessTime>pVSf1Q4AAAA=</LastAccessTime><ExpiryTime>pVSf1Q4AAAA=</ExpiryTime><Expires>False</Expires><UsageCount>1</UsageCount><LocationChanged>pVSf1Q4AAAA=</LocationChanged></Times>
        <String><Key>Title</Key><Value>Keep</Value></String><String><Key>Password</Key><Value Protected="True">keep-pw</Value></String></Entry>
        <Entry><UUID>\(id("40404040-4040-4040-4040-404040404040"))</UUID>
        <Times><CreationTime>pVSf1Q4AAAA=</CreationTime><LastModificationTime>pVSf1Q4AAAA=</LastModificationTime><LastAccessTime>pVSf1Q4AAAA=</LastAccessTime><ExpiryTime>pVSf1Q4AAAA=</ExpiryTime><Expires>False</Expires><UsageCount>1</UsageCount><LocationChanged>pVSf1Q4AAAA=</LocationChanged></Times>
        <String><Key>Title</Key><Value>Drop</Value></String><String><Key>Password</Key><Value Protected="True">drop-pw</Value></String></Entry>
        </Group></Root></KeePassFile>
        """
        var vault = try KDBX.load(data: try KDBX.testingDatabase(xml: xml, password: "secret"), password: "secret")
        let before = fingerprints(vault)
        let drop = try XCTUnwrap(vault.entries.firstIndex { $0.title == "Drop" })
        vault.entries[drop].trashed = true
        var fresh = VaultEntry(groupPath: ["Work", "Freshly"])
        fresh.title = "Fresh"
        fresh.password = "fresh-pw"
        vault.entries.append(fresh)
        let loaded = try KDBX.load(data: try KDBX.save(vault: &vault, password: "secret"), password: "secret")
        let dropped = try entry(loaded, title: "Drop")
        XCTAssertEqual(loaded.entries.first { $0.title == "Drop" }?.trashed, true)
        XCTAssertEqual(loaded.entries.first { $0.title == "Drop" }?.password, "drop-pw")
        XCTAssertEqual(history(dropped).count, 1)
        XCTAssertNotEqual(time(dropped, "LocationChanged"), "pVSf1Q4AAAA=")
        XCTAssertEqual(time(dropped, "CreationTime"), "pVSf1Q4AAAA=")
        let bin = try XCTUnwrap(group(named: "Recycle Bin", in: loaded.preserve!.document))
        XCTAssertTrue(direct(bin, "Entry").contains { field($0, "Title") == "Drop" })
        let recycle = try XCTUnwrap(loaded.preserve?.document.rootElement().flatMap { direct($0, "Meta").first }.flatMap { direct($0, "RecycleBinUUID").first }?.stringValue)
        XCTAssertNotEqual(recycle, id("00000000-0000-0000-0000-000000000000"))
        XCTAssertEqual(loaded.entries.first { $0.title == "Fresh" }?.groupPath, ["Work", "Freshly"])
        XCTAssertEqual(loaded.entries.first { $0.title == "Fresh" }?.password, "fresh-pw")
        XCTAssertNotNil(group(named: "Empty", in: loaded.preserve!.document))
        XCTAssertNotNil(group(named: "Work", in: loaded.preserve!.document))
        XCTAssertEqual(fingerprints(loaded)["Keep"], before["Keep"])
        let tree = fingerprint(loaded.preserve!.document.rootElement()!)
        XCTAssertTrue(tree.contains("stay"))
        XCTAssertTrue(tree.contains("Empty"))
    }

    func testNewDatabaseSecondSaveKeepsUntouchedEntries() throws {
        var first = VaultEntry()
        first.title = "One"
        first.password = "one-pw"
        first.groupPath = ["Work"]
        var second = VaultEntry()
        second.title = "Two"
        second.password = "two-pw"
        var created = Vault(name: "Created", entries: [first, second], kdf: .fastTest)
        var vault = try KDBX.load(data: try KDBX.save(vault: &created, password: "secret"), password: "secret")
        let before = fingerprints(vault)
        let one = try XCTUnwrap(vault.entries.firstIndex { $0.title == "One" })
        vault.entries[one].password = "one-new"
        let loaded = try KDBX.load(data: try KDBX.save(vault: &vault, password: "secret"), password: "secret")
        XCTAssertEqual(loaded.entries.first { $0.title == "One" }?.password, "one-new")
        XCTAssertEqual(loaded.entries.first { $0.title == "Two" }?.password, "two-pw")
        XCTAssertEqual(loaded.entries.first { $0.title == "One" }?.groupPath, ["Work"])
        XCTAssertEqual(loaded.entries.first { $0.title == "Two" }?.groupPath, [])
        XCTAssertEqual(history(try entry(loaded, title: "One")).count, 1)
        XCTAssertEqual(history(try entry(loaded, title: "Two")).count, 0)
        XCTAssertEqual(fingerprints(loaded)["Two"], before["Two"])
        XCTAssertEqual(loaded.entries.first { $0.title == "One" }?.favorite, false)
    }

    func testKeePassXCCliCrossCheck() throws {
        let cli = "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: cli), "KeePassXC CLI is not installed")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("passwordpie-kdbx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                XCTFail("Could not remove \(directory.path): \(error)")
            }
        }
        let database = directory.appendingPathComponent("scratch.kdbx")
        let attachment = Data("secret bytes\n".utf8)
        let attachmentURL = directory.appendingPathComponent("secret.txt")
        try attachment.write(to: attachmentURL)

        // KeePassXC 2.8 `db-create` still writes KDBX 3.1. Seed a KDBX 4 file (fast AES-KDF) and let the CLI edit that.
        var created = Vault(name: "Scratch", rootName: "Passwords", entries: [], kdf: .fastTest)
        try KDBX.save(vault: &created, password: "scratch").write(to: database, options: .atomic)
        try runCLI(["mkdir", "-q", database.path, "Work"], stdin: ["scratch"])
        try runCLI(["mkdir", "-q", database.path, "Work/Domains"], stdin: ["scratch"])
        try runCLI(["mkdir", "-q", database.path, "Empty"], stdin: ["scratch"])
        try runCLI(["add", "-q", "-u", "ada", "--url", "https://example.test", "--notes", "line one", "-p", database.path, "Work/Domains/Cafe"], stdin: ["scratch", "entry-secret"])
        try runCLI(["add", "-q", "-u", "bob", "-p", database.path, "Other"], stdin: ["scratch", "other-secret"])
        try runCLI(["attachment-import", "-q", database.path, "Work/Domains/Cafe", "secret.txt", attachmentURL.path], stdin: ["scratch"])
        try runCLI(["edit", "-q", "-p", database.path, "Work/Domains/Cafe"], stdin: ["scratch", "second-secret"])

        var vault = try KDBX.load(data: Data(contentsOf: database), password: "scratch")
        let untouched = try KDBX.save(vault: &vault, password: "scratch")
        try untouched.write(to: database, options: .atomic)
        let listed = try runCLI(["ls", "-q", "-R", "-f", database.path], stdin: ["scratch"])
        let shown = try runCLI(["show", "-q", "-s", database.path, "Work/Domains/Cafe"], stdin: ["scratch"])
        let otherShown = try runCLI(["show", "-q", "-s", database.path, "Other"], stdin: ["scratch"])
        let exported = try runCLI(["attachment-export", "-q", "--stdout", database.path, "Work/Domains/Cafe", "secret.txt"], stdin: ["scratch"])
        let historyXML = try runCLI(["export", "-q", "-f", "xml", database.path], stdin: ["scratch"])
        print("KEEPASSXC-CROSSCHECK ls-after-noop:\n\(listed)")
        print("KEEPASSXC-CROSSCHECK show-after-noop:\n\(shown)")
        XCTAssertTrue(listed.contains("Work/Domains/Cafe"))
        XCTAssertTrue(listed.contains("Empty/"))
        XCTAssertTrue(listed.contains("Empty/[empty]"))
        XCTAssertTrue(listed.contains("Other"))
        XCTAssertFalse(listed.contains("PasswordPie"))
        XCTAssertTrue(shown.contains("Password: second-secret"))
        XCTAssertTrue(shown.contains("UserName: ada"))
        XCTAssertTrue(shown.contains("URL: https://example.test"))
        XCTAssertTrue(shown.contains("Notes: line one"))
        XCTAssertTrue(otherShown.contains("Password: other-secret"))
        XCTAssertEqual(Data(exported.utf8), attachment)
        XCTAssertTrue(historyXML.contains("entry-secret"))
        XCTAssertTrue(historyXML.contains("second-secret"))

        let cafe = try XCTUnwrap(vault.entries.firstIndex { $0.title == "Cafe" })
        vault.entries[cafe].password = "mini-secret"
        try KDBX.save(vault: &vault, password: "scratch").write(to: database, options: .atomic)
        let editedShow = try runCLI(["show", "-q", "-s", database.path, "Work/Domains/Cafe"], stdin: ["scratch"])
        let editedOther = try runCLI(["show", "-q", "-s", database.path, "Other"], stdin: ["scratch"])
        let editedAttachment = try runCLI(["attachment-export", "-q", "--stdout", database.path, "Work/Domains/Cafe", "secret.txt"], stdin: ["scratch"])
        let editedHistory = try runCLI(["export", "-q", "-f", "xml", database.path], stdin: ["scratch"])
        print("KEEPASSXC-CROSSCHECK show-after-edit:\n\(editedShow)")
        XCTAssertTrue(editedShow.contains("Password: mini-secret"))
        XCTAssertTrue(editedOther.contains("Password: other-secret"))
        XCTAssertEqual(Data(editedAttachment.utf8), attachment)
        XCTAssertTrue(editedHistory.contains("entry-secret"))
        XCTAssertTrue(editedHistory.contains("second-secret"))
        XCTAssertTrue(editedHistory.contains("mini-secret"))

        var fresh = VaultEntry(groupPath: ["Work", "Freshly"])
        fresh.title = "Fresh"
        fresh.password = "fresh-secret"
        vault.entries.append(fresh)
        let other = try XCTUnwrap(vault.entries.firstIndex { $0.title == "Other" })
        vault.entries[other].trashed = true
        try KDBX.save(vault: &vault, password: "scratch").write(to: database, options: .atomic)
        let after = try runCLI(["ls", "-q", "-R", "-f", database.path], stdin: ["scratch"])
        let freshShow = try runCLI(["show", "-q", "-s", database.path, "Work/Freshly/Fresh"], stdin: ["scratch"])
        let keptAttachment = try runCLI(["attachment-export", "-q", "--stdout", database.path, "Work/Domains/Cafe", "secret.txt"], stdin: ["scratch"])
        print("KEEPASSXC-CROSSCHECK ls-after-add-delete:\n\(after)")
        print("KEEPASSXC-CROSSCHECK show-fresh:\n\(freshShow)")
        XCTAssertTrue(after.contains("Work/Freshly/Fresh"))
        XCTAssertTrue(after.contains("Empty/[empty]"))
        XCTAssertTrue(after.contains("Recycle Bin"))
        XCTAssertTrue(after.contains("Other"))
        XCTAssertTrue(freshShow.contains("Password: fresh-secret"))
        XCTAssertEqual(Data(keptAttachment.utf8), attachment)
    }

    private func loadSmall(maxItems: Int, maxBytes: Int, password: String) throws -> Vault {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <KeePassFile><Meta><DatabaseName>Hist</DatabaseName><HistoryMaxItems>\(maxItems)</HistoryMaxItems><HistoryMaxSize>\(maxBytes)</HistoryMaxSize></Meta>
        <Root><Group><UUID>\(id("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))</UUID><Name>Root</Name>
        <Entry><UUID>\(id("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))</UUID>
        <Times><LastModificationTime>pVSf1Q4AAAA=</LastModificationTime></Times>
        <String><Key>Title</Key><Value>Item</Value></String>
        <String><Key>Password</Key><Value Protected="True">\(password)</Value></String>
        <History></History></Entry></Group></Root></KeePassFile>
        """
        return try KDBX.load(data: try KDBX.testingDatabase(xml: xml, password: "secret"), password: "secret")
    }

    private func setPassword(_ password: String, on vault: inout Vault) throws {
        let index = try XCTUnwrap(vault.entries.firstIndex { $0.title == "Item" })
        vault.entries[index].password = password
        _ = try KDBX.save(vault: &vault, password: "secret")
    }

    private func richXML() -> String {
        let icon = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <KeePassFile>
        <Meta>
        <Generator>KeePassXC</Generator>
        <DatabaseName>Fixture</DatabaseName>
        <DatabaseDescription>keep me</DatabaseDescription>
        <HistoryMaxItems>10</HistoryMaxItems>
        <HistoryMaxSize>6291456</HistoryMaxSize>
        <RecycleBinEnabled>True</RecycleBinEnabled>
        <RecycleBinUUID>\(id("0a0a0a0a-0a0a-0a0a-0a0a-0a0a0a0a0a0a"))</RecycleBinUUID>
        <CustomIcons><Icon><UUID>\(id("55555555-5555-5555-5555-555555555555"))</UUID><Data>\(icon)</Data></Icon></CustomIcons>
        <!-- keep-comment -->
        <PasswordPieProbe>keep-me</PasswordPieProbe>
        </Meta>
        <Root>
        <Group>
        <UUID>\(id("01010101-0101-0101-0101-010101010101"))</UUID>
        <Name>Passwords</Name>
        <Notes>root notes</Notes>
        <IconID>49</IconID>
        <Entry>
        <UUID>\(id("22222222-2222-2222-2222-222222222222"))</UUID>
        <Tags>keep</Tags>
        <Times><CreationTime>pVSf1Q4AAAA=</CreationTime><LastModificationTime>pVSf1Q4AAAA=</LastModificationTime><LastAccessTime>pVSf1Q4AAAA=</LastAccessTime><ExpiryTime>pVSf1Q4AAAA=</ExpiryTime><Expires>False</Expires><UsageCount>2</UsageCount><LocationChanged>pVSf1Q4AAAA=</LocationChanged></Times>
        <String><Key>Title</Key><Value>Untouched</Value></String>
        <String><Key>Password</Key><Value Protected="True">other-secret</Value></String>
        </Entry>
        <Group>
        <UUID>\(id("02020202-0202-0202-0202-020202020202"))</UUID>
        <Name>Work</Name>
        <Group>
        <UUID>\(id("03030303-0303-0303-0303-030303030303"))</UUID>
        <Name>Domains</Name>
        <Entry>
        <UUID>\(id("11111111-1111-1111-1111-111111111111"))</UUID>
        <IconID>5</IconID>
        <CustomIconUUID>\(id("55555555-5555-5555-5555-555555555555"))</CustomIconUUID>
        <ForegroundColor>#FF0000</ForegroundColor>
        <BackgroundColor>#00FF00</BackgroundColor>
        <Tags>alpha,beta</Tags>
        <Times><CreationTime>pVSf1Q4AAAA=</CreationTime><LastModificationTime>pVSf1Q4AAAA=</LastModificationTime><LastAccessTime>pVSf1Q4AAAA=</LastAccessTime><ExpiryTime>pVSf1Q4AAAA=</ExpiryTime><Expires>False</Expires><UsageCount>4</UsageCount><LocationChanged>pVSf1Q4AAAA=</LocationChanged></Times>
        <String><Key>Title</Key><Value>Cafe</Value></String>
        <String><Key>UserName</Key><Value>ada</Value></String>
        <String><Key>Password</Key><Value Protected="True">live-secret</Value></String>
        <String><Key>otp</Key><Value Protected="True">otpauth://totp/Cafe:ada?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&amp;issuer=Cafe</Value></String>
        <String><Key>Notes</Key><Value>hello</Value></String>
        <Binary><Key>secret.txt</Key><Value Ref="0"/></Binary>
        <AutoType><Enabled>True</Enabled><DefaultSequence>{USERNAME}{TAB}{PASSWORD}</DefaultSequence><Association><Window>Chrome</Window><KeystrokeSequence>{PASSWORD}</KeystrokeSequence></Association></AutoType>
        <CustomData><Item><Key>color</Key><Value>blue</Value></Item></CustomData>
        <History>
        <Entry>
        <UUID>\(id("11111111-1111-1111-1111-111111111111"))</UUID>
        <String><Key>Password</Key><Value Protected="True"></Value></String>
        <String><Key>Password</Key><Value Protected="True">older</Value></String>
        </Entry>
        </History>
        <UnknownKeep>yes</UnknownKeep>
        </Entry>
        </Group>
        </Group>
        <Group><UUID>\(id("04040404-0404-0404-0404-040404040404"))</UUID><Name>Empty</Name><Notes>vacant</Notes></Group>
        <Group>
        <UUID>\(id("0a0a0a0a-0a0a-0a0a-0a0a-0a0a0a0a0a0a"))</UUID>
        <Name>Recycle Bin</Name>
        <Entry>
        <UUID>\(id("33333333-3333-3333-3333-333333333333"))</UUID>
        <Times><CreationTime>pVSf1Q4AAAA=</CreationTime><LastModificationTime>pVSf1Q4AAAA=</LastModificationTime><LastAccessTime>pVSf1Q4AAAA=</LastAccessTime><ExpiryTime>pVSf1Q4AAAA=</ExpiryTime><Expires>False</Expires><UsageCount>1</UsageCount><LocationChanged>pVSf1Q4AAAA=</LocationChanged></Times>
        <String><Key>Title</Key><Value>Gone</Value></String>
        <String><Key>Password</Key><Value Protected="True">gone-secret</Value></String>
        </Entry>
        </Group>
        </Group>
        <DeletedObjects><DeletedObject><UUID>\(id("44444444-4444-4444-4444-444444444444"))</UUID><DeletionTime>pVSf1Q4AAAA=</DeletionTime></DeletedObject></DeletedObjects>
        </Root>
        </KeePassFile>
        """
    }

    private func id(_ uuid: String) -> String {
        base64UUID(UUID(uuidString: uuid)!)
    }

    private func fingerprints(_ vault: Vault) -> [String: String] {
        guard let document = vault.preserve?.document else { return [:] }
        var result: [String: String] = [:]
        for element in liveEntryElements(document) {
            if let title = field(element, "Title") {
                result[title] = fingerprint(element)
            }
        }
        return result
    }

    private func entry(_ vault: Vault, title: String) throws -> XMLElement {
        let found = liveEntryElements(try XCTUnwrap(vault.preserve).document).first { field($0, "Title") == title }
        return try XCTUnwrap(found)
    }

    private func liveEntryElements(_ document: XMLDocument) -> [XMLElement] {
        guard let root = document.rootElement().flatMap({ direct($0, "Root").first }) else { return [] }
        var result: [XMLElement] = []
        func walk(_ group: XMLElement) {
            result.append(contentsOf: direct(group, "Entry"))
            for child in direct(group, "Group") { walk(child) }
        }
        for group in direct(root, "Group") { walk(group) }
        return result
    }

    private func history(_ entry: XMLElement) -> [XMLElement] {
        guard let history = direct(entry, "History").first else { return [] }
        return direct(history, "Entry")
    }

    private func field(_ entry: XMLElement, _ key: String) -> String? {
        for string in direct(entry, "String") where direct(string, "Key").first?.stringValue == key {
            return direct(string, "Value").first?.stringValue
        }
        return nil
    }

    private func time(_ entry: XMLElement, _ name: String) -> String {
        guard let times = direct(entry, "Times").first else { return "" }
        return direct(times, name).first?.stringValue ?? ""
    }

    private func group(named name: String, in document: XMLDocument) -> XMLElement? {
        guard let root = document.rootElement().flatMap({ direct($0, "Root").first }) else { return nil }
        var pending = direct(root, "Group")
        while !pending.isEmpty {
            let group = pending.removeFirst()
            if direct(group, "Name").first?.stringValue == name { return group }
            pending.append(contentsOf: direct(group, "Group"))
        }
        return nil
    }

    private func fingerprint(_ node: XMLNode) -> String {
        switch node.kind {
        case .element:
            guard let element = node as? XMLElement else { return "" }
            let attributes = (element.attributes ?? [])
                .map { "\($0.name ?? "")=\($0.stringValue ?? "")" }
                .sorted()
                .joined(separator: " ")
            let children = (element.children ?? []).compactMap { child -> String? in
                if child.kind == .text {
                    let text = child.stringValue ?? ""
                    return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
                }
                if child.kind == .element || child.kind == .comment {
                    return fingerprint(child)
                }
                return nil
            }.joined()
            return "<\(element.name ?? "") [\(attributes)]>\(children)</\(element.name ?? "")>"
        case .text:
            return node.stringValue ?? ""
        case .comment:
            return "<!--\(node.stringValue ?? "")-->"
        default:
            return ""
        }
    }

    @discardableResult
    private func runCLI(_ arguments: [String], stdin lines: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli")
        process.arguments = arguments
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        input.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: stdout, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let err = String(data: stderr, encoding: .utf8) ?? ""
            XCTFail("keepassxc-cli \(arguments.joined(separator: " ")) failed (\(process.terminationStatus)): \(err)\n\(text)")
        }
        return text
    }
}
