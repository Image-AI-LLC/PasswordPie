import XCTest
@testable import PasswordPieCore

/// Exports from browsers and other password managers, read into the open database (docs/UX.md, "Import with a guide").
final class ImportSourcesTests: XCTestCase {
    /// KeePassXC's own test files, when its checkout is on this machine.
    private let fixtures = URL(fileURLWithPath: "/Users/oldcai/projects/PasswordPie/keepassxc/tests/data", isDirectory: true)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func file(_ name: String, _ text: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func file(_ name: String, base64: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try XCTUnwrap(Data(base64Encoded: base64)).write(to: url)
        return url
    }

    private func fixture(_ name: String) throws -> URL {
        let url = fixtures.appendingPathComponent(name)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "KeePassXC's \(name) is not on this machine")
        return url
    }

    private func message(_ body: @autoclosure () throws -> ImportedFile) -> String {
        do {
            _ = try body()
            return ""
        } catch {
            return (error as? VaultOpenError)?.description ?? "\(error)"
        }
    }

    // MARK: CSV shapes

    func testFirefoxRowsTakeTheSiteAsTheirTitleAndDropFirefoxBookkeeping() throws {
        let csv = """
        "url","username","password","httpRealm","formActionOrigin","guid","timeCreated","timeLastUsed","timePasswordChanged"
        "https://www.example.com","ann","pw1",,"https://www.example.com","{0c1f}","1700000000000","1700000000001","1700000000002"
        """
        let read = try BrowserImport.read(file("passwords.csv", csv), source: .firefox)
        XCTAssertEqual(read.entries.count, 1)
        let entry = read.entries[0]
        XCTAssertEqual(entry.title, "example.com")
        XCTAssertEqual(entry.username, "ann")
        XCTAssertEqual(entry.password, "pw1")
        XCTAssertEqual(entry.groupPath, ["Firefox"])
        XCTAssertEqual(entry.tagList, ["Firefox"])
        XCTAssertEqual(entry.fields.map(\.key).sorted(), ["Password", "Title", "URL", "UserName"])
        XCTAssertTrue(read.plainText)
    }

    func testLastPassKeepsItsFoldersNotesAndCodes() throws {
        let csv = """
        url,username,password,totp,extra,name,grouping,fav
        https://example.com,ann,pw1,JBSWY3DPEHPK3PXP,my note,Example,Work\\Servers,1
        http://sn,,,,only a note,Wifi,,0
        """
        let read = try BrowserImport.read(file("lastpass_vault_export.csv", csv), source: .lastPass)
        XCTAssertEqual(read.entries.count, 2)
        let login = read.entries[0]
        XCTAssertEqual(login.title, "Example")
        XCTAssertEqual(login.notes, "my note")
        XCTAssertEqual(login.groupPath, ["LastPass", "Work", "Servers"])
        XCTAssertTrue(login.otp.contains("JBSWY3DPEHPK3PXP"))
        XCTAssertTrue(login.favorite)
        XCTAssertTrue(login.tagList.contains("LastPass"))
        XCTAssertEqual(read.entries[1].title, "Wifi")
        XCTAssertEqual(read.entries[1].groupPath, ["LastPass"])
    }

    func testDashlaneCategoryIsTheFolderAndItsCodeComesAlong() throws {
        let csv = """
        username,username2,username3,title,password,note,url,category,otpUrl
        ann@example.com,,,Example,pw3,,https://example.com,Work,otpauth://totp/Example:ann?secret=JBSWY3DPEHPK3PXP
        """
        let read = try BrowserImport.read(file("credentials.csv", csv), source: .dashlane)
        let entry = try XCTUnwrap(read.entries.first)
        XCTAssertEqual(entry.groupPath, ["Dashlane", "Work"])
        XCTAssertEqual(entry.username, "ann@example.com")
        XCTAssertTrue(entry.otp.hasPrefix("otpauth://"))
        XCTAssertTrue(entry.value(for: "username2").isEmpty)
    }

    func testAOnePasswordCSVKeepsItsTags() throws {
        let csv = """
        Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes
        Example,https://example.com,ann,pw1,,true,false,work;bank,hello
        """
        let read = try BrowserImport.read(file("1PasswordExport.csv", csv), source: .onePassword)
        let entry = try XCTUnwrap(read.entries.first)
        XCTAssertEqual(Set(entry.tagList), ["work", "bank", "Favorite", "1Password"])
        XCTAssertEqual(entry.notes, "hello")
        XCTAssertTrue(entry.value(for: "Tags").isEmpty)
    }

