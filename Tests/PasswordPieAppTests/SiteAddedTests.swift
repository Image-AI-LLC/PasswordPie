import AppKit
import PasswordPieBridge
import PasswordPieCore
import XCTest
@testable import PasswordPie

/// An account picked on another site's sign-in page fills that page, and the site is added to the account
/// (docs/UX.md, "An account you pick on another site's sign-in page"). The real session and a database file; the
/// extension is scripted.
@MainActor
final class SiteAddedTests: XCTestCase {
    private var directory: URL!
    /// The bridge holds its session unowned.
    private var session: VaultSession?
    private var pokes: [Int?] = []
    private var opened: [URL] = []
    private var hidden: [Bool] = []
    private var notices: [SiteNotice] = []
    private let chrome = FrontApp(bundleID: BrowserBridge.chromeBundleID, bundleURL: URL(fileURLWithPath: "/tmp/Test Chrome.app"))
    private let portal = "https://portal.example.com/"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("passwordpie-site-added-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("PASSWORDPIE_DB", directory.appendingPathComponent("test.kdbx").path, 1)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
        try XCTSkipUnless(BrowserBridge.chromeSupported, "Chrome is in the direct channel only")
    }

    override func tearDownWithError() throws {
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        session = nil
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    /// An unlocked database with one login, and a bridge that records what it would send, open and hide.
    private func bridge(website: String = "https://github.com", session background: VaultSession? = nil) -> (BrowserBridge, UUID) {
        let session = background ?? VaultSession(writes: .inline)
        session.restore()
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        var entry = VaultEntry()
        entry.title = "GitHub"
        entry.url = website
        entry.username = "octocat"
        entry.password = "hunter2"
        session.saveEditing(entry)
        session.onSiteNotice = { [unowned self] in self.notices.append($0) }
        self.session = session
        let bridge = BrowserBridge(session: session)
        bridge.pushToChrome = { [weak self] _, link in self?.pokes.append(link) }
        bridge.openInBrowser = { [weak self] url, _ in self?.opened.append(url) }
        bridge.hidePanel = { [weak self] refocus in self?.hidden.append(refocus) }
        return (bridge, entry.id)
    }

    private func account(_ id: UUID) throws -> VaultEntry {
        try XCTUnwrap(session?.entry(id))
    }

    @discardableResult
    private func tab(_ bridge: BrowserBridge, link: Int = 1, _ url: String, focused: Bool? = true, signIn: Bool? = nil) throws -> [String: Any] {
        var report: [String: Any] = ["type": "tab", "id": 1, "url": url, "reason": "focus"]
        if let focused { report["focused"] = focused }
        if let signIn { report["signIn"] = signIn }
        let answer = try XCTUnwrap(bridge.answer(try JSONSerialization.data(withJSONObject: report), from: .chrome, link: link))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: answer) as? [String: Any])
    }

    private func connect(_ bridge: BrowserBridge, _ links: Int...) {
        bridge.connectionsChanged(Set(links.map { BridgePeer(.chrome, link: $0) }))
        pokes = []
    }

    func testAPickOnAnotherSitesSignInPageFillsThatPageAndAddsItsSite() throws {
        let (bridge, id) = bridge()
        connect(bridge, 1)
        try tab(bridge, portal, signIn: true)
        XCTAssertTrue(bridge.signInShowing(for: .chrome))

        XCTAssertTrue(bridge.fill(try account(id), .fillOrOpen, website: nil, front: chrome))
        XCTAssertTrue(opened.isEmpty, "no new tab")
        XCTAssertEqual(hidden, [true], "the panel closes and the browser has the keyboard again")
        XCTAssertEqual(pokes, [1], "the tab in front is asked to take the fill")
        XCTAssertEqual(entryWebsites(try account(id)), ["https://github.com", "https://portal.example.com"])
        XCTAssertEqual(notices, [.added(entry: id, title: "GitHub", website: "https://portal.example.com")])
        XCTAssertEqual(notices.first?.message, "portal.example.com is now a website of GitHub")

        let fill = try XCTUnwrap(try tab(bridge, portal, signIn: true)["fill"] as? [String: Any])
        XCTAssertEqual(fill["origin"] as? String, "https://portal.example.com")
        XCTAssertEqual(fill["username"] as? String, "octocat")
        XCTAssertEqual(fill["password"] as? String, "hunter2")
        XCTAssertNil(try tab(bridge, portal, signIn: true)["fill"], "once")
    }

    func testTheWebsiteIsInTheFileBeforeThePageIsFilled() throws {
        let (bridge, id) = bridge()
        connect(bridge, 1)
        try tab(bridge, portal, signIn: true)
        XCTAssertTrue(bridge.fill(try account(id), .fillOrOpen, website: nil, front: chrome))

        // The file itself holds the website before any tab is answered: the fill goes to a site the account holds.
        let file = try KDBX.load(data: Data(contentsOf: directory.appendingPathComponent("test.kdbx")), password: "pw", keyFile: nil)
        let saved = try XCTUnwrap(file.entries.first { $0.id == id })
        XCTAssertEqual(entryWebsites(saved), ["https://github.com", "https://portal.example.com"])
        XCTAssertNotNil(try tab(bridge, portal, signIn: true)["fill"])
    }

    func testTheNextTimeTheAccountIsTheSitesOwn() throws {
        let (bridge, id) = bridge()
        connect(bridge, 1)
        try tab(bridge, portal, signIn: true)
        XCTAssertTrue(bridge.fill(try account(id), .fillOrOpen, website: nil, front: chrome))
        _ = try tab(bridge, portal, signIn: true)
        notices = []

        let listed = SiteSuggestions.entries(try XCTUnwrap(session).allEntries, pageURL: portal)
        XCTAssertEqual(listed.map(\.id), [id], "it is in the site's group now")
        XCTAssertTrue(bridge.fill(try account(id), .fillOrOpen, website: nil, front: chrome))
        XCTAssertTrue(notices.isEmpty, "nothing is added twice")
        XCTAssertEqual(entryWebsites(try account(id)).count, 2)
        XCTAssertNotNil(try tab(bridge, portal, signIn: true)["fill"])
    }

    func testWithoutASignInFormANewTabOpensAsBefore() throws {
        let (bridge, id) = bridge()
        connect(bridge, 1)
        // An extension from before 0.8.0 says nothing; a newer one says no.
        for signIn in [nil, false] as [Bool?] {
            opened = []
            try tab(bridge, "https://news.example.org/", signIn: signIn)
            XCTAssertFalse(bridge.signInShowing(for: .chrome))
            XCTAssertTrue(bridge.fill(try account(id), .fillOrOpen, website: nil, front: chrome))
            XCTAssertEqual(opened.map(\.absoluteString), ["https://github.com"])
        }
        XCTAssertEqual(entryWebsites(try account(id)), ["https://github.com"])
        XCTAssertTrue(notices.isEmpty)
    }

    func testOptionReturnStillOpensTheAccountsOwnWebsite() throws {
        let (bridge, id) = bridge()
        connect(bridge, 1)
        try tab(bridge, portal, signIn: true)
        XCTAssertTrue(bridge.fill(try account(id), .openAndFill, website: nil, front: chrome))
        XCTAssertEqual(opened.map(\.absoluteString), ["https://github.com"])
        XCTAssertEqual(entryWebsites(try account(id)), ["https://github.com"])
        XCTAssertNil(try tab(bridge, portal, signIn: true)["fill"], "the fill waits for the account's own site")
    }

    func testAnAccountWithoutAWebsiteIsFilledThereAndGetsItsWebsite() throws {
        let (bridge, id) = bridge(website: "")
        connect(bridge, 1)
        try tab(bridge, portal, signIn: true)
        XCTAssertTrue(bridge.fill(try account(id), .fillOrOpen, website: nil, front: chrome), "no keystrokes, so no Accessibility")
        XCTAssertEqual(try account(id).url, "https://portal.example.com")
        XCTAssertNotNil(try tab(bridge, portal, signIn: true)["fill"])
    }

    func testASignInPageInAnotherProfileAddsNothing() throws {
        let (bridge, id) = bridge()
        connect(bridge, 1, 2)
        try tab(bridge, link: 2, portal, focused: false, signIn: true)
        try tab(bridge, link: 1, "https://news.example.org/", focused: true, signIn: false)
        XCTAssertTrue(bridge.fill(try account(id), .fillOrOpen, website: nil, front: chrome))
        XCTAssertEqual(opened.map(\.absoluteString), ["https://github.com"], "the page in front has no form: a new tab")
        XCTAssertEqual(entryWebsites(try account(id)), ["https://github.com"])
    }

    func testTheFillIsOnlyForTheProfileThatWasInFront() throws {
        let (bridge, id) = bridge()
        connect(bridge, 1, 2)
        try tab(bridge, link: 2, portal, focused: false, signIn: true)
        try tab(bridge, link: 1, portal, focused: true, signIn: true)
        XCTAssertTrue(bridge.fill(try account(id), .fillOrOpen, website: nil, front: chrome))
        XCTAssertEqual(pokes, [1])
        XCTAssertNil(try tab(bridge, link: 2, portal, focused: false, signIn: true)["fill"])
        XCTAssertNotNil(try tab(bridge, link: 1, portal, focused: true, signIn: true)["fill"])
    }

    func testUndoTakesTheWebsiteOffAgain() throws {
        let (bridge, id) = bridge()
        connect(bridge, 1)
        try tab(bridge, portal, signIn: true)
        XCTAssertTrue(bridge.fill(try account(id), .fillOrOpen, website: nil, front: chrome))
        let notice = try XCTUnwrap(notices.first)

        var undone: Bool?
        try XCTUnwrap(session).removeWebsite(notice.website, from: notice.entry) { undone = $0 }
        XCTAssertEqual(undone, true)
        XCTAssertEqual(entryWebsites(try account(id)), ["https://github.com"])
        XCTAssertTrue(SiteSuggestions.entries(try XCTUnwrap(session).allEntries, pageURL: portal).isEmpty)
        // The fill that was waiting is for a site the account no longer holds.
        XCTAssertNil(try tab(bridge, portal, signIn: true)["fill"])
    }

    func testAFailedSaveAddsNothingAndFillsNothing() throws {
        let (bridge, id) = bridge()
        connect(bridge, 1)
        try tab(bridge, portal, signIn: true)
        // The folder cannot be written: the new file cannot replace the old one.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

        XCTAssertTrue(bridge.fill(try account(id), .fillOrOpen, website: nil, front: chrome), "handled: nothing is typed instead")
        XCTAssertEqual(entryWebsites(try account(id)), ["https://github.com"])
        XCTAssertTrue(notices.isEmpty)
        XCTAssertTrue(pokes.isEmpty)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertNil(try tab(bridge, portal, signIn: true)["fill"])
        XCTAssertFalse(try XCTUnwrap(session).message.isEmpty, "the session says why")
    }

    #if PP_DIRECT
    func testAChromeLoginIsSavedIntoTheDatabaseWithTheWebsite() async throws {
        let (bridge, _) = bridge()
        let session = try XCTUnwrap(session)
        // A login that is only in Chrome: nothing of it is in the file yet.
        var live = VaultEntry(groupPath: ["Chrome (live)", "Work"])
        live.title = "northwind.example"
        live.url = "https://sso.northwind.example"
        live.username = "ann"
        live.password = "from-chrome"
        session.chromeSyncEnabled = true
        let rows = [ChromeRow(loginID: live.id, password: live.password, modifiedAt: Date(), isForm: true)]
        let result = ChromeLoginsResult(entries: [live], profileCount: 1, rows: rows)
        session.chromeSource = ChromeSnapshotSource(signature: { ChromeStoreSignature() }, load: { _ in (Data(repeating: 1, count: 16), result) })
        session.refreshChrome()
        for _ in 0..<2_000 where session.chromeBusy || session.chromeWriteInFlight { try? await Task.sleep(nanoseconds: 5_000_000) }
        let login = try XCTUnwrap(session.allEntries.first { $0.username == "ann" })
        let file = directory.appendingPathComponent("test.kdbx")
        XCTAssertFalse(try KDBX.load(data: Data(contentsOf: file), password: "pw", keyFile: nil).entries.contains { $0.username == "ann" })

        connect(bridge, 1)
        try tab(bridge, portal, signIn: true)
        XCTAssertTrue(bridge.fill(login, .fillOrOpen, website: nil, front: chrome))

        let saved = try XCTUnwrap(try KDBX.load(data: Data(contentsOf: file), password: "pw", keyFile: nil).entries.first { $0.username == "ann" })
        XCTAssertEqual(entryWebsites(saved), ["https://sso.northwind.example", "https://portal.example.com"])
        XCTAssertEqual(notices.map(\.website), ["https://portal.example.com"])
        let fill = try XCTUnwrap(try tab(bridge, portal, signIn: true)["fill"] as? [String: Any])
        XCTAssertEqual(fill["username"] as? String, "ann")
        XCTAssertEqual(fill["password"] as? String, "from-chrome")
    }
    #endif

    /// The save is written off the main thread, as in the app, and takes a moment: a pick made meanwhile is the newest.
    func testAPickMadeDuringTheSaveKeepsItsFill() async throws {
        let (bridge, id) = bridge(session: VaultSession())
        let session = try XCTUnwrap(session)
        await session.savesSettled()
        var other = VaultEntry()
        other.title = "Other"
        other.url = "https://github.com"
        other.username = "hubot"
        other.password = "pw2"
        session.saveEditing(other)
        await session.savesSettled()
        connect(bridge, 1)
        try tab(bridge, portal, signIn: true)

        XCTAssertTrue(bridge.fill(try account(id), .fillOrOpen, website: nil, front: chrome))
        XCTAssertTrue(pokes.isEmpty, "nothing is filled before the file is written")
        try tab(bridge, "https://github.com/login", signIn: true)
        XCTAssertTrue(bridge.fill(try account(id), .fillOrOpen, website: "https://github.com", front: chrome))
        await session.savesSettled()

        let fill = try XCTUnwrap(try tab(bridge, "https://github.com/login", signIn: true)["fill"] as? [String: Any])
        XCTAssertEqual(fill["origin"] as? String, "https://github.com", "the older pick does not replace it")
        XCTAssertEqual(entryWebsites(try account(id)), ["https://github.com", "https://portal.example.com"])
    }

    func testTheSameAccountPickedTwiceDuringTheSaveFillsOnce() async throws {
        let (bridge, id) = bridge(session: VaultSession())
        let session = try XCTUnwrap(session)
        await session.savesSettled()
        connect(bridge, 1)
        try tab(bridge, portal, signIn: true)

        XCTAssertTrue(bridge.fill(try account(id), .fillOrOpen, website: nil, front: chrome))
        XCTAssertTrue(bridge.fill(try account(id), .fillOrOpen, website: nil, front: chrome))
        await session.savesSettled()

        XCTAssertNotNil(try tab(bridge, portal, signIn: true)["fill"])
        XCTAssertNil(try tab(bridge, portal, signIn: true)["fill"], "once")
        XCTAssertEqual(entryWebsites(try account(id)), ["https://github.com", "https://portal.example.com"])
    }

    func testLockedNothingIsFilled() throws {
        let (bridge, id) = bridge()
        connect(bridge, 1)
        try tab(bridge, portal, signIn: true)
        let entry = try account(id)
        try XCTUnwrap(session).lock()
        XCTAssertTrue(bridge.fill(entry, .fillOrOpen, website: nil, front: chrome))
        XCTAssertNil(try tab(bridge, portal, signIn: true)["fill"])
        XCTAssertTrue(notices.isEmpty)
    }
}
