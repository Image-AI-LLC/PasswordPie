import PasswordPieCore
import XCTest
@testable import PasswordPie

/// The App Store channel: no account, no network. Premium is this Apple Account's purchases or an activation from the website.
@MainActor
final class AppStorePremiumStoreTests: XCTestCase {
    private var clock = PremiumFixtures.now
    private var backend: FakePremiumBackend!
    private var secrets: FakeSecrets!
    private var store: AppStorePremiumStore!
    private var paywalls = 0

    override func setUp() async throws {
        clock = PremiumFixtures.now
        backend = FakePremiumBackend()
        secrets = FakeSecrets()
        paywalls = 0
        store = makeStore()
    }

    override func tearDown() async throws {
        store.stop()
    }

    private func makeStore(firstCheckTimeout: TimeInterval = 3) -> AppStorePremiumStore {
        let store = AppStorePremiumStore(
            backend: backend,
            secrets: secrets,
            verify: PassKey.verifyActivation,
            now: { [unowned self] in self.clock },
            firstCheckTimeout: firstCheckTimeout
        )
        store.presentPaywall = { [unowned self] in self.paywalls += 1 }
        return store
    }

    private func later(_ seconds: TimeInterval) -> Date { PremiumFixtures.now.addingTimeInterval(seconds) }
    private var year: Date { later(365 * 86400) }

    // MARK: Who has Premium

    func testAPurchaseUnlocksWithNoAccount() async {
        backend.transactions = [PremiumFixtures.lifetime]
        await store.refresh()
        XCTAssertTrue(store.hasPremium)
        XCTAssertEqual(secrets.values, [:], "a purchase keeps nothing of ours")
    }

    func testNoPurchaseIsFree() async {
        await store.refresh()
        XCTAssertFalse(store.hasPremium)
        XCTAssertEqual(store.storeStatus, .free)
    }

    func testAnUnverifiedPurchaseUnlocksNothing() async {
        backend.transactions = [PremiumTransaction(productID: PremiumPlan.lifetime.productID, verified: false, revocationDate: nil, expirationDate: nil)]
        await store.refresh()
        XCTAssertFalse(store.hasPremium)
    }

    func testARefundLocksAtTheNextLook() async {
        backend.transactions = [PremiumFixtures.lifetime]
        await store.refresh()
        backend.transactions = [PremiumTransaction(productID: PremiumPlan.lifetime.productID, verified: true, revocationDate: clock, expirationDate: nil)]
        await store.refresh()
        XCTAssertFalse(store.hasPremium)
    }

    func testASubscriptionLocksTheMomentItRunsOut() async {
        backend.transactions = [PremiumFixtures.yearly(expires: later(60))]
        await store.refresh()
        XCTAssertTrue(store.hasPremium)
        clock = later(61)
        XCTAssertFalse(store.hasPremium, "with no event from the store")
    }

    func testAnUpdateFromTheStoreUnlocks() async {
        store.start()
        let answered = await waitUntil { self.store.storeStatus == .free }
        XCTAssertTrue(answered)
        backend.transactions = [PremiumFixtures.lifetime]
        backend.emitUpdate()
        let unlocked = await waitUntil { self.store.hasPremium }
        XCTAssertTrue(unlocked)
    }

    func testAStoreThatNeverAnswersFailsClosedAndStillOpensTheWindow() async {
        backend.holdsAnswers = true
        let store = makeStore(firstCheckTimeout: 0.01)
        store.start()
        store.requestUnlock()
        let opened = await waitUntil { self.paywalls == 1 }
        XCTAssertTrue(opened)
        XCTAssertFalse(store.hasPremium)
        backend.answer()
        store.stop()
    }

    func testARequestDuringTheCheckWaitsAndRunsForAPurchaser() async {
        backend.holdsAnswers = true
        backend.transactions = [PremiumFixtures.lifetime]
        store.start()
        var ran = 0
        store.requestUnlock { ran += 1 }
        XCTAssertEqual(ran, 0)
        let held = await waitUntil { self.backend.answerGate != nil }
        XCTAssertTrue(held)
        backend.answer()
        let done = await waitUntil { ran == 1 }
        XCTAssertTrue(done)
        XCTAssertEqual(paywalls, 0)
    }

