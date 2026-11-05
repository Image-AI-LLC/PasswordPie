import Foundation
import PasswordPieCore
@testable import PasswordPie

/// The store, scripted. Nothing here touches StoreKit.
@MainActor
final class FakePremiumBackend: PremiumBackend {
    struct Failure: LocalizedError {
        var errorDescription: String? { "The App Store said no." }
    }

    var transactions: [PremiumTransaction] = []
    /// After this many more answers, `currentTransactions` starts returning these. A store that lags behind a purchase.
    var transactionsAfterRefreshes: (count: Int, transactions: [PremiumTransaction])?
    var products: Result<[PremiumProduct], Failure> = .success([FakePremiumBackend.lifetime, FakePremiumBackend.yearly])
    var purchaseOutcome: Result<PremiumPurchaseOutcome, Failure> = .success(.success)
    var restoreOutcome: Result<PremiumRestoreOutcome, Failure> = .success(.finished)
    /// Runs inside `purchase`, as the store records the transaction before it returns.
    var onPurchase: ((PremiumPlan) -> Void)?
    var onRestore: (() -> Void)?
    /// Holds `currentTransactions` open, as a store that has not answered yet.
    var answerGate: CheckedContinuation<Void, Never>?
    var holdsAnswers = false
    /// Holds `purchase` open, as the App Store's own sheet does while the user decides.
    var purchaseGate: CheckedContinuation<Void, Never>?
    var holdsPurchases = false
    private(set) var purchases: [PremiumPlan] = []
    private(set) var restores = 0
    private(set) var productLoads = 0
    private var continuation: AsyncStream<Void>.Continuation?

    static let lifetime = PremiumProduct(plan: .lifetime, displayName: "Premium Lifetime", displayPrice: "€33,99", period: nil)
    static let yearly = PremiumProduct(plan: .yearly, displayName: "Premium Yearly", displayPrice: "€11,99", period: PremiumPeriod(value: 1, unit: .year))

    func currentTransactions() async -> [PremiumTransaction] {
        if holdsAnswers {
            await withCheckedContinuation { answerGate = $0 }
        }
        if let lag = transactionsAfterRefreshes {
            if lag.count <= 0 {
                transactions = lag.transactions
                transactionsAfterRefreshes = nil
            } else {
                transactionsAfterRefreshes = (lag.count - 1, lag.transactions)
            }
        }
        return transactions
    }

    func transactionUpdates() -> AsyncStream<Void> {
        AsyncStream { continuation = $0 }
    }

    func loadProducts() async throws -> [PremiumProduct] {
        productLoads += 1
        return try products.get()
    }

    func purchase(_ plan: PremiumPlan) async throws -> PremiumPurchaseOutcome {
        purchases.append(plan)
        if holdsPurchases {
            await withCheckedContinuation { purchaseGate = $0 }
        }
        onPurchase?(plan)
        return try purchaseOutcome.get()
    }

    func restore() async throws -> PremiumRestoreOutcome {
        restores += 1
        onRestore?()
        return try restoreOutcome.get()
    }

    func emitUpdate() {
        continuation?.yield(())
    }

    func answer() {
        answerGate?.resume()
        answerGate = nil
        holdsAnswers = false
    }
}

/// Records what reaches the clipboard, so tests never touch the real one.
final class FakePasteboard: PasteboardLike {
    private(set) var changeCount = 0
    private(set) var writes: [String] = []

    func write(_ string: String) -> Int {
        writes.append(string)
        changeCount += 1
        return changeCount
    }

    func clear() {
        changeCount += 1
    }
}

enum PremiumFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let lifetime = PremiumTransaction(productID: PremiumPlan.lifetime.productID, verified: true, revocationDate: nil, expirationDate: nil)

    static func yearly(expires: Date) -> PremiumTransaction {
        PremiumTransaction(productID: PremiumPlan.yearly.productID, verified: true, revocationDate: nil, expirationDate: expires)
    }

    static func login(_ title: String = "Bank", code: Bool = true) -> VaultEntry {
        var entry = VaultEntry()
        entry.title = title
        entry.username = "ada"
        entry.password = "secret"
        entry.url = "https://bank.example/login"
        if code { entry.otp = "otpauth://totp/Bank:ada?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Bank" }
        return entry
    }
}

@MainActor
func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { return false }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return true
}
