import AppKit
import PasswordPieBridge
import PasswordPieCore
import XCTest
@testable import PasswordPie

/// Chrome with more than one profile: the panel goes by the profile in front (docs/UX.md, "More than one Chrome profile").
final class ChromeFillRouteTests: XCTestCase {
    private let work = BridgePeer(.chrome, link: 1)

    func testAProfileInFrontThatSaysSoGetsTheFillItself() {
        let route = chromeFillRoute(chromeInFront: true, front: FrontLink(peer: work, certain: true), connected: true)
        XCTAssertEqual(route, .link(1))
    }

    func testAProfileInFrontWithoutTheExtensionGetsKeystrokes() {
        // Another profile is connected, but nobody speaks for the window in front.
        XCTAssertEqual(chromeFillRoute(chromeInFront: true, front: nil, connected: true), .keystrokes)
    }

    func testAnExtensionThatSaysNothingAboutFocusFillsAsBefore() {
        let route = chromeFillRoute(chromeInFront: true, front: FrontLink(peer: work, certain: false), connected: true)
        XCTAssertEqual(route, .anyProfile)
    }

    func testFromAnotherAppTheProfileIsNotKnownYet() {
        // Open and Fill from another app: Chrome opens the tab in the profile used last, whichever that is.
        XCTAssertEqual(chromeFillRoute(chromeInFront: false, front: nil, connected: true), .anyProfile)
        XCTAssertEqual(chromeFillRoute(chromeInFront: false, front: nil, connected: false), .keystrokes)
    }
}

final class ExtensionStatusTests: XCTestCase {
    func testChromeSaysHowManyProfilesAreConnected() {
        XCTAssertEqual(ExtensionStatus.chrome(profiles: 0), ExtensionStatus(text: "Not connected", on: false))
        XCTAssertEqual(ExtensionStatus.chrome(profiles: 1), ExtensionStatus(text: "Connected", on: true))
        XCTAssertEqual(ExtensionStatus.chrome(profiles: 2), ExtensionStatus(text: "Connected in 2 profiles", on: true))
    }

    func testSafariIsOnOrOff() {
        XCTAssertEqual(ExtensionStatus.safari(enabled: true), ExtensionStatus(text: "On", on: true))
        XCTAssertEqual(ExtensionStatus.safari(enabled: false), ExtensionStatus(text: "Off", on: false))
    }

    func testTheButtonsSayWhatTheBannerSays() {
        XCTAssertEqual(ExtensionBanner.addChrome.title, "Add Chrome Extension…")
        XCTAssertEqual(safariExtensionButtonTitle(enabled: false), ExtensionBanner.enableSafari.title)
        XCTAssertEqual(safariExtensionButtonTitle(enabled: true), "Open Safari Settings…")
    }
}

@MainActor
final class BrowserProfilesTests: XCTestCase {
    private var directory: URL!
    /// The bridge holds its session unowned.
    private var session: VaultSession?
    private var pokes: [Int?] = []
    private var opened: [(url: URL, app: URL?)] = []
    private let chrome = FrontApp(bundleID: BrowserBridge.chromeBundleID, bundleURL: URL(fileURLWithPath: "/tmp/Test Chrome.app"))

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("passwordpie-profiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("PASSWORDPIE_DB", directory.appendingPathComponent("test.kdbx").path, 1)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
        try XCTSkipUnless(BrowserBridge.chromeSupported, "Chrome is in the direct channel only")
    }