    func testAFreeUserAskingForACodeOpensTheWindow() async {
        await store.refresh()
        var ran = 0
        store.requestUnlock { ran += 1 }
        XCTAssertEqual(ran, 0)
        XCTAssertEqual(paywalls, 1)
    }

    // MARK: Activation from the website

    func testAGoodLinkUnlocksAndIsKept() async {
        await store.refresh()
        let link = PassKey.activationLink(expires: year)
        XCTAssertTrue(store.activate(link))
        XCTAssertTrue(store.hasPremium)
        XCTAssertEqual(store.activity, .activated(until: year))
        XCTAssertEqual(secrets.values[.activation], ActivationLink.token(in: link))
    }

    func testAKeptActivationUnlocksAfterALaunchWithNoStoreAnswer() async {
        secrets.values[.activation] = ActivationLink.token(in: PassKey.activationLink(expires: year))
        backend.holdsAnswers = true
        store.start()
        XCTAssertTrue(store.hasPremium, "nothing to wait for")
        let held = await waitUntil { self.backend.answerGate != nil }
        XCTAssertTrue(held)
        backend.answer()
    }

    func testAForgedLinkChangesNothing() async {
        await store.refresh()
        let forged = PassKey.activationLink(expires: year, signer: .init())
        XCTAssertTrue(store.activate(forged), "still ours to answer")
        XCTAssertFalse(store.hasPremium)
        XCTAssertEqual(store.activity, .activationFailed)
        XCTAssertEqual(secrets.values, [:])
    }

    func testAnExpiredLinkChangesNothing() async {
        await store.refresh()
        store.activate(PassKey.activationLink(expires: later(-60)))
        XCTAssertFalse(store.hasPremium)
        XCTAssertEqual(store.activity, .activationFailed)
    }

    func testTheSevenDayPassForTheBrowserIsNotAnActivation() async {
        await store.refresh()
        let pass = PassKey.pass(expires: year)
        store.activate(URL(string: "passwordpie://activate?token=\(pass)")!)
        XCTAssertFalse(store.hasPremium)
    }

    func testALinkWithoutATokenSaysSo() async {
        await store.refresh()
        XCTAssertTrue(store.activate(URL(string: "passwordpie://activate")!))
        XCTAssertEqual(store.activity, .activationFailed)
    }

    func testOtherURLsAreNotOurs() async {
        XCTAssertFalse(store.activate(URL(string: "passwordpie://auth?code=abc")!))
        XCTAssertEqual(store.activity, .idle)
    }

    func testAnActivationLocksTheMomentItRunsOutAndIsForgotten() async {
        await store.refresh()
        store.activate(PassKey.activationLink(expires: later(60)))
        XCTAssertTrue(store.hasPremium)
        clock = later(61)
        XCTAssertFalse(store.hasPremium)
        await store.refresh()
        XCTAssertNil(store.activation)
        XCTAssertNil(secrets.values[.activation])
    }

    func testAForgedActivationInTheKeychainIsThrownAway() async {
        secrets.values[.activation] = "forged.token.here"
        await store.refresh()
        XCTAssertFalse(store.hasPremium)
        XCTAssertNil(secrets.values[.activation])
    }

    func testRenewingKeepsTheLaterDate() async {
        await store.refresh()
        store.activate(PassKey.activationLink(expires: later(100)))
        store.activate(PassKey.activationLink(expires: year))
        XCTAssertEqual(store.activation?.expiresAt, year)
    }

    func testAnOlderLinkCannotShortenAnActivation() async {
        await store.refresh()
        let long = PassKey.activationLink(expires: year)
        store.activate(long)
        store.activate(PassKey.activationLink(expires: later(100)))
        XCTAssertEqual(store.activation?.expiresAt, year)
        XCTAssertEqual(secrets.values[.activation], ActivationLink.token(in: long))
        XCTAssertEqual(store.activity, .activated(until: year))
    }

    func testALinkArrivingDuringAPurchaseLeavesThePurchaseAlone() async {
        await store.refresh()
        backend.holdsPurchases = true
        let buying = Task { await store.purchase(.lifetime) }
        let held = await waitUntil { self.backend.purchaseGate != nil }
        XCTAssertTrue(held)
        store.activate(PassKey.activationLink(expires: year))
        XCTAssertEqual(store.activity, .purchasing(.lifetime))
        backend.purchaseGate?.resume()
        await buying.value
        XCTAssertEqual(store.activity, .idle)
    }

