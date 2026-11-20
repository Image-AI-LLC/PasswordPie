import XCTest
@testable import PasswordPieCore

/// The person's answer per browser built on Chromium, and connections kept apart per browser app:
/// docs/BROWSER_EXTENSION.md, "Other Chromium browsers".
final class BrowserApprovalsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 3_000_000)

    func testGooglesBrowsersAreAllowedWithoutAnAnswer() {
        let approvals = BrowserApprovals()
        XCTAssertEqual(approvals.approval(bundleID: "com.google.Chrome", teamID: BrowserApprovals.googleTeamID), .allowed)
        XCTAssertEqual(approvals.approval(bundleID: "com.google.Chrome.canary", teamID: BrowserApprovals.googleTeamID), .allowed)
        XCTAssertNil(approvals.approval(bundleID: "com.google.Chrome", teamID: "ZZZZZZZZZZ"), "Chrome's ID signed by someone else is not Chrome")
    }

    func testAnAnswerIsPerBrowserAndTeamAndCanChange() {
        var approvals = BrowserApprovals()
        XCTAssertNil(approvals.approval(bundleID: "com.citrolabs.ego.lite", teamID: "JGQLC6YQYJ"))
        approvals.set(.allowed, bundleID: "com.citrolabs.ego.lite", teamID: "JGQLC6YQYJ", name: "ego lite", now: now)
        XCTAssertEqual(approvals.approval(bundleID: "com.citrolabs.ego.lite", teamID: "JGQLC6YQYJ"), .allowed)
        XCTAssertNil(approvals.approval(bundleID: "com.citrolabs.ego.lite", teamID: "AAAAAAAAAA"))

        approvals.set(.denied, bundleID: "com.citrolabs.ego.lite", teamID: "JGQLC6YQYJ", name: "ego lite", now: now)
        XCTAssertEqual(approvals.approval(bundleID: "com.citrolabs.ego.lite", teamID: "JGQLC6YQYJ"), .denied)
        XCTAssertEqual(approvals.records.count, 1, "the answer is replaced, not added")
        XCTAssertTrue(approvals.denied(bundleID: "com.citrolabs.ego.lite"))
    }

    func testGooglesBrowsersAreNotRecorded() {
        var approvals = BrowserApprovals()
        approvals.set(.denied, bundleID: "com.google.Chrome", teamID: BrowserApprovals.googleTeamID, name: "Google Chrome", now: now)
        XCTAssertTrue(approvals.records.isEmpty)
        XCTAssertEqual(approvals.approval(bundleID: "com.google.Chrome", teamID: BrowserApprovals.googleTeamID), .allowed)
    }

    func testAnswersSurviveTheRoundTripAndGarbageReadsAsNone() {
        var approvals = BrowserApprovals()
        approvals.set(.allowed, bundleID: "com.citrolabs.ego.lite", teamID: "JGQLC6YQYJ", name: "ego lite", now: now)
        approvals.set(.denied, bundleID: "com.example.other", teamID: "AAAAAAAAAA", name: "Other", now: now)
        XCTAssertEqual(BrowserApprovals.decode(approvals.encoded()), approvals)
        XCTAssertEqual(BrowserApprovals.decode(Data("not json".utf8)), BrowserApprovals())
        XCTAssertEqual(BrowserApprovals.decode(nil), BrowserApprovals())
    }

    // MARK: Connections per browser app

    private let chromeWork = BridgePeer(.chrome, link: 1)
    private let ego = BridgePeer(.chrome, link: 2)

    private func links() -> BridgeLinks {
        var links = BridgeLinks()
        links.opened(chromeWork, app: "com.google.Chrome")
        links.opened(ego, app: "com.citrolabs.ego.lite")
        return links
    }

    func testEachBrowserAppHasItsOwnProfileInFront() {
        var links = links()
        links.said(chromeWork, focused: true)
        links.said(chromeWork, focused: false)
        links.said(ego, focused: true)
        XCTAssertEqual(links.front(.chrome, app: "com.citrolabs.ego.lite")?.peer, ego)
        XCTAssertNil(links.front(.chrome, app: "com.google.Chrome"), "Chrome's profile lost the focus")
        XCTAssertEqual(links.front(.chrome)?.peer, ego, "any app: as before")
        XCTAssertEqual(links.recent(.chrome, app: "com.google.Chrome")?.peer, chromeWork, "Chrome's profile used last")
        XCTAssertEqual(links.count(.chrome, app: "com.citrolabs.ego.lite"), 1)
        XCTAssertEqual(links.count(.chrome), 2)
        XCTAssertNil(links.front(.chrome, app: "com.example.none"))
    }

    func testThePanelHoldsTheProfileInFrontOfEachBrowser() {
        var links = links()
        links.said(chromeWork, focused: true)
        links.said(ego, focused: true)
        links.hold()
        // The panel takes the keyboard: both say they lost the focus.
        links.said(chromeWork, focused: false)
        links.said(ego, focused: false)
        XCTAssertEqual(links.front(.chrome, app: "com.google.Chrome")?.peer, chromeWork)
        XCTAssertEqual(links.front(.chrome, app: "com.citrolabs.ego.lite")?.peer, ego)
        links.release()
        XCTAssertNil(links.front(.chrome, app: "com.google.Chrome"))
    }

    func testAFillForOneBrowserAppIsTakenByNoOther() throws {
        var store = PendingFillStore()
        let fill = try XCTUnwrap(PendingFill(entryID: UUID(), browser: .chrome, website: "https://github.com", created: now, app: "com.citrolabs.ego.lite"))
        store.set(fill)
        XCTAssertNil(store.take(browser: .chrome, link: 1, focused: nil, app: "com.google.Chrome", pageURL: "https://github.com/login", now: now))
        XCTAssertNotNil(store.take(browser: .chrome, link: 2, focused: nil, app: "com.citrolabs.ego.lite", pageURL: "https://github.com/login", now: now))
    }
}
