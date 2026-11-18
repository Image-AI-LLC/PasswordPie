#if PP_DIRECT
import XCTest
@testable import PasswordPieCore

/// An agent's login through the extension (docs/BROWSER_EXTENSION.md, "Agent logins"): the pending fill is bound to one
/// site and one connection, a report of another site from that connection drops it, and `login-result` counts once, from
/// the connection and site that took it.
final class BridgeAgentLoginTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 3_000_000)
    private let token = UUID()

    private func login(code: Bool = false) -> VaultEntry {
        var entry = VaultEntry()
        entry.title = "GitHub"
        entry.url = "https://github.com/login"
        entry.username = "octocat"
        entry.password = "planted-agent-pass-55"
        if code { entry.otp = "otpauth://totp/GitHub:octocat?secret=JBSWY3DPEHPK3PXP&issuer=GitHub" }
        return entry
    }

    private func request(_ json: String) -> BridgeRequest {
        try! JSONDecoder().decode(BridgeRequest.self, from: Data(json.utf8))
    }

    private func json(_ response: BridgeResponse) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(response), as: UTF8.self)
    }

    private func tab(_ url: String, focused: Bool? = nil) -> BridgeRequest {
        let focus = focused.map { #","focused":\#($0)"# } ?? ""
        return request(#"{"type":"tab","id":7,"url":"\#(url)","reason":"poke"\#(focus)}"#)
    }

    private func result(_ result: String, url: String = "https://github.com/", loginId: UUID? = nil) -> BridgeRequest {
        request(#"{"type":"login-result","id":8,"url":"\#(url)","result":"\#(result)","loginId":"\#((loginId ?? token).uuidString)"}"#)
    }

    private func armed(_ entry: VaultEntry, submit: Bool = true, link: Int? = 2, browser: BridgeBrowser = .chrome) -> BridgeState {
        var state = BridgeState()
        var fill = PendingFill(entryID: entry.id, browser: browser, website: entry.url, created: start, link: link)!
        fill.agent = AgentFillTicket(token: token, submit: submit)
        state.pending.set(fill)
        return state
    }

    private func handle(
        _ state: inout BridgeState, _ request: BridgeRequest, _ entry: VaultEntry, link: Int = 2, browser: BridgeBrowser = .chrome,
        at offset: TimeInterval = 1, locked: Bool = false, premium: Bool = false, events: inout [AgentFillEvent]
    ) -> BridgeResponse {
        var seen: [AgentFillEvent] = []
        let answer = state.handle(request, from: browser, link: link, locked: locked, now: start + offset, codeAllowed: { premium }, agent: { seen.append($0) }) { _ in entry }
        events += seen
        return answer
    }

    func testTheFillCarriesSubmitAndReportAndIsTakenOnItsSite() {
        let entry = login()
        var state = armed(entry)
        var events: [AgentFillEvent] = []
        let answer = handle(&state, tab("https://github.com/"), entry, events: &events)
        XCTAssertEqual(
            json(answer),
            #"{"fill":{"expiresIn":29,"loginId":"\#(token.uuidString)","origin":"https://github.com","password":"planted-agent-pass-55","report":true,"submit":true,"username":"octocat"},"id":7,"type":"tab"}"#
        )
        XCTAssertEqual(events, [.taken(token)])
        XCTAssertNil(state.pending.pending)
        XCTAssertEqual(state.pending.agentResult?.link, 2)
    }

    func testWithoutSubmitTheFillOnlyReports() {
        let entry = login()
        var state = armed(entry, submit: false)
        var events: [AgentFillEvent] = []
        let answer = handle(&state, tab("https://github.com/"), entry, events: &events)
        XCTAssertTrue(json(answer).contains(#""report":true"#))
        XCTAssertFalse(json(answer).contains("submit"))
    }

    /// The acceptance check: a fill requested for site A is never answered on site B. The connection's report of B says
    /// the agent's tab is not in front, and the fill is dropped, so a later switch to A gets nothing either.
    func testAFillForSiteAIsNeverAnsweredOnSiteB() {
        let entry = login()
        var state = armed(entry)
        var events: [AgentFillEvent] = []
        let other = handle(&state, tab("https://gitlab.com/"), entry, events: &events)
        XCTAssertNil(other.fill)
        XCTAssertFalse(json(other).contains("planted-agent-pass-55"))
        XCTAssertEqual(events, [.otherSite(token, site: "gitlab.com")])
        XCTAssertNil(state.pending.pending, "dropped, not left for a tab switch")
        let after = handle(&state, tab("https://github.com/"), entry, at: 2, events: &events)
        XCTAssertNil(after.fill)
    }

    func testANonWebTabInFrontSaysSo() {
        let entry = login()
        var state = armed(entry)
        var events: [AgentFillEvent] = []
        _ = handle(&state, tab(""), entry, events: &events)
        XCTAssertEqual(events, [.otherSite(token, site: nil)])
    }

    func testADowngradedPageIsAnotherSite() {
        let entry = login()
        var state = armed(entry)
        var events: [AgentFillEvent] = []
        let answer = handle(&state, tab("http://github.com/"), entry, events: &events)
        XCTAssertNil(answer.fill)
        XCTAssertEqual(events, [.otherSite(token, site: "github.com")])
    }

    /// Another profile's tab neither takes the fill nor ends it.
    func testAnotherConnectionNeitherTakesNorEndsIt() {
        let entry = login()
        var state = armed(entry)
        var events: [AgentFillEvent] = []
        XCTAssertNil(handle(&state, tab("https://github.com/"), entry, link: 5, events: &events).fill)
        XCTAssertNil(handle(&state, tab("https://gitlab.com/"), entry, link: 5, events: &events).fill)
        XCTAssertTrue(events.isEmpty)
        XCTAssertNotNil(handle(&state, tab("https://github.com/"), entry, link: 2, events: &events).fill)
    }

    func testAFillForNoConnectionIgnoresAProfileThatSaysItIsNotInFront() {
        let entry = login()
        var state = armed(entry, link: nil)
        var events: [AgentFillEvent] = []
        _ = handle(&state, tab("https://gitlab.com/", focused: false), entry, link: 4, events: &events)
        XCTAssertTrue(events.isEmpty)
        XCTAssertNotNil(state.pending.pending)
    }

    func testAnExpiredFillIsNeitherTakenNorReported() {
        let entry = login()
        var state = armed(entry)
        var events: [AgentFillEvent] = []
        let late = handle(&state, tab("https://gitlab.com/"), entry, at: PendingFillStore.lifetime + 1, events: &events)
        XCTAssertNil(late.fill)
        XCTAssertTrue(events.isEmpty)
        XCTAssertNil(handle(&state, tab("https://github.com/"), entry, at: PendingFillStore.lifetime + 2, events: &events).fill)
    }

    func testTheResultCountsOnceFromTheConnectionAndSiteThatTookIt() {
        let entry = login()
        var state = armed(entry)
        var events: [AgentFillEvent] = []
        _ = handle(&state, tab("https://github.com/"), entry, events: &events)
        events = []
        let fromElsewhere = handle(&state, result("submitted"), entry, link: 9, at: 2, events: &events)
        _ = handle(&state, result("submitted", url: "https://gitlab.com/"), entry, at: 2, events: &events)
        _ = handle(&state, result("made-up"), entry, at: 2, events: &events)
        // Word about an older fill on the same site and connection is not this one's.
        _ = handle(&state, result("no-fields", loginId: UUID()), entry, at: 2, events: &events)
        XCTAssertTrue(events.isEmpty)
        let counted = handle(&state, result("submitted"), entry, at: 3, events: &events)
        XCTAssertEqual(events, [.result(token, "submitted")])
        _ = handle(&state, result("filled"), entry, at: 4, events: &events)
        XCTAssertEqual(events.count, 1, "once")
        XCTAssertEqual(json(fromElsewhere), json(counted), "the answer says nothing about what was waiting")
        XCTAssertEqual(json(counted), #"{"id":8,"type":"login-result"}"#)
    }

    func testTheResultIsNotTakenWhileLockedOrTooLate() {
        let entry = login()
        var state = armed(entry)
        var events: [AgentFillEvent] = []
        _ = handle(&state, tab("https://github.com/"), entry, events: &events)
        events = []
        _ = handle(&state, result("submitted"), entry, at: 1 + PendingFillStore.agentResultLifetime + 1, events: &events)
        XCTAssertTrue(events.isEmpty)
    }

    /// The code after an agent's fill: with Premium it goes in and the agent hears so; without, it does not.
    func testTheCodeIsReportedWithAndWithoutPremium() {
        let entry = login(code: true)
        for premium in [true, false] {
            var state = armed(entry)
            var events: [AgentFillEvent] = []
            let fill = handle(&state, tab("https://github.com/"), entry, events: &events)
            XCTAssertTrue(json(fill).contains(#""otp":true"#))
            events = []
            let code = handle(&state, request(#"{"type":"code","id":9,"url":"https://github.com/"}"#), entry, at: 3, premium: premium, events: &events)
            XCTAssertEqual(events, [.code(token, filled: premium)])
            XCTAssertEqual(code.otp != nil, premium)
            XCTAssertEqual(code.premium, premium ? nil : false)
        }
    }

    func testAnOrdinaryFillHasNoAgentKeysAndNoEvents() {
        let entry = login()
        var state = BridgeState()
        state.pending.set(PendingFill(entryID: entry.id, browser: .chrome, website: entry.url, created: start, link: 2)!)
        var events: [AgentFillEvent] = []
        XCTAssertNil(handle(&state, tab("https://gitlab.com/"), entry, events: &events).fill)
        let answer = handle(&state, tab("https://github.com/"), entry, events: &events)
        XCTAssertFalse(json(answer).contains("report"))
        XCTAssertFalse(json(answer).contains("submit"))
        XCTAssertTrue(events.isEmpty)
        XCTAssertNil(state.pending.agentResult)
    }

    func testWithdrawingDropsOnlyThatFill() {
        let entry = login()
        var state = armed(entry)
        state.pending.withdrawAgentFill(UUID())
        XCTAssertNotNil(state.pending.pending)
        state.pending.withdrawAgentFill(token)
        XCTAssertNil(state.pending.pending)
    }
}
#endif
