import PasswordPieCore
import XCTest
@testable import PasswordPie

#if PP_DIRECT
/// The direct channel: Premium is the signed-in PasswordPie account's.
@MainActor
final class AccountPremiumStoreTests: XCTestCase {
    private var clock = PremiumFixtures.now
    private var account: FakeAccount!
    private var store: PremiumStore!
    private var paywalls = 0

    override func setUp() async throws {
        clock = PremiumFixtures.now
        account = FakeAccount()
        paywalls = 0
        store = makeStore()
    }

    override func tearDown() async throws {
        store.stop()
    }

    private func makeStore(freeCodes: Bool = false, firstCheckTimeout: TimeInterval = 3) -> PremiumStore {
        let store = PremiumStore(
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
        let store = makeStore(freeCodes: true)
        await store.refresh()
        XCTAssertTrue(store.hasPremium)
        XCTAssertFalse(store.accountHasPremium, "the browser still needs the account")
    }
}
#endif

/// What each release channel does out of the box.
@MainActor
final class PremiumChannelTests: XCTestCase {
    #if PP_DIRECT
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

    func testTheDirectChannelNeedsTheAccountForCodes() {
        XCTAssertFalse(directChannelCodesAreFree, "the user's decision of 2026-11-08")
    }
    #else
    func testTheStoreChannelStartsCheckingWithoutPremium() {
        let store = PremiumChannel.makeStore(secrets: FakeAccountSecrets())
        XCTAssertFalse(store.hasPremium)
        XCTAssertEqual(store.storeStatus, .checking)
    }
    #endif

    func testASessionMakesNoCodesByDefault() {
        let session = VaultSession()
        XCTAssertFalse(session.premium.hasPremium)
        XCTAssertEqual(session.oneTimeCodeAccess(for: PremiumFixtures.login()), .locked)
    }
}
