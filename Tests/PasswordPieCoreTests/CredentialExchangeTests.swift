import XCTest
@testable import PasswordPieCore

final class CredentialExchangeTests: XCTestCase {
    private func item(
        title: String = "GitHub",
        urls: [String] = ["https://github.com"],
        username: String? = "ann",
        password: String? = "pw1",
        totp: ExchangedItem.TOTPSecret? = nil,
        note: String? = nil
    ) -> ExchangedItem {
        ExchangedItem(title: title, urls: urls, username: username, password: password, totp: totp, note: note)
    }

    func testLoginBecomesAnEntryInTheAppleGroup() {
        let entries = BrowserImport.entries(fromExchange: [item(note: "work")], source: .applePasswords)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].title, "GitHub")
        XCTAssertEqual(entries[0].url, "https://github.com")
        XCTAssertEqual(entries[0].username, "ann")
        XCTAssertEqual(entries[0].password, "pw1")
        XCTAssertEqual(entries[0].notes, "work")
        XCTAssertEqual(entries[0].groupPath, ["Apple Passwords"])
        XCTAssertEqual(entries[0].tagList, ["Apple Passwords"])
    }

    func testItemWithoutAPasswordIsSkipped() {
        let entries = BrowserImport.entries(
            fromExchange: [item(password: nil), item(password: ""), item(title: "Keep", password: "x")],
            source: .applePasswords
        )
        XCTAssertEqual(entries.map(\.title), ["Keep"])
    }

    func testTOTPSecretBecomesAnOtpauthURL() {
        let secret = Data("Hello!\u{DE}\u{AD}\u{BE}\u{EF}".utf8)
        let totp = ExchangedItem.TOTPSecret(secret: secret, period: 30, digits: 6, algorithm: "sha1")
        let entries = BrowserImport.entries(fromExchange: [item(totp: totp)], source: .applePasswords)
        let settings = TOTP.parseOTPAuth(entries[0].otp)
        XCTAssertEqual(settings?.secret, secret)
        XCTAssertEqual(settings?.period, 30)
        XCTAssertEqual(settings?.digits, 6)
    }

    func testTOTPKeepsNonDefaultSettings() {
        let totp = ExchangedItem.TOTPSecret(secret: Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]), period: 60, digits: 8, algorithm: "sha256")
        let entries = BrowserImport.entries(fromExchange: [item(totp: totp)], source: .applePasswords)
        let settings = TOTP.parseOTPAuth(entries[0].otp)
        XCTAssertEqual(settings?.period, 60)
        XCTAssertEqual(settings?.digits, 8)
        XCTAssertEqual(settings?.algorithm, .sha256)
    }

    func testBase32EncodeRoundTrips() {
        for length in 1...20 {
            let data = Data((0..<length).map { UInt8(($0 * 37 + 11) & 0xff) })
            XCTAssertEqual(TOTP.base32Decode(TOTP.base32Encode(data)), data, "length \(length)")
        }
        XCTAssertEqual(TOTP.base32Encode(Data("foobar".utf8)), "MZXW6YTBOI")
    }

    func testEmptyTitleFallsBackToTheSiteName() {
        let entries = BrowserImport.entries(fromExchange: [item(title: "", urls: ["https://www.example.org/login"])], source: .applePasswords)
        XCTAssertEqual(entries[0].title, "example.org")
    }

    func testExchangedEntriesMergeLikeAnyOtherImport() {
        let first = BrowserImport.entries(fromExchange: [item()], source: .applePasswords)
        let second = BrowserImport.entries(fromExchange: [item(password: "changed")], source: .applePasswords)
        let one = BrowserImport.merge(first, into: [], source: .applePasswords)
        let two = BrowserImport.merge(second, into: one.entries, source: .applePasswords)
        XCTAssertEqual(two.summary.updated, 1)
        XCTAssertEqual(two.entries[0].password, "changed")
    }
}
