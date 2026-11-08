import PasswordPieCore
import XCTest
@testable import PasswordPie

/// Premium is the signed-in PasswordPie account's. The App Store channel also sells, and puts each purchase on the account.
@MainActor
final class PremiumStoreTests: XCTestCase {
    private var clock = PremiumFixtures.now
    private var backend: FakePremiumBackend!
    private var account: FakeAccount!
    private var store: PremiumStore!
    private var paywalls = 0

    override func setUp() async throws {
        clock = PremiumFixtures.now
        backend = FakePremiumBackend()
        account = FakeAccount()
        paywalls = 0
        store = makeStore()
    }

    override func tearDown() async throws {
        store.stop()
    }

    private func makeStore(backend: PremiumBackend?? = nil, freeCodes: Bool = false, firstCheckTimeout: TimeInterval = 3) -> PremiumStore {
        let store = PremiumStore(
            backend: backend ?? self.backend,
            services: account.services,
            now: { [unowned self] in self.clock },
            freeCodes: freeCodes,
            firstCheckTimeout: firstCheckTimeout
        )
        store.presentPaywall = { [unowned self] in self.paywalls += 1 }
        return store
    }

    private func later(_ seconds: TimeInterval) -> Date { PremiumFixtures.now.addingTimeInterval(seconds) }

    // MARK: Who has Premium

    func testNothingIsReadFromTheKeychainUntilTheStoreStarts() {
        _ = account.signedIn()
        let fresh = makeStore()
        XCTAssertEqual(account.secrets.reads, 0)
        XCTAssertEqual(fresh.account, .signedOut)
        XCTAssertFalse(fresh.hasPremium)
    }

    func testSignedOutIsNotPremiumAndAsksNoOne() async {
        await store.refresh(force: true)
        XCTAssertEqual(store.account, .signedOut)
        XCTAssertFalse(store.hasPremium)
        XCTAssertEqual(account.client.entitlementCalls, [])
    }

    func testASignedInAccountWithPremiumUnlocks() async {
        _ = account.signedIn()
        account.client.entitlementReply = PassKey.premium(plan: "yearly", until: later(100 * 86400))
        await store.refresh()
        XCTAssertTrue(store.hasPremium)
        XCTAssertEqual(store.email, "ada@example.com")
        XCTAssertEqual(account.client.entitlementCalls, ["session-1"])
        XCTAssertNotNil(account.secrets.values[.pass], "kept for when the site cannot be reached")
        XCTAssertEqual(store.summary(dateText: { _ in "D" }), AccountPremiumSummary(title: "Premium: Yearly", detail: "Paid through D."))
    }

    func testASignedInAccountWithoutPremiumIsFree() async {
        _ = account.signedIn()
        await store.refresh()
        XCTAssertEqual(store.account, .free)
        XCTAssertFalse(store.hasPremium)
    }

    func testTheSiteSayingPremiumWithoutAGoodPassUnlocksNothing() async {
        _ = account.signedIn()
        account.client.entitlementReply = .ok(AccountEntitlementResponse(
            premium: true, plan: "lifetime", expiresAt: nil, token: PassKey.pass(expires: later(86400), signer: .init())
        ))
        await store.refresh()
        XCTAssertEqual(store.account, .unverified)
        XCTAssertFalse(store.hasPremium)
        XCTAssertNil(account.secrets.values[.pass])
    }

    func testOfflineAGoodCachedPassKeepsCodesWorking() async {
        _ = account.signedIn()
        account.secrets.values[.pass] = PassKey.pass(expires: later(3 * 86400))
        account.client.entitlementReply = .unreachable
        await store.refresh()
        XCTAssertTrue(store.hasPremium)
        XCTAssertNotNil(account.secrets.values[.pass])
    }

