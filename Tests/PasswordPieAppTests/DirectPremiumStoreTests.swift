import PasswordPieCore
import XCTest
@testable import PasswordPie

#if PP_DIRECT
/// The direct channel: Premium is a pass the browser extension handed over, or an activation link from the website.
/// Nothing here signs in or talks to a site.
@MainActor
final class DirectPremiumStoreTests: XCTestCase {
    private var clock = PremiumFixtures.now
    private var secrets: FakeSecrets!
    private var store: DirectPremiumStore!
    private var paywalls = 0
    private let day: TimeInterval = 86400

    override func setUp() async throws {
        clock = PremiumFixtures.now
        secrets = FakeSecrets()
        paywalls = 0
        store = makeStore()
    }

    override func tearDown() async throws {
        store.stop()
    }

    private func makeStore(freeCodes: Bool = false) -> DirectPremiumStore {
        let store = DirectPremiumStore.testing(secrets: secrets, now: { [unowned self] in self.clock }, freeCodes: freeCodes)
        store.presentPaywall = { [unowned self] in self.paywalls += 1 }
        return store
    }

    private func later(_ days: Double) -> Date { PremiumFixtures.now.addingTimeInterval(days * day) }
    private func pass(_ days: Double = 7) -> String { PassKey.pass(expires: later(days)) }

    // MARK: Launch

    func testNothingIsReadBeforeStart() {
        XCTAssertFalse(store.hasPremium)
        XCTAssertEqual(secrets.reads, 0)
    }

    func testAFreshAppIsFreeAndSaysNothingRanOut() {
        store.start()
        XCTAssertFalse(store.hasPremium)
        XCTAssertEqual(store.status, .none)
        XCTAssertNil(store.lapse)
    }

    func testAKeptPassUnlocksAtLaunchWithNothingToWaitFor() {
        secrets.values[.safariPass] = pass()
        store.start()
        XCTAssertTrue(store.hasPremium)
        XCTAssertEqual(store.status, .fromBrowser(activationUntil: nil))
    }

    /// A build that signed in inside the app left a session, an email and a pass. The pass counts until it ends; the rest
    /// goes at the first launch.
    func testTheOldSignInIsForgottenAndItsPassCountsUntilItEnds() {
        secrets.values[.legacySession] = "session-1"
        secrets.values[.legacyEmail] = "ada@example.com"
        let old = pass(3)
        secrets.values[.appSignInPass] = old
        store.start()
        XCTAssertNil(secrets.values[.legacySession])
        XCTAssertNil(secrets.values[.legacyEmail])
        XCTAssertTrue(store.hasPremium)
        XCTAssertEqual(secrets.values[.appSignInPass], old, "kept until it runs out")
        clock = later(4)
        store.reevaluate()
        XCTAssertFalse(store.hasPremium)
        XCTAssertNil(secrets.values[.appSignInPass])
        XCTAssertEqual(store.lapse, .passRanOut)
    }

    func testAnExpiredPassAtLaunchIsDeletedAndExplained() {
        secrets.values[.chromePass] = pass(-1)
        store.start()
        XCTAssertFalse(store.hasPremium)
        XCTAssertNil(secrets.values[.chromePass])
        XCTAssertEqual(store.lapse, .passRanOut)
    }

    func testAForgedTokenInTheKeychainIsThrownAwayWithNoStory() {
        secrets.values[.chromePass] = PassKey.pass(expires: later(7), signer: .init())
        secrets.values[.activation] = "forged.token.here"
        store.start()
        XCTAssertFalse(store.hasPremium)
        XCTAssertEqual(secrets.values, [:])
        XCTAssertNil(store.lapse)
    }

    // MARK: From the browser extension

    func testAPassFromTheExtensionUnlocksAndIsKeptForThatBrowser() {
        store.start()
        let token = pass()
        XCTAssertTrue(store.receive(.pass(token), from: .chrome))
        XCTAssertTrue(store.hasPremium)
        XCTAssertEqual(secrets.values[.chromePass], token)
        XCTAssertNil(secrets.values[.safariPass])
    }

    func testAPassThatDoesNotCheckChangesNothingStored() {
        store.start()
        store.receive(.pass(pass()), from: .chrome)
        let kept = secrets.values
        XCTAssertFalse(store.receive(.pass(PassKey.pass(expires: later(7), signer: .init())), from: .chrome))
        XCTAssertFalse(store.receive(.pass(pass(-1)), from: .chrome))
        XCTAssertFalse(store.receive(.pass(ActivationLink.token(in: PassKey.activationLink(expires: later(300)))!), from: .chrome))
        XCTAssertEqual(secrets.values, kept)
        XCTAssertTrue(store.hasPremium)
    }

