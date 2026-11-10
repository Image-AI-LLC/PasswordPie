import AppKit
import PasswordPieCore
import XCTest
@testable import PasswordPie

/// Hover opens the row under the pointer, also when the keyboard (or a fresh showing) selected that row first.
@MainActor
final class MenuHoverTests: XCTestCase {
    private var directory: URL!
    private var window: NSWindow!
    /// `MenuController` holds its session unowned.
    private var session: VaultSession?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("PASSWORDPIE_DB", directory.appendingPathComponent("test.kdbx").path, 1)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
    }

    override func tearDownWithError() throws {
        window?.orderOut(nil)
        window = nil
        session = nil
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        try? FileManager.default.removeItem(at: directory)
    }

    private final class Host: MenuHost {
        let rootWindow: NSWindow
        var performed: [MenuAction] = []
        var hidden = 0
        init(window: NSWindow) { rootWindow = window }
        func menuRootNeedsLayout(contentWidth: CGFloat, contentHeight: CGFloat) {
            rootWindow.setContentSize(NSSize(width: contentWidth, height: contentHeight))
        }
        func menuHide() { hidden += 1 }
        func menuPerform(_ action: MenuAction) { performed.append(action) }
    }

    /// A session on a new database, with `entries` saved into it, and a controller whose root list lives in a window
    /// (a popover needs its row to be in one).
    private func makeMenu(entries: [VaultEntry] = []) -> (VaultSession, MenuController, Host) {
        let session = VaultSession()
        session.restore()
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        for entry in entries { session.saveEditing(entry) }
        self.session = session
        window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = Host(window: window)
        let menu = MenuController(session: session)
        menu.host = host
        menu.root.scroll.frame = window.contentView!.bounds
        window.contentView!.addSubview(menu.root.scroll)
        window.orderFront(nil)
        return (session, menu, host)
    }

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func login(_ title: String) -> VaultEntry {
        var entry = VaultEntry(groupPath: ["Sites"])
        entry.title = title
        entry.username = "me"
        entry.password = "pw-\(title)"
        entry.url = "https://\(title.lowercased()).example.com"
        return entry
    }

    func testHoveringTheSelectedGeneratorOpensIt() async {
        let (_, menu, _) = makeMenu()
        menu.reset()
        XCTAssertEqual(menu.root.selectedRow?.title, "Password Generator", "a fresh showing selects the first row")

        menu.menuList(menu.root.list, pointerMovedTo: 0)
        XCTAssertEqual(menu.levels.count, 1, "the generator waits for the pointer to rest")
        await wait(0.4)
        XCTAssertEqual(menu.levels.count, 2)
        guard case .generator = menu.deepest.content else { return XCTFail("the generator opens") }
        XCTAssertEqual(menu.deepest.parentIndex, 0)
    }

    func testHoveringTheSelectedSubmenuOpensIt() async {
        var favorite = login("GitHub")
        favorite.favorite = true
        let (_, menu, _) = makeMenu(entries: [favorite])
        menu.reset()
        XCTAssertEqual(menu.root.selectedRow?.title, "Favorites")

        menu.menuList(menu.root.list, pointerMovedTo: 0)
        await wait(0.4)
        XCTAssertEqual(menu.levels.count, 2)
        XCTAssertEqual(menu.deepest.rows.map(\.title), ["GitHub"])
        XCTAssertNil(menu.deepest.list.selectedIndex, "a hover opens without selecting inside")
    }

    func testAnOpenChildStaysOpenWhenThePointerMovesOnItsRow() async {
        let (_, menu, _) = makeMenu()
        menu.reset()
        XCTAssertTrue(menu.handle(.right), "Right opens the generator")
        XCTAssertEqual(menu.levels.count, 2)
        let child = menu.deepest
        let childWindow = child.window

        for _ in 0..<3 { menu.menuList(menu.root.list, pointerMovedTo: 0) }
        await wait(0.4)
        XCTAssertEqual(menu.levels.count, 2)
        XCTAssertTrue(menu.deepest === child, "the open child is neither closed nor reopened")
        XCTAssertTrue(childWindow?.isVisible ?? false)
    }

    func testHoveringASelectedEntryShowsItsDetails() async {
        let entry = login("GitHub")
        let (_, menu, _) = makeMenu(entries: [entry])
        // The browser's site section puts the account first, so the showing selects it.
        menu.siteSection = { [MenuRow(kind: .entry(entry.id), title: entry.title)] }
        menu.reset()
        XCTAssertEqual(menu.root.selectedRow?.entryID, entry.id)

        menu.menuList(menu.root.list, pointerMovedTo: 0)
        XCTAssertFalse(menu.popoverIsOpen, "the first details since launch wait 0.7 s")
        await wait(1.0)
        XCTAssertTrue(menu.popoverIsOpen)
        XCTAssertEqual(menu.selectedTitle, "GitHub")

        // Moving on the same row keeps the details as they are.
        menu.menuList(menu.root.list, pointerMovedTo: 0)
        await wait(0.2)
        XCTAssertTrue(menu.popoverIsOpen)
        menu.closeAll()
    }

    func testEmptyDatabaseActionsRunFromReturnAndClick() async {
        let (_, menu, host) = makeMenu()
        menu.reset()
        let titles = menu.root.rows.map { $0.kind == .separator ? "-" : $0.title }
        XCTAssertEqual(titles, MenuBuilder.topLevel(entries: []).map { $0.kind == .separator ? "-" : $0.title })
        XCTAssertTrue(titles.contains("Import Passwords…"))

        // Down from the generator skips the separator and the hint.
        XCTAssertTrue(menu.handle(.down))
        XCTAssertEqual(menu.root.selectedRow?.title, "Import Passwords…")
        XCTAssertFalse(menu.handle(.right), "an action row has no submenu")
        XCTAssertEqual(menu.levels.count, 1)
        XCTAssertTrue(menu.handle(.enter))
        await wait(0.4)
        XCTAssertEqual(host.performed, [.importPasswords])

        guard let newItem = menu.root.rows.firstIndex(where: { $0.title == "New Item…" }) else {
            return XCTFail("the empty menu offers New Item…")
        }
        menu.menuList(menu.root.list, pressed: newItem)
        menu.menuList(menu.root.list, released: newItem)
        await wait(0.4)
        XCTAssertEqual(host.performed, [.importPasswords, .newItem])
    }
}
