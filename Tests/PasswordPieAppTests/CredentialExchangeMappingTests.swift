import AuthenticationServices
import PasswordPieCore
import XCTest
@testable import PasswordPie

@available(macOS 26.0, *)
@MainActor
final class CredentialExchangeMappingTests: XCTestCase {
    private func field(_ value: String) -> ASImportableEditableField {
        ASImportableEditableField(id: nil, fieldType: .string, value: value)
    }

    private func exported(_ items: [ASImportableItem]) -> ASExportedCredentialData {
        let account = ASImportableAccount(id: Data([1]), userName: "ann", email: "ann@example.com", collections: [], items: items)
        return ASExportedCredentialData(
            accounts: [account], formatVersion: .v1, exporterRelyingPartyIdentifier: "com.apple.passwords",
            exporterDisplayName: "Passwords", timestamp: Date(timeIntervalSince1970: 0)
        )
    }

    func testLoginWithCodeAndNoteIsMapped() {
        let item = ASImportableItem(
            id: Data([2]), created: Date(timeIntervalSince1970: 0), lastModified: Date(timeIntervalSince1970: 0), title: "GitHub",
            scope: ASImportableCredentialScope(urls: [URL(string: "https://github.com")!]),
            credentials: [
                .basicAuthentication(.init(userName: field("ann"), password: field("pw1"))),
                .totp(.init(secret: Data([1, 2, 3, 4, 5]), period: 30, digits: 6, userName: nil, algorithm: .sha1)),
                .note(.init(content: field("work")))
            ]
        )
        let mapped = VaultSession.exchangedItems(from: exported([item]))
        XCTAssertEqual(mapped.count, 1)
        XCTAssertEqual(mapped[0].title, "GitHub")
        XCTAssertEqual(mapped[0].urls, ["https://github.com"])
        XCTAssertEqual(mapped[0].username, "ann")
        XCTAssertEqual(mapped[0].password, "pw1")
        XCTAssertEqual(mapped[0].note, "work")
        XCTAssertEqual(mapped[0].totp?.secret, Data([1, 2, 3, 4, 5]))
        XCTAssertEqual(mapped[0].totp?.algorithm, "sha1")
    }

    func testNonLoginItemsHaveNoPassword() {
        let item = ASImportableItem(id: Data([3]), created: Date(timeIntervalSince1970: 0), lastModified: Date(timeIntervalSince1970: 0), title: "Wi-Fi", credentials: [.note(.init(content: field("x")))])
        let entries = BrowserImport.entries(fromExchange: VaultSession.exchangedItems(from: exported([item])), source: .applePasswords)
        XCTAssertTrue(entries.isEmpty)
    }
}
