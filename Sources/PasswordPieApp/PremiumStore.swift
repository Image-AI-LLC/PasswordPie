import AppKit
import Combine
import PasswordPieCore

enum PremiumPurchaseOutcome: Equatable {
    case success
    /// Waiting for someone to approve it, such as Ask to Buy. Arrives later through the updates stream.
    case pending
    case cancelled
    /// The store returned a transaction that failed Apple's signature check.
    case unverified
}

enum PremiumRestoreOutcome: Equatable {
    case finished
    case cancelled
}

/// The store, as the rest of the app sees it. `StoreKitPremiumBackend` is the real one, and tests script a fake.
@MainActor
protocol PremiumBackend: AnyObject {
    func currentTransactions() async -> [PremiumTransaction]
    /// Fires whenever the store's answer may have changed: a renewal, a refund, an approval, another device.
    func transactionUpdates() -> AsyncStream<Void>
    func loadProducts() async throws -> [PremiumProduct]
    func purchase(_ plan: PremiumPlan) async throws -> PremiumPurchaseOutcome
    func restore() async throws -> PremiumRestoreOutcome
}

enum PremiumProducts: Equatable {
    case idle
    case loading
    case loaded([PremiumProduct])
    /// The store failed, or knows none of the products.
    case failed
}

/// What a purchase or restore is doing, and what to say about how the last one ended.
enum PremiumActivity: Equatable {
    case idle
    case purchasing(PremiumPlan)
    case restoring
    /// Waiting for someone to approve this plan.
    case pending(PremiumPlan)
    /// The store finished the purchase, and the entitlement has not shown up yet. Only the entitlement grants Premium.
    case awaitingDelivery(PremiumPlan)
    case cancelled
    case failed(String)
    case alreadyOwned(PremiumPlan)
    case nothingToRestore
    case restored

    var isBusy: Bool {
        switch self {
        case .purchasing, .restoring: return true
        default: return false
        }
    }

    var isError: Bool {
        if case .failed = self { return true }
        return false
    }

    var message: String? {
        switch self {
        case .idle, .purchasing, .restoring: return nil
        case .pending: return "Waiting for approval. Premium unlocks by itself when it is approved."
        case .awaitingDelivery: return "The App Store finished the purchase. Premium unlocks as soon as it arrives. If it does not, press Restore Purchases."
        case .cancelled: return "Purchase cancelled."
        case .failed(let reason): return reason
        case .alreadyOwned: return "You already own this plan."
        case .nothingToRestore: return "No purchases to restore on this Apple Account."
        case .restored: return "Purchases restored."
        }
    }
}

struct PremiumStatusSummary: Equatable {
    var title: String
    var detail: String
}

extension PremiumStatus {
    func summary(dateText: (Date) -> String) -> PremiumStatusSummary {
        switch self {
        case .checking:
            return PremiumStatusSummary(title: "Checking…", detail: "Asking the App Store what this Apple Account owns.")
        case .free:
            return PremiumStatusSummary(title: "Free", detail: "Two-step codes need Premium. Everything else in PasswordPie is free.")
        case .yearly(let expires):
            return PremiumStatusSummary(
                title: "Premium: Yearly",
                detail: "Paid through \(dateText(expires)). It renews unless you cancel. Buying Lifetime does not cancel it: use Manage Subscription."
            )
        case .lifetime(let subscriptionExpires):
            if let subscriptionExpires {
                return PremiumStatusSummary(
                    title: "Premium: Lifetime",
                    detail: "You also have a yearly subscription, paid through \(dateText(subscriptionExpires)). It keeps renewing until you cancel it under Manage Subscription."
                )
            }
            return PremiumStatusSummary(title: "Premium: Lifetime", detail: "Two-step codes are yours for good.")
        #if PP_DIRECT
        case .directChannel:
            return PremiumStatusSummary(title: "Premium", detail: "")
        #endif
        }
    }
}

/// Who has Premium right now, and the purchase flow's state. Nothing here is saved: on the App Store channel every answer
/// comes from the store on each launch.
@MainActor
final class PremiumStore: ObservableObject {
    @Published private(set) var status: PremiumStatus
    @Published private(set) var products = PremiumProducts.idle
    @Published private(set) var activity = PremiumActivity.idle
    /// Opens the plans. Wired by the app delegate, on the App Store channel only.
    var presentPaywall: (() -> Void)?

    private let backend: PremiumBackend?
    private let now: () -> Date
    private let firstCheckTimeout: TimeInterval
    /// How long to keep asking after a purchase or restore. The store can report success a moment before the entitlement appears.
    private let deliveryRetryDelays: [TimeInterval]
    private var refreshGeneration = 0
    private var updatesTask: Task<Void, Never>?
    private var firstCheckTask: Task<Void, Never>?
    private var firstCheckTimeoutTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var activation: NSObjectProtocol?
    /// Asked for a code while the store had not answered yet.
    private var waiting: [() -> Void] = []

    init(
        backend: PremiumBackend,
        now: @escaping () -> Date = Date.init,
        firstCheckTimeout: TimeInterval = 3,
        deliveryRetryDelays: [TimeInterval] = [0.2, 0.5, 1, 2]
    ) {
        self.backend = backend
        self.now = now
        self.firstCheckTimeout = firstCheckTimeout
        self.deliveryRetryDelays = deliveryRetryDelays
        status = .checking
    }

