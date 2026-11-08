#if PP_DIRECT
import CryptoKit
import Foundation
import XCTest
@testable import PasswordPieCore

/// Signs passes the way passwordpie.com does, with a key made for each test.
struct PassSigner {
    let key = Curve25519.Signing.PrivateKey()
    var publicKey: Data { key.publicKey.rawRepresentation }

    func pass(plan: String = "lifetime", expires: Date, premium: Bool = true) -> String {
        let header: [String: Any] = ["alg": "EdDSA", "typ": "JWT", "kid": "pp-1"]
        let claims: [String: Any] = [
            "iss": "https://passwordpie.com", "aud": "passwordpie-app", "sub": "user-1", "premium": premium,
            "plan": plan, "iat": 1_700_000_000, "exp": Int(expires.timeIntervalSince1970),
        ]
        let head = try! JSONSerialization.data(withJSONObject: header, options: .sortedKeys).base64URLText
        let body = try! JSONSerialization.data(withJSONObject: claims, options: .sortedKeys).base64URLText
        let signature = try! key.signature(for: Data("\(head).\(body)".utf8))
        return "\(head).\(body).\(signature.base64URLText)"
    }

    func verifier() -> (String, Date) -> Entitlement? {
        let key = publicKey
        return { EntitlementToken.verify($0, now: $1, publicKey: key) }
    }
}

extension Data {
    var base64URLText: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

final class AccountReplyTests: XCTestCase {
    private func json(_ text: String) -> Data { Data(text.utf8) }

