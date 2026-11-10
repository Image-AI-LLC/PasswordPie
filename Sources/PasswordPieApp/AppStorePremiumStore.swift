import AppKit
import Combine
import PasswordPieCore

enum PremiumPurchaseOutcome: Equatable {
    /// The store finished and verified it.
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
    case cancelled
    case failed(String)
    case alreadyOwned(PremiumPlan)
    case nothingToRestore
    case restored
    /// An activation link from the website worked.
    case activated(until: Date)
    case activationFailed

    var isBusy: Bool {
        switch self {
        case .purchasing, .restoring: return true
        default: return false
        }
    }

    var isError: Bool {
        switch self {
        case .failed, .activationFailed: return true
        default: return false
        }
    }

    func message(dateText: (Date) -> String = { $0.formatted(date: .long, time: .omitted) }) -> String? {
        switch self {
        case .idle, .purchasing, .restoring: return nil
        case .pending: return "Waiting for approval. Premium unlocks by itself when it is approved."
        case .cancelled: return "Purchase cancelled."
        case .failed(let reason): return reason
        case .alreadyOwned: return "You already own this plan."
        case .nothingToRestore: return "No purchases to restore on this Apple Account."
        case .restored: return "Purchases restored."
        case .activated(let until): return "Premium is on through \(dateText(until))."
        case .activationFailed: return "This activation link is not valid or has run out."
        }
    }

    var message: String? { message() }
}

/// What the Premium window and Preferences say this Mac has.
struct PremiumStatusLine: Equatable {
    var title: String
    var detail: String
}

/// Who has Premium in the App Store channel: this Apple Account's purchases, or an activation from the website. There is no
/// account here and nothing leaves the Mac, which is what lets the app answer "Data Not Collected" (docs/CHANNELS.md).
/// Not `#if`-ed out of the direct build, so the default test run covers it; only the App Store channel uses it.
@MainActor
final class AppStorePremiumStore: ObservableObject {
    @Published private(set) var storeStatus = PremiumStatus.checking
    @Published private(set) var products = PremiumProducts.idle
    @Published private(set) var activity = PremiumActivity.idle
    @Published private(set) var activation: Entitlement?
    /// Opens the Premium window. Wired by the app delegate.
    var presentPaywall: (() -> Void)?

    private let backend: PremiumBackend
    /// The activation from the website, kept and checked as the direct app keeps it.
    private let vault: ActivationVault
    private let now: () -> Date
    private let firstCheckTimeout: TimeInterval
    private var refreshGeneration = 0
    private var started = false
    private var updatesTask: Task<Void, Never>?
    private var firstCheckTask: Task<Void, Never>?
    private var firstCheckTimeoutTask: Task<Void, Never>?
    private var renewalTask: Task<Void, Never>?
    private var becameActive: NSObjectProtocol?
    /// When a link last said something. The window it opens must not clear that as it appears.
    private var linkSpokeAt: Date?
    /// Asked for a code while the store had not answered yet.
    private var waiting: [() -> Void] = []

    init(
        backend: PremiumBackend,
        secrets: SecretStore,
        verify: @escaping TokenCheck,
        now: @escaping () -> Date = Date.init,
        firstCheckTimeout: TimeInterval = 3
    ) {
        self.backend = backend
        vault = ActivationVault(secrets: secrets, verify: verify)
        self.now = now
        self.firstCheckTimeout = firstCheckTimeout
    }

    deinit {
        updatesTask?.cancel()
        firstCheckTask?.cancel()
        firstCheckTimeoutTask?.cancel()
        renewalTask?.cancel()
        if let becameActive { NotificationCenter.default.removeObserver(becameActive) }
    }

    /// Read at every use, so a subscription or an activation stops counting the moment it ends, even with no event.
    var hasPremium: Bool { storeStatus.grantsPremium(at: now()) || activationIsGood }

    var ownedPlans: Set<PremiumPlan> { storeStatus.ownedPlans(at: now()) }

    private var activationIsGood: Bool { activation.map { $0.expiresAt > now() } ?? false }

    // MARK: Lifecycle