    #if PP_DIRECT
    /// A channel with no store. Compiled out of the App Store channel, so nothing there can build a store that skips Apple.
    init(fixedStatus: PremiumStatus) {
        backend = nil
        now = Date.init
        firstCheckTimeout = 0
        deliveryRetryDelays = []
        status = fixedStatus
    }
    #endif

    deinit {
        updatesTask?.cancel()
        firstCheckTask?.cancel()
        firstCheckTimeoutTask?.cancel()
        expiryTask?.cancel()
        if let activation { NotificationCenter.default.removeObserver(activation) }
    }

    /// Read at every use, so a subscription stops counting the moment it ends, even with no event from the store.
    var hasPremium: Bool { status.grantsPremium(at: now()) }

    var ownedPlans: Set<PremiumPlan> { status.ownedPlans(at: now()) }

    /// Starts listening to the store, then asks it what this account owns. Call once at launch.
    func start() {
        guard let backend, updatesTask == nil else { return }
        let updates = backend.transactionUpdates()
        updatesTask = Task { [weak self] in
            for await _ in updates {
                await self?.refresh()
            }
        }
        firstCheckTask = Task { [weak self] in await self?.refresh() }
        // A store that never answers must not leave a shortcut doing nothing. A late answer still unlocks.
        let timeout = firstCheckTimeout
        firstCheckTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self, self.status == .checking else { return }
            self.apply(.free)
        }
        // A menu-bar app stays running for months, so look again whenever it comes forward.
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh() }
            }
        }
    }

    func stop() {
        updatesTask?.cancel()
        updatesTask = nil
        firstCheckTask?.cancel()
        firstCheckTimeoutTask?.cancel()
        expiryTask?.cancel()
        if let activation { NotificationCenter.default.removeObserver(activation) }
        activation = nil
    }

    func refresh() async {
        guard let backend else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        let transactions = await backend.currentTransactions()
        // An older answer that took longer must not overwrite a newer one.
        guard generation == refreshGeneration else { return }
        apply(PremiumStatus(transactions: transactions, now: now()))
    }

    private func apply(_ newStatus: PremiumStatus) {
        if status != newStatus { status = newStatus }
        switch activity {
        case .pending(let plan), .awaitingDelivery(let plan):
            if ownedPlans.contains(plan) { activity = .idle }
        default:
            break
        }
        scheduleExpiryCheck()
        let requests = waiting
        waiting = []
        if hasPremium {
            requests.forEach { $0() }
        } else if !requests.isEmpty {
            presentPaywall?()
        }
    }

    /// The store sends nothing when a subscription simply ends, so the status changes here and open views redraw.
    private func scheduleExpiryCheck() {
        expiryTask?.cancel()
        expiryTask = nil
        guard let expires = status.nextExpiration else { return }
        let delay = max(expires.timeIntervalSince(now()), 0) + 0.01
        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Runs `action` if Premium is here. Otherwise opens the plans. While the store has not answered yet this waits for it,
    /// so someone who owns Premium never sees the plans just because they were quick.
    func requestUnlock(then action: @escaping () -> Void = {}) {
        if hasPremium {
            action()
        } else if status == .checking {
            waiting.append(action)
        } else {
            presentPaywall?()
        }
    }

    /// Asks the store again until `arrived`, or until the retries run out.
    private func refreshUntil(_ arrived: () -> Bool) async {
        await refresh()
        for delay in deliveryRetryDelays where !arrived() {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await refresh()
        }
    }

    func loadProducts() async {
        guard let backend else { return }
        products = .loading
        do {
            let loaded = try await backend.loadProducts()
            let ordered = PremiumPlan.allCases.compactMap { plan in loaded.first { $0.plan == plan } }
            products = ordered.isEmpty ? .failed : .loaded(ordered)
        } catch {
            products = .failed
        }
    }

    func loadProductsIfNeeded() async {
        switch products {
        case .loaded, .loading: return
        case .idle, .failed: await loadProducts()
        }
    }

    func purchase(_ plan: PremiumPlan) async {
        guard let backend, !activity.isBusy else { return }
        if ownedPlans.contains(plan) {
            activity = .alreadyOwned(plan)
            return
        }
        activity = .purchasing(plan)
        do {
            switch try await backend.purchase(plan) {
            case .success:
                await refreshUntil { ownedPlans.contains(plan) }
                activity = ownedPlans.contains(plan) ? .idle : .awaitingDelivery(plan)
            case .pending:
                activity = .pending(plan)
            case .cancelled:
                activity = .cancelled
            case .unverified:
                activity = .failed("The App Store could not verify this purchase, so Premium was not turned on.")
            }
        } catch {
            activity = .failed(error.localizedDescription)
        }
    }

    func restore() async {
        guard let backend, !activity.isBusy else { return }
        activity = .restoring
        do {
            switch try await backend.restore() {
            case .finished:
                await refreshUntil { hasPremium }
                activity = hasPremium ? .restored : .nothingToRestore
            case .cancelled:
                activity = .idle
            }
        } catch {
            activity = .failed(error.localizedDescription)
        }
    }

    /// When the plans open again, the last outcome is old news. Something still being waited for is not.
    func clearMessage() {
        switch activity {
        case .purchasing, .restoring, .pending, .awaitingDelivery: return
        default: activity = .idle
        }
    }
}
