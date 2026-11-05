import PasswordPieCore
import XCTest
@testable import PasswordPie

@MainActor
final class PremiumStoreTests: XCTestCase {
    private var clock = PremiumFixtures.now
    private var backend: FakePremiumBackend!
    private var store: PremiumStore!
    private var paywalls = 0

    override func setUp() async throws {
        clock = PremiumFixtures.now
        backend = FakePremiumBackend()
        paywalls = 0
        store = PremiumStore(backend: backend, now: { [unowned self] in self.clock })
        store.presentPaywall = { [unowned self] in self.paywalls += 1 }
    }

    private func later(_ seconds: TimeInterval) -> Date { PremiumFixtures.now.addingTimeInterval(seconds) }

    // MARK: Entitlements

    func testStartsCheckingAndNotPremium() {
        XCTAssertEqual(store.status, .checking)
        XCTAssertFalse(store.hasPremium)
    }

    func testAnOwnedPlanUnlocksAfterTheCheck() async {
        backend.transactions = [PremiumFixtures.lifetime]
        await store.refresh()
        XCTAssertEqual(store.status, .lifetime(subscriptionExpires: nil))
        XCTAssertTrue(store.hasPremium)
    }

    func testNothingOwnedIsFreeAfterTheCheck() async {
        await store.refresh()
        XCTAssertEqual(store.status, .free)
        XCTAssertFalse(store.hasPremium)
    }

    func testAStoreUpdateUnlocksWithoutARelaunch() async {
        store.start()
        let checked = await waitUntil { self.store.status == .free }
        XCTAssertTrue(checked)
        backend.transactions = [PremiumFixtures.lifetime]
        backend.emitUpdate()
        let unlocked = await waitUntil { self.store.hasPremium }
        XCTAssertTrue(unlocked)
        store.stop()
    }

    func testARefundThroughTheUpdatesStreamLocksAgain() async {
        backend.transactions = [PremiumFixtures.lifetime]
        store.start()
        let unlocked = await waitUntil { self.store.hasPremium }
        XCTAssertTrue(unlocked)
        var revoked = PremiumFixtures.lifetime
        revoked.revocationDate = PremiumFixtures.now
        backend.transactions = [revoked]
        backend.emitUpdate()
        let locked = await waitUntil { !self.store.hasPremium }
        XCTAssertTrue(locked)
        store.stop()
    }

    func testASubscriptionLocksTheMomentItEndsEvenIfTheStoreSaysNothing() async {
        backend.transactions = [PremiumFixtures.yearly(expires: later(60))]
        await store.refresh()
        XCTAssertTrue(store.hasPremium)
        clock = later(60)
        XCTAssertFalse(store.hasPremium)
    }

    func testTheStatusFollowsWhenASubscriptionEnds() async {
        // A real timer on a real clock: the status has to change so that open views redraw.
        let realStore = PremiumStore(backend: backend)
        backend.transactions = [PremiumFixtures.yearly(expires: Date().addingTimeInterval(0.05))]
        realStore.start()
        let active = await waitUntil(timeout: 1) { realStore.status != .checking }
        XCTAssertTrue(active)
        let ended = await waitUntil(timeout: 3) { realStore.status == .free }
        XCTAssertTrue(ended, "\(realStore.status)")
        realStore.stop()
    }

    /// The store is asked on every menu open. An answer that changes nothing must not redraw anything.
    func testAnUnchangedAnswerPublishesNothing() async {
        await store.refresh()
        var changes = 0
        let watcher = store.objectWillChange.sink { changes += 1 }
        await store.refresh()
        await store.refresh()
        XCTAssertEqual(changes, 0)
        watcher.cancel()
    }

