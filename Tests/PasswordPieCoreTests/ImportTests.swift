import XCTest
@testable import PasswordPieCore

final class ImportTests: XCTestCase {
    private let fixtures = URL(fileURLWithPath: "/Users/oldcai/projects/vault/keepassxc/tests/data", isDirectory: true)

    func testTwofishAllZeroBlock() {
        let zeros16 = Data(repeating: 0, count: 16)
        XCTAssertEqual(hex(Twofish.encryptBlock(zeros16, key: zeros16)), "9F589F5CF6122C32B6BFEC2F2AE8C35A")
        let zeros32 = Data(repeating: 0, count: 32)
        XCTAssertEqual(hex(Twofish.encryptBlock(zeros16, key: zeros32)), "57FF739D4DC92C1BD7FC01700CC8216F")
        let key = Data((0..<32).map { UInt8($0) })
        let block = Data((0..<16).map { UInt8($0 + 1) })
        XCTAssertEqual(hex(Twofish.encryptBlock(block, key: key)), "7C2D5268F4A9FB21F65F2E22636D327D")
    }

    func testOversizedKDFParametersFailInsteadOfTrapping() {
        XCTAssertThrowsError(try importPBKDF2(
            password: Data("a".utf8),
            salt: Data("salt".utf8),
            iterations: Int(UInt32.max) + 1,
            length: 32,
            sha512: false
        )) { error in
            guard let open = error as? VaultOpenError, case .crypto = open else {
                return XCTFail("\(error)")
            }
        }
        let argon = """
        {"encrypted":true,"kdfType":1,"kdfIterations":5000000000,"kdfMemory":64,"kdfParallelism":4,"salt":"abc"}
        """
        XCTAssertThrowsError(try loadBitwarden(Data(argon.utf8), password: "a")) { error in
            guard let open = error as? VaultOpenError, case .crypto = open else {
                return XCTFail("\(error)")
            }
        }
        let memory = """
        {"encrypted":true,"kdfType":1,"kdfIterations":3,"kdfMemory":\(Int(UInt32.max)),"kdfParallelism":1,"salt":"abc"}
        """
        XCTAssertThrowsError(try loadBitwarden(Data(memory.utf8), password: "a")) { error in
            guard let open = error as? VaultOpenError, case .crypto = open else {
                return XCTFail("\(error)")
            }
        }
        XCTAssertTrue(VaultFormat.blocksImportSave(writesKDBX: false, password: ""))
        XCTAssertFalse(VaultFormat.blocksImportSave(writesKDBX: false, password: "secret"))
        XCTAssertFalse(VaultFormat.blocksImportSave(writesKDBX: true, password: ""))
    }

