import XCTest
@testable import PasswordPieCore

/// Which of Chrome's connections stands for the profile in front: docs/BROWSER_EXTENSION.md, "Chrome profiles".
final class BridgeLinksTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 3_000_000)
    private let work = BridgePeer(.chrome, link: 1)
    private let home = BridgePeer(.chrome, link: 2)

    private func links(_ peers: BridgePeer...) -> BridgeLinks {
        var links = BridgeLinks()
        peers.forEach { links.opened($0) }
        return links
    }

    func testTheProfileThatSaysItHasTheFocusIsInFront() {
        var links = links(work, home)
        links.said(work, focused: true)
        links.said(home, focused: false)
        XCTAssertEqual(links.front(.chrome), FrontLink(peer: work, certain: true))

        // The person clicks the other profile's window: one says it lost the focus, the other that it has it.
        links.said(work, focused: false)
        links.said(home, focused: true)
        XCTAssertEqual(links.front(.chrome), FrontLink(peer: home, certain: true))
    }

    func testNoProfileIsInFrontWhenEachSaysItLostTheFocus() {
        // The window in front belongs to a profile without the extension: nobody speaks for it.
        var links = links(work)
        links.said(work, focused: true)
        links.said(work, focused: false)
        XCTAssertNil(links.front(.chrome))
    }

    func testTheLatestToSayItHasTheFocusWinsWhenTwoStillDo() {
        // The one that lost it has not said so yet.
        var links = links(work, home)
        links.said(work, focused: true)
        links.said(home, focused: true)
        XCTAssertEqual(links.front(.chrome)?.peer, home)
    }

    func testAnExtensionThatSaysNothingAboutFocusCountsAsBefore() {
        // The extension in the store before this: connected means it may be in front.
        var links = links(work)
        XCTAssertEqual(links.front(.chrome), FrontLink(peer: work, certain: false))
        links.reported(work, url: "https://github.com/", focused: nil, now: start)
        XCTAssertEqual(links.front(.chrome), FrontLink(peer: work, certain: false))
    }

    func testAmongSilentExtensionsTheLastToReportIsInFront() {
        var links = links(work, home)
        links.reported(work, url: "https://github.com/", focused: nil, now: start)
        links.reported(home, url: "https://example.com/", focused: nil, now: start + 1)
        XCTAssertEqual(links.front(.chrome)?.peer, home)
        links.reported(work, url: "https://github.com/", focused: nil, now: start + 2)
        XCTAssertEqual(links.front(.chrome)?.peer, work)
    }

    func testASilentExtensionMayBeInFrontWhenTheOthersSayTheyAreNot() {
        var links = links(work, home)
        links.said(work, focused: false)
        XCTAssertEqual(links.front(.chrome), FrontLink(peer: home, certain: false))
        links.said(work, focused: true)
        XCTAssertEqual(links.front(.chrome), FrontLink(peer: work, certain: true), "one that says so wins over a guess")
    }

    func testThePanelKeepsTheProfileItOpenedOver() {
        // PasswordPie's panel takes the keyboard, so Chrome tells the extension its window lost the focus.
        var links = links(work)
        links.said(work, focused: true)
        links.hold()
        links.said(work, focused: false)
        links.reported(work, url: "https://github.com/", focused: false, now: start + 0.2)
        XCTAssertEqual(links.front(.chrome), FrontLink(peer: work, certain: true))
        links.release()
        XCTAssertNil(links.front(.chrome), "the panel is gone: what the profile last said counts again")
    }

    func testThePanelOverAProfileWithoutTheExtensionHasNoneInFront() {
        var links = links(work)
        links.said(work, focused: false)
        links.hold()
        links.reported(work, url: "https://github.com/", focused: false, now: start + 0.2)
        XCTAssertNil(links.front(.chrome))
    }

    func testAFocusSaidWhileThePanelOpensStillCounts() {
        // The shortcut came a moment after the click on Chrome: "focused" arrives after the panel began to open.
        var links = links(work)
        links.said(work, focused: false)
        links.hold()
        links.said(work, focused: true)
        links.said(work, focused: false)
        XCTAssertEqual(links.front(.chrome)?.peer, work)
    }

    func testOpeningThePanelAgainKeepsWhatItHeld() {
        var links = links(work)
        links.said(work, focused: true)
        links.hold()
        links.said(work, focused: false)
        links.hold()
        XCTAssertEqual(links.front(.chrome)?.peer, work)
    }

    func testAClosedConnectionIsForgotten() {
        var links = links(work, home)
        links.said(work, focused: true)
        links.hold()
        links.closed(work)
        XCTAssertEqual(links.front(.chrome), FrontLink(peer: home, certain: false), "the other has said nothing yet")
        links.said(home, focused: false)
        XCTAssertNil(links.front(.chrome))
        XCTAssertEqual(links.count(.chrome), 1)
    }

    func testBrowsersAreKeptApart() {
        var links = links(work, BridgePeer(.safari))
        links.said(work, focused: false)
        XCTAssertNil(links.front(.chrome))
        XCTAssertEqual(links.front(.safari)?.peer, BridgePeer(.safari))
    }
}