    func testAnOlderAnswerCannotOverwriteANewerOne() async {
        backend.holdsAnswers = true
        let slow = Task { await store.refresh() }
        let held = await waitUntil { self.backend.answerGate != nil }
        XCTAssertTrue(held)
        let first = backend.answerGate
        backend.answerGate = nil
        backend.holdsAnswers = false
        backend.transactions = [PremiumFixtures.lifetime]
        await store.refresh()
        XCTAssertTrue(store.hasPremium)
        backend.transactions = []
        first?.resume()
        await slow.value
        XCTAssertTrue(store.hasPremium)
    }

    /// A store that never answers must not leave a shortcut silently doing nothing.
    func testAStoreThatNeverAnswersFailsClosedAndStillOpensThePlans() async {
        let store = PremiumStore(backend: backend, firstCheckTimeout: 0.05)
        var paywalls = 0
        store.presentPaywall = { paywalls += 1 }
        backend.holdsAnswers = true
        store.start()
        var ran = false
        store.requestUnlock { ran = true }
        let opened = await waitUntil(timeout: 2) { paywalls == 1 }
        XCTAssertTrue(opened)
        XCTAssertFalse(store.hasPremium)
        XCTAssertFalse(ran)
        store.stop()
        backend.answer()
    }

    // MARK: Unlock requests

    func testAFreeUserAskingForACodeOpensThePlans() async {
        await store.refresh()
        var ran = false
        store.requestUnlock { ran = true }
        XCTAssertEqual(paywalls, 1)
        XCTAssertFalse(ran)
    }

    func testARequestDuringTheCheckWaitsAndRunsForAPremiumUser() async {
        backend.transactions = [PremiumFixtures.lifetime]
        backend.holdsAnswers = true
        let check = Task { await store.refresh() }
        let held = await waitUntil { self.backend.answerGate != nil }
        XCTAssertTrue(held)
        var ran = false
        store.requestUnlock { ran = true }
        XCTAssertFalse(ran)
        XCTAssertEqual(paywalls, 0)
        backend.answer()
        await check.value
        XCTAssertTrue(ran)
        XCTAssertEqual(paywalls, 0, "someone who owns Premium never sees the plans")
    }

    func testARequestDuringTheCheckOpensThePlansForAFreeUser() async {
        backend.holdsAnswers = true
        let check = Task { await store.refresh() }
        let held = await waitUntil { self.backend.answerGate != nil }
        XCTAssertTrue(held)
        var ran = false
        store.requestUnlock { ran = true }
        backend.answer()
        await check.value
        XCTAssertFalse(ran)
        XCTAssertEqual(paywalls, 1)
    }

    // MARK: Products

    func testProductsLoadInPlanOrder() async {
        backend.products = .success([FakePremiumBackend.yearly, FakePremiumBackend.lifetime])
        await store.loadProducts()
        XCTAssertEqual(store.products, .loaded([FakePremiumBackend.lifetime, FakePremiumBackend.yearly]))
    }

    func testProductsFailingToLoad() async {
        backend.products = .failure(.init())
        await store.loadProducts()
        XCTAssertEqual(store.products, .failed)
    }

    /// The store returns an empty list, with no error, for products it does not know.
    func testAnEmptyProductListCountsAsFailing() async {
        backend.products = .success([])
        await store.loadProducts()
        XCTAssertEqual(store.products, .failed)
    }

    func testProductsCanBeRetriedAfterFailing() async {
        backend.products = .failure(.init())
        await store.loadProducts()
        backend.products = .success([FakePremiumBackend.lifetime])
        await store.loadProducts()
        XCTAssertEqual(store.products, .loaded([FakePremiumBackend.lifetime]))
    }

    func testLoadedProductsAreNotFetchedAgainWhenTheWindowReopens() async {
        await store.loadProductsIfNeeded()
        await store.loadProductsIfNeeded()
        XCTAssertEqual(backend.productLoads, 1)
    }

    // MARK: Purchase

