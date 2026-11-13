import XCTest
@testable import PasswordPieCore

/// Reset Password through the extension: the new password in a `tab` answer, and the page's `changed` report
/// (docs/BROWSER_EXTENSION.md, "`changed`").
final class BridgeChangeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 2_000_000)
    private let reset = "https://github.com/settings/security"

    private func login(password: String = "hunter2") -> VaultEntry {
        var entry = VaultEntry()
        entry.title = "GitHub"
        entry.url = "https://github.com"
        entry.username = "octocat"
        entry.password = password
        return entry
    }

    private func request(_ json: String) -> BridgeRequest {
        try! JSONDecoder().decode(BridgeRequest.self, from: Data(json.utf8))
    }

    private func object(_ response: BridgeResponse) -> [String: Any] {
        let data = try! JSONEncoder().encode(response)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func json(_ response: BridgeResponse) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(response), as: UTF8.self)
    }

    private var tab: BridgeRequest { request(#"{"type":"tab","id":7,"url":"https://github.com/","reason":"updated"}"#) }
    private var changed: BridgeRequest { request(#"{"type":"changed","id":8,"url":"https://github.com/"}"#) }

    /// A state whose reset fill was just taken by `browser` on `link`, at `start`.
    private func armed(_ entry: VaultEntry, browser: BridgeBrowser = .chrome, link: Int = 0) -> BridgeState {
        var state = BridgeState()
        state.pending.set(PendingFill(entryID: entry.id, browser: browser, website: reset, created: start, newPassword: "brand-new")!)
        _ = state.handle(tab, from: browser, link: link, locked: false, now: start) { _ in entry }
        return state
    }

    func testAResetFillCarriesTheNewPasswordAndArmsTheChange() {
        var state = BridgeState()
        let entry = login()
        state.pending.set(PendingFill(entryID: entry.id, browser: .chrome, website: reset, created: start, link: 3, newPassword: "brand-new")!)

        let answer = state.handle(tab, from: .chrome, link: 3, locked: false, now: start + 1) { _ in entry }

        XCTAssertEqual(
            json(answer),
            #"{"fill":{"expiresIn":29,"newPassword":"brand-new","origin":"https://github.com","password":"hunter2","username":"octocat"},"id":7,"type":"tab"}"#
        )
        XCTAssertEqual(state.pending.change, PendingChange(entryID: entry.id, browser: .chrome, link: 3, site: BrowserSite(url: reset)!, created: start + 1))
        XCTAssertNil(state.pending.pending, "the fill is used once")
    }

    func testAnOrdinaryFillHasNoNewPasswordKeyAndArmsNothing() {
        var state = BridgeState()
        let entry = login()
        state.pending.set(PendingFill(entryID: entry.id, browser: .chrome, website: entry.url, created: start)!)

        let answer = state.handle(tab, from: .chrome, locked: false, now: start + 1) { _ in entry }

        XCTAssertEqual(
            json(answer),
            #"{"fill":{"expiresIn":29,"origin":"https://github.com","password":"hunter2","username":"octocat"},"id":7,"type":"tab"}"#
        )
        XCTAssertNil(state.pending.change)
    }

    func testANewPasswordThatIsAlreadyTheSavedOneIsAnOrdinaryFill() {
        var state = BridgeState()
        let entry = login(password: "brand-new")
        state.pending.set(PendingFill(entryID: entry.id, browser: .chrome, website: reset, created: start, newPassword: "brand-new")!)
        let fill = object(state.handle(tab, from: .chrome, locked: false, now: start) { _ in entry })["fill"] as? [String: Any]
        XCTAssertEqual(fill?["password"] as? String, "brand-new")
        XCTAssertNil(fill?["newPassword"])
        XCTAssertNil(state.pending.change)
    }

    func testTheNewPasswordNeverGoesToAnotherSite() {
        var state = BridgeState()
        let entry = login()
        state.pending.set(PendingFill(entryID: entry.id, browser: .chrome, website: reset, created: start, newPassword: "brand-new")!)
        let elsewhere = request(#"{"type":"tab","id":7,"url":"https://github.com.evil.example/"}"#)
        XCTAssertNil(object(state.handle(elsewhere, from: .chrome, locked: false, now: start) { _ in entry })["fill"])
        XCTAssertNil(state.pending.change)

        // A reset address that is not on a site of the account: no account website allows the page.
        var other = BridgeState()
        other.pending.set(PendingFill(entryID: entry.id, browser: .chrome, website: "https://example.org/reset", created: start, newPassword: "brand-new")!)
        let page = request(#"{"type":"tab","id":7,"url":"https://example.org/"}"#)
        XCTAssertNil(object(other.handle(page, from: .chrome, locked: false, now: start) { _ in entry })["fill"])
        XCTAssertNil(other.pending.change)
    }

    func testChangedReportsTheAccountOnce() {
        let entry = login()
        var state = armed(entry)
        var reported: [UUID] = []

        let first = state.handle(changed, from: .chrome, locked: false, now: start + 60, changed: { reported.append($0) }) { _ in entry }
        let second = state.handle(changed, from: .chrome, locked: false, now: start + 61, changed: { reported.append($0) }) { _ in entry }

        XCTAssertEqual(reported, [entry.id])
        XCTAssertEqual(json(first), #"{"id":8,"type":"changed","version":1}"#)
        XCTAssertEqual(first, second, "the answer does not say whether an account matched")
        XCTAssertNil(state.pending.change)
    }

    func testChangedWithNothingWaitingGetsTheSameAnswerAndNoCall() {
        var state = BridgeState()
        var reported: [UUID] = []
        let answer = state.handle(changed, from: .chrome, locked: false, now: start, changed: { reported.append($0) }) { _ in nil }
        XCTAssertEqual(json(answer), #"{"id":8,"type":"changed","version":1}"#)
        XCTAssertTrue(reported.isEmpty)
        // Without a page, too: never an error.
        let bare = state.handle(request(#"{"type":"changed","id":9}"#), from: .chrome, locked: false, now: start, changed: { reported.append($0) }) { _ in nil }
        XCTAssertEqual(json(bare), #"{"id":9,"type":"changed","version":1}"#)
        XCTAssertTrue(reported.isEmpty)
    }

    func testChangedFromAnotherBrowserOrProfileIsNotIt() {
        let entry = login()
        var state = armed(entry, browser: .chrome, link: 2)
        var reported: [UUID] = []
        _ = state.handle(changed, from: .safari, locked: false, now: start + 5, changed: { reported.append($0) }) { _ in entry }
        _ = state.handle(changed, from: .chrome, link: 1, locked: false, now: start + 5, changed: { reported.append($0) }) { _ in entry }
        XCTAssertTrue(reported.isEmpty)
        XCTAssertNotNil(state.pending.change, "it still waits for the profile that got the password")
        _ = state.handle(changed, from: .chrome, link: 2, locked: false, now: start + 6, changed: { reported.append($0) }) { _ in entry }
        XCTAssertEqual(reported, [entry.id])
    }

    func testChangedFromAnotherSiteOrADowngradedPageIsNotIt() {
        let entry = login()
        var state = armed(entry)
        var reported: [UUID] = []
        for url in ["https://example.com/", "http://github.com/", "chrome://settings/"] {
            let report = request(#"{"type":"changed","id":8,"url":"\#(url)"}"#)
            let answer = state.handle(report, from: .chrome, locked: false, now: start + 5, changed: { reported.append($0) }) { _ in entry }
            XCTAssertEqual(json(answer), #"{"id":8,"type":"changed","version":1}"#)
        }
        XCTAssertTrue(reported.isEmpty)
        XCTAssertNotNil(state.pending.change)
        // Another host of the same site is the site.
        let sub = request(#"{"type":"changed","id":8,"url":"https://gist.github.com/"}"#)
        _ = state.handle(sub, from: .chrome, locked: false, now: start + 6, changed: { reported.append($0) }) { _ in entry }
        XCTAssertEqual(reported, [entry.id])
    }

    func testChangedCountsForTenMinutes() {
        let entry = login()
        var reported: [UUID] = []
        var inTime = armed(entry)
        _ = inTime.handle(changed, from: .chrome, locked: false, now: start + 600, changed: { reported.append($0) }) { _ in entry }
        XCTAssertEqual(reported, [entry.id])

        reported = []
        var late = armed(entry)
        _ = late.handle(changed, from: .chrome, locked: false, now: start + 601, changed: { reported.append($0) }) { _ in entry }
        XCTAssertTrue(reported.isEmpty)
        XCTAssertNil(late.pending.change, "an expired one is deleted unused")
    }

    func testLockingForgetsTheChange() {
        let entry = login()
        var reported: [UUID] = []
        var state = armed(entry)
        let locked = state.handle(changed, from: .chrome, locked: true, now: start + 5, changed: { reported.append($0) }) { _ in entry }
        XCTAssertEqual(json(locked), #"{"id":8,"type":"changed","version":1}"#)
        XCTAssertNil(state.pending.change)
        _ = state.handle(changed, from: .chrome, locked: false, now: start + 6, changed: { reported.append($0) }) { _ in entry }
        XCTAssertTrue(reported.isEmpty, "unlocking does not bring it back")

        var cleared = armed(entry)
        cleared.pending.clear()
        XCTAssertNil(cleared.pending.change)
    }

    func testChangedForAnAccountThatIsGoneOrMovedSitesIsNotReported() {
        let entry = login()
        var reported: [UUID] = []
        var gone = armed(entry)
        _ = gone.handle(changed, from: .chrome, locked: false, now: start + 5, changed: { reported.append($0) }) { _ in nil }
        var moved = armed(entry)
        var elsewhere = entry
        elsewhere.url = "https://example.com"
        _ = moved.handle(changed, from: .chrome, locked: false, now: start + 5, changed: { reported.append($0) }) { _ in elsewhere }
        XCTAssertTrue(reported.isEmpty)
    }

    func testAnotherPickDoesNotAnswerTheChange() {
        let entry = login()
        var state = armed(entry)
        state.pending.set(PendingFill(entryID: UUID(), browser: .chrome, website: "https://example.com", created: start + 5)!)
        XCTAssertNotNil(state.pending.change)
    }
}