    func testACachedPassUnlocksBeforeTheSiteAnswers() async {
        _ = account.signedIn()
        account.secrets.values[.pass] = PassKey.pass(expires: later(3 * 86400))
        account.client.holdsAnswers = true
        store.start()
        XCTAssertTrue(store.hasPremium, "straight from the keychain, offline or not")
        account.client.answer()
    }

    func testOfflineWithAPassThatRanOutLocksAndSaysWhy() async {
        _ = account.signedIn()
        account.secrets.values[.pass] = PassKey.pass(expires: later(-60))
        account.client.entitlementReply = .unreachable
        await store.refresh()
        XCTAssertEqual(store.account, .unreachable(passExpired: true))
        XCTAssertFalse(store.hasPremium)
        XCTAssertTrue(store.summary().detail.contains("could not reach passwordpie.com to renew Premium"))
    }

    func testAForgedPassInTheKeychainUnlocksNothingAndIsThrownAway() async {
        _ = account.signedIn()
        account.secrets.values[.pass] = PassKey.pass(expires: later(86400), signer: .init())
        account.client.entitlementReply = .unreachable
        await store.refresh()
        XCTAssertFalse(store.hasPremium)
        XCTAssertNil(account.secrets.values[.pass])
    }

    func testAPassLocksTheMomentItRunsOutEvenWithNoAnswer() async {
        _ = account.signedIn()
        account.client.entitlementReply = PassKey.premium(passExpires: later(60))
        await store.refresh()
        XCTAssertTrue(store.hasPremium)
        clock = later(61)
        XCTAssertFalse(store.hasPremium)
    }

    func testASessionTheSiteEndedSignsOutAndForgetsEverything() async {
        _ = account.signedIn()
        account.secrets.values[.pass] = PassKey.pass(expires: later(86400))
        account.client.entitlementReply = .unauthorized
        await store.refresh()
        XCTAssertEqual(store.account, .signedOut)
        XCTAssertFalse(store.hasPremium)
        XCTAssertEqual(account.secrets.values, [:])
        XCTAssertEqual(store.activity, .signedOutBySite)
        XCTAssertNotNil(store.activity.message)
    }

    func testTheSiteIsNotAskedOnEveryMenuOpen() async {
        _ = account.signedIn()
        account.client.entitlementReply = PassKey.premium()
        await store.refresh()
        await store.refresh()
        XCTAssertEqual(account.client.entitlementCalls.count, 1)
        clock = later(301)
        await store.refresh()
        XCTAssertEqual(account.client.entitlementCalls.count, 2)
        await store.refresh(force: true)
        XCTAssertEqual(account.client.entitlementCalls.count, 3)
    }

    func testAnOlderAnswerCannotOverwriteANewerOne() async {
        _ = account.signedIn()
        account.client.entitlementReply = PassKey.premium()
        account.client.holdsAnswers = true
        let slow = Task { await store.refresh(force: true) }
        let held = await waitUntil { self.account.client.answerGate != nil }
        XCTAssertTrue(held)
        let gate = account.client.answerGate
        account.client.answerGate = nil
        account.client.holdsAnswers = false
        account.client.entitlementReply = PassKey.free
        await store.refresh(force: true)
        XCTAssertEqual(store.account, .free)
        account.client.entitlementReply = PassKey.premium()
        gate?.resume()
        await slow.value
        XCTAssertEqual(store.account, .free, "the slow answer was older")
    }

    func testASiteThatNeverAnswersFailsClosedAndStillOpensTheWindow() async {
        _ = account.signedIn()
        account.client.holdsAnswers = true
        let store = makeStore(firstCheckTimeout: 0.05)
        store.start()
        var ran = false
        store.requestUnlock { ran = true }
        let failed = await waitUntil { store.account == .unreachable(passExpired: false) }
        XCTAssertTrue(failed)
        XCTAssertFalse(ran)
        XCTAssertEqual(paywalls, 1)
        account.client.entitlementReply = PassKey.premium()
        account.client.answer()
        let unlocked = await waitUntil { store.hasPremium }
        XCTAssertTrue(unlocked, "a late answer still unlocks")
        store.stop()
    }

