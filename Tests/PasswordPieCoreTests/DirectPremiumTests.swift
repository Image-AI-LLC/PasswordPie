import CryptoKit
import Foundation
import XCTest
@testable import PasswordPieCore

/// Who has Premium in the direct app: a pass the browser extension handed over, or an activation from the website.
/// docs/CHANNELS.md, "Who has Premium: the direct channel".
final class DirectPremiumTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86400

    private func token(audience: String, expires: Date, signer: Curve25519.Signing.PrivateKey? = nil) -> String {
        func b64(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = try! JSONSerialization.data(withJSONObject: ["alg": "EdDSA", "typ": "JWT", "kid": "pp-1"], options: .sortedKeys)
        let claims = try! JSONSerialization.data(withJSONObject: [
            "iss": "https://passwordpie.com", "aud": audience, "sub": "user-1", "premium": true, "plan": "lifetime",
            "iat": Int(min(now, expires).timeIntervalSince1970) - 3600, "exp": Int(expires.timeIntervalSince1970),
        ] as [String: Any], options: .sortedKeys)
        let signing = "\(b64(header)).\(b64(claims))"
        return "\(signing).\(b64(try! (signer ?? key).signature(for: Data(signing.utf8))))"
    }

    private func pass(_ days: Double = 7, signer: Curve25519.Signing.PrivateKey? = nil) -> String {
        token(audience: EntitlementToken.audience, expires: now.addingTimeInterval(days * day), signer: signer)
    }

    private func activation(_ days: Double = 365, signer: Curve25519.Signing.PrivateKey? = nil) -> String {
        token(audience: EntitlementToken.activationAudience, expires: now.addingTimeInterval(days * day), signer: signer)
    }

    private var verifyPass: TokenCheck {
        let key = key.publicKey.rawRepresentation
        return { EntitlementToken.verify($0, now: $1, publicKey: key) }
    }

    private var verifyActivation: TokenCheck {
        let key = key.publicKey.rawRepresentation
        return { EntitlementToken.verify($0, now: $1, publicKey: key, audience: EntitlementToken.activationAudience) }
    }

    private func load(passes: [PassSource: String] = [:], activation: String? = nil, at: Date? = nil) -> DirectPremiumLoad {
        DirectPremium.load(passes: passes, activation: activation, now: at ?? now, verifyPass: verifyPass, verifyActivation: verifyActivation)
    }

    private func entitlement(_ days: Double) -> Entitlement {
        Entitlement(subject: "user-1", plan: "lifetime", expiresAt: now.addingTimeInterval(days * day))
    }

    // MARK: The decision table

    func testAPassOnlyIsPremiumKeptUpByTheBrowser() {
        let loaded = load(passes: [.chrome: pass()])
        XCTAssertTrue(loaded.premium.grantsPremium(at: now))
        XCTAssertEqual(loaded.premium.status(at: now), .fromBrowser(activationUntil: nil))
        XCTAssertEqual(loaded.discard, [])
        XCTAssertNil(loaded.lapse)
    }

    func testAnActivationOnlyIsPremiumUntilItsDate() {
        let loaded = load(activation: activation(200))
        XCTAssertTrue(loaded.premium.grantsPremium(at: now))
        XCTAssertEqual(loaded.premium.status(at: now), .activation(until: now.addingTimeInterval(200 * day)))
    }

    func testBothSayTheBrowserKeepsItUpAndRememberTheActivation() {
        let loaded = load(passes: [.safari: pass()], activation: activation(200))
        XCTAssertEqual(loaded.premium.status(at: now), .fromBrowser(activationUntil: now.addingTimeInterval(200 * day)))
    }

    func testNeitherIsFree() {
        let loaded = load()
        XCTAssertFalse(loaded.premium.grantsPremium(at: now))
        XCTAssertEqual(loaded.premium.status(at: now), .none)
        XCTAssertNil(loaded.lapse)
    }

    func testAnExpiredPassIsDiscardedAndSaysTheBrowserDidNotRenewIt() {
        let loaded = load(passes: [.chrome: pass(-1)])
        XCTAssertFalse(loaded.premium.grantsPremium(at: now))
        XCTAssertEqual(loaded.discard, [.pass(.chrome)])
        XCTAssertEqual(loaded.lapse, .passRanOut)
    }

    func testAnExpiredActivationIsDiscardedAndSaysWhenItEnded() {
        let loaded = load(activation: activation(-2))
        XCTAssertEqual(loaded.discard, [.activation])
        XCTAssertEqual(loaded.lapse, .activationRanOut(now.addingTimeInterval(-2 * day)))
    }

    func testSomethingThatRanOutBesideSomethingGoodIsNoLapse() {
        let loaded = load(passes: [.chrome: pass(-1), .safari: pass()])
        XCTAssertTrue(loaded.premium.grantsPremium(at: now))
        XCTAssertEqual(loaded.discard, [.pass(.chrome)])
        XCTAssertNil(loaded.lapse)
    }

    func testAPassMadeForTheWrongAudienceIsDiscardedWithNoStory() {
        let loaded = load(passes: [.chrome: activation()], activation: pass())
        XCTAssertFalse(loaded.premium.grantsPremium(at: now))
        XCTAssertEqual(Set(loaded.discard), [.pass(.chrome), .activation])
        XCTAssertNil(loaded.lapse, "a token that never checked is not something that ran out")
    }

    func testABadSignatureCountsForNothing() {
        let other = Curve25519.Signing.PrivateKey()
        let loaded = load(passes: [.chrome: pass(signer: other)], activation: activation(signer: other))
        XCTAssertFalse(loaded.premium.grantsPremium(at: now))
        XCTAssertNil(loaded.lapse)
    }

    func testPremiumEndsTheMomentTheLastProofRunsOut() {
        let premium = load(passes: [.chrome: pass(3)], activation: activation(5)).premium
        XCTAssertTrue(premium.grantsPremium(at: now.addingTimeInterval(4 * day)))
        XCTAssertFalse(premium.grantsPremium(at: now.addingTimeInterval(5 * day)))
        XCTAssertEqual(premium.status(at: now.addingTimeInterval(4 * day)), .activation(until: now.addingTimeInterval(5 * day)))
    }

    func testTheNextLookIsWhenTheEarliestProofRunsOut() {
        let premium = load(passes: [.chrome: pass(3), .safari: pass(6)], activation: activation(5)).premium
        XCTAssertEqual(premium.nextExpiry(after: now), now.addingTimeInterval(3 * day))
        XCTAssertEqual(premium.nextExpiry(after: now.addingTimeInterval(3 * day)), now.addingTimeInterval(5 * day))
        XCTAssertNil(DirectPremium().nextExpiry(after: now))
    }

    // MARK: Expiring while running

    func testExpiringRemovesWhatRanOutAndSaysWhy() {
        var premium = DirectPremium(passes: [.chrome: entitlement(1)], activation: nil)
        XCTAssertEqual(premium.expire(now: now), DirectPremiumExpiry(removed: [], lapse: nil))
        let later = now.addingTimeInterval(2 * day)
        XCTAssertEqual(premium.expire(now: later), DirectPremiumExpiry(removed: [.pass(.chrome)], lapse: .passRanOut))
        XCTAssertEqual(premium, DirectPremium())
    }

    func testAnActivationRunningOutSaysItsDate() {
        var premium = DirectPremium(passes: [:], activation: entitlement(1))
        let expiry = premium.expire(now: now.addingTimeInterval(2 * day))
        XCTAssertEqual(expiry.removed, [.activation])
        XCTAssertEqual(expiry.lapse, .activationRanOut(now.addingTimeInterval(day)))
    }

    // MARK: Passes from the browser

    func testAGoodPassFromABrowserIsKept() {
        var premium = DirectPremium()
        XCTAssertTrue(premium.receivePass(pass(), from: .chrome, now: now, verify: verifyPass))
        XCTAssertEqual(premium.passes[.chrome]?.expiresAt, now.addingTimeInterval(7 * day))
        XCTAssertTrue(premium.grantsPremium(at: now))
    }

    func testAPassThatDoesNotCheckChangesNothing() {
        var premium = DirectPremium(passes: [.chrome: entitlement(5)], activation: nil)
        let before = premium
        XCTAssertFalse(premium.receivePass("not.a.token", from: .chrome, now: now, verify: verifyPass))
        XCTAssertFalse(premium.receivePass(pass(signer: Curve25519.Signing.PrivateKey()), from: .chrome, now: now, verify: verifyPass))
        XCTAssertFalse(premium.receivePass(pass(-1), from: .chrome, now: now, verify: verifyPass))
        XCTAssertFalse(premium.receivePass(activation(), from: .chrome, now: now, verify: verifyPass), "an activation is not a pass")
        XCTAssertEqual(premium, before)
    }

    func testSigningOutInTheOnlyBrowserEndsPremiumAndSaysSo() {
        var premium = DirectPremium(passes: [.chrome: entitlement(5)], activation: nil)
        XCTAssertEqual(premium.dropPass(from: .chrome, reason: .signedOut, now: now), .signedOutInBrowser)
        XCTAssertFalse(premium.grantsPremium(at: now))
    }

    func testAnAccountThatLostPremiumSaysSo() {
        var premium = DirectPremium(passes: [.safari: entitlement(5)], activation: nil)
        XCTAssertEqual(premium.dropPass(from: .safari, reason: .noPremium, now: now), .browserAccountFree)
    }

    func testSigningOutInOneBrowserLeavesAnotherBrowsersPass() {
        var premium = DirectPremium(passes: [.chrome: entitlement(5), .safari: entitlement(5)], activation: nil)
        XCTAssertNil(premium.dropPass(from: .chrome, reason: .signedOut, now: now))
        XCTAssertNil(premium.passes[.chrome])
        XCTAssertTrue(premium.grantsPremium(at: now))
        XCTAssertEqual(premium.status(at: now), .fromBrowser(activationUntil: nil))
    }

    func testSigningOutLeavesAnActivation() {
        var premium = DirectPremium(passes: [.chrome: entitlement(5)], activation: entitlement(100))
        XCTAssertNil(premium.dropPass(from: .chrome, reason: .signedOut, now: now))
        XCTAssertEqual(premium.status(at: now), .activation(until: now.addingTimeInterval(100 * day)))
    }

    func testABrowserCannotDropWhatAnotherBrowserOrTheOldSignInDelivered() {
        var premium = DirectPremium(passes: [.appSignIn: entitlement(5)], activation: nil)
        XCTAssertNil(premium.dropPass(from: .chrome, reason: .signedOut, now: now))
        XCTAssertTrue(premium.grantsPremium(at: now))
    }

    func testDroppingWhenNothingWasHeldSaysNothing() {
        var premium = DirectPremium()
        XCTAssertNil(premium.dropPass(from: .chrome, reason: .signedOut, now: now))
    }

    // MARK: Migration from a build that signed in inside the app

    func testAPassFromTheOldSignInCountsUntilItRunsOut() {
        let loaded = load(passes: [.appSignIn: pass(4)])
        XCTAssertTrue(loaded.premium.grantsPremium(at: now))
        XCTAssertEqual(loaded.premium.status(at: now), .fromBrowser(activationUntil: nil))
        let later = load(passes: [.appSignIn: pass(4)], at: now.addingTimeInterval(5 * day))
        XCTAssertFalse(later.premium.grantsPremium(at: now.addingTimeInterval(5 * day)))
        XCTAssertEqual(later.discard, [.pass(.appSignIn)])
    }

    // MARK: Activation links

    func testANewActivationIsTaken() {
        XCTAssertEqual(
            ActivationLink.decide(token: activation(100), current: nil, now: now, verify: verifyActivation),
            .replace(entitlement(100))
        )
    }

    func testALongerActivationReplacesAShorterOne() {
        XCTAssertEqual(
            ActivationLink.decide(token: activation(300), current: entitlement(100), now: now, verify: verifyActivation),
            .replace(entitlement(300))
        )
    }

    func testAShorterActivationKeepsTheLongerOne() {
        XCTAssertEqual(
            ActivationLink.decide(token: activation(50), current: entitlement(100), now: now, verify: verifyActivation),
            .keep(entitlement(100))
        )
    }

    func testAnExpiredLinkIsRefusedAsRunOut() {
        XCTAssertEqual(ActivationLink.decide(token: activation(-1), current: nil, now: now, verify: verifyActivation), .refuse(expired: true))
    }

    func testAPassInAnActivationLinkIsRefused() {
        XCTAssertEqual(ActivationLink.decide(token: pass(), current: nil, now: now, verify: verifyActivation), .refuse(expired: false))
    }

    func testAForgedActivationIsRefused() {
        let forged = activation(signer: Curve25519.Signing.PrivateKey())
        XCTAssertEqual(ActivationLink.decide(token: forged, current: nil, now: now, verify: verifyActivation), .refuse(expired: false))
        XCTAssertEqual(ActivationLink.decide(token: nil, current: nil, now: now, verify: verifyActivation), .refuse(expired: false))
    }
}