    func testABitwardenCSVCountsAsHavingAPasswordColumn() throws {
        let csv = """
        folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp
        Work,,login,Example,,,0,https://example.com,ann,pw1,
        """
        let read = try BrowserImport.read(file("bitwarden_export.csv", csv), source: .bitwarden)
        let entry = try XCTUnwrap(read.entries.first)
        XCTAssertEqual(entry.password, "pw1")
        XCTAssertEqual(entry.groupPath, ["Bitwarden", "Work"])
    }

    func testACSVWithoutAPasswordColumnIsRefused() throws {
        let url = try file("bookmarks.csv", "name,url\nExample,https://example.com\n")
        XCTAssertEqual(message(try BrowserImport.read(url, source: .csv)), "This file has no Password column, so it is not a password export.")
    }

    func testAnotherAppsCSVGoesIntoImported() throws {
        let csv = "title,url,username,password,notes,otp\nExample,https://example.com,ann,pw1,hi,\n"
        let read = try BrowserImport.read(file("anything.csv", csv), source: .csv)
        XCTAssertEqual(read.entries.first?.groupPath, ["Imported"])
        XCTAssertEqual(read.entries.first?.tagList, ["Imported"])
    }

    // MARK: ZIP exports

    private let safariZIP = "UEsDBBQAAAAIAA0Fcl0fhxtgCwAAAA0AAAAOAAAAQm9va21hcmtzLmh0bWyzySjJzbGz0QdTAFBLAwQUAAAACAANBXJdDkGgWWsAAAB4AAAADQAAAFBhc3N3b3Jkcy5jc3Y9jUEKwjAQRfc5hQf4tOjSnau6kFqkPcC0DiZgJqEzIR7fgODyweO9OdibsTxuWJR3ociYSLWm/YkxGSvu83Qp5t0Q7FpWeLOs575/BfNl7bYUQSLI9Qi4kav+DWnQ8YdiboefcwIdpFXhvlBLAQIUAxQAAAAIAA0Fcl0fhxtgCwAAAA0AAAAOAAAAAAAAAAAAAACAAQAAAABCb29rbWFya3MuaHRtbFBLAQIUAxQAAAAIAA0Fcl0OQaBZawAAAHgAAAANAAAAAAAAAAAAAACAATcAAABQYXNzd29yZHMuY3N2UEsFBgAAAAACAAIAdwAAAM0AAAAAAA=="
    /// Written to a stream, so each entry is followed by a data descriptor and its local header has no sizes.
    private let dashlaneZIP = "UEsDBBQACAAIAA0Fcl0AAAAAAAAAAAAAAAAPAAAAc2VjdXJlbm90ZXMuY3N2K8ksyUnVycsvSeUqz0zL1MlIzcnJ5wIAUEsHCH1bweQYAAAAFgAAAFBLAwQUAAgACAANBXJdAAAAAAAAAAAAAAAADwAAAGNyZWRlbnRpYWxzLmNzdk3KMQvCMBCG4b2/5cOC2ZykWBBdAh2qY4iHiknuuFyp/nsLirg9L7xTJS0hE6Yv1j852N0SQUKtM+sFhW35NCEGoyvrC2wyUFSyJpSypWfIkmgVOQPoPwWZHXAzk7pp2/9lZH3g0A3j2e18v/dH50++eQNQSwcI6a5dWHMAAACRAAAAUEsBAhQDFAAIAAgADQVyXX1bweQYAAAAFgAAAA8AAAAAAAAAAAAAAIABAAAAAHNlY3VyZW5vdGVzLmNzdlBLAQIUAxQACAAIAA0Fcl3prl1YcwAAAJEAAAAPAAAAAAAAAAAAAACAAVUAAABjcmVkZW50aWFscy5jc3ZQSwUGAAAAAAIAAgB6AAAABQEAAAAA"
    private let protonZIP = "UEsDBBQAAAAIAA0Fcl1vxRHu4gAAAIkBAAAVAAAAUHJvdG9uIFBhc3MvZGF0YS5qc29uVVBNa8MwDP0rQefRkrFT7x0Mdtilp9KDSLTNYMvCVtKWkP8+S13LBgJLT7wPa4GZSg2ZYddBv3luBU8dTJXK22jYZCPxUK6iZMgnxkoNm3GKWhuwwNz7w5jIKB9NMTNGY45UhxJEfx0MCkrJeMfF25tN6G1VFdUk+tZLYP5nOKKi+yRSfAwP05I1c/eevwKbFGdXAoa1TXoVn+J9PWRWYnUJS7FPGOLfhId2gbs2snMEaz3n4nnl/OJ3KtG/At+qUnfbrXiMDV0wSSQ4mXdWOZTg4paFLlrwNVAcnXpa11brD1BLAQIUAxQAAAAIAA0Fcl1vxRHu4gAAAIkBAAAVAAAAAAAAAAAAAACAAQAAAABQcm90b24gUGFzcy9kYXRhLmpzb25QSwUGAAAAAAEAAQBDAAAAFQEAAAAA"
    private let emptyZIP = "UEsDBBQAAAAAAA0Fcl2GphA2BQAAAAUAAAAKAAAAcmVhZG1lLnR4dGhlbGxvUEsBAhQDFAAAAAAADQVyXYamEDYFAAAABQAAAAoAAAAAAAAAAAAAAIABAAAAAHJlYWRtZS50eHRQSwUGAAAAAAEAAQA4AAAALQAAAAAA"
    private let protonPGPZIP = "UEsDBBQAAAAAAA0Fcl38EIesGwAAABsAAAAUAAAAUHJvdG9uIFBhc3MvZGF0YS5wZ3AtLS0tLUJFR0lOIFBHUCBNRVNTQUdFLS0tLS1QSwECFAMUAAAAAAANBXJd/BCHrBsAAAAbAAAAFAAAAAAAAAAAAAAAgAEAAAAAUHJvdG9uIFBhc3MvZGF0YS5wZ3BQSwUGAAAAAAEAAQBCAAAATQAAAAAA"