    func testAFreeUserAskingForACodeOpensTheWindow() async {
        await store.refresh()
        var ran = false
        store.requestUnlock { ran = true }
        XCTAssertFalse(ran)
        XCTAssertEqual(paywalls, 1)
    }

    func testARequestDuringTheCheckWaitsAndRunsForAPremiumUser() async {
        _ = account.signedIn()
        account.client.entitlementReply = PassKey.premium()
        account.client.holdsAnswers = true
        store.start()
        XCTAssertEqual(store.account, .checking)
        var ran = false
        store.requestUnlock { ran = true }
        XCTAssertFalse(ran)
        account.client.answer()
        let done = await waitUntil { ran }
        XCTAssertTrue(done)
        XCTAssertEqual(paywalls, 0)
    }

    func testARequestDuringTheCheckOpensTheWindowForAFreeUser() async {
        _ = account.signedIn()
        account.client.holdsAnswers = true
        store.start()
        var ran = false
        store.requestUnlock { ran = true }
        account.client.answer()
        let opened = await waitUntil { self.paywalls == 1 }
        XCTAssertTrue(opened)
        XCTAssertFalse(ran)
    }

    // MARK: Signing in and out

    func testSignInWithAppleOpensTheSitesSheetAndKeepsTheSession() async throws {
        account.client.entitlementReply = PassKey.premium()
        await store.signIn(with: .apple)
        let url = try XCTUnwrap(account.signIn.opened.first)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(url.host, "passwordpie.com")
        XCTAssertEqual(url.path, "/app/sign-in")
        XCTAssertEqual(items.first { $0.name == "provider" }?.value, "apple")
        XCTAssertEqual(account.client.exchanged, ["one-time"])
        XCTAssertEqual(account.secrets.values[.session], "session-from-code")
        XCTAssertEqual(store.email, "ada@example.com")
        XCTAssertTrue(store.isSignedIn)
        XCTAssertTrue(store.hasPremium)
        XCTAssertEqual(store.signInState, .idle)
    }

    func testACallbackWithTheTokenNeedsNoExchange() async {
        account.signIn.script = .token("direct-token")
        await store.signIn(with: nil)
        XCTAssertEqual(account.client.exchanged, [])
        XCTAssertEqual(account.secrets.values[.session], "direct-token")
    }

    func testACallbackFromAnotherSignInIsRefused() async {
        account.signIn.script = .wrongState
        await store.signIn(with: .google)
        XCTAssertEqual(store.signInState, .failed)
        XCTAssertNotNil(store.signInState.message)
        XCTAssertNil(account.secrets.values[.session])
        XCTAssertEqual(account.client.exchanged, [], "a code meant for someone else is not even exchanged")
    }

    func testClosingTheSheetIsQuiet() async {
        account.signIn.script = .cancel
        await store.signIn(with: .apple)
        XCTAssertEqual(store.signInState, .idle)
        XCTAssertNil(account.secrets.values[.session])
    }

    func testASignInThatFailsSaysSo() async {
        account.signIn.script = .fail
        await store.signIn(with: .apple)
        XCTAssertEqual(store.signInState, .failed)
        account.signIn.script = .code
        account.client.exchangeToken = nil
        await store.signIn(with: .apple)
        XCTAssertEqual(store.signInState, .failed)
        XCTAssertNil(account.secrets.values[.session])
    }

    func testSignOutForgetsTheSessionAndLocksCodes() async {
        _ = account.signedIn()
        account.client.entitlementReply = PassKey.premium()
        await store.refresh()
        XCTAssertTrue(store.hasPremium)
        await store.signOut()
        XCTAssertFalse(store.hasPremium)
        XCTAssertFalse(store.isSignedIn)
        XCTAssertNil(store.email)
        XCTAssertEqual(account.secrets.values, [:])
        XCTAssertEqual(account.client.signedOut, ["session-1"])
    }

