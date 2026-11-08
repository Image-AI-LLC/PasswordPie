import CryptoKit
import Foundation
import XCTest
@testable import PasswordPieCore

/// The entitlement token from passwordpie.com, as the app checks it before a two-step code goes to the browser.
/// See docs/ACCOUNTS.md, "The entitlement token".
final class EntitlementTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()
    private let now = Date(timeIntervalSince1970: 1_762_560_000)

    private func check(_ token: String, key: Data? = nil) -> Result<Entitlement, EntitlementError> {
        EntitlementToken.check(token, now: now, publicKey: key ?? self.key.publicKey.rawRepresentation)
    }

    private func claims(_ changes: [String: Any] = [:], removing: [String] = []) -> [String: Any] {
        var claims: [String: Any] = [
            "iss": "https://passwordpie.com",
            "aud": "passwordpie-app",
            "sub": "user-1",
            "premium": true,
            "plan": "lifetime",
            "iat": Int(now.timeIntervalSince1970) - 60,
            "exp": Int(now.timeIntervalSince1970) + 7 * 86400,
        ]
        for (name, value) in changes { claims[name] = value }
        for name in removing { claims[name] = nil }
        return claims
    }

    private func token(
        header: [String: Any] = ["alg": "EdDSA", "typ": "JWT", "kid": "pp-1"],
        claims: [String: Any]? = nil,
        signer: Curve25519.Signing.PrivateKey? = nil
    ) throws -> String {
        let head = try JSONSerialization.data(withJSONObject: header, options: .sortedKeys).base64URL
        let body = try JSONSerialization.data(withJSONObject: claims ?? self.claims(), options: .sortedKeys).base64URL
        let signature = try (signer ?? key).signature(for: Data("\(head).\(body)".utf8))
        return "\(head).\(body).\(signature.base64URL)"
    }

    // MARK: Accepted

    func testAGoodTokenGivesItsClaims() throws {
        let result = check(try token())
        XCTAssertEqual(try result.get(), Entitlement(
            subject: "user-1",
            plan: "lifetime",
            expiresAt: Date(timeIntervalSince1970: now.timeIntervalSince1970 + 7 * 86400)
        ))
    }

    func testTheAudienceMayBeAnArrayThatHoldsTheApp() throws {
        let result = check(try token(claims: claims(["aud": ["something-else", "passwordpie-app"]])))
        XCTAssertNoThrow(try result.get())
    }

    func testATokenFromAMinuteAheadOfThisClockStillCounts() throws {
        let result = check(try token(claims: claims(["iat": Int(now.timeIntervalSince1970) + 60])))
        XCTAssertNoThrow(try result.get())
    }

    func testThePublicAPIGivesTheClaimsOrNil() throws {
        let good = try token()
        XCTAssertEqual(EntitlementToken.verify(good, now: now, publicKey: key.publicKey.rawRepresentation)?.plan, "lifetime")
        XCTAssertNil(EntitlementToken.verify(good, now: now.addingTimeInterval(8 * 86400), publicKey: key.publicKey.rawRepresentation))
        XCTAssertNil(EntitlementToken.verify(good, now: now), "not signed with the site's key")
    }

    // MARK: Signature

    func testASignatureFromAnotherKeyFails() throws {
        let result = check(try token(signer: Curve25519.Signing.PrivateKey()))
        XCTAssertEqual(result.failure, .badSignature)
    }

    func testChangedClaimsFailTheSignature() throws {
        let good = try token(claims: claims(["plan": "yearly"]))
        let parts = good.split(separator: ".").map(String.init)
        let forged = try JSONSerialization.data(withJSONObject: claims(["plan": "lifetime", "sub": "someone-else"]), options: .sortedKeys).base64URL
        XCTAssertEqual(check("\(parts[0]).\(forged).\(parts[2])").failure, .badSignature)
    }

    func testAChangedHeaderFailsTheSignature() throws {
        let good = try token()
        let parts = good.split(separator: ".").map(String.init)
        let header = try JSONSerialization.data(withJSONObject: ["alg": "EdDSA", "kid": "pp-1"], options: .sortedKeys).base64URL
        XCTAssertEqual(check("\(header).\(parts[1]).\(parts[2])").failure, .badSignature)
    }

    func testAFlippedSignatureBitFails() throws {
        let parts = try token().split(separator: ".").map(String.init)
        var signature = try XCTUnwrap(Data(base64URL: parts[2]))
        signature[5] ^= 0x01
        XCTAssertEqual(check("\(parts[0]).\(parts[1]).\(signature.base64URL)").failure, .badSignature)
    }

    func testAnUnsignedTokenFails() throws {
        let parts = try token(header: ["alg": "none", "typ": "JWT", "kid": "pp-1"]).split(separator: ".").map(String.init)
        XCTAssertEqual(check("\(parts[0]).\(parts[1]).").failure, .unsupportedAlgorithm)
    }

    func testAnotherAlgorithmFails() throws {
        XCTAssertEqual(check(try token(header: ["alg": "HS256", "typ": "JWT", "kid": "pp-1"])).failure, .unsupportedAlgorithm)
    }

    func testNoKeyTrustsNothing() throws {
        XCTAssertEqual(check(try token(), key: Data()).failure, .badKey)
        XCTAssertEqual(check(try token(), key: Data(repeating: 1, count: 31)).failure, .badKey)
    }

    // MARK: Claims

    func testAnExpiredTokenFails() throws {
        let expired = try token(claims: claims(["exp": Int(now.timeIntervalSince1970) - 1]))
        XCTAssertEqual(check(expired).failure, .expired)
        let atTheSecond = try token(claims: claims(["exp": Int(now.timeIntervalSince1970)]))
        XCTAssertEqual(check(atTheSecond).failure, .expired)
    }

    func testATokenWithNoExpiryFails() throws {
        XCTAssertEqual(check(try token(claims: claims(removing: ["exp"]))).failure, .malformed)
    }

    func testTheWrongAudienceFails() throws {
        XCTAssertEqual(check(try token(claims: claims(["aud": "passwordpie-web"]))).failure, .wrongAudience)
        XCTAssertEqual(check(try token(claims: claims(["aud": ["passwordpie-web"]]))).failure, .wrongAudience)
        XCTAssertEqual(check(try token(claims: claims(removing: ["aud"]))).failure, .wrongAudience)
    }

    func testTheWrongIssuerFails() throws {
        XCTAssertEqual(check(try token(claims: claims(["iss": "https://passwordpie.com.evil"]))).failure, .wrongIssuer)
        XCTAssertEqual(check(try token(claims: claims(removing: ["iss"]))).failure, .wrongIssuer)
    }

    func testATokenIssuedLaterThanFiveMinutesFromNowFails() throws {
        let future = try token(claims: claims(["iat": Int(now.timeIntervalSince1970) + 301]))
        XCTAssertEqual(check(future).failure, .notYetValid)
        let notBefore = try token(claims: claims(["nbf": Int(now.timeIntervalSince1970) + 301]))
        XCTAssertEqual(check(notBefore).failure, .notYetValid)
    }

    func testATokenThatDoesNotSayPremiumFails() throws {
        XCTAssertEqual(check(try token(claims: claims(["premium": false]))).failure, .notPremium)
        XCTAssertEqual(check(try token(claims: claims(["premium": "true"]))).failure, .notPremium)
        XCTAssertEqual(check(try token(claims: claims(removing: ["premium"]))).failure, .notPremium)
    }

    // MARK: Shape

    func testGarbageFails() {
        for text in ["", "a", "a.b", "a.b.c.d", "...", "!!.@@.##", String(repeating: "a", count: 5000)] {
            XCTAssertEqual(check(text).failure, .malformed, text)
        }
    }

    func testPaddedBase64IsNotBase64URL() throws {
        let parts = try token().split(separator: ".").map(String.init)
        XCTAssertEqual(check("\(parts[0])=.\(parts[1]).\(parts[2])").failure, .malformed)
    }

    func testClaimsThatAreNotAnObjectFail() throws {
        let head = try JSONSerialization.data(withJSONObject: ["alg": "EdDSA", "kid": "pp-1"]).base64URL
        let body = Data("[1,2]".utf8).base64URL
        let signature = try key.signature(for: Data("\(head).\(body)".utf8)).base64URL
        XCTAssertEqual(check("\(head).\(body).\(signature)").failure, .malformed)
    }

    // MARK: Built-in keys

    func testTheBuiltInKeysAre32Bytes() {
        for key in EntitlementToken.trustedKeys { XCTAssertEqual(key.count, 32) }
        XCTAssertTrue(EntitlementToken.publicKey.isEmpty || EntitlementToken.publicKey.count == 32)
        XCTAssertNotEqual(EntitlementToken.publicKey, EntitlementToken.testPublicKey)
    }

    /// The production key the site handed over (passwordpie.com#8): every build trusts it.
    func testEveryBuildTrustsTheSitesProductionKey() {
        XCTAssertEqual(EntitlementToken.publicKey, Data(base64URL: "h2YWSwg8b--b6tXhehQ6Ccav0CdLqFR0HLeWj9F6dM0"))
        XCTAssertEqual(EntitlementToken.publicKey.count, 32)
        XCTAssertTrue(EntitlementToken.trustedKeys.contains(EntitlementToken.publicKey))
    }

    func testTheTestKeyIsTrustedOnlyInDevelopmentBuilds() {
        #if DEBUG || PP_DEV_EXTENSION
        XCTAssertTrue(EntitlementToken.trustedKeys.contains(EntitlementToken.testPublicKey))
        #else
        XCTAssertFalse(EntitlementToken.trustedKeys.contains(EntitlementToken.testPublicKey))
        #endif
    }

    /// passwordpie.com's own published vector (RFC 8032 TEST 1 key pair, docs/premium-api.md in the site's repo): the
    /// site signs, the app verifies, byte for byte.
    func testTheSitesPublishedVectorVerifies() throws {
        let key = try XCTUnwrap(Data(base64URL: "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"))
        let token = "eyJhbGciOiJFZERTQSIsInR5cCI6IkpXVCIsImtpZCI6InBwLTEifQ."
            + "eyJpc3MiOiJodHRwczovL3Bhc3N3b3JkcGllLmNvbSIsImF1ZCI6InBhc3N3b3JkcGllLWFwcCIsInN1YiI6InVzZXItdGVzdC12ZWN0b3IiLCJwcmVtaXVtIjp0cnVlLCJwbGFuIjoibGlmZXRpbWUiLCJpYXQiOjE3OTM4MzY4MDAsImV4cCI6MTc5NDQ0MTYwMH0."
            + "U6C9pA9QVxN6wKKvfxMZPTtFJHYv7izRQXo9KYUfabNv7pW88cwe8B4QHHdxvIxDSKtK8nYNPTBgbmIvkFDECw"
        let inside = Date(timeIntervalSince1970: 1_793_923_200) // 2026-11-06
        XCTAssertEqual(EntitlementToken.verify(token, now: inside, publicKey: key),
                       Entitlement(subject: "user-test-vector", plan: "lifetime", expiresAt: Date(timeIntervalSince1970: 1_794_441_600)))
        XCTAssertNil(EntitlementToken.verify(token, now: Date(timeIntervalSince1970: 1_794_441_600), publicKey: key))
        XCTAssertNil(EntitlementToken.verify(token, now: inside, publicKey: EntitlementToken.testPublicKey))
    }

    /// The private half is in extension/dev/test-key.json for the mock site. Its sample token was made with it.
    func testTheMockSitesTokensCheckWithTheTestKey() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("extension/dev/test-key.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: String])
        XCTAssertEqual(json["x"].flatMap { Data(base64URL: $0) }, EntitlementToken.testPublicKey)
        let sample = try XCTUnwrap(json["sampleToken"])
        // Good until 2100.
        XCTAssertNoThrow(try check(sample, key: EntitlementToken.testPublicKey).get())
        #if DEBUG || PP_DEV_EXTENSION
        XCTAssertNotNil(EntitlementToken.verifyTrusted(sample, now: now))
        #endif
        XCTAssertNil(EntitlementToken.verifyTrusted(nil, now: now))
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
