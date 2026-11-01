import PasswordPieCore
import XCTest
@testable import PasswordPie

final class QuickAccessShortcutTests: XCTestCase {
    func testCommandCCopiesThePrimaryFieldUnlessSearchTextIsSelected() {
        XCTAssertEqual(quickAccessShortcut(press("c", command: true)), .copyPrimary)
        XCTAssertNil(quickAccessShortcut(press("c", command: true, searchTextIsSelected: true)))
        XCTAssertNil(quickAccessShortcut(press("c")))
    }

    func testShiftCommandCCopiesThePasswordEvenWhenSearchTextIsSelected() {
        let selected = press("c", command: true, shift: true, searchTextIsSelected: true)
        XCTAssertEqual(quickAccessShortcut(selected), .copyPassword)
        XCTAssertEqual(quickAccessShortcut(press("c", command: true, shift: true)), .copyPassword)
    }

    func testOptionCommandCCopiesTheOneTimePassword() {
        XCTAssertEqual(quickAccessShortcut(press("c", command: true, option: true)), .copyOneTimePassword)
        XCTAssertNil(quickAccessShortcut(press("c", command: true, option: true, control: true)))
        XCTAssertNil(quickAccessShortcut(press("c", command: true, shift: true, option: true)))
    }

    func testCommandOPinsTheItemWindow() {
        XCTAssertEqual(quickAccessShortcut(press("o", command: true)), .pinItem)
        XCTAssertEqual(quickAccessShortcut(press("O", command: true)), .pinItem)
        XCTAssertNil(quickAccessShortcut(press("o", command: true, shift: true)))
        XCTAssertNil(quickAccessShortcut(press("o", command: true, option: true)))
    }

    func testModifiedReturnFillsOrOpens() {
        XCTAssertEqual(quickAccessShortcut(press("\r", option: true)), .openAndFill)
        XCTAssertEqual(quickAccessShortcut(press("\n", shift: true)), .fillFocusedApp)
        XCTAssertNil(quickAccessShortcut(press("\r")))
        XCTAssertNil(quickAccessShortcut(press("\r", shift: true, option: true)))
        XCTAssertNil(quickAccessShortcut(press("\r", command: true)))
        XCTAssertNil(quickAccessShortcut(press("\r", control: true)))
    }

    func testAccountAppAndZoomShortcutsStayOutOfQuickAccess() {
        for key in ["1", "2", "9", "e", "n", "=", "-", "0", "w"] {
            XCTAssertNil(quickAccessShortcut(press(key, command: true)), key)
        }
        XCTAssertNil(quickAccessShortcut(press("o", command: true, shift: true)))
    }

    func testEscapeClearsAQueryAndClosesWhenTheFieldIsEmpty() {
        XCTAssertEqual(quickAccessEscape(searchIsEmpty: false), .clearSearch)
        XCTAssertEqual(quickAccessEscape(searchIsEmpty: true), .close)
    }

    func testPrimaryCopyPrefersUsernameThenPasswordThenTheNextField() {
        var login = VaultEntry()
        login.username = "ada"
        login.password = "secret"
        login.url = "https://example.com"
        XCTAssertEqual(quickAccessPrimaryCopy(login), .username)

        var passwordOnly = VaultEntry()
        passwordOnly.password = "secret"
        XCTAssertEqual(quickAccessPrimaryCopy(passwordOnly), .password)

        var site = VaultEntry()
        site.url = "https://example.com"
        XCTAssertEqual(quickAccessPrimaryCopy(site), .url)

        var card = VaultEntry()
        card.notes = "note"
        card.fields.append(VaultField(key: "Number", value: "4242"))
        XCTAssertEqual(quickAccessPrimaryCopy(card), .custom("Number"))

        var note = VaultEntry()
        note.notes = "remember the gate code"
        XCTAssertEqual(quickAccessPrimaryCopy(note), .notes)
    }

    func testPrimaryCopySkipsOneTimePasswordsAndReservedKeys() {
        var otp = VaultEntry()
        otp.otp = "otpauth://totp/Example?secret=JBSWY3DPEHPK3PXP"
        XCTAssertNil(quickAccessPrimaryCopy(otp))

        var reserved = VaultEntry()
        reserved.fields.append(VaultField(key: EntryMerge.keepSeparateKey, value: "1"))
        reserved.fields.append(VaultField(key: EntryMerge.manifestKey, value: "{}"))
        XCTAssertNil(quickAccessPrimaryCopy(reserved))
    }
}

private func press(
    _ key: String,
    command: Bool = false,
    shift: Bool = false,
    option: Bool = false,
    control: Bool = false,
    searchTextIsSelected: Bool = false
) -> QuickAccessKeyPress {
    QuickAccessKeyPress(
        key: key,
        command: command,
        shift: shift,
        option: option,
        control: control,
        searchTextIsSelected: searchTextIsSelected
    )
}
