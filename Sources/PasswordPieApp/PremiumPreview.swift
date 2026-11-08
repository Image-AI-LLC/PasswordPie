#if DEBUG && !PP_DIRECT
import Foundation
import PasswordPieCore

/// Debug builds only: draws any Premium state with made-up prices, without a store. The real prices come from Apple.
/// `PASSWORDPIE_PREMIUM_PREVIEW` is one of the raw values below. Release builds do not compile this file's contents.
@MainActor
final class PremiumPreviewBackend: PremiumBackend {
    enum Scenario: String {
        /// Free. Buying succeeds at once, so the unlock can be watched.
        case free
        case lifetime
        case yearly
        case both
        case loadFailed = "load-failed"
        case slowLoad = "slow-load"
        case pending
        case cancelled
        case failed
        case nothingToRestore = "nothing-to-restore"
    }

    private let scenario: Scenario
    private var transactions: [PremiumTransaction]
    private var continuation: AsyncStream<Void>.Continuation?

    static func fromEnvironment() -> PremiumPreviewBackend? {
        ProcessInfo.processInfo.environment["PASSWORDPIE_PREMIUM_PREVIEW"].flatMap(Scenario.init(rawValue:)).map(PremiumPreviewBackend.init)
    }

    init(_ scenario: Scenario) {
        self.scenario = scenario
        let year = Date().addingTimeInterval(200 * 24 * 3600)
        let lifetime = Self.transaction(.lifetime, expires: nil)
        let yearly = Self.transaction(.yearly, expires: year)
        switch scenario {
        case .lifetime: transactions = [lifetime]
        case .yearly: transactions = [yearly]
        case .both: transactions = [lifetime, yearly]
        default: transactions = []
        }
    }

    /// Shaped like a StoreKit 2 JWS, unsigned, so the mock site (`Scripts/mock-account-site.mjs`) can read it. A real site
    /// refuses it: it checks Apple's signature.
    private static func transaction(_ plan: PremiumPlan, expires: Date?) -> PremiumTransaction {
        let payload = try! JSONSerialization.data(withJSONObject: ["productId": plan.productID, "originalTransactionId": "preview-\(plan.rawValue)"])
        let body = payload.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return PremiumTransaction(
            productID: plan.productID, verified: true, revocationDate: nil, expirationDate: expires,
            signedTransaction: "eyJhbGciOiJub25lIn0.\(body).preview"
        )
    }

    func currentTransactions() async -> [PremiumTransaction] { transactions }

    func transactionUpdates() -> AsyncStream<Void> {
        AsyncStream { continuation = $0 }
    }

    func loadProducts() async throws -> [PremiumProduct] {
        struct Unreachable: Error {}
        if scenario == .loadFailed { throw Unreachable() }
        if scenario == .slowLoad { try await Task.sleep(nanoseconds: 600_000_000_000) }
        return [
            PremiumProduct(plan: .lifetime, displayName: "Premium Lifetime", displayPrice: "$29.00", period: nil),
            PremiumProduct(plan: .yearly, displayName: "Premium Yearly", displayPrice: "$10.00", period: PremiumPeriod(value: 1, unit: .year)),
        ]
    }

    func purchase(_ plan: PremiumPlan) async throws -> PremiumPurchaseOutcome {
        struct Declined: LocalizedError {
            var errorDescription: String? { "The App Store could not complete this purchase. (Preview)" }
        }
        switch scenario {
        case .pending: return .pending
        case .cancelled: return .cancelled
        case .failed: throw Declined()
        default:
            let expires = plan == .yearly ? Date().addingTimeInterval(365 * 24 * 3600) : nil
            let transaction = Self.transaction(plan, expires: expires)
            transactions.append(transaction)
            return .success(signedTransaction: transaction.signedTransaction)
        }
    }

    func restore() async throws -> PremiumRestoreOutcome { .finished }
}
#endif
