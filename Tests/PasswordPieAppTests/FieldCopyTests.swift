import AppKit
import PasswordPieCore
import XCTest
@testable import PasswordPie

final class FieldCopyTests: XCTestCase {
    func testPlainFieldsCopyWithNoMenu() {
        let kinds: [DetailField.Kind] = [.username, .notes, .oneTimePassword, .custom("PIN")]
        for kind in kinds {
            let field = DetailField(id: "id", kind: kind, label: "label", value: "value", secret: false)
            XCTAssertEqual(fieldControl(field, revealed: false), FieldControl(primary: .copy, menu: []))
            XCTAssertEqual(fieldControl(field, revealed: true), FieldControl(primary: .copy, menu: []))
        }
    }

    func testPasswordMenuIsRevealAndLargeType() {
        let field = DetailField(id: "password", kind: .password, label: "password", value: "secret", secret: true)
        XCTAssertEqual(fieldControl(field, revealed: false), FieldControl(primary: .copy, menu: [.reveal, .largeType]))
        XCTAssertEqual(fieldControl(field, revealed: true), FieldControl(primary: .copy, menu: [.conceal, .largeType]))
        XCTAssertFalse(fieldControl(field, revealed: false).menu.contains(.open))
    }

    func testWebsiteOpensByDefaultAndCopiesFromTheMenu() {
        let field = DetailField(id: "url", kind: .url, label: "website", value: "https://example.com", secret: false)
        let control = fieldControl(field, revealed: false)
        XCTAssertEqual(control.primary, .open)
        XCTAssertEqual(control.primary.title, "open")
        XCTAssertEqual(control.menu, [.copy, .openAndFill])
        XCTAssertFalse(control.menu.contains(.open))
        XCTAssertEqual(FieldAction.copy.title, "copy")
        XCTAssertEqual(fieldControl(field, revealed: true), control)
    }

    func testPopoverClosesAfterCopyOrOpenButPinnedWindowDoesNot() {
        for action in [FieldAction.copy, .open, .openAndFill] {
            XCTAssertTrue(fieldActionClosesDetails(action, presentation: .popover), "\(action) closes the popover")
            XCTAssertFalse(fieldActionClosesDetails(action, presentation: .pinned), "\(action) leaves the pinned window up")
        }
        for action in [FieldAction.reveal, .conceal, .largeType] {
            XCTAssertFalse(fieldActionClosesDetails(action, presentation: .popover))
            XCTAssertFalse(fieldActionClosesDetails(action, presentation: .pinned))
        }
    }

    func testPinButtonIsOnlyInThePopover() {
        XCTAssertTrue(showsPinButton(.popover))
        XCTAssertFalse(showsPinButton(.pinned))
    }

    func testPinnedFieldActionsStayVisible() {
        XCTAssertFalse(fieldActionsStayVisible(.popover))
        XCTAssertTrue(fieldActionsStayVisible(.pinned))
    }

    func testTrashedOrRemovedAccountLeavesThePinnedWindow() {
        var entry = VaultEntry()
        entry.title = "Bank"
        XCTAssertEqual(activePinnedEntry([entry], id: entry.id)?.id, entry.id)
        entry.trashed = true
        XCTAssertNil(activePinnedEntry([entry], id: entry.id))
        XCTAssertNil(activePinnedEntry([], id: entry.id))
    }

    func testOnlyTheCloseButtonDismissesAPinnedWindow() {
        XCTAssertFalse(pinnedWindowShouldClose(.resignKey))
        XCTAssertFalse(pinnedWindowShouldClose(.escape))
        XCTAssertTrue(pinnedWindowShouldClose(.closeButton))
    }

    @MainActor
    func testPinnedPanelFloatsAboveNormalWindowsUntilClosed() {
        let panel = PinnedEntryPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120))
        XCTAssertEqual(panel.level, .floating)
        XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.normal.rawValue)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertTrue(panel.styleMask.contains(.closable))
        XCTAssertFalse(panel.styleMask.contains(.resizable))
        XCTAssertFalse(panel.isVisible)
    }
}
