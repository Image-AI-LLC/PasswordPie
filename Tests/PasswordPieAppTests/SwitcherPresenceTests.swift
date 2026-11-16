import AppKit
import XCTest
@testable import PasswordPie

/// PasswordPie is in the ⌘Tab switcher only while Preferences is open (docs/UX.md, "Preferences is in the app switcher").
@MainActor
final class SwitcherPresenceTests: XCTestCase {
    func testPreferencesPutsTheAppInTheSwitcher() {
        XCTAssertEqual(SwitcherPresence.policy(preferencesOpen: true, otherWindowOpen: false, current: .accessory), .regular)
        XCTAssertEqual(SwitcherPresence.policy(preferencesOpen: true, otherWindowOpen: true, current: .regular), .regular)
    }

    func testWithoutPreferencesTheAppIsAMenuBarItemOnly() {
        XCTAssertEqual(SwitcherPresence.policy(preferencesOpen: false, otherWindowOpen: false, current: .accessory), .accessory)
        XCTAssertEqual(SwitcherPresence.policy(preferencesOpen: false, otherWindowOpen: false, current: .regular), .accessory)
    }

    func testTheEditorAloneDoesNotPutTheAppInTheSwitcher() {
        XCTAssertEqual(SwitcherPresence.policy(preferencesOpen: false, otherWindowOpen: true, current: .accessory), .accessory)
    }

    func testClosingPreferencesWaitsForTheWindowOpenedBesideIt() {
        // Leaving the switcher gives the keyboard to the app behind: an editor still open would drop behind that app.
        XCTAssertEqual(SwitcherPresence.policy(preferencesOpen: false, otherWindowOpen: true, current: .regular), .regular)
    }

    func testThePolicyIsSetOnlyWhenItChanges() {
        var applied: [NSApplication.ActivationPolicy] = []
        var current = NSApplication.ActivationPolicy.accessory
        let presence = SwitcherPresence(current: { current }, apply: { applied.append($0); current = $0 })

        presence.sync(preferencesOpen: false, otherWindowOpen: false)
        presence.sync(preferencesOpen: false, otherWindowOpen: true)
        XCTAssertEqual(applied, [], "a menu, a pinned window or the editor opening changes nothing")

        presence.sync(preferencesOpen: true, otherWindowOpen: false)
        presence.sync(preferencesOpen: true, otherWindowOpen: false)
        XCTAssertEqual(applied, [.regular], "Preferences asked for again is already in the switcher")

        // The editor opens beside Preferences, Preferences closes, then the editor closes.
        presence.sync(preferencesOpen: true, otherWindowOpen: true)
        presence.sync(preferencesOpen: false, otherWindowOpen: true)
        XCTAssertEqual(applied, [.regular], "the editor is still open")
        presence.sync(preferencesOpen: false, otherWindowOpen: false)
        XCTAssertEqual(applied, [.regular, .accessory])
    }

    func testTheMenuAndAPinnedWindowAreNotWindowsToSwitchTo() {
        // Neither can be the main window, so neither is what ⌘Tab would bring forward.
        let pinned = PinnedEntryPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160))
        XCTAssertFalse(pinned.canBecomeMain)
        XCTAssertFalse(pinned.canBecomeKey)
        XCTAssertTrue(pinned.styleMask.contains(.nonactivatingPanel))
    }
}