    // MARK: Buying

    func testBuyingNeedsNoSignInAndUnlocks() async {
        await store.refresh()
        await store.purchase(.lifetime)
        XCTAssertEqual(backend.purchases, [.lifetime])
        XCTAssertTrue(store.hasPremium)
        XCTAssertEqual(store.activity, .idle)
    }

    func testAPendingPurchaseWaitsThenUnlocksByItself() async {
        store.start()
        backend.purchaseOutcome = .success(.pending)
        await store.purchase(.lifetime)
        XCTAssertEqual(store.activity, .pending(.lifetime))
        XCTAssertFalse(store.hasPremium)
        backend.transactions = [PremiumFixtures.lifetime]
        backend.emitUpdate()
        let unlocked = await waitUntil { self.store.hasPremium && self.store.activity == .idle }
        XCTAssertTrue(unlocked)
    }

    func testACancelledPurchaseLeavesEverythingAlone() async {
        backend.purchaseOutcome = .success(.cancelled)
        await store.refresh()
        await store.purchase(.lifetime)
        XCTAssertEqual(store.activity, .cancelled)
        XCTAssertFalse(store.hasPremium)
    }

    func testAFailedPurchaseShowsTheStoresReason() async {
        backend.purchaseOutcome = .failure(FakePremiumBackend.Failure())
        await store.refresh()
        await store.purchase(.lifetime)
        XCTAssertEqual(store.activity, .failed("The App Store said no."))
    }

    func testAnUnverifiedPurchaseSaysSo() async {
        backend.purchaseOutcome = .success(.unverified)
        await store.refresh()
        await store.purchase(.lifetime)
        XCTAssertTrue(store.activity.isError)
        XCTAssertFalse(store.hasPremium)
    }

    func testAPlanAlreadyOwnedIsNotBoughtAgain() async {
        backend.transactions = [PremiumFixtures.lifetime]
        await store.refresh()
        await store.purchase(.lifetime)
        XCTAssertEqual(store.activity, .alreadyOwned(.lifetime))
        XCTAssertEqual(backend.purchases, [])
    }

    func testOnlyOnePurchaseRunsAtATime() async {
        await store.refresh()
        backend.holdsPurchases = true
        let first = Task { await store.purchase(.lifetime) }
        let held = await waitUntil { self.backend.purchaseGate != nil }
        XCTAssertTrue(held)
        await store.purchase(.yearly)
        XCTAssertEqual(backend.purchases, [.lifetime])
        backend.purchaseGate?.resume()
        await first.value
    }

    // MARK: Restore

    func testRestoreNeedsNoSignIn() async {
        backend.onRestore = { [unowned self] in self.backend.transactions = [PremiumFixtures.lifetime] }
        await store.refresh()
        await store.restore()
        XCTAssertEqual(backend.restores, 1)
        XCTAssertEqual(store.activity, .restored)
        XCTAssertTrue(store.hasPremium)
    }

    func testRestoreWithNothingToRestoreSaysSo() async {
        await store.restore()
        XCTAssertEqual(store.activity, .nothingToRestore)
    }

    func testRestoreDoesNotCountAnActivationAsAPurchase() async {
        await store.refresh()
        store.activate(PassKey.activationLink(expires: year))
        await store.restore()
        XCTAssertEqual(store.activity, .nothingToRestore)
        XCTAssertTrue(store.hasPremium)
    }

    func testRestoreCancelledIsQuiet() async {
        backend.restoreOutcome = .success(.cancelled)
        await store.restore()
        XCTAssertEqual(store.activity, .idle)
    }

    func testRestoreFailingShowsTheReason() async {
        backend.restoreOutcome = .failure(FakePremiumBackend.Failure())
        await store.restore()
        XCTAssertEqual(store.activity, .failed("The App Store said no."))
    }

    func testOpeningTheWindowClearsAnOldMessageButNotAWait() async {
        backend.purchaseOutcome = .success(.cancelled)
        await store.refresh()
        await store.purchase(.lifetime)
        store.clearMessage()
        XCTAssertEqual(store.activity, .idle)
        backend.purchaseOutcome = .success(.pending)
        await store.purchase(.lifetime)
        store.clearMessage()
        XCTAssertEqual(store.activity, .pending(.lifetime))
    }

