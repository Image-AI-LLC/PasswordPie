#if !PP_DIRECT
import AppKit
import PasswordPieCore
import StoreKit

/// The App Store channel's one link to Apple. The only file that imports StoreKit, so the direct binary does not link it.
/// It passes on what the store says. Nothing leaves this Mac except through StoreKit itself.
@MainActor
final class StoreKitPremiumBackend: PremiumBackend {
    private var products: [PremiumPlan: Product] = [:]

    func currentTransactions() async -> [PremiumTransaction] {
        var transactions: [PremiumTransaction] = []
        for await entitlement in Transaction.currentEntitlements {
            transactions.append(PremiumTransaction(entitlement))
        }
        return transactions
    }

    func transactionUpdates() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let listener = Task.detached {
                for await update in Transaction.updates {
                    // Only a verified transaction is finished. An unverified one is not ours to accept.
                    if case .verified(let transaction) = update {
                        await transaction.finish()
                    }
                    continuation.yield(())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in listener.cancel() }
        }
    }

    func loadProducts() async throws -> [PremiumProduct] {
        let loaded = try await Product.products(for: PremiumPlan.allCases.map(\.productID))
        var known: [PremiumPlan: Product] = [:]
        for product in loaded {
            if let plan = PremiumPlan(productID: product.id) { known[plan] = product }
        }
        products = known
        return known.map { plan, product in
            PremiumProduct(
                plan: plan,
                displayName: product.displayName,
                displayPrice: product.displayPrice,
                period: product.subscription.map { PremiumPeriod($0.subscriptionPeriod) }
            )
        }
    }

    func purchase(_ plan: PremiumPlan) async throws -> PremiumPurchaseOutcome {
        guard let product = products[plan] else { throw StoreKitError.notAvailableInStorefront }
        let result: Product.PurchaseResult
        if #available(macOS 15.2, *), let window = NSApp.keyWindow {
            result = try await product.purchase(confirmIn: window)
        } else {
            result = try await product.purchase()
        }
        switch result {
        case .success(let verification):
            // Only a verified transaction is finished.
            guard case .verified(let transaction) = verification else { return .unverified }
            await transaction.finish()
            return .success
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    func restore() async throws -> PremiumRestoreOutcome {
        do {
            try await AppStore.sync()
            return .finished
        } catch StoreKitError.userCancelled {
            return .cancelled
        }
    }
}

private extension PremiumTransaction {
    init(_ result: VerificationResult<Transaction>) {
        switch result {
        case .verified(let transaction):
            self.init(transaction, verified: true)
        case .unverified(let transaction, _):
            self.init(transaction, verified: false)
        }
    }

    init(_ transaction: Transaction, verified: Bool) {
        self.init(
            productID: transaction.productID,
            verified: verified,
            revocationDate: transaction.revocationDate,
            expirationDate: transaction.expirationDate
        )
    }
}

private extension PremiumPeriod {
    init(_ period: Product.SubscriptionPeriod) {
        let unit: Unit
        switch period.unit {
        case .day: unit = .day
        case .week: unit = .week
        case .month: unit = .month
        case .year: unit = .year
        @unknown default: unit = .year
        }
        self.init(value: period.value, unit: unit)
    }
}
#endif
