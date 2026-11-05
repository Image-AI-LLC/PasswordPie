import PasswordPieCore
import XCTest
@testable import PasswordPie

final class QuickAccessShortcutTests: XCTestCase {
    func testControlCommandCCopiesThePrimaryField() {
        XCTAssertEqual(quickAccessShortcut(press("c", command: true, control: true)), .copyPrimary)
        XCTAssertEqual(quickAccessShortcut(press("C", command: true, control: true)), .copyPrimary)
        XCTAssertNil(quickAccessShortcut(press("c", control: true)))
        XCTAssertNil(quickAccessShortcut(press("c", command: true, shift: true, control: true)))
    }

    func testPlainCommandCStaysATextCopy() {
        XCTAssertNil(quickAccessShortcut(press("c", command: true)))
        XCTAssertNil(quickAccessShortcut(press("c")))
    }

    func testCopyAndCutWithNothingSelectedLeaveTheClipboardAlone() {
        XCTAssertTrue(editCommandWouldEmptyClipboard(key: "c", selectionLength: 0))
        XCTAssertTrue(editCommandWouldEmptyClipboard(key: "x", selectionLength: 0))
        XCTAssertFalse(editCommandWouldEmptyClipboard(key: "c", selectionLength: 3))
        XCTAssertFalse(editCommandWouldEmptyClipboard(key: "v", selectionLength: 0))
        XCTAssertFalse(editCommandWouldEmptyClipboard(key: "c", selectionLength: nil))
    }

    func testShiftCommandCCopiesThePassword() {
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

    func testEachCopyShortcutPicksItsField() {
        var login = VaultEntry()
        login.username = "ada"
        XCTAssertEqual(quickAccessCopyTarget(.copyPrimary, of: login), .username)
        XCTAssertEqual(quickAccessCopyTarget(.copyPassword, of: login), .password)
        XCTAssertEqual(quickAccessCopyTarget(.copyOneTimePassword, of: login), .oneTimePassword)
        XCTAssertNil(quickAccessCopyTarget(.pinItem, of: login))
        XCTAssertNil(quickAccessCopyTarget(.openAndFill, of: login))
        XCTAssertNil(quickAccessCopyTarget(.fillFocusedApp, of: login))
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
    control: Bool = false
) -> QuickAccessKeyPress {
    QuickAccessKeyPress(
        key: key,
        command: command,
        shift: shift,
        option: option,
        control: control
    )
}