    func testSigningOutInTheExtensionLocksAndSaysWhy() {
        store.start()
        store.receive(.pass(pass()), from: .chrome)
        store.receive(.drop(.signedOut), from: .chrome)
        XCTAssertFalse(store.hasPremium)
        XCTAssertNil(secrets.values[.chromePass])
        XCTAssertEqual(store.lapse, .signedOutInBrowser)
    }

    func testAnAccountWithoutPremiumSaysSo() {
        store.start()
        store.receive(.pass(pass()), from: .safari)
        store.receive(.drop(.noPremium), from: .safari)
        XCTAssertEqual(store.lapse, .browserAccountFree)
    }

    func testSigningOutInOneBrowserKeepsTheOtherBrowsersPass() {
        store.start()
        store.receive(.pass(pass()), from: .chrome)
        store.receive(.pass(pass()), from: .safari)
        store.receive(.drop(.signedOut), from: .chrome)
        XCTAssertTrue(store.hasPremium)
        XCTAssertNotNil(secrets.values[.safariPass])
        XCTAssertNil(store.lapse)
    }

    func testSigningOutKeepsAnActivation() {
        store.start()
        store.receive(.pass(pass()), from: .chrome)
        store.activate(PassKey.activationLink(expires: later(200)))
        store.receive(.drop(.signedOut), from: .chrome)
        XCTAssertTrue(store.hasPremium)
        XCTAssertEqual(store.status, .activation(until: later(200)))
    }

    func testAPassArrivingClearsAnOldLapse() {
        store.start()
        store.receive(.pass(pass()), from: .chrome)
        store.receive(.drop(.signedOut), from: .chrome)
        store.receive(.pass(pass()), from: .chrome)
        XCTAssertNil(store.lapse)
    }

    func testAPassLocksTheMomentItRunsOut() {
        store.start()
        store.receive(.pass(pass(1)), from: .chrome)
        clock = later(1).addingTimeInterval(1)
        XCTAssertFalse(store.hasPremium, "read at every use")
    }

    func testTheStoreLooksAgainWhenThePassRunsOut() async {
        let realStore = DirectPremiumStore.testing(secrets: secrets, now: Date.init)
        realStore.start()
        realStore.receive(.pass(PassKey.pass(expires: Date().addingTimeInterval(1.2))), from: .chrome)
        XCTAssertTrue(realStore.hasPremium)
        let lapsed = await waitUntil(timeout: 5) { realStore.lapse == .passRanOut }
        XCTAssertTrue(lapsed)
        XCTAssertNil(secrets.values[.chromePass])
        realStore.stop()
    }

    // MARK: Activation links

    func testAGoodLinkUnlocksSaysUntilWhenAndIsKept() {
        store.start()
        let link = PassKey.activationLink(expires: later(365))
        XCTAssertTrue(store.activate(link))
        XCTAssertTrue(store.hasPremium)
        XCTAssertEqual(store.activity, .activated(until: later(365)))
        XCTAssertEqual(store.activity.message(dateText: { _ in "D" }), "Premium is on through D.")
        XCTAssertEqual(secrets.values[.activation], ActivationLink.token(in: link))
    }

    func testAnActivationSurvivesARelaunch() {
        store.start()
        store.activate(PassKey.activationLink(expires: later(365)))
        store.stop()
        let relaunched = makeStore()
        relaunched.start()
        XCTAssertTrue(relaunched.hasPremium)
        XCTAssertEqual(relaunched.status, .activation(until: later(365)))
        relaunched.stop()
    }

    func testAnExpiredLinkIsRefusedAndSaysSo() {
        store.start()
        store.activate(PassKey.activationLink(expires: later(-1)))
        XCTAssertFalse(store.hasPremium)
        XCTAssertEqual(store.activity, .activationRefused(expired: true))
        XCTAssertEqual(store.activity.message, "This activation link has run out. Press Activate on passwordpie.com for a new one.")
        XCTAssertTrue(store.activity.isError)
    }

    func testAPassInAnActivationLinkIsRefused() {
        store.start()
        store.activate(URL(string: "passwordpie://activate?token=\(pass())")!)
        XCTAssertFalse(store.hasPremium)
        XCTAssertEqual(store.activity, .activationRefused(expired: false))
        XCTAssertEqual(store.activity.message, "This activation link is not valid. Press Activate on passwordpie.com for a new one.")
        XCTAssertNil(secrets.values[.activation])
    }