    override func tearDownWithError() throws {
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        session = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// An unlocked database with one GitHub login, and a bridge that records what it would send and open.
    private func bridge() -> (BrowserBridge, VaultEntry) {
        let session = VaultSession()
        session.restore()
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        var entry = VaultEntry()
        entry.title = "GitHub"
        entry.url = "https://github.com"
        entry.username = "octocat"
        entry.password = "hunter2"
        session.saveEditing(entry)
        self.session = session
        let bridge = BrowserBridge(session: session)
        bridge.pushToChrome = { [weak self] _, link in self?.pokes.append(link) }
        bridge.openInBrowser = { [weak self] url, app in self?.opened.append((url, app)) }
        return (bridge, session.allEntries.first { $0.title == "GitHub" }!)
    }

    @discardableResult
    private func send(_ bridge: BrowserBridge, link: Int, _ object: [String: Any]) throws -> [String: Any] {
        let frame = try JSONSerialization.data(withJSONObject: object)
        let answer = try XCTUnwrap(bridge.answer(frame, from: .chrome, link: link))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: answer) as? [String: Any])
    }

    @discardableResult
    private func tab(_ bridge: BrowserBridge, link: Int, _ url: String, focused: Bool?) throws -> [String: Any] {
        var report: [String: Any] = ["type": "tab", "id": 1, "url": url, "reason": "focus"]
        if let focused { report["focused"] = focused }
        return try send(bridge, link: link, report)
    }

    private func connect(_ bridge: BrowserBridge, _ links: Int...) {
        bridge.connectionsChanged(Set(links.map { BridgePeer(.chrome, link: $0) }))
    }

    // MARK: A profile without the extension in front, another connected

    func testTheBannerOffersTheExtensionForTheProfileInFront() throws {
        let (bridge, _) = bridge()
        connect(bridge, 1)
        try tab(bridge, link: 1, "https://github.com/", focused: true)
        XCTAssertNil(bridge.banner(frontBundleID: chrome.bundleID))
        XCTAssertTrue(bridge.chromeInFront)

        // The person clicks a window of a profile that has no extension.
        try send(bridge, link: 1, ["type": "focus", "id": 2, "focused": false])
        XCTAssertEqual(bridge.banner(frontBundleID: chrome.bundleID), .addChrome)
        XCTAssertFalse(bridge.chromeInFront)
        XCTAssertEqual(bridge.chromeProfiles, 1, "the other profile is still connected")
    }

    func testAnotherProfilesTabIsNotThePage() throws {
        let (bridge, _) = bridge()
        connect(bridge, 1)
        try tab(bridge, link: 1, "https://github.com/", focused: true)
        XCTAssertEqual(bridge.pageURL(for: .chrome), "https://github.com/")
        try send(bridge, link: 1, ["type": "focus", "id": 2, "focused": false])
        XCTAssertNil(bridge.pageURL(for: .chrome), "without Accessibility the page is not known")
        XCTAssertFalse(bridge.canFill(in: .chrome))
    }

    func testFillTypesInsteadOfReachingAnotherProfile() throws {
        let (bridge, entry) = bridge()
        connect(bridge, 1)
        try tab(bridge, link: 1, "https://github.com/login", focused: false)
        pokes = []
        XCTAssertFalse(bridge.fill(entry, .fillOrOpen, website: nil, front: chrome), "the caller types the keystrokes")
        XCTAssertTrue(pokes.isEmpty)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertNil(try tab(bridge, link: 1, "https://github.com/login", focused: false)["fill"])
    }

    func testTheStorePageOpensInTheBrowserInFront() {
        let (bridge, _) = bridge()
        bridge.install(.addChrome, in: chrome)
        XCTAssertEqual(opened.map(\.url), [BrowserBridge.chromeInstallURL])
        XCTAssertEqual(opened.first?.app, chrome.bundleURL, "Chrome opens it in the profile whose window was in front")
    }

    // MARK: Both profiles have the extension

    func testThePageAndTheFillAreTheFrontProfiles() throws {
        let (bridge, entry) = bridge()
        connect(bridge, 1, 2)
        try tab(bridge, link: 1, "https://example.com/", focused: false)
        try tab(bridge, link: 2, "https://github.com/login", focused: true)
        // A page finishes loading behind, in the other profile.
        try tab(bridge, link: 1, "https://github.com/login", focused: false)
        XCTAssertEqual(bridge.pageURL(for: .chrome), "https://github.com/login")

        pokes = []
        XCTAssertTrue(bridge.fill(entry, .fillOrOpen, website: nil, front: chrome))
        XCTAssertEqual(pokes, [2], "only the profile in front is asked")
        XCTAssertNil(try tab(bridge, link: 1, "https://github.com/login", focused: false)["fill"])
        let fill = try XCTUnwrap(try tab(bridge, link: 2, "https://github.com/login", focused: true)["fill"] as? [String: Any])
        XCTAssertEqual(fill["username"] as? String, "octocat")
    }

    func testANewTabIsForTheProfileInFront() throws {
        let (bridge, entry) = bridge()
        connect(bridge, 1, 2)
        try tab(bridge, link: 2, "https://github.com/", focused: false)
        try tab(bridge, link: 1, "https://example.com/", focused: true)
        XCTAssertTrue(bridge.fill(entry, .fillOrOpen, website: nil, front: chrome))
        XCTAssertEqual(opened.map(\.url.absoluteString), ["https://github.com"])
        XCTAssertEqual(opened.first?.app, chrome.bundleURL)
        XCTAssertNil(try tab(bridge, link: 2, "https://github.com/", focused: false)["fill"], "the other profile was on the site already")
        XCTAssertNotNil(try tab(bridge, link: 1, "https://github.com/", focused: true)["fill"])
    }

    func testANewConnectionIsAskedForItsTab() {
        let (bridge, _) = bridge()
        connect(bridge, 1)
        XCTAssertEqual(pokes, [1])
        connect(bridge, 1, 2)
        XCTAssertEqual(pokes, [1, 2])
        XCTAssertEqual(bridge.chromeProfiles, 2)
        connect(bridge, 2)
        XCTAssertEqual(bridge.chromeProfiles, 1)
        XCTAssertEqual(pokes, [1, 2], "a closed one asks nobody")
    }

    // MARK: The panel takes the keyboard

    func testThePanelKeepsTheProfileItOpenedOver() throws {
        let (bridge, entry) = bridge()
        connect(bridge, 1)
        try tab(bridge, link: 1, "https://github.com/login", focused: true)
        pokes = []
        bridge.panelWillShow(over: chrome, pid: nil)
        XCTAssertEqual(pokes, [1])
        // Chrome tells the extension its window lost the focus: PasswordPie's panel has the keyboard.
        try send(bridge, link: 1, ["type": "focus", "id": 2, "focused": false])
        try tab(bridge, link: 1, "https://github.com/login", focused: false)
        XCTAssertNil(bridge.banner(frontBundleID: chrome.bundleID))
        XCTAssertEqual(bridge.pageURL(for: .chrome), "https://github.com/login")
        XCTAssertTrue(bridge.fill(entry, .fillOrOpen, website: nil, front: chrome))

        bridge.panelDidHide()
        // The poke's report arrives before Chrome gives the window its focus back.
        XCTAssertNotNil(try tab(bridge, link: 1, "https://github.com/login", focused: false)["fill"])
    }

    func testThePanelOverAProfileWithoutTheExtensionShowsTheBanner() throws {
        let (bridge, _) = bridge()
        connect(bridge, 1)
        try tab(bridge, link: 1, "https://github.com/login", focused: true)
        try send(bridge, link: 1, ["type": "focus", "id": 2, "focused": false])
        pokes = []
        bridge.panelWillShow(over: chrome, pid: nil)
        XCTAssertTrue(pokes.isEmpty, "nobody to ask: the profile behind is left alone")
        XCTAssertEqual(bridge.banner(frontBundleID: chrome.bundleID), .addChrome)
        bridge.panelDidHide()
    }

    func testThePanelOpenedByTheToolbarButtonOfAnAppJustStartedShowsNoBanner() throws {
        // The app was not running: the host started it, and the connection has said nothing when the panel opens.
        let (bridge, entry) = bridge()
        connect(bridge, 1)
        try send(bridge, link: 1, ["type": "show", "id": 1])
        bridge.panelWillShow(over: chrome, pid: nil)
        try send(bridge, link: 1, ["type": "focus", "id": 2, "focused": false])
        try tab(bridge, link: 1, "https://github.com/login", focused: false)
        XCTAssertNil(bridge.banner(frontBundleID: chrome.bundleID))
        XCTAssertEqual(bridge.pageURL(for: .chrome), "https://github.com/login")
        XCTAssertTrue(bridge.fill(entry, .fillOrOpen, website: nil, front: chrome))
        bridge.panelDidHide()
        // Chrome has its window back and says so.
        XCTAssertNotNil(try tab(bridge, link: 1, "https://github.com/login", focused: true)["fill"])
    }

    // MARK: PasswordPie's own window was in front

    func testOverPasswordPiesOwnWindowTheProfileUsedLastStandsForChrome() throws {
        // Preferences is open and in front; the app the panel returns to is still Chrome, which no longer has the focus.
        let (bridge, entry) = bridge()
        connect(bridge, 1)
        try tab(bridge, link: 1, "https://github.com/login", focused: true)
        try send(bridge, link: 1, ["type": "focus", "id": 2, "focused": false])
        let behind = FrontApp(bundleID: chrome.bundleID, bundleURL: chrome.bundleURL, inFront: false)
        XCTAssertNil(bridge.banner(frontBundleID: chrome.bundleID, inFront: false), "connected, as it always counted")
        XCTAssertEqual(bridge.pageURL(for: .chrome, inFront: false), "https://github.com/login")
        pokes = []
        XCTAssertTrue(bridge.fill(entry, .fillOrOpen, website: nil, front: behind))
        XCTAssertEqual(pokes, [nil])
        XCTAssertNil(try tab(bridge, link: 1, "https://github.com/login", focused: false)["fill"], "not while Chrome is behind")
        XCTAssertNotNil(try tab(bridge, link: 1, "https://github.com/login", focused: true)["fill"], "once Chrome is in front again")
    }

    func testOverPasswordPiesOwnWindowWithNothingConnectedTheBannerStillOffersTheExtension() {
        let (bridge, entry) = bridge()
        let behind = FrontApp(bundleID: chrome.bundleID, bundleURL: chrome.bundleURL, inFront: false)
        XCTAssertEqual(bridge.banner(frontBundleID: chrome.bundleID, inFront: false), .addChrome)
        XCTAssertFalse(bridge.fill(entry, .fillOrOpen, website: nil, front: behind))
    }

    // MARK: The extension in the store before 0.4.0, and one profile

    func testAnExtensionThatSaysNothingAboutFocusWorksAsBefore() throws {
        let (bridge, entry) = bridge()
        connect(bridge, 1)
        XCTAssertNil(bridge.banner(frontBundleID: chrome.bundleID), "connected is enough, as it was")
        try tab(bridge, link: 1, "https://github.com/login", focused: nil)
        XCTAssertEqual(bridge.pageURL(for: .chrome), "https://github.com/login")
        pokes = []
        XCTAssertTrue(bridge.fill(entry, .fillOrOpen, website: nil, front: chrome))
        XCTAssertEqual(pokes, [nil], "every connection is asked, as it was")
        XCTAssertNotNil(try tab(bridge, link: 1, "https://github.com/login", focused: nil)["fill"])
    }

    func testNoConnectionOffersTheExtension() {
        let (bridge, entry) = bridge()
        XCTAssertEqual(bridge.banner(frontBundleID: chrome.bundleID), .addChrome)
        XCTAssertFalse(bridge.fill(entry, .fillOrOpen, website: nil, front: chrome))
        XCTAssertNil(bridge.banner(frontBundleID: "com.apple.TextEdit"))
    }
}