/// The bridge's answers when Chrome has more than one profile connected.
final class BridgeProfilesTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 3_100_000)

    private func login(code: Bool = false) -> VaultEntry {
        var entry = VaultEntry()
        entry.title = "GitHub"
        entry.url = "https://github.com"
        entry.username = "octocat"
        entry.password = "hunter2"
        if code { entry.setValue("otpauth://totp/GitHub:octocat?secret=JBSWY3DPEHPK3PXP&issuer=GitHub", for: "otp") }
        return entry
    }

    private func request(_ json: String) -> BridgeRequest {
        try! JSONDecoder().decode(BridgeRequest.self, from: Data(json.utf8))
    }

    private func object(_ response: BridgeResponse) -> [String: Any] {
        let data = try! JSONEncoder().encode(response)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func tab(_ url: String, focused: Bool?) -> BridgeRequest {
        let focus = focused.map { #","focused":\#($0)"# } ?? ""
        return request(#"{"type":"tab","id":7,"url":"\#(url)","reason":"poke"\#(focus)}"#)
    }

    @discardableResult
    private func report(_ state: inout BridgeState, link: Int, _ url: String, focused: Bool?, at offset: TimeInterval = 0, entry: VaultEntry? = nil) -> [String: Any] {
        object(state.handle(tab(url, focused: focused), from: .chrome, link: link, locked: false, now: start + offset) { _ in entry })
    }

    func testThePageIsTheFrontProfilesNotTheLastReported() {
        var state = BridgeState()
        report(&state, link: 1, "https://github.com/", focused: true)
        // A tab finishes loading in the other profile's window, behind.
        report(&state, link: 2, "https://example.com/", focused: false, at: 1)
        XCTAssertEqual(state.currentURL(for: .chrome, now: start + 2), "https://github.com/")
    }

    func testNoPageWhenTheFrontProfileHasNoExtension() {
        var state = BridgeState()
        report(&state, link: 1, "https://github.com/", focused: true)
        _ = state.handle(request(#"{"type":"focus","id":8,"focused":false}"#), from: .chrome, link: 1, locked: false, now: start + 1) { _ in nil }
        XCTAssertNil(state.currentURL(for: .chrome, now: start + 2))
        XCTAssertNil(state.front(.chrome))
        XCTAssertTrue(state.heardFrom(.chrome, now: start + 2), "the extension still works, in its own profile")
    }

    func testFocusIsAnsweredAndCarriesNothing() {
        var state = BridgeState()
        let answer = object(state.handle(request(#"{"type":"focus","id":4,"focused":true}"#), from: .chrome, link: 3, locked: true, now: start) { _ in nil })
        XCTAssertEqual(answer.keys.sorted(), ["id", "type"])
        XCTAssertEqual(answer["type"] as? String, "focus")
        XCTAssertEqual(state.front(.chrome), FrontLink(peer: BridgePeer(.chrome, link: 3), certain: true))
    }

    func testFocusWithoutAValueIsABadRequest() {
        var state = BridgeState()
        let answer = object(state.handle(request(#"{"type":"focus","id":4}"#), from: .chrome, link: 3, locked: false, now: start) { _ in nil })
        XCTAssertEqual(answer["code"] as? String, "bad-request")
    }

    func testWithoutFocusWordsTheLastReportIsThePageAsBefore() {
        var state = BridgeState()
        report(&state, link: 1, "https://github.com/", focused: nil)
        report(&state, link: 2, "https://example.com/", focused: nil, at: 1)
        XCTAssertEqual(state.currentURL(for: .chrome, now: start + 2), "https://example.com/")
    }

    func testAProfileBehindNeverTakesAFill() {
        var state = BridgeState()
        let entry = login()
        state.pending.set(PendingFill(entryID: entry.id, browser: .chrome, website: entry.url, created: start)!)
        let behind = report(&state, link: 2, "https://github.com/login", focused: false, at: 1, entry: entry)
        XCTAssertNil(behind["fill"])
        XCTAssertNotNil(state.pending.pending, "it keeps waiting for the profile in front")
        let front = report(&state, link: 1, "https://github.com/login", focused: true, at: 2, entry: entry)
        XCTAssertEqual((front["fill"] as? [String: Any])?["username"] as? String, "octocat")
    }

    func testAFillForOneProfileIsNotTakenByAnother() {
        var state = BridgeState()
        let entry = login()
        state.pending.set(PendingFill(entryID: entry.id, browser: .chrome, website: entry.url, created: start, link: 1)!)
        let other = report(&state, link: 2, "https://github.com/login", focused: true, at: 1, entry: entry)
        XCTAssertNil(other["fill"])
        // The panel is still closing: Chrome has not given the window its focus back yet.
        let mine = report(&state, link: 1, "https://github.com/login", focused: false, at: 2, entry: entry)
        XCTAssertNotNil(mine["fill"])
    }

    func testTheCodeGoesToTheProfileThatFilled() {
        var state = BridgeState()
        let entry = login(code: true)
        state.pending.set(PendingFill(entryID: entry.id, browser: .chrome, website: entry.url, created: start, link: 1)!)
        let filled = report(&state, link: 1, "https://github.com/login", focused: true, at: 1, entry: entry)
        XCTAssertEqual((filled["fill"] as? [String: Any])?["otp"] as? Bool, true)
        let ask = request(#"{"type":"code","id":9,"url":"https://github.com/"}"#)
        let other = object(state.handle(ask, from: .chrome, link: 2, locked: false, now: start + 2, codeAllowed: { true }) { _ in entry })
        XCTAssertNil(other["otp"])
        let mine = object(state.handle(ask, from: .chrome, link: 1, locked: false, now: start + 3, codeAllowed: { true }) { _ in entry })
        XCTAssertNotNil(mine["otp"], "the other profile's question did not use it up")
    }

    func testAScannedCodeIsExpectedInTheProfileThatScanned() {
        var state = BridgeState()
        let entry = login(code: true)
        XCTAssertTrue(state.expectCode(afterScanOf: entry.id, browser: .chrome, link: 2, pageURL: "https://github.com", now: start))
        let other = report(&state, link: 1, "https://github.com/settings", focused: true, at: 1, entry: entry)
        XCTAssertNil(other["expectCode"])
        let mine = report(&state, link: 2, "https://github.com/settings", focused: true, at: 2, entry: entry)
        XCTAssertNotNil(mine["expectCode"])
    }

    func testAClosedProfileNoLongerCounts() {
        var state = BridgeState()
        report(&state, link: 1, "https://github.com/", focused: true)
        state.closed(BridgePeer(.chrome, link: 1))
        XCTAssertNil(state.currentURL(for: .chrome, now: start + 1))
        XCTAssertFalse(state.heardFrom(.chrome, now: start + 1))
        XCTAssertEqual(state.linkCount(.chrome), 0)
    }

    func testThePanelHoldsThePageOfTheProfileItOpenedOver() {
        var state = BridgeState()
        report(&state, link: 1, "https://github.com/", focused: true)
        state.panelOpened()
        // Asked by the panel's poke, while the panel has the keyboard.
        report(&state, link: 1, "https://github.com/", focused: false, at: 1)
        XCTAssertEqual(state.currentURL(for: .chrome, now: start + 2), "https://github.com/")
        state.panelClosed()
        XCTAssertNil(state.currentURL(for: .chrome, now: start + 2))
    }
}
