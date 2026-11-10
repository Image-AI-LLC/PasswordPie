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
        var laidOut: CGSize?
        init(window: NSWindow) { rootWindow = window }
        func menuRootNeedsLayout(contentWidth: CGFloat, contentHeight: CGFloat) {
            laidOut = CGSize(width: contentWidth, height: contentHeight)
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

    /// The empty database's generator row, last in the menu.
    private func generatorIndex(_ menu: MenuController) -> Int {
        menu.root.rows.firstIndex { $0.kind == .generator }!
    }

    /// Down until the generator is selected, the way a user reaches it from the keyboard.
    private func selectGenerator(_ menu: MenuController) {
        while menu.root.selectedRow?.kind != .generator, menu.handle(.down) {
            if menu.root.list.selectedIndex == menu.root.rows.count - 1 { break }
        }
    }

    func testHoveringTheSelectedGeneratorOpensIt() async {
        let (_, menu, _) = makeMenu()
        menu.reset()
        selectGenerator(menu)
        let generator = generatorIndex(menu)
        XCTAssertEqual(menu.root.list.selectedIndex, generator, "the keyboard selected the generator without opening it")
        XCTAssertEqual(menu.levels.count, 1)

        menu.menuList(menu.root.list, pointerMovedTo: generator)
        XCTAssertEqual(menu.levels.count, 1, "the generator waits for the pointer to rest")
        await wait(0.4)
        XCTAssertEqual(menu.levels.count, 2)
        guard case .generator = menu.deepest.content else { return XCTFail("the generator opens") }
        XCTAssertEqual(menu.deepest.parentIndex, generator)
    }

    func testHoveringTheGeneratorInLastPlaceOpensIt() async {
        let (_, menu, _) = makeMenu()
        menu.reset()
        let generator = generatorIndex(menu)
        XCTAssertEqual(generator, menu.root.rows.count - 1, "an empty database lists the generator last")
        XCTAssertNotEqual(menu.root.list.selectedIndex, generator)

        menu.menuList(menu.root.list, pointerMovedTo: generator)
        XCTAssertEqual(menu.root.list.selectedIndex, generator)
        XCTAssertEqual(menu.levels.count, 1, "the generator waits for the pointer to rest")
        await wait(0.4)
        XCTAssertEqual(menu.levels.count, 2)
        guard case .generator = menu.deepest.content else { return XCTFail("the generator opens") }
        XCTAssertEqual(menu.deepest.parentIndex, generator)
        menu.closeAll()
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
        selectGenerator(menu)
        let generator = generatorIndex(menu)
        XCTAssertTrue(menu.handle(.right), "Right opens the generator")
        XCTAssertEqual(menu.levels.count, 2)
        let child = menu.deepest
        let childWindow = child.window

        for _ in 0..<3 { menu.menuList(menu.root.list, pointerMovedTo: generator) }
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

        XCTAssertEqual(menu.root.selectedRow?.title, "Import Passwords…", "the showing selects the first action")
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

    // MARK: Get Started

    private var emptyTitles: [String] {
        var titles = ["Get Started", "Import Passwords…"]
        if AppChannel.current == .direct { titles.append("Sync Chrome Passwords…") }
        return titles + ["New Item…", "", "Password Generator"]
    }

    func testTheEmptyMenuIsTallActionRowsThenTheGenerator() {
        let (_, menu, host) = makeMenu()
        menu.reset()
        let rows = menu.root.rows
        XCTAssertEqual(rows.map(\.title), emptyTitles)
        let actions = rows.filter { if case .action = $0.kind { return true } else { return false } }
        XCTAssertEqual(actions.count, AppChannel.current == .direct ? 3 : 2)
        for index in rows.indices {
            let expected: CGFloat
            switch rows[index].kind {
            case .header: expected = 16
            case .action: expected = 42
            case .separator: expected = 11
            default: expected = 21
            }
            XCTAssertEqual(menu.root.list.rect(of: index).height, expected, rows[index].title)
        }
        XCTAssertEqual(menu.root.list.contentHeight, 16 + 42 * CGFloat(actions.count) + 11 + 21)
        XCTAssertEqual(host.laidOut, CGSize(width: 300, height: 16 + 42 * CGFloat(actions.count) + 11 + 21), "the panel is as tall as its rows, 300 wide")
    }

    func testOrdinaryRowsKeepTheirHeight() {
        for row in [
            MenuRow(kind: .generator, title: "Password Generator", icon: .generator),
            MenuRow(kind: .submenu, title: "Logins", category: .login),
            MenuRow(kind: .entry(UUID()), title: "GitHub"),
            MenuRow(kind: .showMore, title: "Show 2 more items"),
            MenuRow(kind: .disabled, title: "No items found"),
            MenuRow(kind: .action(.newItem), title: "New Item…")
        ] {
            XCTAssertEqual(MenuListView.height(of: row), 21, row.title)
        }
        XCTAssertEqual(MenuListView.height(of: MenuRow(kind: .header, title: "Open Login")), 16)
    }

    func testArrowKeysWalkTheActionsAndTheGenerator() {
        let (_, menu, _) = makeMenu()
        menu.reset()
        var visited = [menu.root.selectedRow?.title ?? ""]
        while menu.root.list.selectedIndex != menu.root.rows.count - 1 {
            XCTAssertTrue(menu.handle(.down))
            visited.append(menu.root.selectedRow?.title ?? "")
            if visited.count > 10 { break }
        }
        XCTAssertEqual(visited, emptyTitles.filter { !["Get Started", ""].contains($0) })
        XCTAssertTrue(menu.handle(.down))
        XCTAssertEqual(menu.root.selectedRow?.title, "Password Generator", "the generator is the end")
        for _ in 0..<5 { _ = menu.handle(.up) }
        XCTAssertEqual(menu.root.selectedRow?.title, "Import Passwords…", "Up stops at the first action, not the header")
    }

    func testHoveringAnActionRowSelectsItAndOpensNothing() async {
        let (_, menu, host) = makeMenu()
        menu.reset()
        let newItem = menu.root.rows.firstIndex { $0.title == "New Item…" }!
        menu.menuList(menu.root.list, pointerMovedTo: newItem)
        XCTAssertEqual(menu.root.list.selectedIndex, newItem)
        await wait(0.4)
        XCTAssertEqual(menu.levels.count, 1)
        XCTAssertFalse(menu.popoverIsOpen)
        XCTAssertEqual(host.performed, [], "hover never runs an action")
        // Back on the first action, which the showing selected: still nothing opens.
        menu.menuList(menu.root.list, pointerMovedTo: 1)
        await wait(0.4)
        XCTAssertEqual(menu.levels.count, 1)
        XCTAssertEqual(host.performed, [])
    }

    func testSiteRowsStillComeFirstAndHoldTheSelection() {
        let (_, menu, _) = makeMenu()
        let id = UUID()
        menu.siteSection = {
            [MenuRow(kind: .header, title: "github.com"), MenuRow(kind: .entry(id), title: "GitHub"), .separator]
        }
        menu.reset()
        XCTAssertEqual(Array(menu.root.rows.map(\.title).prefix(4)), ["github.com", "GitHub", "", "Get Started"])
        XCTAssertEqual(menu.root.selectedRow?.entryID, id)
    }

    func testTheFirstEntryBringsBackTheUsualMenu() {
        let (_, menu, _) = makeMenu(entries: [login("GitHub")])
        menu.reset()
        XCTAssertEqual(menu.root.rows.first?.title, "Password Generator")
        XCTAssertFalse(menu.root.rows.contains { $0.title == "Get Started" })
        XCTAssertTrue(menu.root.rows.allSatisfy { MenuListView.height(of: $0) <= 21 })
    }

    func testWidthCountsTheSecondLine() {
        let title = MenuRow(kind: .action(.newItem), title: "New Item…", detail: "")
        var long = title
        long.detail = String(repeating: "A login, password or secure note ", count: 3)
        let detailWidth = MenuListView.textWidth(long.detail, MenuMetrics.detailFont)
        XCTAssertGreaterThan(MenuListView.preferredWidth(of: [long]), MenuListView.preferredWidth(of: [title]))
        XCTAssertGreaterThanOrEqual(MenuListView.preferredWidth(of: [long]), MenuMetrics.actionTextX + detailWidth + 12)
        XCTAssertGreaterThanOrEqual(
            MenuListView.preferredWidth(of: [long]),
            MenuMetrics.actionTextX + MenuListView.textWidth(long.title, MenuMetrics.actionTitleFont) + 12
        )
    }

    func testEveryLineFitsTheDefaultWidth() {
        for channel in [AppChannel.direct, .appStore] {
            let rows = MenuBuilder.topLevel(entries: [], channel: channel)
            XCTAssertLessThanOrEqual(MenuListView.preferredWidth(of: rows), MenuGeometry.rootWidth, "nothing is cut at 300 pt")
        }
    }

    func testVoiceOverReadsTheTitleThenTheLine() throws {
        let (_, menu, _) = makeMenu()
        menu.reset()
        let elements = try XCTUnwrap(menu.root.list.accessibilityChildren() as? [NSAccessibilityElement])
        let labels = elements.compactMap { $0.accessibilityLabel() }
        XCTAssertTrue(labels.contains("Import Passwords…, From a Chrome or Apple Passwords export"), "\(labels)")
        XCTAssertTrue(labels.contains("New Item…, A login, password or secure note"), "\(labels)")
        XCTAssertTrue(labels.contains("Password Generator"), "an ordinary row reads its title")
        let selected = elements.filter { $0.isAccessibilitySelected() }.compactMap { $0.accessibilityLabel() }
        XCTAssertEqual(selected, ["Import Passwords…, From a Chrome or Apple Passwords export"])
    }
}
