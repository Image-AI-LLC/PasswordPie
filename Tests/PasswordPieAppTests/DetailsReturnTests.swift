import PasswordPieCore
import XCTest
@testable import PasswordPie

/// Return in an account's details fills from the username and password, the same as Return on the account's row.
@MainActor
final class DetailsReturnTests: XCTestCase {
    private func login() -> VaultEntry {
        var entry = VaultEntry()
        entry.title = "GitHub"
        entry.username = "ann"
        entry.password = "secret"
        entry.url = "https://github.com/login"
        entry.notes = "recovery codes in the safe"
        entry.fields.append(VaultField(key: "PIN", value: "1234"))
        return entry
    }

    func testOnlyTheUsernameAndPasswordFill() {
        let kinds: [DetailField.Kind] = [.username, .password]
        for kind in kinds {
            XCTAssertTrue(returnFillsAccount(DetailField(id: "id", kind: kind, label: "label", value: "v", secret: false)), "\(kind)")
        }
        let others: [DetailField.Kind] = [.url, .otherWebsite("URL2"), .oneTimePassword, .notes, .custom("PIN")]
        for kind in others {
            XCTAssertFalse(returnFillsAccount(DetailField(id: "id", kind: kind, label: "label", value: "v", secret: false)), "\(kind)")
        }
    }

    func testReturnOnThePasswordFillsInsteadOfCopying() async {
        let pasteboard = FakePasteboard()
        var fills = 0
        var closed = 0
        let session = VaultSession(pasteboard: pasteboard)
        let model = DetailsModel(entry: login(), session: session, done: { closed += 1 }, fill: { fills += 1 })
        XCTAssertEqual(model.fields[model.focused].kind, .password, "the details open on the password")
        model.activateFocused()
        let filled = await waitUntil(timeout: 2) { fills == 1 }
        XCTAssertTrue(filled)
        XCTAssertEqual(pasteboard.writes, [])
        XCTAssertEqual(closed, 0, "the fill closes the panel itself")
        withExtendedLifetime(session) {}
    }

    func testReturnOnTheUsernameFills() async throws {
        var fills = 0
        let session = VaultSession()
        let model = DetailsModel(entry: login(), session: session, done: {}, fill: { fills += 1 })
        model.focused = try XCTUnwrap(model.fields.firstIndex { $0.kind == .username })
        model.activateFocused()
        let filled = await waitUntil(timeout: 2) { fills == 1 }
        XCTAssertTrue(filled)
        withExtendedLifetime(session) {}
    }

    func testReturnOnAnotherFieldKeepsItsOwnAction() async throws {
        var fills = 0
        var closed = 0
        let session = VaultSession()
        let model = DetailsModel(entry: login(), session: session, done: { closed += 1 }, fill: { fills += 1 })
        model.focused = try XCTUnwrap(model.fields.firstIndex { $0.kind == .notes })
        model.activateFocused()
        let copied = await waitUntil(timeout: 2) { closed == 1 }
        XCTAssertTrue(copied, "notes copy, and copying closes the popover")
        XCTAssertEqual(fills, 0)
        withExtendedLifetime(session) {}
    }

    func testAnAccountWithNothingToFillStillCopiesThePassword() async {
        var closed = 0
        let session = VaultSession()
        let model = DetailsModel(entry: login(), session: session, done: { closed += 1 })
        model.activateFocused()
        let copied = await waitUntil(timeout: 2) { closed == 1 }
        XCTAssertTrue(copied)
        withExtendedLifetime(session) {}
    }
}
