import AppKit
import XCTest
@testable import PasswordPie

/// PasswordPie is in the ⌘Tab switcher only while Preferences is open (docs/UX.md, "Preferences is in the app switcher").
@MainActor
final class SwitcherPresenceTests: XCTestCase {
    func testPreferencesPutsTheAppInTheSwitcher() {
        XCTAssertEqual(SwitcherPresence.policy(preferencesOpen: true), .regular)
    }

    func testWithoutPreferencesTheAppIsAMenuBarItemOnly() {
        XCTAssertEqual(SwitcherPresence.policy(preferencesOpen: false), .accessory)
    }

    func testThePolicyIsSetOnlyWhenItChanges() {
        var applied: [NSApplication.ActivationPolicy] = []
        var current = NSApplication.ActivationPolicy.accessory
        let presence = SwitcherPresence(current: { current }, apply: { applied.append($0); current = $0 })

        presence.sync(preferencesOpen: false)
        XCTAssertEqual(applied, [], "a menu or a pinned window opening changes nothing")

        presence.sync(preferencesOpen: true)
        presence.sync(preferencesOpen: true)
        XCTAssertEqual(applied, [.regular], "Preferences asked for again is already in the switcher")

        presence.sync(preferencesOpen: false)
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