    func testABuyThatSucceedsUnlocks() async {
        await store.refresh()
        backend.onPurchase = { [unowned backend] _ in backend!.transactions = [PremiumFixtures.lifetime] }
        await store.purchase(.lifetime)
        XCTAssertEqual(backend.purchases, [.lifetime])
        XCTAssertTrue(store.hasPremium)
        XCTAssertEqual(store.activity, .idle)
    }

    /// Seen with the real store: `purchase` returns success a moment before the entitlement shows up.
    func testAnEntitlementThatLagsBehindThePurchaseStillUnlocksWithoutAnError() async {
        let lagging = PremiumStore(backend: backend, deliveryRetryDelays: [0.001, 0.001, 0.001])
        await lagging.refresh()
        backend.onPurchase = { [unowned backend] _ in
            backend!.transactionsAfterRefreshes = (2, [PremiumFixtures.lifetime])
        }
        await lagging.purchase(.lifetime)
        XCTAssertTrue(lagging.hasPremium)
        XCTAssertEqual(lagging.activity, .idle)
    }

    func testAPurchaseThatHasNotArrivedIsNotAFailureAndClearsWhenItDoes() async {
        let lagging = PremiumStore(backend: backend, deliveryRetryDelays: [0.001])
        lagging.start()
        let checked = await waitUntil { lagging.status == .free }
        XCTAssertTrue(checked)
        await lagging.purchase(.lifetime)
        XCTAssertEqual(lagging.activity, .awaitingDelivery(.lifetime))
        XCTAssertFalse(lagging.activity.isError)
        XCTAssertFalse(lagging.hasPremium, "only an entitlement from the store grants Premium, not the purchase result")
        lagging.clearMessage()
        XCTAssertEqual(lagging.activity, .awaitingDelivery(.lifetime))
        backend.transactions = [PremiumFixtures.lifetime]
        backend.emitUpdate()
        let unlocked = await waitUntil { lagging.activity == .idle }
        XCTAssertTrue(unlocked)
        XCTAssertTrue(lagging.hasPremium)
        lagging.stop()
    }

    func testRestoreWaitsForALaggingEntitlementToo() async {
        let lagging = PremiumStore(backend: backend, deliveryRetryDelays: [0.001, 0.001])
        await lagging.refresh()
        backend.onRestore = { [unowned backend] in
            backend!.transactionsAfterRefreshes = (1, [PremiumFixtures.lifetime])
        }
        await lagging.restore()
        XCTAssertEqual(lagging.activity, .restored)
    }

    /// A subscriber waiting on approval for Lifetime already has Premium, and is still waiting.
    func testApprovalStillPendingForASubscriberStaysOnScreenUntilThatPlanArrives() async {
        backend.transactions = [PremiumFixtures.yearly(expires: later(3600))]
        store.start()
        let checked = await waitUntil { self.store.hasPremium }
        XCTAssertTrue(checked)
        backend.purchaseOutcome = .success(.pending)
        await store.purchase(.lifetime)
        XCTAssertEqual(store.activity, .pending(.lifetime))
        backend.emitUpdate()
        await store.refresh()
        XCTAssertEqual(store.activity, .pending(.lifetime))
        backend.transactions.append(PremiumFixtures.lifetime)
        backend.emitUpdate()
        let arrived = await waitUntil { self.store.activity == .idle }
        XCTAssertTrue(arrived)
        store.stop()
    }

    func testAPendingPurchaseWaitsThenUnlocksByItself() async {
        store.start()
        let checked = await waitUntil { self.store.status == .free }
        XCTAssertTrue(checked)
        backend.purchaseOutcome = .success(.pending)
        await store.purchase(.yearly)
        XCTAssertEqual(store.activity, .pending(.yearly))
        XCTAssertFalse(store.hasPremium)
        XCTAssertEqual(store.activity.isError, false)
        backend.transactions = [PremiumFixtures.yearly(expires: later(3600))]
        backend.emitUpdate()
        let unlocked = await waitUntil { self.store.activity == .idle }
        XCTAssertTrue(unlocked)
        store.stop()
    }