    // MARK: Direct channel switch

    func testFreeCodesUnlockTheAppButNotTheAccount() async {
        let store = makeStore(backend: .some(nil), freeCodes: true)
        await store.refresh()
        XCTAssertTrue(store.hasPremium)
        XCTAssertFalse(store.accountHasPremium, "the browser still needs the account")
        XCTAssertFalse(store.sellsInApp)
    }

    func testWithoutAStoreThereIsNothingToBuyOrRestore() async {
        _ = account.signedIn()
        let store = makeStore(backend: .some(nil))
        await store.refresh()
        await store.purchase(.lifetime)
        await store.restore()
        XCTAssertEqual(store.activity, .idle)
        XCTAssertEqual(account.client.binds.count, 0)
        XCTAssertEqual(store.storeStatus, .free)
    }

    // MARK: Buying

    func testBuyingWhileSignedOutAsksToSignInFirstThenCarriesOn() async {
        await store.refresh()
        await store.purchase(.lifetime)
        XCTAssertEqual(store.activity, .signInFirst)
        XCTAssertEqual(backend.purchases, [], "nothing is charged before the account is there")
        await store.signIn(with: .apple)
        XCTAssertEqual(backend.purchases, [.lifetime])
        XCTAssertEqual(account.client.binds.map(\.signed), [PremiumFixtures.jws(.lifetime)])
        XCTAssertTrue(store.hasPremium)
        XCTAssertEqual(store.activity, .idle)
    }

    func testABuyGoesOntoTheAccountAndUnlocks() async {
        _ = account.signedIn()
        await store.refresh()
        await store.purchase(.lifetime)
        XCTAssertEqual(account.client.binds.count, 1)
        XCTAssertEqual(account.client.binds.first?.restore, false)
        XCTAssertEqual(account.client.binds.first?.session, "session-1")
        XCTAssertTrue(store.hasPremium)
        XCTAssertEqual(store.activity, .idle)
        XCTAssertTrue(store.ownedPlans.contains(.lifetime))
    }

    func testABuyTheSiteDidNotHearAboutIsSafeAndGoesOnLater() async {
        _ = account.signedIn()
        await store.refresh()
        account.client.bindReplies = [.unreachable]
        await store.purchase(.lifetime)
        XCTAssertEqual(store.activity, .linkPending)
        XCTAssertFalse(store.hasPremium)
        XCTAssertTrue(store.activity.message?.contains("Your purchase is safe") == true)
        await store.refresh(force: true)
        XCTAssertEqual(account.client.binds.count, 2)
        XCTAssertEqual(account.client.binds.last?.restore, false)
        XCTAssertTrue(store.hasPremium)
        XCTAssertEqual(store.activity, .idle)
    }

    func testABuyTheSiteCannotConfirmWithAppleSaysSo() async {
        _ = account.signedIn()
        await store.refresh()
        account.client.bindReplies = [.rejected(status: 400, error: "invalid-transaction", nextAllowedAt: nil, previousAccountEmailMasked: nil)]
        await store.purchase(.lifetime)
        XCTAssertEqual(store.activity, .failed(PremiumActivity.notConfirmed))
        XCTAssertFalse(store.hasPremium)
    }

    func testAPendingPurchaseWaitsThenGoesOntoTheAccountByItself() async {
        _ = account.signedIn()
        store.start()
        let checked = await waitUntil { self.store.account == .free }
        XCTAssertTrue(checked)
        backend.purchaseOutcome = .success(.pending)
        await store.purchase(.yearly)
        XCTAssertEqual(store.activity, .pending(.yearly))
        backend.transactions = [PremiumFixtures.transaction(.yearly)]
        backend.emitUpdate()
        let unlocked = await waitUntil { self.store.hasPremium }
        XCTAssertTrue(unlocked)
        XCTAssertEqual(account.client.binds.map(\.restore), [false])
    }

