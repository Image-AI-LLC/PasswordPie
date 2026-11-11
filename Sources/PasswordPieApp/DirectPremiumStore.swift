#if PP_DIRECT
import AppKit
import Combine
import PasswordPieCore

/// What the last activation link did, for the Premium window.
enum DirectPremiumActivity: Equatable {
    case idle
    case activated(until: Date)
    case activationRefused(expired: Bool)

    var isError: Bool {
        if case .activationRefused = self { return true }
        return false
    }

    var message: String? {
        switch self {
        case .idle: return nil
        // The status line above already says until when; this only confirms the link.
        case .activated: return "The activation link worked."
        case .activationRefused(expired: true): return "This activation link has run out. Press Activate on passwordpie.com for a new one."
        case .activationRefused(expired: false): return "This activation link is not valid. Press Activate on passwordpie.com for a new one."
        }
    }
}

/// Who has Premium in the direct channel: an activation link from the website, where Premium is bought. The app signs in
/// to nothing and asks no site; it trusts the signature on what it holds, never the sender. The browser extension brings
/// nothing. The rules are `DirectPremium` in PasswordPieCore. The App Store channel has `AppStorePremiumStore` instead.
@MainActor
final class DirectPremiumStore: ObservableObject {
    @Published private(set) var premium = DirectPremium()
    /// Why Premium went away, while it is away. Memory only.
    @Published private(set) var lapse: PremiumLapse?
    @Published private(set) var activity = DirectPremiumActivity.idle
    /// Opens the Premium window. Wired by the app delegate.
    var presentPaywall: (() -> Void)?

    private let secrets: SecretStore
    private let verifyActivation: TokenCheck
    private let vault: ActivationVault
    /// The direct channel's switch (`directChannelCodesAreFree`). Codes in the app only; never the browser.
    private let freeCodes: Bool
    let now: () -> Date
    private var started = false
    private var loaded = false
    private var expiryTask: Task<Void, Never>?
    /// When a link last said something. The window it opens must not clear that as it appears.
    private var linkSpokeAt: Date?

    init(
        secrets: SecretStore,
        verifyActivation: @escaping TokenCheck,
        now: @escaping () -> Date = Date.init,
        freeCodes: Bool = false
    ) {
        self.secrets = secrets
        self.verifyActivation = verifyActivation
        self.now = now
        self.freeCodes = freeCodes
        vault = ActivationVault(secrets: secrets, verify: verifyActivation)
        // Nothing is read from the keychain until `start()` or a token arrives, so a store made and thrown away never
        // touches it.
    }

    deinit {
        expiryTask?.cancel()
    }

    /// Read at every use, so an activation stops counting the moment it ends, even with no event.
    var hasPremium: Bool { freeCodes || ownPremium }

    /// What this Mac holds, whatever the direct channel's switch says. What the browser bridge uses.
    var ownPremium: Bool { premium.grantsPremium(at: now()) }

    var status: DirectPremiumStatus { premium.status(at: now()) }

    // MARK: Lifecycle

    /// Reads the keychain and looks again when the activation runs out. Call once at launch.
    func start() {
        guard !started else { return }
        started = true
        load()
        reevaluate()
    }

    func stop() {
        expiryTask?.cancel()
        expiryTask = nil
        started = false
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        // Earlier builds signed in inside the app, or took a pass from the browser extension. None of it unlocks anything
        // now: only an activation does.
        for secret in PremiumSecret.legacy { secrets.delete(secret) }
        let result = DirectPremium.load(activation: vault.storedToken(), now: now(), verify: verifyActivation)
        if result.discard { secrets.delete(.activation) }
        vault.adopt(result.premium.activation)
        premium = result.premium
        lapse = result.lapse
    }

    /// Looks again: at launch, when the menu opens, and when the activation runs out. Nothing here talks to a site.
    func refresh(force: Bool = false) async {
        guard started else { return }
        reevaluate()
    }

    func reevaluate() {
        load()
        var next = premium
        if let ended = next.expire(now: now()) {
            vault.forgetIfExpired(now: now())
            premium = next
            lapse = ended
            // A link's "worked" beside an activation that has since run out would contradict the status.
            if case .activated = activity { activity = .idle }
        }
        scheduleExpiry()
    }

    /// Nothing announces that the activation ran out, so look again then.
    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        guard started, let next = premium.nextExpiry(after: now()) else { return }
        let delay = max(next.timeIntervalSince(now()), 0) + 0.01
        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(min(delay, 400 * 86400) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.reevaluate()
        }
    }

    // MARK: Activation from the website

    /// Takes a `passwordpie://activate?token=…` link. Returns false for any other URL.
    @discardableResult
    func activate(_ url: URL) -> Bool {
        reevaluate()
        guard let outcome = vault.open(url, now: now()) else { return false }
        switch outcome {
        case .refused(let expired):
            say(.activationRefused(expired: expired))
        case .activated(let until):
            var next = premium
            next.setActivation(vault.current)
            if next != premium { premium = next }
            lapse = nil
            say(.activated(until: until))
        }
        scheduleExpiry()
        return true
    }

    private func say(_ outcome: DirectPremiumActivity) {
        activity = outcome
        linkSpokeAt = now()
    }

    /// Runs `action` if Premium is here. Otherwise opens the Premium window. There is nothing to wait for: the proof is on
    /// this Mac.
    func requestUnlock(then action: @escaping () -> Void = {}) {
        if hasPremium {
            action()
        } else {
            presentPaywall?()
        }
    }

    /// When the window opens again, the last link's outcome is old news, except for the window that link opened.
    func clearMessage() {
        if let linkSpokeAt, now().timeIntervalSince(linkSpokeAt) < 5 { return }
        activity = .idle
    }
}

#endif
