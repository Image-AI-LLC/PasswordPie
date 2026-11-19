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

    /// With no extension there is no tab to bring forward: the line says what is missing and who can fix it.
    func testNoExtensionSaysSoInsteadOfBlamingTheTab() async throws {
        logins.target = nil
        let answer = await broker().handle(.login("pp://Web/GitHub", url: "https://github.com/login"), from: Callers.make())
        let login = try XCTUnwrap(answer.login)
        XCTAssertEqual(login.outcome, .noMatchingTab)
        XCTAssertEqual(
            login.line,
            "PasswordPie: nothing was filled. PasswordPie's extension is not connected in Google Chrome or Safari. Ask the owner to turn it on "
                + "(PasswordPie > Preferences > Browsers), then try again. " + AgentConstants.pasteWarning
        )
        XCTAssertFalse(login.line(mcp: true).contains("tab in front"))
        XCTAssertTrue(login.line(mcp: true).hasSuffix(AgentConstants.mcpGuidance))
        // A tab that is elsewhere keeps its own line.
        logins.target = AgentLoginTarget(browser: .chrome, profile: nil, link: 1, page: .url("https://gitlab.com/"))
        let elsewhere = await broker().handle(.login("pp://Web/GitHub", url: "https://github.com/login"), from: Callers.make())
        XCTAssertTrue(try XCTUnwrap(elsewhere.login).line.hasPrefix("PasswordPie: the tab in front in Google Chrome is not on github.com; nothing was filled."))
    }

    /// A site the item does not list is refused as that, whether or not a browser could fill: it needs none to know.
    func testASiteMismatchDoesNotNeedABrowser() async {
        logins.target = nil
        let answer = await broker().handle(.login("pp://Web/GitHub", url: "https://gitlab.com/users/sign_in"), from: Callers.make())
        XCTAssertEqual(answer.login?.outcome, .siteMismatch)
        XCTAssertEqual(answer.login?.site, "gitlab.com")
        XCTAssertNil(answer.login?.item)
        XCTAssertTrue(logins.targetsAsked.isEmpty, "the extension is not poked for a login that cannot happen")
        XCTAssertTrue(approver.prompts.isEmpty)
        XCTAssertEqual(activity.records.map(\.outcome), [.siteMismatch])
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

    func testAccessTurnedOffWhileThePromptWasUpFillsNothing() async {
        var on = true
        let broker = VaultBroker(vault: vault, approver: approver, grants: NoAgentGrants(), activity: activity) { on }
        broker.logins = logins
        approver.onPresent = { _ in on = false }
        approver.script = [.allow([0])]
        let answer = await broker.handle(.login("pp://Web/GitHub"), from: Callers.make())
        XCTAssertEqual(answer.errorCode, .accessOff)
        XCTAssertTrue(logins.plans.isEmpty)
    }

    func testAnItemUnsharedWhileThePromptWasUpIsNotFilled() async {
        approver.onPresent = { [unowned self] _ in self.vault.shared.remove(self.github.id) }
        approver.script = [.allow([0])]
        let answer = await broker().handle(.login("pp://Web/GitHub"), from: Callers.make())
        XCTAssertEqual(answer.errorCode, .notAvailable)
        XCTAssertTrue(logins.plans.isEmpty)
    }

    /// A page's address is logged as its origin only: its path and query can hold a token.
    func testActivityKeepsOnlyTheOriginOfAnAddress() async {
        _ = await broker().handle(.login(nil, url: "https://bank.example/reset?token=planted-reset-token-42#x"), from: Callers.make())
        _ = await broker().handle(.login(nil, url: "ftp://bank.example/?token=planted-reset-token-42"), from: Callers.make())
        let logged = encoded(activity.records)
        XCTAssertFalse(logged.contains("planted-reset-token-42"), logged)
        XCTAssertEqual(activity.records.first?.items, ["https://bank.example/"])
        XCTAssertEqual(VaultBroker.loggedAddress("bank.example/reset?token=x"), "https://bank.example/")
        XCTAssertEqual(VaultBroker.loggedAddress("http://[::1]:8080/reset?t=x"), "http://[::1]:8080/")
        XCTAssertEqual(VaultBroker.loggedAddress("HTTPS://Bank.Example:443/x"), "https://bank.example/")
        XCTAssertEqual(VaultBroker.loggedAddress("localhost:8000/login?x=1"), "https://localhost:8000/")
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

    // MARK: Lasting login permissions (Premium)

    private func grantStore(premium: Bool) -> (StandingPermissions, FakeGrantDatabase) {
        let database = FakeGrantDatabase()
        let store = StandingPermissions(
            mac: "mac-1", hasPremium: { premium }, read: { database.read() }, write: { edit, done in database.write(edit, done) }
        )
        store.sessionAlive = { _ in true }
        return (store, database)
    }

    private func broker(grants: AgentGrantStore) -> VaultBroker {
        let broker = VaultBroker(vault: vault, approver: approver, grants: grants, activity: activity) { true }
        broker.logins = logins
        return broker
    }

    /// "Allow for 7 days" on a login: the next login with that item, on that site, by that agent, asks nothing, in any
    /// project. Another item, another site or another agent asks again.
    func testALoginGrantCoversTheItemSiteAndAgentOnly() async {
        let (store, database) = grantStore(premium: true)
        let broker = broker(grants: store)
        logins.target?.page = .url("https://github.com/")
        approver.script = [.allowLasting([0], .days7)]
        let first = await broker.handle(.login("pp://Web/GitHub"), from: Callers.make())
        XCTAssertEqual(first.login?.outcome, .submitted)
        XCTAssertEqual(approver.prompts.first?.lasting, .offered)
        XCTAssertEqual(AgentGrants(customData: database.customData).all.map(\.site), ["github.com"])
        XCTAssertEqual(activity.records.last?.outcomeText, "filled and sent, and for 7 days, github.com")
        XCTAssertEqual(activity.records.last?.ranUnderGrant, false, "the owner saw that one")

        let again = await broker.handle(.login("pp://Web/GitHub"), from: Callers.make(project: "/tmp/elsewhere"))
        XCTAssertEqual(again.login?.outcome, .submitted)
        XCTAssertEqual(again.by, "7 days, github.com")
        XCTAssertEqual(approver.prompts.count, 1, "no window under the grant, in another project too")
        XCTAssertEqual(activity.records.last?.outcomeText, "filled and sent, by 7 days, github.com")
        XCTAssertEqual(activity.records.last?.ranUnderGrant, true, "the menu-bar dot shows for it")
        XCTAssertEqual(logins.plans.count, 2)

        approver.script = [.deny, .deny, .deny]
        _ = await broker.handle(.login("pp://Web/GitHub Work"), from: Callers.make())
        _ = await broker.handle(.login("pp://Web/GitHub"), from: Callers.make(session: "agent:300:3", agent: "codex"))
        logins.websites[github.id] = ["https://github.com/login", "https://gist.github.io/"]
        logins.target?.page = .url("https://gist.github.io/")
        _ = await broker.handle(.login("pp://Web/GitHub"), from: Callers.make())
        XCTAssertEqual(approver.prompts.count, 4, "another item, another agent and another site each ask")
    }

    /// Without Premium the lasting choice makes nothing, and a grant already in the file is not used.
    func testWithoutPremiumNoLoginGrantIsMadeOrUsed() async {
        let (store, database) = grantStore(premium: false)
        let broker = broker(grants: store)
        approver.script = [.allowLasting([0], .days7), .allowLasting([0], .days7), .allow([0])]
        _ = await broker.handle(.login("pp://Web/GitHub"), from: Callers.make())
        XCTAssertTrue(AgentGrants(customData: database.customData).isEmpty)
        let (premiumStore, premiumDatabase) = grantStore(premium: true)
        _ = await self.broker(grants: premiumStore).handle(.login("pp://Web/GitHub"), from: Callers.make())
        database.customData = premiumDatabase.customData
        _ = await broker.handle(.login("pp://Web/GitHub"), from: Callers.make())
        XCTAssertEqual(approver.prompts.count, 3, "the grant is not used without Premium")
        XCTAssertTrue(approver.script.isEmpty)
    }

    /// A login grant never makes `run` (or `list`'s "covered") skip the window for the same item.
    func testALoginGrantDoesNotCoverRunningWithTheItem() async {
        let (store, _) = grantStore(premium: true)
        let broker = broker(grants: store)
        approver.script = [.allowLasting([0], .days7), .allow([0])]
        _ = await broker.handle(.login("pp://Web/GitHub"), from: Callers.make())
        let run = await broker.handle(.use([AgentSecretRequest(name: "T", ref: "pp://Web/GitHub", delivery: .env)]), from: Callers.make())
        XCTAssertEqual(run.by, "once")
        XCTAssertEqual(approver.prompts.count, 2)
        XCTAssertFalse(store.covers(github, for: Callers.make()))
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