    func testACancelledPurchaseLeavesEverythingAlone() async {
        _ = account.signedIn()
        await store.refresh()
        backend.purchaseOutcome = .success(.cancelled)
        await store.purchase(.lifetime)
        XCTAssertEqual(store.activity, .cancelled)
        XCTAssertEqual(account.client.binds.count, 0)
    }

    func testAFailedPurchaseShowsTheStoresReason() async {
        _ = account.signedIn()
        await store.refresh()
        backend.purchaseOutcome = .failure(.init())
        await store.purchase(.lifetime)
        XCTAssertEqual(store.activity, .failed("The App Store said no."))
    }

    func testAnUnverifiedPurchaseIsNotSent() async {
        _ = account.signedIn()
        await store.refresh()
        backend.purchaseOutcome = .success(.unverified)
        await store.purchase(.lifetime)
        XCTAssertTrue(store.activity.isError)
        XCTAssertEqual(account.client.binds.count, 0)
        XCTAssertFalse(store.hasPremium)
    }

    func testAPlanAlreadyOwnedIsNotBoughtAgain() async {
        _ = account.signedIn()
        backend.transactions = [PremiumFixtures.lifetime]
        await store.refresh()
        await store.purchase(.lifetime)
        XCTAssertEqual(backend.purchases, [])
        XCTAssertEqual(store.activity, .alreadyOwned(.lifetime))
    }

    func testOnlyOnePurchaseRunsAtATime() async {
        _ = account.signedIn()
        await store.refresh()
        backend.holdsPurchases = true
        let first = Task { await store.purchase(.lifetime) }
        let started = await waitUntil { self.backend.purchaseGate != nil }
        XCTAssertTrue(started)
        await store.purchase(.yearly)
        XCTAssertEqual(backend.purchases, [.lifetime])
        backend.purchaseGate?.resume()
        await first.value
    }

    // MARK: A purchase on this Mac that is on no account yet

    func testAPurchaseHereWhileSignedOutWaitsAndGoesOnAtSignIn() async {
        backend.transactions = [PremiumFixtures.lifetime]
        await store.refresh()
        XCTAssertEqual(store.activity, .unclaimedPurchase)
        XCTAssertFalse(store.hasPremium, "Premium is the account's")
        XCTAssertNotNil(store.activity.message)
        await store.signIn(with: .apple)
        XCTAssertEqual(account.client.binds.map(\.restore), [false])
        XCTAssertTrue(store.hasPremium)
        XCTAssertEqual(store.activity, .idle)
    }

    func testAPurchaseOnAnotherAccountIsNeverMovedWithoutAsking() async {
        _ = account.signedIn()
        backend.transactions = [PremiumFixtures.lifetime]
        account.client.bindDefault = .rejected(status: 409, error: "bound-elsewhere", nextAllowedAt: nil, previousAccountEmailMasked: "j•••@gmail.com")
        await store.refresh()
        XCTAssertEqual(account.client.binds.map(\.restore), [false])
        XCTAssertEqual(store.activity, .onAnotherAccount)
        XCTAssertNil(store.moveRequest, "only Restore Purchases offers to move it")
        await store.refresh(force: true)
        XCTAssertEqual(account.client.binds.count, 1, "not sent again on every refresh")
    }

    func testARefundedPurchaseIsNotSent() async {
        _ = account.signedIn()
        var refunded = PremiumFixtures.lifetime
        refunded.revocationDate = later(-10)
        backend.transactions = [refunded]
        await store.refresh()
        XCTAssertEqual(account.client.binds.count, 0)
    }

    // MARK: Restore and moving Premium

    func testRestoreWhileSignedOutAsksToSignInFirstThenCarriesOn() async {
        backend.onRestore = { [unowned self] in self.backend.transactions = [PremiumFixtures.lifetime] }
        await store.restore()
        XCTAssertEqual(store.activity, .signInFirst)
        XCTAssertEqual(backend.restores, 0)
        await store.signIn(with: .apple)
        XCTAssertEqual(backend.restores, 1)
        XCTAssertTrue(store.hasPremium)
        XCTAssertEqual(store.activity, .restored)
    }

