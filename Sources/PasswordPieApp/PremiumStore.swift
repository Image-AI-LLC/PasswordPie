import AppKit
import Combine
import PasswordPieCore

enum PremiumPurchaseOutcome: Equatable {
    /// The store finished and verified it. `signedTransaction` is Apple's JWS, which passwordpie.com checks with Apple.
    case success(signedTransaction: String?)
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
/// Only the App Store channel has one.
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

/// What a purchase, restore or move is doing, and what to say about how the last one ended.
enum PremiumActivity: Equatable {
    case idle
    case purchasing(PremiumPlan)
    case restoring
    /// Waiting for someone to approve this plan.
    case pending(PremiumPlan)
    /// Putting a purchase on the account at passwordpie.com.
    case linking
    /// Bought, not on the account yet because the site did not answer. Tried again by itself.
    case linkPending
    case moving
    case moved(previousAccountEmailMasked: String?)
    case moveLimited(nextAllowedAt: Date?)
    /// A purchase on this Mac is on another account, and nobody asked to move it.
    case onAnotherAccount
    /// Asked to buy or restore while signed out. It carries on after sign-in.
    case signInFirst
    /// A purchase is on this Mac and nobody is signed in to add it to.
    case unclaimedPurchase
    /// The site ended the session.
    case signedOutBySite
    case cancelled
    case failed(String)
    case alreadyOwned(PremiumPlan)
    case nothingToRestore
    case restored

    static let notConfirmed = "passwordpie.com could not confirm this purchase with Apple. Press Restore Purchases to try again."

    var isBusy: Bool {
        switch self {
        case .purchasing, .restoring, .linking, .moving: return true
        default: return false
        }
    }

    var isError: Bool {
        switch self {
        case .failed, .moveLimited: return true
        default: return false
        }
    }

    func message(dateText: (Date) -> String = { $0.formatted(date: .long, time: .omitted) }) -> String? {
        switch self {
        case .idle, .purchasing, .restoring: return nil
        case .pending: return "Waiting for approval. Premium unlocks by itself when it is approved."
        case .linking: return "Adding Premium to your account…"
        case .linkPending: return "Your purchase is safe. PasswordPie adds it to your account as soon as it reaches passwordpie.com."
        case .moving: return "Moving Premium to this account…"
        case .moved(let previous): return PremiumMoveText.moved(previousAccountEmailMasked: previous)
        case .moveLimited(let next): return PremiumMoveText.limited(nextAllowedAt: next, dateText: dateText)
        case .onAnotherAccount: return "The purchase on this Mac is on another PasswordPie account. Restore Purchases can move it here."
        case .signInFirst: return "Sign in first, so Premium goes with your account."
        case .unclaimedPurchase: return "Sign in to add this purchase to your account."
        case .signedOutBySite: return "You were signed out. Sign in again to use Premium."
        case .cancelled: return "Purchase cancelled."
        case .failed(let reason): return reason
        case .alreadyOwned: return "You already own this plan."
        case .nothingToRestore: return "No purchases to restore on this Apple Account."
        case .restored: return "Purchases restored."
        }
    }

    var message: String? { message() }
}

enum AccountSignInState: Equatable {
    case idle
    case waiting(AccountSite.Provider?)
    case failed

    var message: String? { self == .failed ? "Could not sign in. Try again." : nil }
}

/// A purchase on another account, waiting for the user to say whether to move it here.
struct PremiumMoveRequest: Equatable {
    var signedTransactions: [String]
    var previousAccountEmailMasked: String?
}

/// Who has Premium right now: the PasswordPie account signed in on this Mac. The App Store channel also sells through
/// StoreKit and puts each purchase on the account. Nothing but a signed pass in the keychain can turn Premium on.
@MainActor
final class PremiumStore: ObservableObject {
    @Published private(set) var account: AccountPremium
    @Published private(set) var email: String?
    /// What this Apple Account owns. App Store channel only; `.free` elsewhere.
    @Published private(set) var storeStatus: PremiumStatus
    @Published private(set) var products = PremiumProducts.idle
    @Published private(set) var activity = PremiumActivity.idle
    @Published private(set) var signInState = AccountSignInState.idle
    @Published private(set) var moveRequest: PremiumMoveRequest?
    /// Opens the Premium window. Wired by the app delegate.
    var presentPaywall: (() -> Void)?

