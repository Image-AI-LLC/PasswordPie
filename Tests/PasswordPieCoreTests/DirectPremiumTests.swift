import CryptoKit
import Foundation
import XCTest
@testable import PasswordPieCore

/// Who has Premium in the direct app: an activation from the website, and nothing the browser extension sends.
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

    private func load(activation: String? = nil, at: Date? = nil) -> DirectPremiumLoad {
        DirectPremium.load(activation: activation, now: at ?? now, verify: verifyActivation)
    }

    private func entitlement(_ days: Double) -> Entitlement {
        Entitlement(subject: "user-1", plan: "lifetime", expiresAt: now.addingTimeInterval(days * day))
    }

    // MARK: The decision table

    func testAnActivationIsPremiumUntilItsDate() {
        let loaded = load(activation: activation(200))
        XCTAssertTrue(loaded.premium.grantsPremium(at: now))
        XCTAssertEqual(loaded.premium.status(at: now), .activation(until: now.addingTimeInterval(200 * day)))
        XCTAssertFalse(loaded.discard)
        XCTAssertNil(loaded.lapse)
    }

    func testNothingIsFree() {
        let loaded = load()
        XCTAssertFalse(loaded.premium.grantsPremium(at: now))
        XCTAssertEqual(loaded.premium.status(at: now), .none)
        XCTAssertFalse(loaded.discard)
        XCTAssertNil(loaded.lapse)
    }

    func testAnExpiredActivationIsDiscardedAndSaysWhenItEnded() {
        let loaded = load(activation: activation(100), at: now.addingTimeInterval(101 * day))
        XCTAssertFalse(loaded.premium.grantsPremium(at: now.addingTimeInterval(101 * day)))
        XCTAssertTrue(loaded.discard)
        XCTAssertEqual(loaded.lapse, .activationRanOut(now.addingTimeInterval(100 * day)))
    }

    /// The week-long pass the browser extension carried until 2026-11-11 unlocks nothing, wherever it turns up.
    func testAPassOfTheKindTheExtensionCarriedIsNotAnActivation() {
        XCTAssertNotNil(verifyPass(pass(), now), "the pass itself is well made")
        let loaded = load(activation: pass())
        XCTAssertFalse(loaded.premium.grantsPremium(at: now))
        XCTAssertTrue(loaded.discard)
        XCTAssertNil(loaded.lapse, "nothing of ours ran out")
    }

    func testABadSignatureCountsForNothing() {
        let loaded = load(activation: activation(signer: Curve25519.Signing.PrivateKey()))
        XCTAssertFalse(loaded.premium.grantsPremium(at: now))
        XCTAssertTrue(loaded.discard)
        XCTAssertNil(loaded.lapse)
    }

    func testPremiumEndsTheMomentTheActivationRunsOut() {
        let premium = load(activation: activation(2)).premium
        XCTAssertTrue(premium.grantsPremium(at: now.addingTimeInterval(2 * day - 1)))
        XCTAssertFalse(premium.grantsPremium(at: now.addingTimeInterval(2 * day)))
        XCTAssertEqual(premium.status(at: now.addingTimeInterval(2 * day)), DirectPremiumStatus.none)
    }

    func testTheNextLookIsWhenTheActivationRunsOut() {
        let premium = load(activation: activation(200)).premium
        XCTAssertEqual(premium.nextExpiry(after: now), now.addingTimeInterval(200 * day))
        XCTAssertNil(premium.nextExpiry(after: now.addingTimeInterval(200 * day)))
        XCTAssertNil(DirectPremium().nextExpiry(after: now))
    }

    func testExpiringRemovesAnActivationThatRanOutAndSaysItsDate() {
        var premium = load(activation: activation(100)).premium
        XCTAssertNil(premium.expire(now: now.addingTimeInterval(99 * day)), "still good: nothing is removed")
        XCTAssertNotNil(premium.activation)
        XCTAssertEqual(premium.expire(now: now.addingTimeInterval(100 * day)), .activationRanOut(now.addingTimeInterval(100 * day)))
        XCTAssertNil(premium.activation)
        XCTAssertNil(premium.expire(now: now.addingTimeInterval(101 * day)), "nothing left to remove")
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

/// What the extension may ask about Premium: only that the app open its Premium window. It hands over no proof.
/// docs/BROWSER_EXTENSION.md, "`upgrade`".
final class BridgeUpgradeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func answer(_ json: String, locked: Bool = false) -> [String: Any] {
        var state = BridgeState()
        let request = try! JSONDecoder().decode(BridgeRequest.self, from: Data(json.utf8))
        let response = state.handle(request, from: .chrome, locked: locked, now: now) { _ in nil }
        return try! JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as! [String: Any]
    }

    func testUpgradeIsAcknowledgedAndSaysNothingAboutThisMac() {
        for locked in [false, true] {
            let acknowledged = answer(#"{"type":"upgrade","id":9}"#, locked: locked)
            XCTAssertEqual(acknowledged["type"] as? String, "upgrade")
            XCTAssertEqual(acknowledged["id"] as? Int, 9)
            XCTAssertEqual(Set(acknowledged.keys), ["type", "id"], "no word about Premium, the vault or the lock")
        }
    }

    /// An extension from before 2026-11-11 still sends its pass. The app does not know the message any more, in either
    /// channel, so nothing an extension sends can turn Premium on.
    func testAPassFromAnOlderExtensionIsNotAMessageTheAppKnows() {
        for json in [#"{"type":"premium","id":4,"pass":"jwt-1"}"#, #"{"type":"premium","id":5,"drop":"signed-out"}"#] {
            let refused = answer(json)
            XCTAssertEqual(refused["type"] as? String, "error")
            XCTAssertEqual(refused["code"] as? String, "bad-request")
        }
    }
}