    func testRestoreWithNothingToRestoreSaysSo() async {
        _ = account.signedIn()
        await store.refresh()
        await store.restore()
        XCTAssertEqual(store.activity, .nothingToRestore)
    }

    func testRestorePutsThePurchaseOnThisAccount() async {
        _ = account.signedIn()
        await store.refresh()
        backend.onRestore = { [unowned self] in self.backend.transactions = [PremiumFixtures.lifetime] }
        await store.restore()
        XCTAssertEqual(store.activity, .restored)
        XCTAssertTrue(store.hasPremium)
        XCTAssertEqual(account.client.binds.map(\.restore), [false])
    }

    func testRestoreAsksBeforeMovingFromAnotherAccount() async throws {
        _ = account.signedIn()
        await store.refresh()
        backend.onRestore = { [unowned self] in self.backend.transactions = [PremiumFixtures.lifetime] }
        account.client.bindReplies = [.rejected(status: 409, error: "bound-elsewhere", nextAllowedAt: nil, previousAccountEmailMasked: "j•••@gmail.com")]
        await store.restore()
        XCTAssertEqual(store.moveRequest, PremiumMoveRequest(signedTransactions: [PremiumFixtures.jws(.lifetime)], previousAccountEmailMasked: "j•••@gmail.com"))
        XCTAssertEqual(account.client.binds.map(\.restore), [false], "nothing moved yet")
        XCTAssertFalse(store.hasPremium)
    }

    func testMovingSaysTheOtherAccountLostPremium() async throws {
        try await testRestoreAsksBeforeMovingFromAnotherAccount()
        var moved = try XCTUnwrap({ if case .ok(let r) = PassKey.premium() { return r } else { return nil } }())
        moved.rebound = true
        moved.previousAccountEmailMasked = "j•••@gmail.com"
        account.client.bindReplies = [.ok(moved)]
        await store.confirmMove()
        XCTAssertEqual(account.client.binds.map(\.restore), [false, true])
        XCTAssertTrue(store.hasPremium)
        XCTAssertEqual(store.activity, .moved(previousAccountEmailMasked: "j•••@gmail.com"))
        XCTAssertEqual(store.activity.message, "Premium moved to this account. j•••@gmail.com no longer has Premium from this purchase.")
        XCTAssertNil(store.moveRequest)
    }

    func testAMoveTooSoonGivesTheNextDate() async throws {
        try await testRestoreAsksBeforeMovingFromAnotherAccount()
        let next = later(100 * 86400)
        account.client.bindReplies = [.rejected(status: 409, error: "rebind-limited", nextAllowedAt: next, previousAccountEmailMasked: nil)]
        await store.confirmMove()
        XCTAssertEqual(store.activity, .moveLimited(nextAllowedAt: next))
        XCTAssertEqual(store.activity.message(dateText: { _ in "March 3, 2027" }), "This purchase moved to another account less than a year ago. It can move again on March 3, 2027.")
        XCTAssertTrue(store.activity.isError)
        XCTAssertFalse(store.hasPremium)
    }

    func testCancellingTheMoveSendsNothing() async throws {
        try await testRestoreAsksBeforeMovingFromAnotherAccount()
        store.cancelMove()
        XCTAssertNil(store.moveRequest)
        XCTAssertEqual(account.client.binds.count, 1)
    }

    func testRestoreCancelledAtTheSignInIsQuiet() async {
        _ = account.signedIn()
        await store.refresh()
        backend.restoreOutcome = .success(.cancelled)
        await store.restore()
        XCTAssertEqual(store.activity, .idle)
    }