    private enum AfterSignIn: Equatable {
        case purchase(PremiumPlan)
        case restore
    }

    private let backend: PremiumBackend?
    private let services: AccountServices
    /// The direct channel's switch (`directChannelCodesAreFree`). Codes in the app only; never the browser.
    private let freeCodes: Bool
    private let now: () -> Date
    private let firstCheckTimeout: TimeInterval
    private let minimumRefreshInterval: TimeInterval
    private var session: String?
    private var pass: String?
    private var lastAnswer: Date?
    private var storeTransactions: [PremiumTransaction] = []
    /// Purchases sent to the site this session, so a refresh does not send them again. Forgotten on a failure to reach it.
    private var linked: Set<String> = []
    private var afterSignIn: AfterSignIn?
    private var refreshGeneration = 0
    private var started = false
    private var loaded = false
    private var updatesTask: Task<Void, Never>?
    private var firstCheckTask: Task<Void, Never>?
    private var firstCheckTimeoutTask: Task<Void, Never>?
    private var renewalTask: Task<Void, Never>?
    private var activation: NSObjectProtocol?
    /// Asked for a code while the account had not answered yet.
    private var waiting: [() -> Void] = []

    init(
        backend: PremiumBackend?,
        services: AccountServices,
        now: @escaping () -> Date = Date.init,
        freeCodes: Bool = false,
        firstCheckTimeout: TimeInterval = 3,
        minimumRefreshInterval: TimeInterval = 300
    ) {
        self.backend = backend
        self.services = services
        self.freeCodes = freeCodes
        self.now = now
        self.firstCheckTimeout = firstCheckTimeout
        self.minimumRefreshInterval = minimumRefreshInterval
        // Nothing is read from the keychain until `start()`, so a store made and thrown away never touches it.
        account = .signedOut
        storeStatus = backend == nil ? .free : .checking
    }

    deinit {
        updatesTask?.cancel()
        firstCheckTask?.cancel()
        firstCheckTimeoutTask?.cancel()
        renewalTask?.cancel()
        if let activation { NotificationCenter.default.removeObserver(activation) }
    }

    /// Whether this build sells Premium itself (StoreKit). The direct channel sends people to passwordpie.com instead.
    var sellsInApp: Bool { backend != nil }
    var isSignedIn: Bool { session != nil }
    var site: AccountSite { services.site }

    /// Read at every use, so a pass or a subscription stops counting the moment it ends, even with no event.
    var hasPremium: Bool { freeCodes || accountHasPremium }

    /// The signed-in account's own Premium, whatever the direct channel's switch says. What the browser bridge uses.
    var accountHasPremium: Bool { account.grantsPremium(at: now()) }

    var ownedPlans: Set<PremiumPlan> { storeStatus.ownedPlans(at: now()) }

    /// Purchases on this Mac that still count and can be sent to the site.
    private var activeSignedTransactions: [String] {
        let now = now()
        var seen = Set<String>()
        return storeTransactions.filter { $0.isActive(at: now) }.compactMap(\.signedTransaction).filter { seen.insert($0).inserted }
    }

    // MARK: Lifecycle