    func testACancelledPurchaseLeavesEverythingAlone() async {
        await store.refresh()
        backend.purchaseOutcome = .success(.cancelled)
        await store.purchase(.lifetime)
        XCTAssertEqual(store.activity, .cancelled)
        XCTAssertFalse(store.activity.isError)
        XCTAssertFalse(store.hasPremium)
    }

    func testAFailedPurchaseShowsTheStoresReason() async {
        await store.refresh()
        backend.purchaseOutcome = .failure(.init())
        await store.purchase(.lifetime)
        XCTAssertEqual(store.activity, .failed("The App Store said no."))
        XCTAssertTrue(store.activity.isError)
        XCTAssertFalse(store.hasPremium)
    }

    func testAnUnverifiedPurchaseGrantsNothing() async {
        await store.refresh()
        backend.purchaseOutcome = .success(.unverified)
        backend.onPurchase = { [unowned backend] _ in
            backend!.transactions = [PremiumTransaction(productID: PremiumPlan.lifetime.productID, verified: false, revocationDate: nil, expirationDate: nil)]
        }
        await store.purchase(.lifetime)
        XCTAssertFalse(store.hasPremium)
        XCTAssertTrue(store.activity.isError)
    }

    func testAPlanAlreadyOwnedIsNotBoughtAgain() async {
        backend.transactions = [PremiumFixtures.lifetime]
        await store.refresh()
        await store.purchase(.lifetime)
        XCTAssertEqual(backend.purchases, [])
        XCTAssertEqual(store.activity, .alreadyOwned(.lifetime))
        XCTAssertFalse(store.activity.isError)
    }

    func testAYearlySubscriberCanStillBuyLifetime() async {
        backend.transactions = [PremiumFixtures.yearly(expires: later(3600))]
        await store.refresh()
        backend.onPurchase = { [unowned self] _ in
            self.backend.transactions = [PremiumFixtures.yearly(expires: self.later(3600)), PremiumFixtures.lifetime]
        }
        await store.purchase(.lifetime)
        XCTAssertEqual(store.status, .lifetime(subscriptionExpires: later(3600)))
    }

    func testOnlyOnePurchaseRunsAtATime() async {
        await store.refresh()
        backend.holdsPurchases = true
        let first = Task { await store.purchase(.lifetime) }
        let held = await waitUntil { self.backend.purchaseGate != nil }
        XCTAssertTrue(held)
        XCTAssertEqual(store.activity, .purchasing(.lifetime))
        await store.purchase(.yearly)
        await store.restore()
        XCTAssertEqual(backend.purchases, [.lifetime])
        XCTAssertEqual(backend.restores, 0)
        backend.purchaseGate?.resume()
        await first.value
    }

    // MARK: Restore

    func testRestoreBringsPremiumBack() async {
        await store.refresh()
        backend.onRestore = { [unowned backend] in backend!.transactions = [PremiumFixtures.lifetime] }
        await store.restore()
        XCTAssertEqual(backend.restores, 1)
        XCTAssertTrue(store.hasPremium)
        XCTAssertEqual(store.activity, .restored)
    }

    func testRestoreWithNothingToRestoreSaysSo() async {
        let store = PremiumStore(backend: backend, deliveryRetryDelays: [])
        await store.refresh()
        await store.restore()
        XCTAssertEqual(store.activity, .nothingToRestore)
        XCTAssertFalse(store.activity.isError)
    }

    func testRestoreCancelledAtTheSignInIsQuiet() async {
        await store.refresh()
        backend.restoreOutcome = .success(.cancelled)
        await store.restore()
        XCTAssertEqual(store.activity, .idle)
    }

    func testRestoreFailingShowsTheReason() async {
        await store.refresh()
        backend.restoreOutcome = .failure(.init())
        await store.restore()
        XCTAssertEqual(store.activity, .failed("The App Store said no."))
    }

