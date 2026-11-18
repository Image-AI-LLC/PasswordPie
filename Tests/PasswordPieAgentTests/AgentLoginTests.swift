import Foundation
import XCTest
@testable import PasswordPieAgent

/// `login` in the broker: which item, which website the fill is bound to, what is refused before anyone is asked, the
/// prompt, and that no answer or log line carries the password.
@MainActor
final class AgentLoginTests: XCTestCase {
    private var vault: FakeVault!
    private var approver: FakeApprover!
    private var activity: MemoryActivity!
    private var logins: FakeLogins!
    private var github: AgentItem!
    private var work: AgentItem!
    private var bank: AgentItem!
    private let planted = "planted-login-password-71c9"

    override func setUp() async throws {
        vault = FakeVault()
        approver = FakeApprover()
        activity = MemoryActivity()
        logins = FakeLogins()
        github = vault.add("GitHub", folder: ["Web"], password: planted)
        work = vault.add("GitHub Work", folder: ["Web"], password: planted + "-work")
        bank = vault.add("Bank", folder: ["Web"], password: "bank-password-9", shared: false)
        logins.websites = [
            github.id: ["https://github.com/login"],
            work.id: ["https://github.com/"],
            bank.id: ["https://bank.example/"],
        ]
        logins.usernames = [github.id: "octocat", work.id: "octo-work"]
    }

    private func broker(browserSide: Bool = true) -> VaultBroker {
        let broker = VaultBroker(vault: vault, approver: approver, grants: NoAgentGrants(), activity: activity) { true }
        broker.logins = browserSide ? logins : nil
        return broker
    }

    private func encoded(_ value: some Encodable) -> String {
        String(decoding: AgentCoding.encode(value), as: UTF8.self)
    }

    func testAllowOnceFillsTheItemsWebsiteAndAnswersTheOverviewOnly() async {
        logins.target?.page = .url("https://github.com/")
        approver.script = [.allow([0])]
        let answer = await broker().handle(.login("pp://Web/GitHub", reason: "Open billing"), from: Callers.make())
        XCTAssertNil(answer.errorCode)
        XCTAssertEqual(answer.login?.outcome, .submitted)
        XCTAssertEqual(answer.login?.item, AgentLoginOverview(title: "GitHub", username: "octocat", websites: ["https://github.com/login"]))
        XCTAssertEqual(answer.login?.site, "github.com")
        XCTAssertEqual(answer.login?.browser, "Google Chrome")
        XCTAssertEqual(answer.by, "once")
        XCTAssertEqual(logins.plans.count, 1)
        XCTAssertEqual(logins.plans[0].item.id, github.id)
        XCTAssertEqual(logins.plans[0].website, "https://github.com/login")
        XCTAssertEqual(logins.plans[0].target.link, 3)
        XCTAssertTrue(logins.plans[0].submit)
        let prompt = approver.prompts[0]
        XCTAssertEqual(prompt.kind, .login)
        XCTAssertFalse(prompt.raw)
        XCTAssertEqual(prompt.site, "github.com")
        XCTAssertEqual(prompt.browser, "Google Chrome, the profile in use")
        XCTAssertTrue(prompt.submit)
        XCTAssertEqual(prompt.reason, "Open billing")
        XCTAssertEqual(prompt.rows.map(\.title), ["GitHub"])
        XCTAssertEqual(prompt.rows[0].username, "octocat")
        XCTAssertEqual(prompt.rows[0].delivery, .fill)
        XCTAssertEqual(activity.records.map(\.outcome), [.submitted])
        XCTAssertEqual(activity.records[0].kind, "login")
        XCTAssertEqual(activity.records[0].items, ["Web/GitHub › login"])
        XCTAssertEqual(activity.records[0].delivery, ["fill Google Chrome github.com"])
        XCTAssertFalse(encoded(answer).contains(planted), "the answer never carries the password")
        XCTAssertFalse(encoded(activity.records).contains(planted), "the log never carries the password")
        XCTAssertFalse(encoded(approver.prompts.map(\.rows.description)).contains(planted))
        XCTAssertEqual(vault.secretReads, 0, "a login reads no secret in the broker: the browser side fills")
    }

    /// The acceptance check: a fill requested for site A is never bound to site B, and nobody is asked.
    func testAURLTheItemDoesNotListIsASiteMismatchBeforeAnyPrompt() async {
        let answer = await broker().handle(.login("pp://Web/GitHub", url: "https://gitlab.com/users/sign_in"), from: Callers.make())
        XCTAssertNil(answer.errorCode)
        XCTAssertEqual(answer.login?.outcome, .siteMismatch)
        XCTAssertEqual(answer.login?.site, "gitlab.com", "the site the agent asked for")
        XCTAssertNil(answer.login?.item, "no username or websites without an approval")
        XCTAssertTrue(approver.prompts.isEmpty)
        XCTAssertTrue(logins.plans.isEmpty)
        XCTAssertEqual(activity.records.map(\.outcome), [.siteMismatch])
        XCTAssertEqual(AgentLoginOutcome.siteMismatch.exitCode, 75)
    }