    /// Starts listening to the store, then asks the site. Call once at launch.
    func start() {
        guard !started else { return }
        started = true
        restoreSavedAccount()
        if let backend {
            let updates = backend.transactionUpdates()
            updatesTask = Task { [weak self] in
                // A new transaction may be a purchase to add to the account, so the site is asked too.
                for await _ in updates { await self?.refresh(force: true) }
            }
        }
        firstCheckTask = Task { [weak self] in await self?.refresh(force: true) }
        // A site that never answers must not leave a shortcut doing nothing. A late answer still unlocks.
        let timeout = firstCheckTimeout
        firstCheckTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self, self.account == .checking else { return }
            self.setAccount(.unreachable(passExpired: false))
        }
        // A menu-bar app stays running for months, so look again whenever it comes forward.
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh() }
            }
        }
    }

    /// The session and the last pass from the keychain. A pass counts only if it still checks.
    private func restoreSavedAccount() {
        guard !loaded else { return }
        loaded = true
        session = services.secrets.read(.session)
        email = session == nil ? nil : services.secrets.read(.email)
        let cached = session == nil ? nil : services.secrets.read(.pass)
        let decision = AccountPremiumDecision.evaluate(signedIn: session != nil, cachedPass: cached, reply: nil, now: now(), verify: services.verify)
        // A pass that ran out at launch is not "offline" yet: the site has not been asked. It stays in memory, unable to grant
        // anything, until the answer comes, so a failure to reach the site can say Premium needs renewing.
        if case .unreachable(passExpired: true) = decision.state {
            pass = cached
            account = .checking
            return
        }
        pass = decision.pass
        if decision.pass == nil, cached != nil { services.secrets.delete(.pass) }
        account = decision.state == .unreachable(passExpired: false) ? .checking : decision.state
    }

    func stop() {
        updatesTask?.cancel()
        updatesTask = nil
        firstCheckTask?.cancel()
        firstCheckTimeoutTask?.cancel()
        renewalTask?.cancel()
        if let activation { NotificationCenter.default.removeObserver(activation) }
        activation = nil
        started = false
    }

    /// Reads the store again, and asks the site unless it answered in the last few minutes. `force` always asks.
    func refresh(force: Bool = false) async {
        restoreSavedAccount()
        refreshGeneration += 1
        let generation = refreshGeneration
        if let backend {
            let transactions = await backend.currentTransactions()
            // An older answer that took longer must not overwrite a newer one.
            guard generation == refreshGeneration else { return }
            storeTransactions = transactions
            let status = PremiumStatus(transactions: transactions, now: now())
            if storeStatus != status { storeStatus = status }
        }
        guard let session else {
            setAccount(.signedOut)
            if activity == .idle, !activeSignedTransactions.isEmpty { activity = .unclaimedPurchase }
            return
        }
        if !force, let lastAnswer, now().timeIntervalSince(lastAnswer) < minimumRefreshInterval, account.grantsPremium(at: now()) || account == .free {
            await linkUnclaimedPurchases()
            return
        }
        let reply = await services.client.entitlement(session: session)
        guard generation == refreshGeneration, self.session == session else { return }
        apply(reply)
        await linkUnclaimedPurchases()
    }

    private func apply(_ reply: AccountReply) {
        let decision = AccountPremiumDecision.evaluate(signedIn: session != nil, cachedPass: pass, reply: reply, now: now(), verify: services.verify)
        if case .ok = reply { lastAnswer = now() }
        if decision.sessionEnded {
            forgetAccount()
            activity = .signedOutBySite
        }
        if decision.pass != pass {
            pass = decision.pass
            if let pass { services.secrets.write(pass, for: .pass) } else { services.secrets.delete(.pass) }
        }
        setAccount(decision.state)
    }

    private func setAccount(_ state: AccountPremium) {
        if account != state { account = state }
        if hasPremium {
            switch activity {
            case .linkPending, .unclaimedPurchase, .onAnotherAccount, .signedOutBySite: activity = .idle
            default: break
            }
        }
        scheduleRenewal()
        guard state != .checking else { return }
        let requests = waiting
        waiting = []
        if hasPremium {
            requests.forEach { $0() }
        } else if !requests.isEmpty {
            presentPaywall?()
        }
    }

    /// The site sends nothing when a pass runs out, so the app asks again then, and at least once a day.
    private func scheduleRenewal() {
        renewalTask?.cancel()
        renewalTask = nil
        guard started, session != nil else { return }
        var next = now().addingTimeInterval(24 * 3600)
        switch account {
        case .premium(let entitlement, _): next = min(next, entitlement.expiresAt)
        case .unreachable, .unverified: next = min(next, now().addingTimeInterval(15 * 60))
        default: break
        }
        if let expires = storeStatus.nextExpiration { next = min(next, expires) }
        let delay = max(next.timeIntervalSince(now()), 0) + 0.01
        renewalTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.refresh(force: true)
        }
    }

    /// Runs `action` if Premium is here. Otherwise opens the Premium window. While the account has not answered yet this
    /// waits for it, so someone who has Premium never sees the window just because they were quick.
    func requestUnlock(then action: @escaping () -> Void = {}) {
        if hasPremium {
            action()
        } else if account == .checking {
            waiting.append(action)
        } else {
            presentPaywall?()
        }
    }

    // MARK: Signing in

    func signIn(with provider: AccountSite.Provider?) async {
        if case .waiting = signInState { return }
        signInState = .waiting(provider)
        let state = AccountSite.newState()
        let callback: URL
        do {
            callback = try await services.signIn.authenticate(url: services.site.signInURL(state: state, provider: provider), callbackScheme: AccountSite.callbackScheme)
        } catch is AccountSignInCancelled {
            signInState = .idle
            return
        } catch {
            signInState = .failed
            return
        }
        let token: String
        switch AccountSignInCallback(url: callback, expectedState: state) {
        case .token(let value):
            token = value
        case .code(let code):
            guard let value = await services.client.exchange(code: code) else {
                signInState = .failed
                return
            }
            token = value
        case .failed, .invalid:
            signInState = .failed
            return
        }
        session = token
        services.secrets.write(token, for: .session)
        linked = []
        signInState = .idle
        switch activity {
        case .signInFirst, .unclaimedPurchase, .signedOutBySite: activity = .idle
        default: break
        }
        setAccount(.checking)
        if let address = await services.client.email(session: token), session == token {
            email = address
            services.secrets.write(address, for: .email)
        }
        await refresh(force: true)
        guard session == token, let next = afterSignIn else { return }
        afterSignIn = nil
        switch next {
        case .purchase(let plan): await purchase(plan)
        case .restore: await restore()
        }
    }

    /// Forgets the session and the pass. Premium stays on the account at passwordpie.com.
    func signOut() async {
        let old = session
        forgetAccount()
        activity = .idle
        setAccount(.signedOut)
        if let old { await services.client.signOut(session: old) }
    }

    private func forgetAccount() {
        session = nil
        pass = nil
        email = nil
        lastAnswer = nil
        linked = []
        afterSignIn = nil
        moveRequest = nil
        for secret in AccountSecret.allCases { services.secrets.delete(secret) }
    }

    // MARK: Products and purchases (App Store channel)

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

    private func refreshStore() async {
        guard let backend else { return }
        storeTransactions = await backend.currentTransactions()
        let status = PremiumStatus(transactions: storeTransactions, now: now())
        if storeStatus != status { storeStatus = status }
    }

    func purchase(_ plan: PremiumPlan) async {
        guard let backend, !activity.isBusy else { return }
        if ownedPlans.contains(plan) {
            activity = .alreadyOwned(plan)
            return
        }
        guard session != nil else {
            afterSignIn = .purchase(plan)
            activity = .signInFirst
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
        case .success(let signed):
            await refreshStore()
            guard let signed else {
                activity = .linkPending
                return
            }
            activity = .linking
            linked.insert(signed)
            switch await link(signed, restore: false) {
            case .bound:
                activity = hasPremium ? .idle : .failed(PremiumActivity.notConfirmed)
            case .boundElsewhere(let previous):
                activity = .idle
                moveRequest = PremiumMoveRequest(signedTransactions: [signed], previousAccountEmailMasked: previous)
            case .rebindLimited(let next):
                activity = .moveLimited(nextAllowedAt: next)
            case .invalidTransaction:
                activity = .failed(PremiumActivity.notConfirmed)
            case .signedOut:
                // Still on this Mac. It goes onto the account after the next sign-in.
                break
            case .unreachable, .failed:
                linked.remove(signed)
                activity = .linkPending
            }
        case .pending:
            activity = .pending(plan)
        case .cancelled:
            activity = .cancelled
        case .unverified:
            activity = .failed("The App Store could not verify this purchase, so Premium was not turned on.")
        }
    }

    /// Restore Purchases: asks Apple, then puts each purchase on this account. One on another account is moved only after
    /// the user says so (`moveRequest`, then `confirmMove`).
    func restore() async {
        guard let backend, !activity.isBusy else { return }
        guard session != nil else {
            afterSignIn = .restore
            activity = .signInFirst
            return
        }
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
        await refreshStore()
        let purchases = activeSignedTransactions
        guard !purchases.isEmpty else {
            activity = .nothingToRestore
            return
        }
        var elsewhere: [String] = []
        var previous: String?
        var limited: Date??
        var unreachable = false
        var refused = false
        for signed in purchases {
            linked.insert(signed)
            switch await link(signed, restore: false) {
            case .bound: break
            case .boundElsewhere(let masked):
                elsewhere.append(signed)
                previous = previous ?? masked
            case .rebindLimited(let next): limited = .some(next)
            case .invalidTransaction: refused = true
            case .signedOut: return
            case .unreachable, .failed:
                linked.remove(signed)
                unreachable = true
            }
        }
        if !elsewhere.isEmpty, !accountHasPremium {
            activity = .idle
            moveRequest = PremiumMoveRequest(signedTransactions: elsewhere, previousAccountEmailMasked: previous)
        } else if accountHasPremium {
            activity = .restored
        } else if unreachable {
            activity = .linkPending
        } else if let limited {
            activity = .moveLimited(nextAllowedAt: limited)
        } else {
            activity = .failed(refused ? PremiumActivity.notConfirmed : "passwordpie.com did not turn Premium on for these purchases.")
        }
    }

    /// The user chose Move Premium. Each purchase leaves the other account; the site allows one move a year.
    func confirmMove() async {
        guard let request = moveRequest, !activity.isBusy else { return }
        moveRequest = nil
        activity = .moving
        var moved = false
        var previous = request.previousAccountEmailMasked
        var limited: Date??
        var unreachable = false
        for signed in request.signedTransactions {
            switch await link(signed, restore: true) {
            case .bound(let response):
                if response.rebound == true {
                    moved = true
                    previous = response.previousAccountEmailMasked ?? previous
                }
            case .rebindLimited(let next): limited = .some(next)
            case .signedOut: return
            case .unreachable, .failed: unreachable = true
            case .invalidTransaction, .boundElsewhere: break
            }
        }
        if moved {
            activity = .moved(previousAccountEmailMasked: previous)
        } else if let limited {
            activity = .moveLimited(nextAllowedAt: limited)
        } else if accountHasPremium {
            activity = .restored
        } else if unreachable {
            activity = .failed("PasswordPie could not reach passwordpie.com, so nothing moved. Try again.")
        } else {
            activity = .failed(PremiumActivity.notConfirmed)
        }
    }

    func cancelMove() {
        moveRequest = nil
    }

    /// Sends one purchase to the site and applies what came back.
    private func link(_ signed: String, restore: Bool) async -> AppleBindOutcome {
        guard let session else { return .signedOut }
        let reply = await services.client.bindApple(session: session, signedTransaction: signed, restore: restore)
        guard self.session == session else { return .signedOut }
        let outcome = AppleBindOutcome(reply: reply)
        switch outcome {
        case .bound(let response):
            // Newer than any answer still on its way.
            refreshGeneration += 1
            apply(.ok(response))
        case .signedOut:
            refreshGeneration += 1
            apply(.unauthorized)
        default:
            break
        }
        return outcome
    }

    /// A purchase that reached this Mac without the account, such as Ask to Buy or one made while signed out, goes onto it
    /// now. Never moves one off another account.
    private func linkUnclaimedPurchases() async {
        guard backend != nil, session != nil, account == .free, !activity.isBusy, moveRequest == nil else { return }
        for signed in activeSignedTransactions where !linked.contains(signed) {
            linked.insert(signed)
            switch await link(signed, restore: false) {
            case .bound:
                if activity == .unclaimedPurchase || activity == .linkPending { activity = .idle }
            case .boundElsewhere:
                if activity == .idle { activity = .onAnotherAccount }
            case .unreachable, .failed:
                linked.remove(signed)
                if activity == .idle { activity = .linkPending }
                return
            case .rebindLimited, .invalidTransaction, .signedOut:
                break
            }
            if accountHasPremium || session == nil { return }
        }
    }

    /// When the window opens again, the last outcome is old news. Something still being waited for is not.
    func clearMessage() {
        switch activity {
        case .purchasing, .restoring, .pending, .linking, .moving, .linkPending, .unclaimedPurchase, .onAnotherAccount, .signInFirst:
            return
        default:
            activity = .idle
        }
        if signInState == .failed { signInState = .idle }
    }
}

extension PremiumStore {
    func summary(dateText: (Date) -> String = { $0.formatted(date: .long, time: .omitted) }) -> AccountPremiumSummary {
        var summary = account.summary(at: now(), dateText: dateText)
        if !freeCodes || accountHasPremium { return summary }
        summary.detail = "Two-step codes are free in this copy of PasswordPie."
        return summary
    }

    /// The reminder for someone who bought Lifetime with a yearly subscription still running.
    func subscriptionNote(dateText: (Date) -> String = { $0.formatted(date: .long, time: .omitted) }) -> String? {
        guard case .lifetime(let expires?) = storeStatus, expires > now() else { return nil }
        return "Your yearly subscription is paid through \(dateText(expires)) and keeps renewing until you cancel it under Manage Subscription."
    }
}
