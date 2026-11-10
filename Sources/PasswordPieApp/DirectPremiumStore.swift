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

    func message(dateText: (Date) -> String = { $0.formatted(date: .long, time: .omitted) }) -> String? {
        switch self {
        case .idle: return nil
        case .activated(let until): return "Premium is on through \(dateText(until))."
        case .activationRefused(expired: true): return "This activation link has run out. Press Activate on passwordpie.com for a new one."
        case .activationRefused(expired: false): return "This activation link is not valid. Press Activate on passwordpie.com for a new one."
        }
    }

    var message: String? { message() }
}

/// Who has Premium in the direct channel: a pass the browser extension handed over, or an activation link from the
/// website. The app signs in to nothing and asks no site; it trusts the signature on what it holds, never the sender. The
/// rules are `DirectPremium` in PasswordPieCore. The App Store channel has `AppStorePremiumStore` instead.
@MainActor
final class DirectPremiumStore: ObservableObject {
    @Published private(set) var premium = DirectPremium()
    /// Why Premium went away, while it is away. Memory only.
    @Published private(set) var lapse: PremiumLapse?
    @Published private(set) var activity = DirectPremiumActivity.idle
    /// Opens the Premium window. Wired by the app delegate.
    var presentPaywall: (() -> Void)?

    private let secrets: SecretStore
    private let verifyPass: TokenCheck
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
        verifyPass: @escaping TokenCheck,
        verifyActivation: @escaping TokenCheck,
        now: @escaping () -> Date = Date.init,
        freeCodes: Bool = false
    ) {
        self.secrets = secrets
        self.verifyPass = verifyPass
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

    /// Read at every use, so a pass or an activation stops counting the moment it ends, even with no event.
    var hasPremium: Bool { freeCodes || ownPremium }

    /// What this Mac holds, whatever the direct channel's switch says. What the browser bridge uses.
    var ownPremium: Bool { premium.grantsPremium(at: now()) }

    var status: DirectPremiumStatus { premium.status(at: now()) }

    // MARK: Lifecycle

    /// Reads the keychain and looks again when the first proof runs out. Call once at launch.
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
        // An earlier build signed in inside the app. Its session and email unlock nothing now; its pass counts until it ends.
        secrets.delete(.legacySession)
        secrets.delete(.legacyEmail)
        var passes: [PassSource: String] = [:]
        for source in PassSource.allCases {
            if let token = secrets.read(source.secret) { passes[source] = token }
        }
        let result = DirectPremium.load(
            passes: passes,
            activation: vault.storedToken(),
            now: now(),
            verifyPass: verifyPass,
            verifyActivation: verifyActivation
        )
        for slot in result.discard { secrets.delete(slot.secret) }
        vault.adopt(result.premium.activation)
        premium = result.premium
        lapse = result.lapse
    }

    /// Looks again: at launch, when the menu opens, and when the earliest proof runs out. Nothing here talks to a site.
    func refresh(force: Bool = false) async {
        guard started else { return }
        reevaluate()
    }

    func reevaluate() {
        load()
        var next = premium
        let expiry = next.expire(now: now())
        if !expiry.removed.isEmpty {
            for slot in expiry.removed where slot != .activation { secrets.delete(slot.secret) }
            if expiry.removed.contains(.activation) { vault.forgetIfExpired(now: now()) }
            premium = next
            if let ended = expiry.lapse { lapse = ended }
        }
        scheduleExpiry()
    }

    /// Nothing announces that a proof ran out, so look again then.
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

    // MARK: From the browser extension

    /// A `premium` request from `source`'s extension. A pass is kept only when it checks; one that does not changes
    /// nothing. Taking it back drops only what this browser delivered. Returns whether a pass was kept.
    @discardableResult
    func receive(_ relay: PassRelay, from source: PassSource) -> Bool {
        load()
        var next = premium
        switch relay {
        case .pass(let token):
            guard next.receivePass(token, from: source, now: now(), verify: verifyPass) else { return false }
            secrets.write(token, for: source.secret)
            premium = next
            lapse = nil
        case .drop(let reason):
            let ended = next.dropPass(from: source, reason: reason, now: now())
            secrets.delete(source.secret)
            if next != premium { premium = next }
            if let ended { lapse = ended }
        }
        scheduleExpiry()
        return true
    }

    // MARK: Activation from the website

    /// Takes a `passwordpie://activate?token=…` link. Returns false for any other URL.
    @discardableResult
    func activate(_ url: URL) -> Bool {
        load()
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

    /// Runs `action` if Premium is here. Otherwise opens the Premium window. There is nothing to wait for: the proofs are
    /// on this Mac.
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

extension PassSource {
    var secret: PremiumSecret {
        switch self {
        case .chrome: .chromePass
        case .safari: .safariPass
        case .appSignIn: .appSignInPass
        }
    }
}

extension DirectPremiumSlot {
    var secret: PremiumSecret {
        switch self {
        case .pass(let source): source.secret
        case .activation: .activation
        }
    }
}
#endif