    func testTheOldSignInCallbackIsNotOurs() {
        store.start()
        XCTAssertFalse(store.activate(URL(string: "passwordpie://auth?code=abc&state=x")!))
        XCTAssertEqual(store.activity, .idle)
    }

    func testAnActivationRunningOutSaysWhen() {
        store.start()
        store.activate(PassKey.activationLink(expires: later(10)))
        clock = later(11)
        store.reevaluate()
        XCTAssertEqual(store.lapse, .activationRanOut(later(10)))
        XCTAssertNil(secrets.values[.activation])
    }

    func testTheWindowALinkOpensKeepsTheLinksMessageUntilItIsOldNews() {
        store.start()
        store.activate(PassKey.activationLink(expires: later(365)))
        store.clearMessage()
        XCTAssertNotEqual(store.activity, .idle)
        clock = clock.addingTimeInterval(6)
        store.clearMessage()
        XCTAssertEqual(store.activity, .idle)
    }

    // MARK: The gate

    func testAFreeUserAskingForACodeOpensTheWindow() {
        store.start()
        var ran = 0
        store.requestUnlock { ran += 1 }
        XCTAssertEqual(ran, 0)
        XCTAssertEqual(paywalls, 1)
    }

    func testTheFreeCodesSwitchUnlocksTheAppButNotTheBrowser() {
        let free = makeStore(freeCodes: true)
        free.start()
        XCTAssertTrue(free.hasPremium)
        XCTAssertFalse(free.ownPremium)
        free.stop()
    }

    func testTheBridgeAsksOnlyWhatThisMacHolds() {
        store.start()
        PremiumChannel.live = store
        XCTAssertFalse(appHasPremium())
        store.receive(.pass(pass()), from: .chrome)
        XCTAssertTrue(appHasPremium())
        PremiumChannel.live = nil
    }

    // MARK: The Premium window

    private func copy(_ status: DirectPremiumStatus, _ lapse: PremiumLapse? = nil) -> DirectPremiumCopy {
        DirectPremiumCopy.make(status: status, lapse: lapse, now: PremiumFixtures.now, dateText: { _ in "D" })
    }

    func testFreeOffersEverythingAndHowPremiumReachesThisMac() {
        let free = copy(.none)
        XCTAssertEqual(free.title, "Free")
        XCTAssertTrue(free.offersPremium)
        XCTAssertTrue(free.showsActivate)
        XCTAssertNil(free.warning)
    }

    func testAPassFromTheBrowserShowsNoEndDate() {
        let fromBrowser = copy(.fromBrowser(activationUntil: nil))
        XCTAssertEqual(fromBrowser.title, "Premium is on")
        XCTAssertEqual(fromBrowser.detail, "The PasswordPie extension in your browser keeps it up to date.")
        XCTAssertFalse(fromBrowser.offersPremium)
        XCTAssertFalse(fromBrowser.showsActivate)
        XCTAssertFalse(fromBrowser.detail.contains("D"), "the seven-day pass is not an end date")
    }

    func testAnActivationSaysUntilWhenAndHowToRenew() {
        let active = copy(.activation(until: later(200)))
        XCTAssertEqual(active.title, "Premium is on")
        XCTAssertTrue(active.detail.contains("through D"))
        XCTAssertTrue(active.detail.contains("press Activate"))
        XCTAssertTrue(active.showsActivate)
        XCTAssertFalse(active.offersPremium)
        XCTAssertNil(active.warning)
    }

    func testAnActivationEndingWithinThirtyDaysSaysSoBeforeTheCodesStop() {
        XCTAssertNil(copy(.activation(until: later(31))).warning)
        XCTAssertEqual(
            copy(.activation(until: later(30))).warning,
            "Premium on this Mac ends on D. Renew it before then to keep your two-step codes."
        )
    }

    func testEachLapseSaysWhatHappenedAndWhatToDo() {
        XCTAssertTrue(copy(.none, .signedOutInBrowser).detail.hasPrefix("You signed out of the PasswordPie extension"))
        XCTAssertTrue(copy(.none, .browserAccountFree).detail.contains("no longer has Premium"))
        XCTAssertTrue(copy(.none, .passRanOut).detail.contains("has not renewed Premium for a week"))
        XCTAssertTrue(copy(.none, .activationRanOut(later(-1))).detail.contains("ended on D"))
        for lapse: PremiumLapse in [.signedOutInBrowser, .browserAccountFree, .passRanOut, .activationRanOut(later(-1))] {
            let lapsed = copy(.none, lapse)
            XCTAssertEqual(lapsed.title, "Premium is off")
            XCTAssertTrue(lapsed.offersPremium)
            XCTAssertTrue(lapsed.showsActivate)
        }
    }

