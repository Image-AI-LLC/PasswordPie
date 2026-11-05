import XCTest
@testable import PasswordPieCore

final class PremiumEntitlementTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var later: Date { now.addingTimeInterval(3600) }
    private var earlier: Date { now.addingTimeInterval(-3600) }

    private func lifetime(verified: Bool = true, revoked: Date? = nil) -> PremiumTransaction {
        PremiumTransaction(productID: PremiumPlan.lifetime.productID, verified: verified, revocationDate: revoked, expirationDate: nil)
    }

    private func yearly(verified: Bool = true, revoked: Date? = nil, expires: Date?) -> PremiumTransaction {
        PremiumTransaction(productID: PremiumPlan.yearly.productID, verified: verified, revocationDate: revoked, expirationDate: expires)
    }

    func testProductIDsAreTheOnesInAppStoreConnect() {
        XCTAssertEqual(PremiumPlan.lifetime.productID, "com.oldcai.passwordpie.premium.lifetime")
        XCTAssertEqual(PremiumPlan.yearly.productID, "com.oldcai.passwordpie.premium.yearly")
        XCTAssertEqual(PremiumPlan(productID: "com.oldcai.passwordpie.premium.yearly"), .yearly)
        XCTAssertNil(PremiumPlan(productID: "com.example.other"))
    }

    func testNoTransactionsIsFree() {
        let status = PremiumStatus(transactions: [], now: now)
        XCTAssertEqual(status, .free)
        XCTAssertFalse(status.grantsPremium(at: now))
    }

    func testLifetimeGrantsPremium() {
        let status = PremiumStatus(transactions: [lifetime()], now: now)
        XCTAssertEqual(status, .lifetime(subscriptionExpires: nil))
        XCTAssertTrue(status.grantsPremium(at: now))
        XCTAssertTrue(status.grantsPremium(at: .distantFuture))
    }

    func testActiveYearlyGrantsPremiumUntilItExpires() {
        let status = PremiumStatus(transactions: [yearly(expires: later)], now: now)
        XCTAssertEqual(status, .yearly(expires: later))
        XCTAssertTrue(status.grantsPremium(at: now))
        XCTAssertFalse(status.grantsPremium(at: later), "the moment it expires it no longer counts")
        XCTAssertFalse(status.grantsPremium(at: later.addingTimeInterval(1)))
    }

    func testExpiredYearlyIsFree() {
        XCTAssertEqual(PremiumStatus(transactions: [yearly(expires: earlier)], now: now), .free)
        XCTAssertEqual(PremiumStatus(transactions: [yearly(expires: now)], now: now), .free)
    }

    /// A subscription always has an end date. One without it is not something to trust.
    func testYearlyWithNoExpirationDateIsFree() {
        XCTAssertEqual(PremiumStatus(transactions: [yearly(expires: nil)], now: now), .free)
    }

    func testRevokedPurchasesAreFree() {
        XCTAssertEqual(PremiumStatus(transactions: [lifetime(revoked: earlier)], now: now), .free)
        XCTAssertEqual(PremiumStatus(transactions: [yearly(revoked: earlier, expires: later)], now: now), .free)
        XCTAssertEqual(PremiumStatus(transactions: [lifetime(revoked: later)], now: now), .free, "any revocation date revokes")
    }

    func testUnverifiedTransactionsNeverCount() {
        XCTAssertEqual(PremiumStatus(transactions: [lifetime(verified: false)], now: now), .free)
        XCTAssertEqual(PremiumStatus(transactions: [yearly(verified: false, expires: later)], now: now), .free)
    }

    func testAnotherProductDoesNotCount() {
        let other = PremiumTransaction(productID: "com.example.other", verified: true, revocationDate: nil, expirationDate: later)
        XCTAssertEqual(PremiumStatus(transactions: [other], now: now), .free)
    }

    func testLifetimeWinsAndRemembersASubscriptionThatIsStillRenewing() {
        let both = PremiumStatus(transactions: [yearly(expires: later), lifetime()], now: now)
        XCTAssertEqual(both, .lifetime(subscriptionExpires: later))
        XCTAssertTrue(both.grantsPremium(at: .distantFuture), "lifetime does not end with the subscription")
    }

    func testARevokedLifetimeFallsBackToAnActiveSubscription() {
        XCTAssertEqual(PremiumStatus(transactions: [lifetime(revoked: earlier), yearly(expires: later)], now: now), .yearly(expires: later))
    }

    func testCheckingIsNotPremium() {
        XCTAssertFalse(PremiumStatus.checking.grantsPremium(at: now))
    }

    func testOwnedPlans() {
        XCTAssertEqual(PremiumStatus.free.ownedPlans(at: now), [])
        XCTAssertEqual(PremiumStatus.checking.ownedPlans(at: now), [])
        XCTAssertEqual(PremiumStatus.yearly(expires: later).ownedPlans(at: now), [.yearly])
        XCTAssertEqual(PremiumStatus.yearly(expires: earlier).ownedPlans(at: now), [])
        XCTAssertEqual(PremiumStatus.lifetime(subscriptionExpires: nil).ownedPlans(at: now), [.lifetime])
        XCTAssertEqual(PremiumStatus.lifetime(subscriptionExpires: later).ownedPlans(at: now), [.lifetime, .yearly])
        XCTAssertEqual(PremiumStatus.lifetime(subscriptionExpires: earlier).ownedPlans(at: now), [.lifetime])
    }

    func testTheSubscriptionsEndDateIsWhenThereIsSomethingToRecheck() {
        XCTAssertEqual(PremiumStatus.yearly(expires: later).nextExpiration, later)
        XCTAssertEqual(PremiumStatus.lifetime(subscriptionExpires: later).nextExpiration, later)
        XCTAssertNil(PremiumStatus.lifetime(subscriptionExpires: nil).nextExpiration)
        XCTAssertNil(PremiumStatus.free.nextExpiration)
    }

    #if PP_DIRECT
    func testTheDirectChannelStatusGrantsPremiumForever() {
        XCTAssertTrue(PremiumStatus.directChannel.grantsPremium(at: .distantFuture))
        XCTAssertEqual(PremiumStatus.directChannel.ownedPlans(at: now), [])
    }
    #endif

    func testPeriodText() {
        XCTAssertEqual(PremiumPeriod(value: 1, unit: .year).text, "1 year")
        XCTAssertEqual(PremiumPeriod(value: 2, unit: .month).text, "2 months")
        XCTAssertEqual(PremiumPeriod(value: 1, unit: .year).renewalWord, "year")
        XCTAssertEqual(PremiumPeriod(value: 2, unit: .month).renewalWord, "2 months")
    }

    func testSubscriptionDisclosureSaysEverythingGuideline312Asks() throws {
        let yearly = PremiumProduct(plan: .yearly, displayName: "Premium Yearly", displayPrice: "€11,99", period: PremiumPeriod(value: 1, unit: .year))
        let text = try XCTUnwrap(yearly.renewalDisclosure)
        XCTAssertTrue(text.contains("Premium Yearly"), "title")
        XCTAssertTrue(text.contains("1 year"), "length")
        XCTAssertTrue(text.contains("€11,99"), "price, as Apple gave it")
        XCTAssertTrue(text.lowercased().contains("renews automatically"), "auto-renewal")
        XCTAssertTrue(text.contains("24 hours"), "how to avoid the next charge")
        XCTAssertTrue(text.contains("Apple Account"), "who charges")
        XCTAssertTrue(text.contains("each renewal is charged"), "when the next charge comes")
        XCTAssertEqual(PremiumLinks.termsOfService.absoluteString, "https://passwordpie.com/terms-of-service")
        XCTAssertEqual(PremiumLinks.privacyPolicy.absoluteString, "https://passwordpie.com/privacy-policy")
    }

    func testOneTimePurchaseHasNoRenewalDisclosure() {
        let lifetime = PremiumProduct(plan: .lifetime, displayName: "Premium Lifetime", displayPrice: "¥198", period: nil)
        XCTAssertNil(lifetime.renewalDisclosure)
    }

    func testPlanSummaryUsesAppleLengthNotAFixedYear() {
        let lifetime = PremiumProduct(plan: .lifetime, displayName: "L", displayPrice: "¥198", period: nil)
        let yearly = PremiumProduct(plan: .yearly, displayName: "Y", displayPrice: "¥68", period: PremiumPeriod(value: 1, unit: .year))
        XCTAssertEqual(lifetime.summary, "One payment. No subscription.")
        XCTAssertEqual(yearly.summary, "Renews every year until you cancel.")
        XCTAssertEqual(yearly.buttonTitle, "¥68 / year")
        XCTAssertEqual(lifetime.buttonTitle, "¥198")
    }

    // MARK: Gate

    private func entryWithCode() -> VaultEntry {
        var entry = VaultEntry()
        entry.title = "Bank"
        entry.otp = "otpauth://totp/Bank?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        return entry
    }

    func testWhetherAnItemHasACodeDoesNotDependOnPremium() {
        XCTAssertTrue(OneTimeCodes.hasCode(entryWithCode()))
        XCTAssertFalse(OneTimeCodes.hasCode(VaultEntry()))
    }

    func testAFreeUserGetsNoCodeAndNoSettings() {
        XCTAssertEqual(OneTimeCodes.access(for: entryWithCode(), hasPremium: false), .locked)
    }

    func testPremiumGetsTheCodeSettings() {
        let access = OneTimeCodes.access(for: entryWithCode(), hasPremium: true)
        guard case .available(let settings) = access else { return XCTFail("\(access)") }
        XCTAssertEqual(OneTimeCodes.code(settings: settings, at: now).count, 6)
    }

    func testAnItemWithoutACodeIsNeverLocked() {
        XCTAssertEqual(OneTimeCodes.access(for: VaultEntry(), hasPremium: false), .noCode)
        XCTAssertEqual(OneTimeCodes.access(for: VaultEntry(), hasPremium: true), .noCode)
    }

    /// Other KeePass apps store the secret under these names. Hiding only the `otp` field would leak a code.
    func testEveryWayOfStoringASecretIsLocked() {
        var keeOtp = VaultEntry()
        keeOtp.setValue("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", for: "TimeOtp-Secret-Base32", protected: true)
        var seed = VaultEntry()
        seed.setValue("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", for: "TOTP Seed", protected: true)
        for entry in [keeOtp, seed] {
            XCTAssertEqual(OneTimeCodes.access(for: entry, hasPremium: false), .locked)
        }
    }
}