    /// Starts listening to the store and reads it. Call once at launch.
    func start() {
        guard !started else { return }
        started = true
        restoreSavedActivation()
        let updates = backend.transactionUpdates()
        updatesTask = Task { [weak self] in
            for await _ in updates { await self?.refresh(force: true) }
        }
        firstCheckTask = Task { [weak self] in await self?.refresh(force: true) }
        // A store that never answers must not leave a shortcut doing nothing. A late answer still unlocks.
        let timeout = firstCheckTimeout
        firstCheckTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self, self.storeStatus == .checking else { return }
            self.storeStatus = .free
            self.settle()
        }
        // A menu-bar app stays running for months, so look again whenever it comes forward.
        becameActive = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
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
        renewalTask?.cancel()
        if let becameActive { NotificationCenter.default.removeObserver(becameActive) }
        becameActive = nil
        started = false
    }

    /// The token from the last activation link. It counts only if it still checks.
    private func restoreSavedActivation() {
        vault.restore(now: now())
        if activation != vault.current { activation = vault.current }
    }

    /// Reads the store again. `force` is here to match the direct channel; the store is on this Mac, so it costs nothing.
    func refresh(force: Bool = false) async {
        restoreSavedActivation()
        refreshGeneration += 1
        let generation = refreshGeneration
        let transactions = await backend.currentTransactions()
        // An older answer that took longer must not overwrite a newer one.
        guard generation == refreshGeneration else { return }
        apply(transactions)
    }

    private func apply(_ transactions: [PremiumTransaction]) {
        let status = PremiumStatus(transactions: transactions, now: now())
        if storeStatus != status { storeStatus = status }
        settle()
    }

    private func settle() {
        if vault.forgetIfExpired(now: now()) != nil { activation = nil }
        if hasPremium, case .pending = activity { activity = .idle }
        scheduleRenewal()
        guard storeStatus != .checking else { return }
        let requests = waiting
        waiting = []
        if hasPremium {
            requests.forEach { $0() }
        } else if !requests.isEmpty {
            presentPaywall?()
        }
    }

    /// Nothing announces that a subscription or an activation ran out, so look again then, and at least once a day.
    private func scheduleRenewal() {
        renewalTask?.cancel()
        renewalTask = nil
        guard started else { return }
        var next = now().addingTimeInterval(24 * 3600)
        if let expires = storeStatus.nextExpiration { next = min(next, expires) }
        if let expires = activation?.expiresAt { next = min(next, expires) }
        let delay = max(next.timeIntervalSince(now()), 0) + 0.01
        renewalTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.refresh(force: true)
        }
    }

    /// Runs `action` if Premium is here. Otherwise opens the Premium window. While the store has not answered yet this waits
    /// for it, so someone who has Premium never sees the window just because they were quick.
    func requestUnlock(then action: @escaping () -> Void = {}) {
        if hasPremium {
            action()
        } else if storeStatus == .checking {
            waiting.append(action)
        } else {
            presentPaywall?()
        }
    }

    // MARK: Activation from the website

    /// Takes a `passwordpie://activate?token=…` link. Returns false for any other URL. Any page can try to open this
    /// scheme, so nothing here trusts the link: only a token that checks changes anything, and the longest-lasting wins.
    @discardableResult
    func activate(_ url: URL) -> Bool {
        guard let outcome = vault.open(url, now: now()) else { return false }
        switch outcome {
        case .refused:
            say(.activationFailed)
        case .activated(let until):
            if activation != vault.current { activation = vault.current }
            say(.activated(until: until))
            settle()
        }
        return true
    }

    /// A link can arrive in the middle of a purchase, whose own outcome must not be lost.
    private func say(_ outcome: PremiumActivity) {
        guard !activity.isBusy else { return }
        activity = outcome
        linkSpokeAt = now()
    }

    // MARK: Products and purchases

    func loadProducts() async {
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
        guard !activity.isBusy else { return }
        if ownedPlans.contains(plan) {
            activity = .alreadyOwned(plan)
            return
        }
        activity = .purchasing(plan)
        let outcome: PremiumPurchaseOutcome
        do {
            outcome = try await backend.purchase(plan)
        } catch {
            activity = .failed(error.localizedDescription)
            return
        }
        switch outcome {
        case .success:
            await refresh(force: true)
            activity = .idle
        case .pending:
            activity = .pending(plan)
        case .cancelled:
            activity = .cancelled
        case .unverified:
            activity = .failed("The App Store could not verify this purchase, so Premium was not turned on.")
        }
    }

    /// Restore Purchases: asks Apple, then reads what this Apple Account owns.
    func restore() async {
        guard !activity.isBusy else { return }
        activity = .restoring
        do {
            if try await backend.restore() == .cancelled {
                activity = .idle
                return
            }
        } catch {
            activity = .failed(error.localizedDescription)
            return
        }
        await refresh(force: true)
        activity = storeStatus.grantsPremium(at: now()) ? .restored : .nothingToRestore
    }

    /// When the window opens again, the last outcome is old news. Something still being waited for is not.
    func clearMessage() {
        switch activity {
        case .purchasing, .restoring, .pending:
            return
        case .activated, .activationFailed:
            if let linkSpokeAt, now().timeIntervalSince(linkSpokeAt) < 5 { return }
            activity = .idle
        default:
            activity = .idle
        }
    }
}

extension AppStorePremiumStore {
    func statusLine(dateText: (Date) -> String = { $0.formatted(date: .long, time: .omitted) }) -> PremiumStatusLine {
        switch storeStatus {
        case .lifetime:
            return PremiumStatusLine(title: "Premium: Lifetime", detail: "Two-step codes are yours for good.")
        case .yearly(let expires) where expires > now():
            return PremiumStatusLine(title: "Premium: Yearly", detail: "Paid through \(dateText(expires)).")
        default:
            break
        }
        if let activation, activation.expiresAt > now() {
            return PremiumStatusLine(title: "Premium", detail: "On through \(dateText(activation.expiresAt)).")
        }
        if storeStatus == .checking {
            return PremiumStatusLine(title: "Checking…", detail: "Asking the App Store about your purchases.")
        }
        return PremiumStatusLine(title: "Free", detail: "Two-step codes need Premium. Everything else in PasswordPie is free.")
    }

    /// The reminder for someone who bought Lifetime with a yearly subscription still running.
    func subscriptionNote(dateText: (Date) -> String = { $0.formatted(date: .long, time: .omitted) }) -> String? {
        guard case .lifetime(let expires?) = storeStatus, expires > now() else { return nil }
        return "Your yearly subscription is paid through \(dateText(expires)) and keeps renewing until you cancel it under Manage Subscription."
    }
}