    /// "Pass", "token" and "entitlement" are the code's words, not the user's.
    func testNoWordsOfTheCodeReachTheUser() {
        let states: [(DirectPremiumStatus, PremiumLapse?)] = [
            (.none, nil), (.none, .signedOutInBrowser), (.none, .browserAccountFree), (.none, .passRanOut),
            (.none, .activationRanOut(later(-1))), (.fromBrowser(activationUntil: later(9)), nil), (.activation(until: later(9)), nil),
        ]
        var texts: [String] = []
        for (status, lapse) in states {
            let words = copy(status, lapse)
            texts += [words.title, words.detail, words.warning ?? ""]
        }
        let outcomes: [DirectPremiumActivity] = [.activated(until: later(1)), .activationRefused(expired: true), .activationRefused(expired: false)]
        texts += outcomes.compactMap(\.message)
        for text in texts {
            let lower = text.lowercased()
            for word in ["pass ", "pass.", "token", "entitlement", "sign in to passwordpie.com"] {
                XCTAssertFalse(lower.contains(word), "\(text) says \(word)")
            }
        }
    }
}
#endif

/// The bridge's `premium` request, through the app.
@MainActor
final class BridgePassRelayTests: XCTestCase {
    private func sampleToken() throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("extension/dev/test-key.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: String])
        return try XCTUnwrap(json["sampleToken"])
    }

    private func answer(_ bridge: BrowserBridge, _ json: String, from browser: BridgeBrowser = .chrome) throws -> [String: Any] {
        let data = try XCTUnwrap(bridge.answer(Data(json.utf8), from: browser))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    #if PP_DIRECT
    func testTheDirectAppKeepsAPassFromTheExtension() throws {
        let secrets = FakeSecrets()
        let store = PremiumChannel.makeStore(secrets: secrets)
        PremiumChannel.live = store
        defer { PremiumChannel.live = nil }
        store.start()
        let session = VaultSession(premium: store, pasteboard: FakePasteboard())
        let bridge = BrowserBridge(session: session)
        defer { withExtendedLifetime(session) {} }
        let token = try sampleToken()
        let taken = try answer(bridge, #"{"type":"premium","id":1,"pass":"\#(token)"}"#)
        XCTAssertEqual(taken["accepted"] as? Bool, true)
        XCTAssertTrue(store.hasPremium)
        XCTAssertEqual(secrets.values[.chromePass], token)
        _ = try answer(bridge, #"{"type":"premium","id":2,"drop":"signed-out"}"#, from: .safari)
        XCTAssertTrue(store.hasPremium, "Safari cannot take back what Chrome delivered")
        _ = try answer(bridge, #"{"type":"premium","id":3,"drop":"signed-out"}"#)
        XCTAssertFalse(store.hasPremium)
        XCTAssertEqual(store.lapse, .signedOutInBrowser)
    }
    #else
    /// The App Store app takes Premium only from StoreKit or an activation. A pass sent to it anyway gets the answer an app
    /// that does not know the message gives, and nothing is kept.
    func testTheAppStoreAppIgnoresARelayedPass() throws {
        let secrets = FakeSecrets()
        let store = PremiumChannel.makeStore(secrets: secrets)
        PremiumChannel.live = store
        defer { PremiumChannel.live = nil }
        let session = VaultSession(premium: store, pasteboard: FakePasteboard())
        let bridge = BrowserBridge(session: session)
        defer { withExtendedLifetime(session) {} }
        let ignored = try answer(bridge, #"{"type":"premium","id":1,"pass":"\#(try sampleToken())"}"#, from: .safari)
        XCTAssertEqual(ignored["type"] as? String, "error")
        XCTAssertEqual(ignored["code"] as? String, "bad-request")
        XCTAssertFalse(store.hasPremium)
        XCTAssertEqual(secrets.values, [:])
    }
    #endif

    /// Compiled in both channels: which channel takes a pass at all.
    func testOnlyTheDirectChannelHasARelay() {
        #if PP_DIRECT
        XCTAssertNotNil(PremiumChannel.passRelay(from: .safari))
        #else
        XCTAssertNil(PremiumChannel.passRelay(from: .safari))
        #endif
    }
}
