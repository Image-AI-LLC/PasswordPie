import PasswordPieCore
import XCTest
@testable import PasswordPie

#if PP_DIRECT
/// The direct channel: Premium is an activation link from the website. Nothing here signs in or talks to a site, and
/// nothing a browser extension sends counts.
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

    func testAKeptActivationUnlocksAtLaunchWithNothingToWaitFor() {
        secrets.values[.activation] = ActivationLink.token(in: PassKey.activationLink(expires: later(200)))
        store.start()
        XCTAssertTrue(store.hasPremium)
        XCTAssertEqual(store.status, .activation(until: later(200)))
    }

    /// Earlier builds signed in inside the app, or took a week-long pass from the browser extension. None of it unlocks
    /// anything now, and all of it goes at the first launch.
    func testWhatEarlierBuildsKeptIsDeletedAndUnlocksNothing() {
        secrets.values[.legacySession] = "session-1"
        secrets.values[.legacyEmail] = "ada@example.com"
        secrets.values[.legacyChromePass] = pass()
        secrets.values[.legacySafariPass] = pass()
        secrets.values[.legacyAppPass] = pass()
        store.start()
        XCTAssertFalse(store.hasPremium)
        XCTAssertEqual(store.status, .none)
        XCTAssertNil(store.lapse, "nothing of ours ran out: the window says Free and how to activate")
        XCTAssertEqual(secrets.values, [:])
    }

    func testAnActivationBesideAnOldPassStays() {
        let token = ActivationLink.token(in: PassKey.activationLink(expires: later(200)))
        secrets.values[.activation] = token
        secrets.values[.legacyChromePass] = pass()
        store.start()
        XCTAssertTrue(store.hasPremium)
        XCTAssertEqual(secrets.values, [.activation: token!])
    }

    func testAnExpiredActivationAtLaunchIsDeletedAndExplained() {
        secrets.values[.activation] = ActivationLink.token(in: PassKey.activationLink(expires: later(-1)))
        store.start()
        XCTAssertFalse(store.hasPremium)
        XCTAssertEqual(store.lapse, .activationRanOut(later(-1)))
        XCTAssertNil(secrets.values[.activation])
    }

    func testAForgedTokenInTheKeychainIsThrownAwayWithNoStory() {
        secrets.values[.activation] = ActivationLink.token(in: PassKey.activationLink(expires: later(200), signer: .init()))
        store.start()
        XCTAssertFalse(store.hasPremium)
        XCTAssertNil(store.lapse)
        XCTAssertNil(secrets.values[.activation])
    }

    /// With the real clock: nothing announces that an activation ran out, so the store looks again at that moment.
    func testTheStoreLooksAgainWhenTheActivationRunsOut() async {
        let realStore = DirectPremiumStore.testing(secrets: secrets, now: Date.init)
        realStore.start()
        realStore.activate(PassKey.activationLink(expires: Date().addingTimeInterval(1.5)))
        XCTAssertTrue(realStore.hasPremium)
        let lapsed = await waitUntil(timeout: 5) { realStore.lapse != nil }
        XCTAssertTrue(lapsed)
        XCTAssertFalse(realStore.hasPremium)
        XCTAssertNil(secrets.values[.activation])
        realStore.stop()
    }

    // MARK: Activation links

    func testAGoodLinkUnlocksSaysUntilWhenAndIsKept() {
        store.start()
        let link = PassKey.activationLink(expires: later(365))
        XCTAssertTrue(store.activate(link))
        XCTAssertTrue(store.hasPremium)
        XCTAssertEqual(store.activity, .activated(until: later(365)))
        XCTAssertEqual(store.activity.message, "The activation link worked.")
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

    /// "The activation link worked." beside "Premium is off" would contradict itself.
    func testAnActivationRunningOutForgetsTheLinksMessage() {
        store.start()
        store.activate(PassKey.activationLink(expires: later(1)))
        XCTAssertEqual(store.activity, .activated(until: later(1)))
        clock = later(2)
        store.reevaluate()
        XCTAssertEqual(store.activity, .idle)
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
        store.activate(PassKey.activationLink(expires: later(365)))
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

    func testAnActivationThatRanOutSaysWhenAndWhatToDo() {
        let lapsed = copy(.none, .activationRanOut(later(-1)))
        XCTAssertEqual(lapsed.title, "Premium is off")
        XCTAssertTrue(lapsed.detail.contains("ended on D"))
        XCTAssertTrue(lapsed.offersPremium)
        XCTAssertTrue(lapsed.showsActivate)
    }

    /// The window never sends anyone to the browser extension: it has no account and brings no Premium.
    func testNothingSendsYouToTheBrowserExtension() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PasswordPieApp/PremiumDirectViews.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        // What the person reads: the string literals, not the Swift around them.
        let literals = try NSRegularExpression(pattern: "\"((?:[^\"\\\\]|\\\\.)*)\"")
            .matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]).lowercased() } }
        XCTAssertTrue(literals.contains { $0.contains("press activate in your account settings on passwordpie.com") })
        for literal in literals {
            XCTAssertFalse(literal.contains("extension"), literal)
            XCTAssertFalse(literal.contains("sign in"), literal)
        }
    }

    /// "Pass", "token" and "entitlement" are the code's words, not the user's.
    func testNoWordsOfTheCodeReachTheUser() {
        let states: [(DirectPremiumStatus, PremiumLapse?)] = [
            (.none, nil), (.none, .activationRanOut(later(-1))), (.activation(until: later(9)), nil),
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

/// What the browser extension can and cannot do about Premium, through the app. Compiled in both channels.
@MainActor
final class BridgePremiumTests: XCTestCase {
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

    /// An extension from before 2026-11-11 hands over its pass. Neither app knows the message: nothing is kept and
    /// nothing unlocks.
    func testAPassFromTheExtensionIsIgnored() throws {
        let secrets = FakeSecrets()
        let store = PremiumChannel.makeStore(secrets: secrets)
        PremiumChannel.live = store
        defer { PremiumChannel.live = nil }
        store.start()
        let session = VaultSession(premium: store, pasteboard: FakePasteboard())
        let bridge = BrowserBridge(session: session)
        defer { withExtendedLifetime(session) {} }
        for browser in [BridgeBrowser.chrome, .safari] {
            let ignored = try answer(bridge, #"{"type":"premium","id":1,"pass":"\#(try sampleToken())"}"#, from: browser)
            XCTAssertEqual(ignored["type"] as? String, "error")
            XCTAssertEqual(ignored["code"] as? String, "bad-request")
        }
        XCTAssertFalse(store.hasPremium)
        XCTAssertFalse(appHasPremium())
        XCTAssertEqual(secrets.values, [:])
        store.stop()
    }

    /// "Upgrade" in the page's note: the app opens its Premium window, after the answer is on its way.
    func testUpgradeOpensThePremiumWindow() async throws {
        let store = PremiumChannel.makeStore(secrets: FakeSecrets())
        let session = VaultSession(premium: store, pasteboard: FakePasteboard())
        let bridge = BrowserBridge(session: session)
        defer { withExtendedLifetime(session) {} }
        var opened = 0
        bridge.onUpgrade = { opened += 1 }
        let acknowledged = try answer(bridge, #"{"type":"upgrade","id":7}"#, from: .safari)
        XCTAssertEqual(acknowledged["type"] as? String, "upgrade")
        XCTAssertEqual(acknowledged["id"] as? Int, 7)
        let shown = await waitUntil { opened == 1 }
        XCTAssertTrue(shown)
    }
}
