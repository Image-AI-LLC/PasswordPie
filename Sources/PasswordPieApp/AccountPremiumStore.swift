#if PP_DIRECT
import AppKit
import Combine
import PasswordPieCore

/// What to say about the account that is not its Premium.
enum AccountActivity: Equatable {
    case idle
    /// The site ended the session.
    case signedOutBySite

    var message: String? { self == .signedOutBySite ? "You were signed out. Sign in again to use Premium." : nil }
}

enum AccountSignInState: Equatable {
    case idle
    case waiting(AccountSite.Provider?)
    case failed

    var message: String? { self == .failed ? "Could not sign in. Try again." : nil }
}

/// Who has Premium in the direct channel: the PasswordPie account signed in on this Mac. Nothing but a signed pass in the
/// keychain can turn Premium on. The App Store channel has `AppStorePremiumStore` instead.
@MainActor
final class AccountPremiumStore: ObservableObject {
    @Published private(set) var account: AccountPremium
    @Published private(set) var email: String?
    @Published private(set) var activity = AccountActivity.idle
    @Published private(set) var signInState = AccountSignInState.idle
    /// Opens the Premium window. Wired by the app delegate.
    var presentPaywall: (() -> Void)?

    private let services: AccountServices
    /// The direct channel's switch (`directChannelCodesAreFree`). Codes in the app only; never the browser.
    private let freeCodes: Bool
    private let now: () -> Date
    private let firstCheckTimeout: TimeInterval
    private let minimumRefreshInterval: TimeInterval
    private var session: String?
    private var pass: String?
    private var lastAnswer: Date?
    private var refreshGeneration = 0
    private var started = false
    private var loaded = false
    private var firstCheckTask: Task<Void, Never>?
    private var firstCheckTimeoutTask: Task<Void, Never>?
    private var renewalTask: Task<Void, Never>?
    private var activation: NSObjectProtocol?
    /// Asked for a code while the account had not answered yet.
    private var waiting: [() -> Void] = []

    init(
        services: AccountServices,
        now: @escaping () -> Date = Date.init,
        freeCodes: Bool = false,
        firstCheckTimeout: TimeInterval = 3,
        minimumRefreshInterval: TimeInterval = 300
    ) {
        self.services = services
        self.freeCodes = freeCodes
        self.now = now
        self.firstCheckTimeout = firstCheckTimeout
        self.minimumRefreshInterval = minimumRefreshInterval
        // Nothing is read from the keychain until `start()`, so a store made and thrown away never touches it.
        account = .signedOut
    }

    deinit {
        firstCheckTask?.cancel()
        firstCheckTimeoutTask?.cancel()
        renewalTask?.cancel()
        if let activation { NotificationCenter.default.removeObserver(activation) }
    }

    var isSignedIn: Bool { session != nil }
    var site: AccountSite { services.site }

    /// Read at every use, so a pass stops counting the moment it ends, even with no event.
    var hasPremium: Bool { freeCodes || accountHasPremium }

    /// The signed-in account's own Premium, whatever the direct channel's switch says. What the browser bridge uses.
    var accountHasPremium: Bool { account.grantsPremium(at: now()) }

    // MARK: Lifecycle

    /// Asks the site. Call once at launch.
    func start() {
        guard !started else { return }
        started = true
        restoreSavedAccount()
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
        firstCheckTask?.cancel()
        firstCheckTimeoutTask?.cancel()
        renewalTask?.cancel()
        if let activation { NotificationCenter.default.removeObserver(activation) }
        activation = nil
        started = false
    }

    /// Asks the site, unless it answered in the last few minutes. `force` always asks.
    func refresh(force: Bool = false) async {
        restoreSavedAccount()
        refreshGeneration += 1
        let generation = refreshGeneration
        guard let session else {
            setAccount(.signedOut)
            return
        }
        if !force, let lastAnswer, now().timeIntervalSince(lastAnswer) < minimumRefreshInterval, account.grantsPremium(at: now()) || account == .free {
            return
        }
        let reply = await services.client.entitlement(session: session)
        // An older answer that took longer must not overwrite a newer one.
        guard generation == refreshGeneration, self.session == session else { return }
        apply(reply)
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
        if hasPremium, activity == .signedOutBySite { activity = .idle }
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
        signInState = .idle
        activity = .idle
        setAccount(.checking)
        if let address = await services.client.email(session: token), session == token {
            email = address
            services.secrets.write(address, for: .email)
        }
        await refresh(force: true)
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
        for secret in AccountSecret.allCases { services.secrets.delete(secret) }
    }

    /// When the window opens again, the last outcome is old news.
    func clearMessage() {
        activity = .idle
        if signInState == .failed { signInState = .idle }
    }
}

extension AccountPremiumStore {
    func summary(dateText: (Date) -> String = { $0.formatted(date: .long, time: .omitted) }) -> AccountPremiumSummary {
        var summary = account.summary(at: now(), dateText: dateText)
        if !freeCodes || accountHasPremium { return summary }
        summary.detail = "Two-step codes are free in this copy of PasswordPie."
        return summary
    }
}
#endif