    func testTheTabInFrontOnAnotherSiteIsASiteMismatchWithoutAURL() async {
        logins.target?.page = .url("https://gitlab.com/")
        let answer = await broker().handle(.login("pp://Web/GitHub"), from: Callers.make())
        XCTAssertEqual(answer.login?.outcome, .siteMismatch)
        // Without a prompt, the answer never says which site the owner has open.
        XCTAssertNil(answer.login?.site)
        XCTAssertNil(answer.login?.item)
        XCTAssertFalse(encoded(answer).contains("gitlab"))
        XCTAssertTrue(approver.prompts.isEmpty)
        XCTAssertTrue(logins.plans.isEmpty)
    }

    /// The agent's tab is not the one in front: say so, never switch tabs.
    func testWithAURLTheTabInFrontOnAnotherSiteIsNoMatchingTab() async {
        logins.target?.page = .url("https://gitlab.com/")
        let answer = await broker().handle(.login("pp://Web/GitHub", url: "https://github.com/login"), from: Callers.make())
        XCTAssertEqual(answer.login?.outcome, .noMatchingTab)
        XCTAssertEqual(answer.login?.site, "github.com")
        XCTAssertEqual(answer.login?.detail, "The tab in front is on another site.")
        XCTAssertFalse(encoded(answer).contains("gitlab"))
        logins.target?.page = .notAWebsite
        let blank = await broker().handle(.login("pp://Web/GitHub"), from: Callers.make())
        XCTAssertEqual(blank.login?.outcome, .noMatchingTab)
        XCTAssertTrue(approver.prompts.isEmpty)
        XCTAssertTrue(logins.plans.isEmpty)
    }

    /// With several items for a site, any of their websites may match the tab in front.
    func testAnyOfTheOfferedWebsitesMayMatchTheTab() async {
        logins.websites[work.id] = ["http://github.com/"]
        logins.target?.page = .url("http://github.com/")
        approver.script = [.allow([1])]
        // The https item cannot fill the http tab; the http one can, so the window is shown.
        let answer = await broker().handle(.login(nil, url: "https://github.com/"), from: Callers.make())
        XCTAssertEqual(approver.prompts.first?.rows.count, 2)
        XCTAssertNil(answer.errorCode)
        XCTAssertEqual(answer.login?.outcome, .submitted)
    }

    func testNoExtensionIsNoMatchingTabWithoutAPrompt() async {
        logins.target = nil
        let answer = await broker().handle(.login("pp://Web/GitHub", browser: "safari"), from: Callers.make())
        XCTAssertEqual(answer.login?.outcome, .noMatchingTab)
        XCTAssertEqual(answer.login?.detail, "PasswordPie's extension is not connected in Safari.")
        XCTAssertEqual(logins.targetsAsked, [.safari])
        XCTAssertTrue(approver.prompts.isEmpty)
    }

    /// An unknown page binds the fill to the item's main website; the browser side then waits for a tab of it.
    func testAnUnknownPageBindsTheMainWebsite() async {
        approver.script = [.allow([0])]
        _ = await broker().handle(.login("pp://Web/GitHub"), from: Callers.make())
        XCTAssertEqual(logins.plans.first?.website, "https://github.com/login")
    }

    /// Without a reference, the shared items for the site are offered and the owner picks one. Unshared ones never show.
    func testAURLAloneOffersTheSharedItemsForThatSite() async {
        logins.websites[bank.id] = ["https://github.com/enterprise"]
        approver.script = [.allow([1])]
        let answer = await broker().handle(.login(nil, url: "https://github.com/login"), from: Callers.make())
        XCTAssertEqual(approver.prompts[0].rows.map(\.title), ["GitHub", "GitHub Work"])
        XCTAssertEqual(approver.prompts[0].rows.map(\.username), ["octocat", "octo-work"])
        XCTAssertEqual(logins.plans.first?.item.id, work.id)
        XCTAssertEqual(logins.plans.first?.website, "https://github.com/")
        XCTAssertEqual(answer.login?.item?.title, "GitHub Work")
    }

    func testPickingMoreThanOneIsADenial() async {
        approver.script = [.allow([0, 1])]
        let answer = await broker().handle(.login(nil, url: "https://github.com/"), from: Callers.make())
        XCTAssertEqual(answer.errorCode, .denied)
        XCTAssertTrue(logins.plans.isEmpty)
    }

    func testAURLWithNoSharedItemIsNotAvailable() async {
        let answer = await broker().handle(.login(nil, url: "https://bank.example/"), from: Callers.make())
        XCTAssertEqual(answer.errorCode, .notAvailable)
        XCTAssertEqual(answer.ref, "https://bank.example/")
        XCTAssertTrue(approver.prompts.isEmpty)
    }

    /// An unshared item answers exactly like one that does not exist.
    func testUnsharedAndNonexistentAnswerTheSame() async {
        let unshared = await broker().handle(.login("pp://Web/Bank"), from: Callers.make())
        vault.items.removeAll { $0.id == bank.id }
        let gone = await broker().handle(.login("pp://Web/Bank"), from: Callers.make())
        XCTAssertEqual(unshared, gone)
        XCTAssertEqual(unshared.errorCode, .notAvailable)
        XCTAssertTrue(approver.prompts.isEmpty)
    }

