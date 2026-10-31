import XCTest
@testable import PasswordPieCore

final class PasswordPieCoreTests: XCTestCase {
    func testChaCha20MatchesRFC8439() {
        let key = Data((0..<32).map { UInt8($0) })
        let nonce = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x4a, 0x00, 0x00, 0x00, 0x00])
        var cipher = ChaCha20(key: key, nonce: nonce, counter: 1)
        let plain = Data("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".utf8)
        let cipherText = cipher.xor(plain)
        let expected = Data([0x6e, 0x2e, 0x35, 0x9a, 0x25, 0x68, 0xf9, 0x80, 0x41, 0xba, 0x07, 0x28, 0xdd, 0x0d, 0x69, 0x81])
        XCTAssertEqual(cipherText.prefix(16), expected)
    }

    func testRoundTripAESKDF() throws {
        var entry = VaultEntry()
        entry.title = "Café GitHub"
        entry.username = "ada"
        entry.password = "correct horse"
        entry.url = "https://GitHub.com/login"
        entry.notes = "recovery-code-zebra"
        entry.otp = TOTP.otpAuthURL(secretBase32: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", title: "Café GitHub", username: "ada")
        entry.favorite = true
        var trashed = VaultEntry()
        trashed.title = "Gone"
        trashed.password = "hidden"
        trashed.trashed = true
        var vault = Vault(name: "Test", entries: [entry, trashed], kdf: .fastTest)
        let data = try KDBX.save(vault: &vault, password: "secret")
        let loaded = try KDBX.load(data: data, password: "secret")
        XCTAssertEqual(loaded.entries.count, 2)
        let kept = try XCTUnwrap(loaded.entries.first { $0.title == "Café GitHub" })
        XCTAssertEqual(kept.username, "ada")
        XCTAssertEqual(kept.password, "correct horse")
        XCTAssertEqual(kept.url, "https://GitHub.com/login")
        XCTAssertEqual(kept.notes, "recovery-code-zebra")
        XCTAssertTrue(kept.favorite)
        XCTAssertFalse(kept.trashed)
        XCTAssertEqual(loaded.entries.first { $0.title == "Gone" }?.trashed, true)
        XCTAssertThrowsError(try KDBX.load(data: data, password: "nope")) { error in
            XCTAssertEqual(error as? KDBXError, .wrongPassword)
        }
    }

    func testFoldersSurviveASave() throws {
        func item(_ title: String, _ path: [String]) -> VaultEntry {
            var entry = VaultEntry(groupPath: path)
            entry.title = title
            entry.password = "pw-" + title
            return entry
        }
        var vault = Vault(entries: [item("root", []), item("a", ["Work"]), item("b", ["Work", "Domains"]), item("c", ["Home"]), item("d", ["Work"])], kdf: .fastTest)
        let loaded = try KDBX.load(data: try KDBX.save(vault: &vault, password: "secret"), password: "secret")
        let paths = Dictionary(uniqueKeysWithValues: loaded.entries.map { ($0.title, $0.groupPath) })
        XCTAssertEqual(paths, ["root": [], "a": ["Work"], "b": ["Work", "Domains"], "c": ["Home"], "d": ["Work"]])
        XCTAssertEqual(loaded.entries.first { $0.title == "b" }?.password, "pw-b", "protected values stay aligned with the stream across groups")
    }

    func testArgon2idRoundTrip() throws {
        var entry = VaultEntry()
        entry.title = "Argon"
        entry.password = "pw"
        let kdf = KDFParameters(kind: .argon2id(memoryKiB: 64, iterations: 2, parallelism: 1, version: 0x13))
        var vault = Vault(entries: [entry], kdf: kdf)
        let data = try KDBX.save(vault: &vault, password: "secret")
        let loaded = try KDBX.load(data: data, password: "secret")
        XCTAssertEqual(loaded.entries.first?.password, "pw")
        if case .argon2id = loaded.kdf.kind {
        } else {
            XCTFail("expected argon2id, got \(loaded.kdf.kind)")
        }
    }

    func testKeePassXCDemoDatabase() throws {
        let url = URL(fileURLWithPath: "/Users/oldcai/projects/retroapps/keepassxc/share/demo.kdbx")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "KeePassXC demo database is not checked out on this machine")
        let data = try Data(contentsOf: url)
        let vault = try KDBX.load(data: data, password: "secret")
        XCTAssertGreaterThan(vault.entries.count, 0)
        XCTAssertTrue(vault.entries.contains { $0.title.range(of: "[A-Za-z]", options: .regularExpression) != nil })
        XCTAssertTrue(vault.entries.contains { $0.url.lowercased().hasPrefix("http") || !$0.username.isEmpty })
    }

    func testTOTPReferenceVector() throws {
        let settings = try XCTUnwrap(TOTP.parseOTPAuth("otpauth://totp/Example:ada?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Example&digits=8&period=30"))
        let date = Date(timeIntervalSince1970: 59)
        XCTAssertEqual(TOTP.code(settings: settings, at: date), "94287082")
        let six = OTPSettings(secret: settings.secret, digits: 6, period: 30)
        XCTAssertEqual(TOTP.code(settings: six, at: date), "287082")
    }
}