    func testOpeningTheWindowClearsAnOldMessageButNotAWait() async {
        await store.refresh()
        backend.purchaseOutcome = .success(.cancelled)
        await store.purchase(.lifetime)
        store.clearMessage()
        XCTAssertEqual(store.activity, .idle)
        backend.purchaseOutcome = .success(.pending)
        await store.purchase(.lifetime)
        store.clearMessage()
        XCTAssertEqual(store.activity, .pending(.lifetime), "still waiting for approval")
    }

    func testEveryStateThatNeedsWordsHasThem() {
        let states: [PremiumActivity] = [.pending(.lifetime), .awaitingDelivery(.lifetime), .cancelled, .failed("x"), .alreadyOwned(.lifetime), .nothingToRestore, .restored]
        for state in states {
            XCTAssertNotNil(state.message, "\(state)")
        }
        XCTAssertNil(PremiumActivity.idle.message)
        XCTAssertTrue(PremiumActivity.purchasing(.lifetime).isBusy)
        XCTAssertTrue(PremiumActivity.restoring.isBusy)
        XCTAssertFalse(PremiumActivity.pending(.lifetime).isBusy, "another plan can be tried while one waits for approval")
    }

    // MARK: Status words

    func testStatusLines() {
        let formatter: (Date) -> String = { _ in "D" }
        XCTAssertEqual(PremiumStatus.free.summary(dateText: formatter).title, "Free")
        XCTAssertEqual(PremiumStatus.lifetime(subscriptionExpires: nil).summary(dateText: formatter).title, "Premium: Lifetime")
        XCTAssertEqual(PremiumStatus.yearly(expires: later(1)).summary(dateText: formatter).title, "Premium: Yearly")
        XCTAssertTrue(PremiumStatus.yearly(expires: later(1)).summary(dateText: formatter).detail.contains("D"))
        XCTAssertTrue(PremiumStatus.lifetime(subscriptionExpires: later(1)).summary(dateText: formatter).detail.contains("Manage Subscription"), "the old subscription keeps charging")
    }
}

/// What each release channel does out of the box.
@MainActor
final class PremiumChannelTests: XCTestCase {
    #if PP_DIRECT
    func testTheDirectChannelIsPremiumFromTheFirstMoment() {
        let store = PremiumChannel.makeStore()
        XCTAssertEqual(store.status, directChannelPremiumStatus())
        XCTAssertTrue(store.hasPremium, "the owner's installed copy must keep working")
        XCTAssertTrue(store.status.grantsPremium(at: .distantFuture))
    }

    func testTheDirectChannelNeverOpensAPaywall() async {
        let store = PremiumChannel.makeStore()
        var paywalls = 0
        store.presentPaywall = { paywalls += 1 }
        store.start()
        var ran = false
        store.requestUnlock { ran = true }
        await store.refresh()
        await store.loadProducts()
        await store.purchase(.lifetime)
        await store.restore()
        XCTAssertTrue(ran)
        XCTAssertEqual(paywalls, 0)
        XCTAssertTrue(store.hasPremium, "nothing here can turn it off")
        store.stop()
    }

    func testADirectChannelSessionMakesCodes() {
        let session = VaultSession()
        XCTAssertTrue(session.premium.hasPremium)
        XCTAssertEqual(session.oneTimeCodeAccess(for: PremiumFixtures.login()).isAvailable, true)
    }
    #else
    func testTheStoreChannelStartsLockedUntilAppleAnswers() {
        let store = PremiumChannel.makeStore()
        XCTAssertEqual(store.status, .checking)
        XCTAssertFalse(store.hasPremium)
    }

    func testAStoreChannelSessionMakesNoCodesByDefault() {
        let session = VaultSession()
        XCTAssertFalse(session.premium.hasPremium)
        XCTAssertEqual(session.oneTimeCodeAccess(for: PremiumFixtures.login()), .locked)
    }
    #endif
}