    func testOpDataRejectsALengthThatDoesNotFit() {
        var data = Data("opdata01".utf8)
        data.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0x80])
        data.append(Data(repeating: 0, count: 48))
        XCTAssertThrowsError(try decodeOpData01(data, key: Data(count: 32), hmacKey: Data(count: 32))) { error in
            guard let open = error as? VaultOpenError, case .crypto = open else {
                return XCTFail("\(error)")
            }
        }
    }

    func testVaultFormatStillOpensKDBX() throws {
        var entry = VaultEntry()
        entry.title = "K"
        entry.password = "p"
        var vault = Vault(entries: [entry], kdf: .fastTest)
        let data = try KDBX.save(vault: &vault, password: "secret")
        let loaded = try VaultFormat.load(data: data, password: "secret", fileName: "vault.kdbx")
        XCTAssertEqual(loaded.entries.first?.password, "p")
        XCTAssertThrowsError(try VaultFormat.load(data: data, password: "nope", fileName: "vault.kdbx")) { error in
            XCTAssertEqual(error as? KDBXError, .wrongPassword)
        }
    }

    func testImportedSavePicksAFreeSibling() {
        let source = URL(fileURLWithPath: "/tmp/vaults/export.csv")
        let taken = ["/tmp/vaults/export.kdbx", "/tmp/vaults/export PasswordPie.kdbx"]
        let url = VaultFormat.importedKDBXURL(beside: source) { taken.contains($0) }
        XCTAssertEqual(url.lastPathComponent, "export PasswordPie 2.kdbx")
        let fresh = VaultFormat.importedKDBXURL(beside: source) { _ in false }
        XCTAssertEqual(fresh.lastPathComponent, "export.kdbx")
        let bundle = URL(fileURLWithPath: "/tmp/vaults/keepassxc.opvault", isDirectory: true)
        XCTAssertEqual(VaultFormat.importedKDBXURL(beside: bundle) { _ in false }.lastPathComponent, "keepassxc.kdbx")
    }

    func testCSVReadsHeaderAndQuotedCommas() throws {
        let text = """
        Group,Title,Username,Password,URL,Notes,TOTP,Favorite,Recovery Hint
        Work/Ops,Router,admin,secret,https://router.example,line,otpauth://totp/Router?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&period=30&digits=6,yes,hint
        "Home","Hello, world","ada","s,ecret","https://example.test","a note","","",""
        """
        let vault = try VaultFormat.load(data: Data(text.utf8), password: "future", fileName: "export.csv")
        let router = try require(vault, ["Work", "Ops"], "Router")
        XCTAssertEqual(router.username, "admin")
        XCTAssertEqual(router.password, "secret")
        XCTAssertEqual(router.url, "https://router.example")
        XCTAssertEqual(router.notes, "line")
        XCTAssertFalse(router.otp.isEmpty)
        XCTAssertTrue(router.favorite)
        XCTAssertEqual(router.value(for: "Recovery Hint"), "hint")
        let hello = try require(vault, ["Home"], "Hello, world")
        XCTAssertEqual(hello.password, "s,ecret")
        XCTAssertEqual(vault.name, "CSV Import")
    }

    func testPuxImport() throws {
        let matches = (try? FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "1pux" } ?? []
        try XCTSkipUnless(matches.count == 1, "PUX fixture is not on this machine")
        let vault = try VaultFormat.load(url: matches[0], password: "")
        let login = try require(vault, ["Personal"], "Login")
        XCTAssertEqual(login.username, "team@keepassxc.org")
        XCTAssertEqual(login.password, "password")
        XCTAssertEqual(login.url, "https://keepassxc.org")
        XCTAssertEqual(login.notes, "Note to self")
        XCTAssertEqual(login.value(for: "KP2A_URL_1"), "https://twitter.com")
        XCTAssertNotNil(TOTP.parse(entry: login))
        XCTAssertFalse(login.value(for: "otp_1").isEmpty)
        XCTAssertTrue(login.tagList.contains("Favorite"))
        XCTAssertTrue(login.tagList.contains("website"))

        let logo = try require(vault, ["Personal"], "KeePassXC Logo")
        XCTAssertEqual(logo.attachments.map(\.name), ["keepassxc.png"])

        let card = try require(vault, ["Personal"], "Credit Card")
        XCTAssertEqual(card.value(for: "Credit Card Fields_cardholder name"), "KeePassXC")
        XCTAssertEqual(card.value(for: "Credit Card Fields_expiry date"), "202206")
        XCTAssertEqual(card.value(for: "Credit Card Fields_verification number"), "123")
        XCTAssertTrue(protected(card, "Credit Card Fields_verification number"))

        let identity = try require(vault, ["Personal"], "Identity")
        XCTAssertEqual(identity.value(for: "Address_address"), "123 Avenue Rd\nBoston, MA 12345\nus")
        XCTAssertTrue(try require(vault, ["Personal"], "Login Archived").tagList.contains("Archived"))
        XCTAssertNotNil(try? require(vault, ["Shared"], "Bank Account"))
        XCTAssertEqual(try require(vault, ["Personal"], "UUID 005 Password").password, "uuid005password")
    }

    func testOPVault() throws {
        let vault = try open("keepassxc.opvault", password: "a")
        let login = try require(vault, ["Login"], "KeePassXC")
        XCTAssertEqual(login.username, "keepassxc")
        XCTAssertEqual(login.password, "opvault")
        XCTAssertEqual(login.url, "https://www.keepassxc.org")
        XCTAssertEqual(login.notes, "KeePassXC Account")
        XCTAssertEqual(login.value(for: "KP2A_URL_1"), "https://snapshot.keepassxc.org")
        XCTAssertNotNil(TOTP.parse(entry: login))
        XCTAssertEqual(login.attachments.map(\.data), [Data("attachment".utf8)])

        let expired = try require(vault, ["Login"], "Expired Login")
        XCTAssertFalse(expired.trashed)

        let card = try require(vault, ["Credit Card"], "My Credit Card")
        XCTAssertEqual(card.value(for: "cardholder name"), "Team KeePassXC")
        XCTAssertFalse(card.value(for: "valid from").isEmpty)
        XCTAssertEqual(card.value(for: "Additional Details_PIN"), "1234")
        XCTAssertTrue(protected(card, "Additional Details_PIN"))

        XCTAssertEqual(try require(vault, ["Identity"], "Team KeePassXC").value(for: "address_street"), "123 Password Lane")
        let complex = try require(vault, ["Password"], "Complex Password")
        XCTAssertEqual(complex.password, "HfgcHjEL}iO}^3N!?*cv~O:9GJZQ0>oC")
        let totp = try XCTUnwrap(TOTP.parse(entry: complex), "otp=\(complex.otp)")
        XCTAssertEqual(totp.digits, 8)
        XCTAssertEqual(totp.period, 45)
        XCTAssertTrue(vault.entries.contains { $0.trashed && $0.title == "Trashed Password" })

        let categories: Set<String> = [
            "Login", "Credit Card", "Secure Note", "Identity", "Password", "Tombstone",
            "Software License", "Bank Account", "Database", "Driver License", "Outdoor License",
            "Membership", "Passport", "Rewards", "SSN", "Router", "Server", "Email"
        ]
        let groups = Set(vault.entries.filter { !$0.trashed }.compactMap(\.groupPath.first))
        XCTAssertTrue(groups.isSubset(of: categories), "unexpected groups \(groups.subtracting(categories))")
    }

    func testBitwardenJSON() throws {
        let vault = try open("bitwarden_export.json")
        let login = try require(vault, ["My Folder"], "Login Name")
        XCTAssertEqual(login.username, "myusername@gmail.com")
        XCTAssertEqual(login.password, "mypassword")
        XCTAssertEqual(login.url, "https://mail.google.com")
        XCTAssertEqual(login.notes, "1st line of note text\n2nd Line of note text")
        XCTAssertEqual(login.value(for: "KP2A_URL_1"), "https://google.com")
        XCTAssertEqual(login.value(for: "KP2A_URL_2"), "https://gmail.com")
        XCTAssertNotNil(TOTP.parse(entry: login))
        XCTAssertTrue(login.value(for: "Password History").contains("oldpassword"))

        let identity = try require(vault, ["My Folder"], "My Identity")
        XCTAssertEqual(identity.value(for: "identity_address"), " 1 North Calle Cesar Chavez \nSanta Barbara, CA 93103\nUnited States ")
        XCTAssertEqual(identity.value(for: "identity_name"), "Mrs Jane A Doe")
        XCTAssertEqual(identity.value(for: "identity_ssn"), "123-12-1234")
        XCTAssertTrue(protected(identity, "identity_ssn"))
        XCTAssertEqual(
            try require(vault, ["My Folder"], "My Secure Note").notes,
            "1st line of secure note\n2nd line of secure note\n3rd line of secure note"
        )
        let card = try require(vault, ["Second Folder"], "Card Name")
        XCTAssertEqual(card.value(for: "card_cardholderName"), "Jane Doe")
        XCTAssertEqual(card.value(for: "card_number"), "1234567891011121")
        XCTAssertEqual(card.value(for: "card_code"), "123")
        XCTAssertTrue(protected(card, "card_code"))
    }

    func testBitwardenEncryptedExports() throws {
        let pbkdf2 = try open("bitwarden_encrypted_export.json", password: "a")
        XCTAssertFalse(pbkdf2.entries.isEmpty)
        let argon2 = try open("bitwarden_encrypted_argon2id_export.json", password: "a")
        XCTAssertFalse(argon2.entries.isEmpty)
        let url = try fixture("bitwarden_encrypted_export.json")
        XCTAssertThrowsError(try VaultFormat.load(url: url, password: "nope")) { error in
            XCTAssertEqual(error as? VaultOpenError, .wrongPassword)
        }
    }

    func testBitwardenPasskey() throws {
        let entry = try require(open("bitwarden_passkey_export.json"), [], "webauthn.io")
        XCTAssertEqual(entry.username, "KPXC_BITWARDEN")
        XCTAssertEqual(entry.url, "https://webauthn.io/")
        XCTAssertEqual(entry.value(for: "KPEX_PASSKEY_CREDENTIAL_ID"), "o-FfiyfBQq6Qz6YVrYeFTw")
        XCTAssertEqual(
            entry.value(for: "KPEX_PASSKEY_PRIVATE_KEY_PEM"),
            "-----BEGIN PRIVATE KEY-----MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgmr4GQQjerojFuf0ZouOuUllMvAwxZSZAfB6gwDYcLiehRANCAAT0WR5zVSp6ieusvjkLkzaGc7fjGBmwpiuLPxR/d+ZjqMI9L2DKh+takp6wGt2x0n4jzr1KA352NZg0vjZX9CHh-----END PRIVATE KEY-----"
        )
        XCTAssertEqual(entry.value(for: "KPEX_PASSKEY_USERNAME"), "KPXC_BITWARDEN")
        XCTAssertEqual(entry.value(for: "KPEX_PASSKEY_RELYING_PARTY"), "webauthn.io")
        XCTAssertEqual(entry.value(for: "KPEX_PASSKEY_USER_HANDLE"), "aTFtdmFnOHYtS2dxVEJ0by1rSFpLWGg0enlTVC1iUVJReDZ5czJXa3c2aw")
    }

    func testBitwardenNestedFolders() throws {
        let vault = try open("bitwarden_nested_export.json")
        let expected: [([String], String, String)] = [
            (["SecondTest"], "GMail entry", "example@gmail.com"),
            ([], "Test Authentication", "test@testauthentication.com"),
            (["Test"], "Gmail test 2", "example2@gmail.com"),
            ([], "Example", "user@example.com"),
            (["Test", "SubFolder"], "WebAuthn.io test", "testUser"),
            (["Test", "Subfolder"], "Webauthn.io test 2", "testUser2"),
            (["Test", "SubFolder", "AnotherSubFolder"], "Webauthn.io test 3", "testUser3"),
            (["Test", "Subfolder"], "Test Account", "test-account"),
            (["Test", "SubFolder", "AnotherSubFolder"], "Another test account", "anotherUser")
        ]
        for (path, title, username) in expected {
            XCTAssertEqual(try require(vault, path, title).username, username, title)
        }
    }

    func testProtonPass() throws {
        let vault = try open("protonpass_export.json")
        let login = try require(vault, ["Personal"], "Test Login")
        XCTAssertEqual(login.username, "Username")
        XCTAssertEqual(login.password, "Password")
        XCTAssertEqual(login.url, "https://example.com/")
        XCTAssertEqual(login.notes, "My login secure note.")
        XCTAssertEqual(login.value(for: "KP2A_URL_1"), "https://example2.com/")
        XCTAssertNotNil(TOTP.parse(entry: login))
        XCTAssertTrue(protected(login, "hidden field"))
        XCTAssertEqual(login.value(for: "second 2fa secret"), "TOTPCODE")
        XCTAssertEqual(try require(vault, ["Personal"], "My Secure Note").notes, "Secure note contents.")
        let card = try require(vault, ["Personal"], "Test Card")
        XCTAssertEqual(card.username, "1234222233334444")
        XCTAssertEqual(card.password, "333")
        XCTAssertEqual(card.value(for: "card_cardholderName"), "Test name")
        XCTAssertEqual(card.value(for: "card_expirationDate"), "2025-01")
        XCTAssertEqual(card.value(for: "card_pin"), "1234")
        XCTAssertTrue(protected(card, "card_pin"))
        let deleted = try require(vault, ["Personal"], "My Deleted Note")
        XCTAssertTrue(deleted.tagList.contains("Expired"))
        XCTAssertFalse(deleted.trashed)
        XCTAssertNotNil(try? require(vault, ["Test"], "Other vault login"))
        let unknown = try require(vault, ["Personal"], "Unknown Type")
        XCTAssertEqual(unknown.value(for: "content_attr1"), "value1")
        XCTAssertEqual(unknown.value(for: "content_attr2"), "value2")

        let encrypted = Data(#"{"encrypted":true,"vaults":{}}"#.utf8)
        XCTAssertThrowsError(try VaultFormat.load(data: encrypted, password: "a", fileName: "proton.json")) { error in
            guard let open = error as? VaultOpenError, case .unsupported = open else {
                return XCTFail("expected unsupported, got \(error)")
            }
        }
    }

    func testKeePass1Basic() throws {
        let vault = try open("basic.kdb", password: "masterpw")
        if case .aes(let rounds) = vault.kdf.kind {
            XCTAssertEqual(rounds, 713)
        } else {
            XCTFail("expected AES-KDF, got \(vault.kdf.kind)")
        }
        let entry = try require(vault, ["Internet"], "Test entry")
        XCTAssertEqual(entry.username, "I")
        XCTAssertEqual(entry.url, "http://example.com/")
        XCTAssertEqual(entry.password, "secretpassword")
        XCTAssertEqual(entry.notes, "Lorem ipsum\ndolor sit amet")
        XCTAssertEqual(entry.attachments.map(\.name), ["attachment.txt"])
        XCTAssertEqual(entry.attachments.map(\.data), [Data("hello world\n".utf8)])
        XCTAssertNotNil(try? require(vault, ["Internet"], ""))
        XCTAssertEqual(try require(vault, ["Internet", "Subgroup 1"], titleContaining: "last line").notes, "last line")
        let other = vault.entries.first { $0.groupPath == ["Internet", "Subgroup 1"] && $0.notes == "start line\nend line" }
        XCTAssertNotNil(other)
        XCTAssertEqual(vault.entries.filter { $0.groupPath == ["eMail"] }.count, 1)
        XCTAssertThrowsError(try VaultFormat.load(url: try fixture("basic.kdb"), password: "nope")) { error in
            XCTAssertEqual(error as? VaultOpenError, .wrongPassword)
        }
    }

    func testKeePass1KeyFilesAndTwofish() throws {
        for name in ["FileKeyBinary", "FileKeyHex", "FileKeyHashed"] {
            let vault = try open("\(name).kdb", password: "", keyFile: "\(name).key")
            let paths = Set(vault.entries.map { $0.groupPath.joined(separator: "/") })
            XCTAssertTrue(paths.isEmpty || paths.contains { $0 == name || $0.hasPrefix(name + "/") }, "\(name) \(paths)")
        }
        let composite = try open("CompositeKey.kdb", password: "mypassword", keyFile: "FileKeyHex.key")
        let compositePaths = Set(composite.entries.map { $0.groupPath.joined(separator: "/") })
        XCTAssertTrue(compositePaths.isEmpty || compositePaths.contains { $0 == "CompositeKey" || $0.hasPrefix("CompositeKey/") }, "\(compositePaths)")
        let twofish = try open("Twofish.kdb", password: "masterpw")
        let twofishPaths = twofish.entries.map { $0.groupPath.joined(separator: "/") }
        XCTAssertTrue(twofishPaths.isEmpty || twofishPaths.contains { $0 == "Twofish" || $0.hasPrefix("Twofish/") }, "\(twofishPaths)")
        let quoted = "\u{201E}password\u{201D}"
        let cp1252 = try open("CP-1252.kdb", password: quoted)
        let cpPaths = cp1252.entries.map { "\($0.groupPath.joined(separator: "/")):\($0.title)" }
        XCTAssertTrue(cpPaths.isEmpty || cpPaths.contains { $0.hasPrefix("CP-1252") }, "\(cpPaths)")
    }

    private func fixture(_ name: String) throws -> URL {
        let url = fixtures.appendingPathComponent(name, isDirectory: name.hasSuffix(".opvault"))
        var directory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
        try XCTSkipUnless(exists, "KeePassXC fixture \(name) is not on this machine")
        return url
    }

    private func open(_ name: String, password: String = "", keyFile: String? = nil) throws -> Vault {
        let url = try fixture(name)
        let key = try keyFile.map { try Data(contentsOf: try fixture($0)) }
        return try VaultFormat.load(url: url, password: password, keyFile: key)
    }

    private func require(_ vault: Vault, _ path: [String], _ title: String, file: StaticString = #filePath, line: UInt = #line) throws -> VaultEntry {
        let found = vault.entries.first { $0.groupPath == path && $0.title == title }
        let listed = vault.entries.map { ($0.groupPath + [$0.title]).joined(separator: "/") }.sorted().joined(separator: ", ")
        return try XCTUnwrap(found, "missing \(path.joined(separator: "/"))/\(title); have \(listed)", file: file, line: line)
    }

    private func require(_ vault: Vault, _ path: [String], titleContaining note: String) throws -> VaultEntry {
        try XCTUnwrap(vault.entries.first { $0.groupPath == path && $0.notes.contains(note) })
    }

    private func protected(_ entry: VaultEntry, _ key: String) -> Bool {
        entry.fields.first { $0.key == key }?.protected == true
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }
}