/// The `premium` request: the extension hands the app its pass, or takes it back. docs/BROWSER_EXTENSION.md, "`premium`".
final class BridgePremiumTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func request(_ json: String) -> BridgeRequest {
        try! JSONDecoder().decode(BridgeRequest.self, from: Data(json.utf8))
    }

    private func object(_ response: BridgeResponse) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as! [String: Any]
    }

    private func answer(_ json: String, locked: Bool = false, relay: ((PassRelay) -> Bool)?) -> [String: Any] {
        var state = BridgeState()
        return object(state.handle(request(json), from: .chrome, locked: locked, now: now, premium: relay) { _ in nil })
    }

    func testAPassGoesToTheAppAndTheAnswerSaysWhetherItWasTaken() {
        var got: [PassRelay] = []
        let taken = answer(#"{"type":"premium","id":4,"pass":"jwt-1"}"#) { got.append($0); return true }
        XCTAssertEqual(got, [.pass("jwt-1")])
        XCTAssertEqual(taken["type"] as? String, "premium")
        XCTAssertEqual(taken["id"] as? Int, 4)
        XCTAssertEqual(taken["accepted"] as? Bool, true)
        let refused = answer(#"{"type":"premium","id":5,"pass":"jwt-2"}"#) { _ in false }
        XCTAssertEqual(refused["accepted"] as? Bool, false)
    }

    func testTheAnswerNeverCarriesThePassBack() throws {
        let taken = answer(#"{"type":"premium","id":4,"pass":"jwt-secret"}"#) { _ in true }
        XCTAssertEqual(Set(taken.keys), ["type", "id", "accepted"])
        let text = String(data: try JSONSerialization.data(withJSONObject: taken), encoding: .utf8)!
        XCTAssertFalse(text.contains("jwt-secret"))
    }

    func testTakingThePassBackSaysWhy() {
        var got: [PassRelay] = []
        let signedOut = answer(#"{"type":"premium","id":6,"drop":"signed-out"}"#) { got.append($0); return true }
        _ = answer(#"{"type":"premium","id":7,"drop":"no-premium"}"#) { got.append($0); return true }
        XCTAssertEqual(got, [.drop(.signedOut), .drop(.noPremium)])
        XCTAssertEqual(Set(signedOut.keys), ["type", "id"])
    }

    func testAPassIsTakenWhileLocked() {
        var got: [PassRelay] = []
        let taken = answer(#"{"type":"premium","id":4,"pass":"jwt-1"}"#, locked: true) { got.append($0); return true }
        XCTAssertEqual(got.count, 1, "Premium has nothing to do with the database being open")
        XCTAssertEqual(taken["accepted"] as? Bool, true)
    }

    func testAMalformedRequestIsABadRequest() {
        var calls = 0
        for json in [
            #"{"type":"premium","id":8}"#,
            #"{"type":"premium","id":8,"pass":""}"#,
            #"{"type":"premium","id":8,"drop":"bored"}"#,
            #"{"type":"premium","id":8,"pass":"a","drop":"signed-out"}"#,
        ] {
            let bad = answer(json) { _ in calls += 1; return true }
            XCTAssertEqual(bad["type"] as? String, "error", json)
            XCTAssertEqual(bad["code"] as? String, "bad-request", json)
            XCTAssertEqual(bad["id"] as? Int, 8, json)
        }
        XCTAssertEqual(calls, 0)
    }

    /// The App Store app takes Premium only from StoreKit or an activation, so it has no relay and answers as an app
    /// that does not know the message: an error, and the connection stays up.
    func testWithNoRelayThePassIsIgnored() {
        let ignored = answer(#"{"type":"premium","id":9,"pass":"jwt-1"}"#, relay: nil)
        XCTAssertEqual(ignored["type"] as? String, "error")
        XCTAssertEqual(ignored["code"] as? String, "bad-request")
    }

    /// What an app from before this message answers: the same error. The extension treats it as "not taken".
    func testAnAppThatDoesNotKnowTheMessageAnswersAnError() {
        var state = BridgeState()
        let unknown = object(state.handle(request(#"{"type":"premium","id":3,"pass":"x"}"#), from: .safari, locked: false, now: now) { _ in nil })
        XCTAssertEqual(unknown["type"] as? String, "error")
        XCTAssertEqual(unknown["id"] as? Int, 3)
    }
}