    func testRestoreFailingShowsTheReason() async {
        _ = account.signedIn()
        await store.refresh()
        backend.restoreOutcome = .failure(.init())
        await store.restore()
        XCTAssertEqual(store.activity, .failed("The App Store said no."))
    }

    func testOpeningTheWindowClearsAnOldMessageButNotAWait() async {
        _ = account.signedIn()
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

    func testLoadedProductsAreNotFetchedAgainWhenTheWindowReopens() async {
        await store.loadProductsIfNeeded()
        await store.loadProductsIfNeeded()
        XCTAssertEqual(backend.productLoads, 1)
    }

    // MARK: Words

    func testEveryStateThatNeedsWordsHasThem() {
        let states: [PremiumActivity] = [
            .pending(.lifetime), .linking, .linkPending, .moving, .moved(previousAccountEmailMasked: nil), .moveLimited(nextAllowedAt: nil),
            .onAnotherAccount, .signInFirst, .unclaimedPurchase, .signedOutBySite, .cancelled, .failed("x"), .alreadyOwned(.lifetime),
            .nothingToRestore, .restored,
        ]
        for state in states {
            XCTAssertNotNil(state.message, "\(state)")
        }
        XCTAssertNil(PremiumActivity.idle.message)
        XCTAssertTrue(PremiumActivity.purchasing(.lifetime).isBusy)
        XCTAssertTrue(PremiumActivity.restoring.isBusy)
        XCTAssertTrue(PremiumActivity.linking.isBusy)
        XCTAssertTrue(PremiumActivity.moving.isBusy)
        XCTAssertFalse(PremiumActivity.pending(.lifetime).isBusy, "another plan can be tried while one waits for approval")
    }

    func testTheYearlyReminderForSomeoneWhoAlsoBoughtLifetime() async {
        backend.transactions = [PremiumFixtures.lifetime, PremiumFixtures.yearly(expires: later(86400))]
        await store.refresh()
        XCTAssertTrue(store.subscriptionNote(dateText: { _ in "D" })?.contains("Manage Subscription") == true)
        backend.transactions = [PremiumFixtures.lifetime]
        await store.refresh()
        XCTAssertNil(store.subscriptionNote())
    }
}

/// What each release channel does out of the box.
@MainActor
final class PremiumChannelTests: XCTestCase {
    func testAStoreFromTheChannelStartsWithoutPremium() {
        let store = PremiumChannel.makeStore(services: FakeAccount().services)
        XCTAssertFalse(store.hasPremium)
        XCTAssertFalse(store.isSignedIn)
    }

    func testTheBrowserSeamFollowsTheAppsOwnAccount() async {
        let account = FakeAccount().signedIn()
        account.client.entitlementReply = PassKey.premium()
        let store = PremiumChannel.makeStore(services: account.services)
        // The first store made is the app's; a test run may have made one before.
        guard PremiumChannel.live === store else { return }
        XCTAssertFalse(appAccountHasPremium())
        await store.refresh()
        XCTAssertTrue(appAccountHasPremium())
    }

    #if PP_DIRECT
    func testTheDirectChannelNeedsTheAccountForCodesAndSellsNothing() {
        XCTAssertFalse(directChannelCodesAreFree, "the user's decision of 2026-11-08")
        let store = PremiumChannel.makeStore(services: FakeAccount().services)
        XCTAssertFalse(store.sellsInApp)
        XCTAssertEqual(store.storeStatus, .free)
    }
    #else
    func testTheStoreChannelSellsThroughApple() {
        let store = PremiumChannel.makeStore(services: FakeAccount().services)
        XCTAssertTrue(store.sellsInApp)
        XCTAssertEqual(store.storeStatus, .checking)
    }
    #endif

    func testASessionMakesNoCodesByDefault() {
        let session = VaultSession()
        XCTAssertFalse(session.premium.hasPremium)
        XCTAssertEqual(session.oneTimeCodeAccess(for: PremiumFixtures.login()), .locked)
    }
}