    func testSafarisBrowsingDataZIPGivesItsPasswords() throws {
        let read = try BrowserImport.read(file("Safari Browsing Data.zip", base64: safariZIP), source: .applePasswords)
        XCTAssertEqual(read.entries.map(\.title), ["GitHub", "News"])
        XCTAssertEqual(read.entries[1].notes, "a note")
        XCTAssertEqual(read.entries[0].groupPath, ["Apple Passwords"])
        XCTAssertTrue(read.plainText)
    }

    func testDashlanesZIPGivesItsCredentialsThoughItWasWrittenToAStream() throws {
        let read = try BrowserImport.read(file("dashlane-export.zip", base64: dashlaneZIP), source: .dashlane)
        XCTAssertEqual(read.entries.map(\.title), ["Example"])
        XCTAssertEqual(read.entries[0].groupPath, ["Dashlane", "Work"])
        XCTAssertTrue(read.entries[0].otp.contains("JBSWY3DPEHPK3PXP"))
    }

    func testProtonPassZIPGivesItsVaults() throws {
        let read = try BrowserImport.read(file("Proton Pass_export.zip", base64: protonZIP), source: .protonPass)
        let entry = try XCTUnwrap(read.entries.first)
        XCTAssertEqual(entry.title, "Proton Login")
        XCTAssertEqual(entry.password, "pw4")
        XCTAssertEqual(entry.groupPath, ["Proton Pass", "Personal"])
    }

    func testAZIPWithNothingToImportSaysSo() throws {
        let url = try file("other.zip", base64: emptyZIP)
        XCTAssertEqual(message(try BrowserImport.read(url, source: .dashlane)), "This ZIP has no password export in it.")
    }

    func testAProtonPassZIPEncryptedWithPGPSaysToExportAgain() throws {
        let url = try file("Proton Pass_export.zip", base64: protonPGPZIP)
        XCTAssertTrue(message(try BrowserImport.read(url, source: .protonPass)).contains("without encryption"))
    }

    // MARK: The wrong file

    func testAKeePassDatabaseIsOpenedNotImported() throws {
        var vault = Vault(entries: [], kdf: .fastTest)
        let url = directory.appendingPathComponent("Passwords.kdbx")
        try KDBX.save(vault: &vault, password: "pw").write(to: url)
        XCTAssertTrue(message(try BrowserImport.read(url, source: .csv)).contains("Open Database…"))
    }

    func testAnotherAppsExportOnTheWrongPageNamesTheRightOne() throws {
        let url = try file("Proton Pass_export.zip", base64: protonZIP)
        XCTAssertEqual(
            message(try BrowserImport.read(url, source: .chrome)),
            "This is a Proton Pass export, not a Chrome one. Go back and choose Proton Pass."
        )
    }

    func testAFolderThatIsNotAnOPVaultIsRefused() {
        XCTAssertFalse(message(try BrowserImport.read(directory, source: .onePassword)).isEmpty)
    }

    // MARK: KeePassXC's files

    func testOnePasswordExportKeepsItsVaultsAsGroups() throws {
        let read = try BrowserImport.read(fixture("1PasswordExport.1pux"), source: .onePassword)
        let login = try XCTUnwrap(read.entries.first { $0.title == "Login" })
        XCTAssertEqual(login.groupPath, ["1Password", "Personal"])
        XCTAssertEqual(login.password, "password")
        XCTAssertTrue(login.tagList.contains("1Password"))
        XCTAssertTrue(read.plainText)
    }