    /// A link often opens the window itself, and the window clears old messages as it appears. This message is not old.
    func testTheWindowALinkOpensKeepsTheLinksMessage() async {
        await store.refresh()
        store.activate(URL(string: "passwordpie://activate")!)
        store.clearMessage()
        XCTAssertEqual(store.activity, .activationFailed)
    }

    func testALinksMessageIsOldNewsTheNextTimeTheWindowOpens() async {
        await store.refresh()
        store.activate(URL(string: "passwordpie://activate")!)
        clock = later(60)
        store.clearMessage()
        XCTAssertEqual(store.activity, .idle)
    }

    // MARK: Products

    func testProductsLoadInPlanOrder() async {
        backend.products = .success([FakePremiumBackend.yearly, FakePremiumBackend.lifetime])
        await store.loadProducts()
        XCTAssertEqual(store.products, .loaded([FakePremiumBackend.lifetime, FakePremiumBackend.yearly]))
    }

    func testProductsFailingToLoad() async {
        backend.products = .failure(FakePremiumBackend.Failure())
        await store.loadProducts()
        XCTAssertEqual(store.products, .failed)
    }

    func testAnEmptyProductListCountsAsFailing() async {
        backend.products = .success([])
        await store.loadProducts()
        XCTAssertEqual(store.products, .failed)
    }

    func testLoadedProductsAreNotFetchedAgainWhenTheWindowReopens() async {
        await store.loadProductsIfNeeded()
        await store.loadProductsIfNeeded()
        XCTAssertEqual(backend.productLoads, 1)
    }

    // MARK: Words

    func testEveryStateThatNeedsWordsHasThem() {
        let states: [PremiumActivity] = [
            .pending(.lifetime), .cancelled, .failed("x"), .alreadyOwned(.lifetime), .nothingToRestore, .restored,
            .activated(until: PremiumFixtures.now), .activationFailed,
        ]
        for state in states { XCTAssertNotNil(state.message, "\(state)") }
        XCTAssertNil(PremiumActivity.idle.message)
        XCTAssertTrue(PremiumActivity.purchasing(.lifetime).isBusy)
        XCTAssertTrue(PremiumActivity.restoring.isBusy)
        XCTAssertFalse(PremiumActivity.pending(.lifetime).isBusy, "another plan can be tried while one waits for approval")
        XCTAssertTrue(PremiumActivity.activationFailed.isError)
        XCTAssertFalse(PremiumActivity.activated(until: PremiumFixtures.now).isError)
    }

    func testTheStatusLine() async {
        let text: (Date) -> String = { _ in "D" }
        XCTAssertEqual(store.statusLine(dateText: text).title, "Checking…")
        await store.refresh()
        XCTAssertEqual(store.statusLine(dateText: text).title, "Free")
        store.activate(PassKey.activationLink(expires: year))
        XCTAssertEqual(store.statusLine(dateText: text), PremiumStatusLine(title: "Premium", detail: "On through D."))
        backend.transactions = [PremiumFixtures.yearly(expires: later(86400))]
        await store.refresh()
        XCTAssertEqual(store.statusLine(dateText: text), PremiumStatusLine(title: "Premium: Yearly", detail: "Paid through D."))
        backend.transactions = [PremiumFixtures.lifetime]
        await store.refresh()
        XCTAssertEqual(store.statusLine(dateText: text).title, "Premium: Lifetime")
    }

    func testTheYearlyReminderForSomeoneWhoAlsoBoughtLifetime() async {
        backend.transactions = [PremiumFixtures.lifetime, PremiumFixtures.yearly(expires: later(86400))]
        await store.refresh()
        XCTAssertTrue(store.subscriptionNote(dateText: { _ in "D" })?.contains("Manage Subscription") == true)
        backend.transactions = [PremiumFixtures.lifetime]
        await store.refresh()
        XCTAssertNil(store.subscriptionNote())
    }

    /// App Store rules: the words this channel shows must not send anyone to the website.
    func testNoMessageNamesTheWebsite() async {
        let states: [PremiumActivity] = [.activated(until: PremiumFixtures.now), .activationFailed]
        for state in states { XCTAssertFalse(state.message?.lowercased().contains("passwordpie.com") == true) }
        store.activate(PassKey.activationLink(expires: year))
        XCTAssertFalse(store.statusLine().detail.lowercased().contains("passwordpie.com"))
    }
}