    func testDenyCountsTowardTheRateLimit() async {
        let broker = broker()
        approver.script = [.deny, .deny, .deny]
        for _ in 0..<3 {
            let denied = await broker.handle(.login("pp://Web/GitHub"), from: Callers.make())
            XCTAssertEqual(denied.errorCode, .denied)
        }
        let blocked = await broker.handle(.login("pp://Web/GitHub"), from: Callers.make())
        XCTAssertEqual(blocked.errorCode, .tooManyRequests)
        XCTAssertEqual(approver.prompts.count, 3)
        XCTAssertTrue(logins.plans.isEmpty)
    }

    /// Without Premium the code is not filled, and the prompt and the answer say so.
    func testWithoutPremiumTheCodeIsNotFilledAndTheAnswerSaysWhy() async {
        logins.codePlans[github.id] = .needsPremium
        logins.end = .finished(.submitted, code: .premiumRequired, detail: nil)
        approver.script = [.allow([0])]
        let answer = await broker().handle(.login("pp://Web/GitHub"), from: Callers.make())
        XCTAssertEqual(approver.prompts[0].rows[0].note, "Two-step code not filled: needs PasswordPie Premium.")
        XCTAssertEqual(logins.plans.first?.code, .needsPremium)
        XCTAssertEqual(answer.login?.code, .premiumRequired)
        XCTAssertTrue(answer.login?.line.contains("Two-step code not filled: needs PasswordPie Premium.") == true)
    }

    func testLockedWaitsThenAnswersLocked() async {
        vault.locked = true
        let answer = await broker().handle(.login("pp://Web/GitHub", wait: 0), from: Callers.make())
        XCTAssertEqual(answer.errorCode, .locked)
        XCTAssertTrue(approver.prompts.isEmpty)
        XCTAssertTrue(logins.targetsAsked.isEmpty, "nothing about the browser is asked while locked")
    }

    func testTheBrowserSideLockingAnswersLocked() async {
        logins.end = .locked
        approver.script = [.allow([0])]
        let answer = await broker().handle(.login("pp://Web/GitHub"), from: Callers.make())
        XCTAssertEqual(answer.errorCode, .locked)
        XCTAssertEqual(activity.records.map(\.outcome), [.locked])
    }

    func testAnItemUnsharedWhileThePromptWasUpIsNotFilled() async {
        approver.onPresent = { [unowned self] _ in self.vault.shared.remove(self.github.id) }
        approver.script = [.allow([0])]
        let answer = await broker().handle(.login("pp://Web/GitHub"), from: Callers.make())
        XCTAssertEqual(answer.errorCode, .notAvailable)
        XCTAssertTrue(logins.plans.isEmpty)
    }

    func testMalformedLoginsAreUsage() async {
        let broker = broker()
        let nothing = await broker.handle(.login(nil), from: Callers.make())
        XCTAssertEqual(nothing.errorCode, .usage)
        let field = await broker.handle(.login("pp://Web/GitHub/username"), from: Callers.make())
        XCTAssertEqual(field.errorCode, .usage)
        let notWeb = await broker.handle(.login("pp://Web/GitHub", url: "ftp://github.com/"), from: Callers.make())
        XCTAssertEqual(notWeb.errorCode, .usage)
        let browser = await broker.handle(.login("pp://Web/GitHub", browser: "firefox"), from: Callers.make())
        XCTAssertEqual(browser.errorCode, .usage)
        let noSide = await self.broker(browserSide: false).handle(.login("pp://Web/GitHub"), from: Callers.make())
        XCTAssertEqual(noSide.errorCode, .usage)
        XCTAssertTrue(approver.prompts.isEmpty)
    }

    /// `run` cannot ask for a value with the login delivery.
    func testUseRefusesTheFillDelivery() async {
        let answer = await broker().handle(.use([AgentSecretRequest(name: "T", ref: "pp://Web/GitHub", delivery: .fill)]), from: Callers.make())
        XCTAssertEqual(answer.errorCode, .usage)
        XCTAssertTrue(approver.prompts.isEmpty)
    }

    func testOutcomeLinesNeverCarryTheValueAndEndWithThePasteWarningOnFailure() {
        let item = AgentLoginOverview(title: "GitHub", username: "octocat", websites: ["https://github.com/"])
        for outcome in AgentLoginOutcome.allCases {
            let line = AgentLoginAnswer(outcome: outcome, item: item, site: "github.com", browser: "Google Chrome", code: AgentLoginCode.none).line
            XCTAssertFalse(line.contains("\n"))
            XCTAssertEqual(line.hasSuffix(AgentConstants.pasteWarning), !outcome.succeeded, outcome.rawValue)
        }
        XCTAssertEqual(AgentLoginOutcome.allCases.map(\.exitCode), [0, 0, 74, 75, 76, 77])
    }
}
