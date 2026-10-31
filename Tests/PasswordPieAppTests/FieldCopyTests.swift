import XCTest
@testable import PasswordPie

final class FieldCopyTests: XCTestCase {
    func testPlainFieldsCopyWithNoMenu() {
        let kinds: [DetailField.Kind] = [.username, .notes, .oneTimePassword, .custom("PIN")]
        for kind in kinds {
            let field = DetailField(id: "id", kind: kind, label: "label", value: "value", secret: false)
            XCTAssertNil(fieldCopyMenu(field, revealed: false))
            XCTAssertNil(fieldCopyMenu(field, revealed: true))
        }
    }

    func testPasswordMenuIsRevealAndLargeType() {
        let field = DetailField(id: "password", kind: .password, label: "password", value: "secret", secret: true)
        XCTAssertEqual(fieldCopyMenu(field, revealed: false), [.reveal, .largeType])
        XCTAssertEqual(fieldCopyMenu(field, revealed: true), [.conceal, .largeType])
        XCTAssertFalse(fieldCopyMenu(field, revealed: false)!.contains(.open))
    }

    func testWebsiteMenuIsOpenActions() {
        let field = DetailField(id: "url", kind: .url, label: "website", value: "https://example.com", secret: false)
        XCTAssertEqual(fieldCopyMenu(field, revealed: false), [.openAndFill, .open])
    }
}