    func testAnEntitlementAnswerReadsEveryField() {
        let reply = AccountReply.parse(status: 200, body: json(#"{"premium":true,"plan":"yearly","expiresAt":"2027-11-08T00:00:00.000Z","token":"a.b.c"}"#))
        XCTAssertEqual(reply, .ok(AccountEntitlementResponse(
            premium: true, plan: "yearly", expiresAt: Date(timeIntervalSince1970: 1_825_632_000), token: "a.b.c"
        )))
    }

    func testDatesWithoutFractionsAndNullsAreRead() {
        let reply = AccountReply.parse(status: 200, body: json(#"{"premium":false,"plan":null,"expiresAt":null,"token":null}"#))
        XCTAssertEqual(reply, .ok(AccountEntitlementResponse(premium: false, plan: nil, expiresAt: nil, token: nil)))
        let plain = AccountReply.parse(status: 200, body: json(#"{"premium":true,"plan":"key","expiresAt":"2027-11-08T00:00:00Z","token":"t"}"#))
        guard case .ok(let response) = plain else { return XCTFail("\(plain)") }
        XCTAssertEqual(response.expiresAt, Date(timeIntervalSince1970: 1_825_632_000))
    }

    func test401IsSignedOutWhateverTheBody() {
        XCTAssertEqual(AccountReply.parse(status: 401, body: Data()), .unauthorized)
        XCTAssertEqual(AccountReply.parse(status: 401, body: json(#"{"error":"x"}"#)), .unauthorized)
    }

    func testAnErrorBodyIsRead() {
        XCTAssertEqual(
            AccountReply.parse(status: 409, body: json(#"{"error":"some-error"}"#)),
            .rejected(status: 409, error: "some-error")
        )
        XCTAssertEqual(
            AccountReply.parse(status: 500, body: json("<html>oops</html>")),
            .rejected(status: 500, error: nil)
        )
    }

    func testA200ThatIsNotAnEntitlementIsRejectedNotPremium() {
        XCTAssertEqual(AccountReply.parse(status: 200, body: json("[]")), .rejected(status: 200, error: nil))
        XCTAssertEqual(AccountReply.parse(status: 200, body: json(#"{"plan":"lifetime"}"#)), .rejected(status: 200, error: nil))
    }

    func testTheSessionEmailIsRead() {
        XCTAssertEqual(AccountSessionInfo.email(from: json(#"{"session":{"id":"s"},"user":{"id":"u","email":"ada@example.com"}}"#)), .some("ada@example.com"))
        XCTAssertEqual(AccountSessionInfo.email(from: json("null")), .none)
        XCTAssertEqual(AccountSessionInfo.email(from: json(#"{"user":{"id":"u"}}"#)), .some(nil))
    }
}

final class AccountPremiumDecisionTests: XCTestCase {
    private let signer = PassSigner()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var week: Date { now.addingTimeInterval(7 * 86400) }

    private func decide(signedIn: Bool = true, cached: String? = nil, reply: AccountReply?) -> AccountPremiumDecision {
        AccountPremiumDecision.evaluate(signedIn: signedIn, cachedPass: cached, reply: reply, now: now, verify: signer.verifier())
    }

    func testSignedOutIsNeverPremiumEvenWithAPassLeftOver() {
        let decision = decide(signedIn: false, cached: signer.pass(expires: week), reply: nil)
        XCTAssertEqual(decision.state, .signedOut)
        XCTAssertNil(decision.pass)
        XCTAssertFalse(decision.state.grantsPremium(at: now))
    }

    func testASignedPassFromTheSiteIsPremium() {
        let pass = signer.pass(plan: "yearly", expires: week)
        let expires = now.addingTimeInterval(200 * 86400)
        let decision = decide(reply: .ok(AccountEntitlementResponse(premium: true, plan: "yearly", expiresAt: expires, token: pass)))
        XCTAssertEqual(decision.state, .premium(Entitlement(subject: "user-1", plan: "yearly", expiresAt: week), accountExpiresAt: expires))
        XCTAssertEqual(decision.pass, pass)
        XCTAssertTrue(decision.state.grantsPremium(at: now))
        XCTAssertFalse(decision.state.grantsPremium(at: week), "the pass ends at its own exp")
    }

    func testTheSiteSayingPremiumWithoutAGoodPassIsNotPremium() {
        let other = PassSigner().pass(expires: week)
        for token in [nil, "junk", other, signer.pass(expires: now.addingTimeInterval(-1))] {
            let decision = decide(reply: .ok(AccountEntitlementResponse(premium: true, plan: "lifetime", expiresAt: nil, token: token)))
            XCTAssertEqual(decision.state, .unverified, "token \(String(describing: token))")
            XCTAssertNil(decision.pass)
            XCTAssertFalse(decision.state.grantsPremium(at: now))
        }
    }

    func testTheSiteSayingFreeDropsTheCachedPass() {
        let decision = decide(cached: signer.pass(expires: week), reply: .ok(AccountEntitlementResponse(premium: false, plan: nil, expiresAt: nil, token: nil)))
        XCTAssertEqual(decision.state, .free)
        XCTAssertNil(decision.pass)
    }

    func testOfflineKeepsAGoodCachedPass() {
        let pass = signer.pass(expires: week)
        for reply in [AccountReply.unreachable, .rejected(status: 503, error: nil), nil] {
            let decision = decide(cached: pass, reply: reply)
            XCTAssertEqual(decision.state, .premium(Entitlement(subject: "user-1", plan: "lifetime", expiresAt: week), accountExpiresAt: nil))
            XCTAssertEqual(decision.pass, pass)
        }
    }

    func testOfflineWithAPassThatRanOutLocksAndSaysWhy() {
        let decision = decide(cached: signer.pass(expires: now.addingTimeInterval(-60)), reply: .unreachable)
        XCTAssertEqual(decision.state, .unreachable(passExpired: true))
        XCTAssertNil(decision.pass)
        XCTAssertFalse(decision.state.grantsPremium(at: now))
    }

    func testAForgedCachedPassCountsForNothing() {
        let decision = decide(cached: PassSigner().pass(expires: week), reply: .unreachable)
        XCTAssertEqual(decision.state, .unreachable(passExpired: false))
        XCTAssertNil(decision.pass)
    }

    func testOfflineWithNoPassAtAll() {
        XCTAssertEqual(decide(reply: .unreachable).state, .unreachable(passExpired: false))
        XCTAssertEqual(decide(reply: nil).state, .checking, "no answer yet, nothing cached")
    }

    func test401SignsOutAndForgetsThePass() {
        let decision = decide(cached: signer.pass(expires: week), reply: .unauthorized)
        XCTAssertEqual(decision.state, .signedOut)
        XCTAssertNil(decision.pass)
        XCTAssertTrue(decision.sessionEnded)
    }

    func testThePassEndsAtTheEarlierOfItsOwnExpiry() {
        let state = AccountPremium.premium(Entitlement(subject: nil, plan: "lifetime", expiresAt: week), accountExpiresAt: nil)
        XCTAssertEqual(state.passExpires, week)
        XCTAssertNil(AccountPremium.free.passExpires)
    }
}

final class AccountSignInTests: XCTestCase {
    private let base = URL(string: "https://passwordpie.com")!

    func testTheSignInPageCarriesStateAndProvider() {
        let url = AccountSite(base: base).signInURL(state: "abc", provider: .apple)
        XCTAssertEqual(url.absoluteString, "https://passwordpie.com/app/sign-in?state=abc&provider=apple&callback=passwordpie://auth")
        XCTAssertEqual(AccountSite(base: base).signInURL(state: "abc", provider: nil).absoluteString, "https://passwordpie.com/app/sign-in?state=abc&callback=passwordpie://auth")
    }

    func testEndpoints() {
        let site = AccountSite(base: URL(string: "http://localhost:8787")!)
        XCTAssertEqual(site.entitlementURL.absoluteString, "http://localhost:8787/api/premium/entitlement")
        XCTAssertEqual(site.exchangeURL.absoluteString, "http://localhost:8787/api/auth/app/exchange")
        XCTAssertEqual(site.sessionURL.absoluteString, "http://localhost:8787/api/auth/get-session")
        XCTAssertEqual(site.signOutURL.absoluteString, "http://localhost:8787/api/auth/sign-out")
    }

    func testACallbackWithACodeOrAToken() {
        XCTAssertEqual(AccountSignInCallback(url: URL(string: "passwordpie://auth?code=xyz&state=abc")!, expectedState: "abc"), .code("xyz"))
        XCTAssertEqual(AccountSignInCallback(url: URL(string: "passwordpie://auth?token=tok.sig&state=abc")!, expectedState: "abc"), .token("tok.sig"))
    }

    func testACallbackForAnotherSignInIsRefused() {
        XCTAssertEqual(AccountSignInCallback(url: URL(string: "passwordpie://auth?code=xyz&state=evil")!, expectedState: "abc"), .invalid)
        XCTAssertEqual(AccountSignInCallback(url: URL(string: "passwordpie://auth?code=xyz")!, expectedState: "abc"), .invalid)
        XCTAssertEqual(AccountSignInCallback(url: URL(string: "https://auth?code=xyz&state=abc")!, expectedState: "abc"), .invalid)
        XCTAssertEqual(AccountSignInCallback(url: URL(string: "passwordpie://other?code=xyz&state=abc")!, expectedState: "abc"), .invalid)
        XCTAssertEqual(AccountSignInCallback(url: URL(string: "passwordpie://auth?state=abc")!, expectedState: "abc"), .invalid)
    }

    func testACallbackWithAnError() {
        XCTAssertEqual(AccountSignInCallback(url: URL(string: "passwordpie://auth?error=access_denied&state=abc")!, expectedState: "abc"), .failed("access_denied"))
    }

    func testStatesAreRandomAndURLSafe() {
        let one = AccountSite.newState()
        XCTAssertNotEqual(one, AccountSite.newState())
        XCTAssertGreaterThanOrEqual(one.count, 32)
        XCTAssertNotNil(Data(base64URL: one))
    }
}

final class AccountPremiumSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let dateText: (Date) -> String = { _ in "Nov 8, 2027" }

    private func premium(_ plan: String?, until: Date? = nil) -> AccountPremium {
        .premium(Entitlement(subject: nil, plan: plan, expiresAt: now.addingTimeInterval(86400)), accountExpiresAt: until)
    }

    func testEachStateHasWords() {
        XCTAssertEqual(premium("lifetime").summary(at: now, dateText: dateText).title, "Premium: Lifetime")
        XCTAssertEqual(premium("yearly", until: now).summary(at: now, dateText: dateText), AccountPremiumSummary(title: "Premium: Yearly", detail: "Paid through Nov 8, 2027."))
        XCTAssertEqual(premium("key", until: now).summary(at: now, dateText: dateText), AccountPremiumSummary(title: "Premium", detail: "From a key, through Nov 8, 2027."))
        XCTAssertEqual(premium("key").summary(at: now, dateText: dateText), AccountPremiumSummary(title: "Premium", detail: "From a key."))
        XCTAssertEqual(premium(nil).summary(at: now, dateText: dateText).title, "Premium")
        XCTAssertEqual(AccountPremium.free.summary(at: now, dateText: dateText).title, "Free")
        XCTAssertEqual(AccountPremium.signedOut.summary(at: now, dateText: dateText).title, "Not signed in")
        XCTAssertEqual(AccountPremium.checking.summary(at: now, dateText: dateText).title, "Checking…")
        XCTAssertTrue(AccountPremium.unreachable(passExpired: true).summary(at: now, dateText: dateText).detail.contains("to renew Premium"))
        XCTAssertTrue(AccountPremium.unreachable(passExpired: false).summary(at: now, dateText: dateText).detail.contains("could not reach passwordpie.com"))
        XCTAssertTrue(AccountPremium.unverified.summary(at: now, dateText: dateText).detail.contains("could not be checked"))
    }

    func testAPassThatRanOutWhileRunningSaysItIsRenewing() {
        let summary = premium("lifetime").summary(at: now.addingTimeInterval(2 * 86400), dateText: dateText)
        XCTAssertEqual(summary.title, "Renewing…")
    }
}
#endif
