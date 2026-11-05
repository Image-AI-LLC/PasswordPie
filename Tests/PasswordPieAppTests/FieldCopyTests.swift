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
        XCTAssertEqual(control.primary.title, "Open")
        XCTAssertEqual(control.menu, [.copy, .openAndFill])
        XCTAssertFalse(control.menu.contains(.open))
        XCTAssertEqual(FieldAction.copy.title, "Copy")
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

    func testFieldActionsShowOnHoverInThePopoverAndThePinnedWindow() {
        XCTAssertFalse(fieldActionsStayVisible(.popover))
        XCTAssertFalse(fieldActionsStayVisible(.pinned))
    }

    func testTrashedOrRemovedAccountLeavesThePinnedWindow() {
        var entry = VaultEntry()
        entry.title = "Bank"
        XCTAssertEqual(activePinnedEntry([entry], id: entry.id)?.id, entry.id)
        entry.trashed = true
        XCTAssertNil(activePinnedEntry([entry], id: entry.id))
        XCTAssertNil(activePinnedEntry([], id: entry.id))
    }

    func testPinnedWindowDoesNotKeepOptionRevealAfterTheAppResigns() {
        // Pinning while Option is already down must not show the secret. The popover still does.
        XCTAssertFalse(optionRevealHeld(after: .opened(presentation: .pinned, optionDown: true)))
        XCTAssertTrue(optionRevealHeld(after: .opened(presentation: .popover, optionDown: true)))
        XCTAssertFalse(optionRevealHeld(after: .opened(presentation: .popover, optionDown: false)))

        // Holding Option in the pinned window reveals it, until PasswordPie resigns.
        XCTAssertTrue(optionRevealHeld(after: .flagsChanged(optionDown: true)))
        XCTAssertFalse(optionRevealHeld(after: .flagsChanged(optionDown: false)))
        XCTAssertFalse(optionRevealHeld(after: .appResignedActive))

        // Coming back samples the key, so a release in the other app stays concealed.
        XCTAssertFalse(optionRevealHeld(after: .appBecameActive(optionDown: false)))
        XCTAssertTrue(optionRevealHeld(after: .appBecameActive(optionDown: true)))
    }

    func testOnlyTheCloseButtonDismissesAPinnedWindow() {
        XCTAssertFalse(pinnedWindowShouldClose(.resignKey))
        XCTAssertFalse(pinnedWindowShouldClose(.escape))
        XCTAssertFalse(pinnedWindowShouldClose(.commandW))
        XCTAssertTrue(pinnedWindowShouldClose(.closeButton))
    }

    func testCommandWIsNotAPinnedClose() {
        let commandW = keyEvent(characters: "w", modifiers: .command)
        let shifted = keyEvent(characters: "w", modifiers: [.command, .shift])
        XCTAssertTrue(pinnedEventIsCommandW(commandW))
        XCTAssertTrue(pinnedEventIsCommandW(shifted))
        XCTAssertFalse(pinnedEventIsCommandW(keyEvent(characters: "w", modifiers: [])))
        XCTAssertFalse(pinnedEventIsCommandW(keyEvent(characters: "q", modifiers: .command)))
    }

    func testEachAccountGetsItsOwnPinnedWindow() {
        let first = UUID()
        let second = UUID()
        XCTAssertEqual(pinnedWindowPlacement(openIDs: [], id: first), .openNew(index: 0))
        XCTAssertEqual(pinnedWindowPlacement(openIDs: [first], id: first), .orderFront)
        XCTAssertEqual(pinnedWindowPlacement(openIDs: [first], id: second), .openNew(index: 1))
    }

    func testNewPinnedWindowsCascadeDownLeft() {
        let size = CGSize(width: 400, height: 160)
        let first = pinnedWindowOrigin(visibleMaxX: 1400, visibleMaxY: 900, size: size, index: 0)
        let second = pinnedWindowOrigin(visibleMaxX: 1400, visibleMaxY: 900, size: size, index: 1)
        XCTAssertEqual(first, CGPoint(x: 1400 - 400 - 24, y: 900 - 160 - 24))
        XCTAssertEqual(second.x, first.x - 28)
        XCTAssertEqual(second.y, first.y - 28)
    }

    @MainActor
    func testPinnedPanelSitsOneLevelUnderTheMenuLikeADetached1PasswordMini() {
        let panel = PinnedEntryPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120))
        let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        XCTAssertEqual(panel.level, pinnedWindowLevel())
        XCTAssertEqual(panel.level.rawValue, menuLevel - 2)
        XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.floating.rawValue)
        XCTAssertLessThan(panel.level.rawValue, menuLevel - 1)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertTrue(panel.styleMask.contains(.closable))
        XCTAssertFalse(panel.styleMask.contains(.resizable))
        XCTAssertFalse(panel.isVisible)
    }
}

private func keyEvent(characters: String, modifiers: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: 13
    )!
}
