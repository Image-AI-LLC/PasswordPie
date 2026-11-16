import AppKit
import PasswordPieCore
import XCTest
@testable import PasswordPie

/// The menu has to be above another app's modal dialog (a sign-in window), and under PasswordPie's own.
@MainActor
final class PanelLevelTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("level-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("PASSWORDPIE_DB", directory.appendingPathComponent("test.kdbx").path, 1)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testTheMenuLevelIsAboveModalDialogsAndPinnedWindowsAndUnderTheMenuBar() {
        let level = PanelLevel.level(ownDialogOpen: false)
        XCTAssertEqual(level, menuWindowLevel)
        XCTAssertGreaterThan(level.rawValue, NSWindow.Level.modalPanel.rawValue)
        XCTAssertGreaterThan(level.rawValue, pinnedWindowLevel().rawValue)
        XCTAssertLessThan(level.rawValue, NSWindow.Level.mainMenu.rawValue)
    }

    func testTheMenuGoesUnderPasswordPiesOwnDialogs() {
        let level = PanelLevel.level(ownDialogOpen: true)
        XCTAssertLessThan(level.rawValue, NSWindow.Level.modalPanel.rawValue)
        XCTAssertGreaterThan(level.rawValue, NSWindow.Level.normal.rawValue)
    }

    func testThePanelIsBuiltAtTheMenuLevel() {
        // Not shown: this is the level the panel is made with, before anything else can set it.
        let session = VaultSession(writes: .inline)
        session.restore()
        let panel = PanelController(session: session)
        // `isFloatingPanel = true` puts a panel back at the floating level, under every modal dialog.
        XCTAssertEqual(panel.rootWindow.level, menuWindowLevel)
        XCTAssertTrue((panel.rootWindow as? NSPanel)?.isFloatingPanel ?? false)
        XCTAssertFalse(panel.rootWindow.hidesOnDeactivate)
    }

    func testThePanelIsStillAtTheMenuLevelOnceShown() throws {
        let (_, panel) = try openPanel()
        defer { panel.hide() }
        XCTAssertEqual(panel.rootWindow.level, menuWindowLevel)
    }

    func testASubmenuIsAtTheMenuLevel() throws {
        var favorite = VaultEntry()
        favorite.title = "GitHub"
        favorite.favorite = true
        let (_, panel) = try openPanel(entries: [favorite])
        defer { panel.hide() }
        panel.menu.debugOpen(path: ["Favorites"])
        XCTAssertEqual(panel.menu.levels.count, 2)
        let submenu = try XCTUnwrap(panel.menu.deepest.window)
        XCTAssertEqual(submenu.level, menuWindowLevel)
        XCTAssertFalse(submenu.hidesOnDeactivate)
    }

    func testThePanelAndItsSubmenusGoUnderPasswordPiesOwnDialogAndComeBack() throws {
        var favorite = VaultEntry()
        favorite.title = "GitHub"
        favorite.favorite = true
        let (_, panel) = try openPanel(entries: [favorite])
        defer { panel.hide() }
        panel.menu.debugOpen(path: ["Favorites"])
        let submenu = try XCTUnwrap(panel.menu.deepest.window)

        let during = panel.keepOpen { (panel.rootWindow.level, submenu.level) }

        XCTAssertEqual(during.0, PanelLevel.level(ownDialogOpen: true))
        XCTAssertEqual(during.1, PanelLevel.level(ownDialogOpen: true))
        XCTAssertEqual(panel.rootWindow.level, menuWindowLevel)
        XCTAssertEqual(submenu.level, menuWindowLevel)
    }

    func testTheDetailsPopoverFollowsThePanel() throws {
        var entry = VaultEntry()
        entry.title = "GitHub"
        entry.username = "first"
        let (_, panel) = try openPanel(entries: [entry])
        defer { panel.hide() }
        panel.header.searchField.stringValue = "github"
        panel.headerSearchChanged("github")
        _ = panel.headerKey(.right)
        let popover = try XCTUnwrap(panel.menu.popoverWindow)
        XCTAssertGreaterThanOrEqual(popover.level.rawValue, menuWindowLevel.rawValue)

        let during = panel.keepOpen { popover.level }

        XCTAssertLessThan(during.rawValue, NSWindow.Level.modalPanel.rawValue)
        XCTAssertGreaterThanOrEqual(popover.level.rawValue, menuWindowLevel.rawValue)
    }

    func testNestedDialogsBringThePanelBackOnlyAfterTheLastOne() throws {
        let (_, panel) = try openPanel()
        defer { panel.hide() }
        panel.keepOpen {
            panel.keepOpen {}
            XCTAssertEqual(panel.rootWindow.level, PanelLevel.level(ownDialogOpen: true))
        }
        XCTAssertEqual(panel.rootWindow.level, menuWindowLevel)
    }

    func testAMenuThatPopsUpFromThePanelLeavesItOnTop() throws {
        let (_, panel) = try openPanel()
        defer { panel.hide() }
        // The gear menu is not a dialog: over another app's sign-in window the panel must not drop behind it.
        let during = panel.keepOpen(underDialog: false) { panel.rootWindow.level }
        XCTAssertEqual(during, menuWindowLevel)
    }

    private func openPanel(entries: [VaultEntry] = []) throws -> (VaultSession, PanelController) {
        try XCTSkipIf(NSScreen.screens.isEmpty, "the panel needs a screen to become visible")
        let session = VaultSession(writes: .inline)
        session.restore()
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        session.entries = entries
        let panel = PanelController(session: session)
        panel.show(.hotkey)
        return (session, panel)
    }
}
