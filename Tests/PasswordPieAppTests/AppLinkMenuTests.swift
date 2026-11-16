import AppKit
@testable import PasswordPieCore
import XCTest
@testable import PasswordPie

/// The app's group at the top of the menu, and Return on one of its accounts.
@MainActor
final class AppLinkMenuTests: XCTestCase {
    private var directory: URL!
    private var window: NSWindow!
    private var session: VaultSession!
    private let harbor = LinkedApp(bundleID: "example.harbor", teamID: "TEAM123456", name: "Harbor")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("applinkmenu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("PASSWORDPIE_DB", directory.appendingPathComponent("test.kdbx").path, 1)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
    }

    override func tearDownWithError() throws {
        window?.close()
        window = nil
        session = nil
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        try? FileManager.default.removeItem(at: directory)
    }

    private final class Host: MenuHost {
        let rootWindow: NSWindow
        var menuLinkableApp: LinkedApp?
        var copied: [UUID] = []
        init(window: NSWindow) { rootWindow = window }
        func menuRootNeedsLayout(contentWidth: CGFloat, contentHeight: CGFloat) {}
        func menuHide() {}
        func menuPerform(_ action: MenuAction) {}
        func menuCopyPrimary(of id: UUID) { copied.append(id) }
    }

    private func makeMenu(front: LinkedApp?) throws -> (MenuController, Host, UUID) {
        let session = VaultSession(pasteboard: FakePasteboard(), writes: .inline)
        session.restore()
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        var entry = VaultEntry(groupPath: ["Work"])
        entry.title = "Northwind SSO"
        entry.username = "ada@northwind.example"
        entry.password = "secret"
        entry.url = "https://sso.northwind.example"
        AppLinks.link(harbor, to: &entry)
        session.saveEditing(entry)
        self.session = session
        let id = try XCTUnwrap(session.entries.first { $0.title == "Northwind SSO" }?.id)
        window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = Host(window: window)
        host.menuLinkableApp = front
        let menu = MenuController(session: session)
        menu.host = host
        menu.siteSection = { [weak session] in
            guard let session, let front else { return [] }
            return MenuBuilder.appRows(app: front, entries: session.appEntries(for: front), sources: session.entrySources)
        }
        menu.root.scroll.frame = window.contentView!.bounds
        window.contentView!.addSubview(menu.root.scroll)
        window.orderFront(nil)
        return (menu, host, id)
    }

    func testOverTheLinkedAppItsGroupIsFirstAndItsAccountSelected() throws {
        let (menu, _, id) = try makeMenu(front: harbor)
        menu.reset()
        XCTAssertEqual(menu.root.rows.first?.kind, .header)
        XCTAssertEqual(menu.root.rows.first?.title, "Harbor")
        XCTAssertEqual(menu.root.selectedRow?.entryID, id)
    }

    func testOverAnotherAppThereIsNoGroup() throws {
        let other = LinkedApp(bundleID: "example.ledger", teamID: nil, name: "Ledger")
        let (menu, _, _) = try makeMenu(front: other)
        menu.reset()
        XCTAssertFalse(menu.root.rows.contains { $0.kind == .header && $0.title == "Harbor" })
        XCTAssertNotEqual(menu.root.rows.first?.title, "Ledger")
    }

    func testReturnOnTheLinkedAccountCopiesAndOpensNoWebsite() async throws {
        let (menu, host, id) = try makeMenu(front: harbor)
        var opened: [URL] = []
        session.openWebPage = { opened.append($0) }
        menu.reset()
        XCTAssertTrue(menu.handle(.enter))
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(host.copied, [id])
        XCTAssertEqual(opened, [])
    }

    func testABrowserAndPasswordPieItselfAreNeverLinked() {
        XCTAssertTrue(AppIdentity.isBrowser(bundleID: "com.google.Chrome", info: nil))
        XCTAssertTrue(AppIdentity.isBrowser(bundleID: "org.example.browser", info: [
            "CFBundleURLTypes": [["CFBundleURLSchemes": ["HTTPS", "http"]]],
        ]))
        XCTAssertFalse(AppIdentity.isBrowser(bundleID: "example.harbor", info: [
            "CFBundleURLTypes": [["CFBundleURLSchemes": ["harbor"]]],
        ]))
        XCTAssertFalse(AppIdentity.isBrowser(bundleID: "example.harbor", info: nil))
        XCTAssertFalse(AppIdentity.isLinkable(bundleID: "example.browser", ownBundleID: "com.passwordpie", isBrowser: true))
        XCTAssertFalse(AppIdentity.isLinkable(bundleID: "com.PasswordPie", ownBundleID: "com.passwordpie", isBrowser: false))
        XCTAssertTrue(AppIdentity.isLinkable(bundleID: "example.harbor", ownBundleID: "com.passwordpie", isBrowser: false))
    }

    func testReadingTheSignerOfARunningAppIsQuickAndDoesNotFail() throws {
        // This test process is not a signed app with a team; the Finder is Apple's and has none either. Both must
        // answer, and quickly: the menu asks while it opens.
        let finder = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        let start = Date()
        XCTAssertNil(AppIdentity.signedTeam(pid: finder.processIdentifier))
        _ = AppIdentity.signedTeam(pid: ProcessInfo.processInfo.processIdentifier)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }
}