    func testAnOPVaultAsksForItsPasswordAndIsNotPlainText() throws {
        let url = try fixture("keepassxc.opvault")
        XCTAssertThrowsError(try BrowserImport.read(url, source: .onePassword)) { error in
            XCTAssertEqual(error as? VaultOpenError, .wrongPassword)
        }
        let read = try BrowserImport.read(url, source: .onePassword, password: "a")
        XCTAssertFalse(read.entries.isEmpty)
        XCTAssertFalse(read.plainText)
        XCTAssertFalse(read.entries.contains { $0.trashed }, "what 1Password had in its trash stays out")
    }

    func testBitwardenKeepsItsFolders() throws {
        let read = try BrowserImport.read(fixture("bitwarden_export.json"), source: .bitwarden)
        XCTAssertFalse(read.entries.isEmpty)
        XCTAssertTrue(read.entries.allSatisfy { $0.groupPath.first == "Bitwarden" })
        XCTAssertTrue(read.plainText)
    }

    func testAProtectedBitwardenExportAsksForItsPassword() throws {
        let url = try fixture("bitwarden_encrypted_export.json")
        XCTAssertThrowsError(try BrowserImport.read(url, source: .bitwarden)) { error in
            XCTAssertEqual(error as? VaultOpenError, .wrongPassword)
        }
        let read = try BrowserImport.read(url, source: .bitwarden, password: "a")
        XCTAssertFalse(read.entries.isEmpty)
        XCTAssertFalse(read.plainText)
    }

    // MARK: Merging

    private func item(_ source: BrowserImportSource, _ folder: [String], _ title: String, _ user: String, _ password: String) -> VaultEntry {
        var entry = VaultEntry(groupPath: [source.label] + folder, tags: source.label)
        entry.title = title
        entry.url = "https://\(title).example"
        entry.username = user
        entry.password = password
        return entry
    }

    func testAPasswordManagersFoldersAreGroupsInsideItsOwn() {
        let result = BrowserImport.merge([item(.onePassword, ["Personal"], "a", "u", "p")], into: [], source: .onePassword)
        XCTAssertEqual(result.entries.map(\.groupPath), [["1Password", "Personal"]])
        XCTAssertEqual(result.summary.added, 1)
    }

    func testImportingAPasswordManagerAgainUpdatesInsideItsFolders() {
        let existing = item(.onePassword, ["Personal"], "a", "u", "old")
        let result = BrowserImport.merge([item(.onePassword, ["Personal"], "a", "u", "new")], into: [existing], source: .onePassword)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries[0].id, existing.id)
        XCTAssertEqual(result.entries[0].password, "new")
        XCTAssertEqual(result.summary, BrowserImportSummary(added: 0, updated: 1, unchanged: 0, removed: 0))
    }

    func testAPasswordManagersMissingItemsAreLeftAlone() {
        let kept = item(.bitwarden, ["Work"], "a", "u", "p")
        let other = item(.bitwarden, ["Home"], "b", "u", "p")
        let result = BrowserImport.merge([item(.bitwarden, ["Work"], "a", "u", "p")], into: [kept, other], source: .bitwarden)
        XCTAssertFalse(result.entries.contains { $0.trashed })
        XCTAssertEqual(result.summary, BrowserImportSummary(added: 0, updated: 0, unchanged: 1, removed: 0))
    }

    func testABrowsersMissingSitesStillGoToTheRecycleBin() {
        for source in [BrowserImportSource.chrome, .applePasswords, .firefox, .edge, .brave] {
            let gone = item(source, [], "b", "u", "p")
            let result = BrowserImport.merge([item(source, [], "a", "u", "p")], into: [gone], source: source)
            XCTAssertEqual(result.summary.removed, 1, source.label)
        }
    }

    func testAnItemWithoutAPasswordFromAPasswordManagerComesIn() throws {
        let csv = "url,username,password,totp,extra,name,grouping,fav\nhttp://sn,,,,only a note,Wifi,,0\n"
        let read = try BrowserImport.read(file("lastpass.csv", csv), source: .lastPass)
        XCTAssertEqual(read.entries.map(\.notes), ["only a note"])
    }

    func testEverySourceHasItsOwnGroup() {
        let labels = BrowserImportSource.allCases.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count)
        XCTAssertEqual(BrowserImportSource.chrome.label, "Chrome")
        XCTAssertEqual(BrowserImportSource.applePasswords.label, "Apple Passwords")
    }
}
