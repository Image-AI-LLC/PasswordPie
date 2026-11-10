import Foundation
import PasswordPieCore

/// How a `passwordpie://activate` link ended.
enum ActivationOutcome: Equatable {
    /// Premium is on through this date: the link's, or a later one already held.
    case activated(until: Date)
    /// Nothing changed. `expired` when the link would have worked but ran out.
    case refused(expired: Bool)
}

/// The activation from the website, as both channels keep it: one token in the keychain, checked against the activation
/// audience, the longest-lasting kept (`ActivationLink.decide`). Any page can open the link, so nothing here trusts it.
@MainActor
final class ActivationVault {
    private let secrets: SecretStore
    private let verify: TokenCheck
    private(set) var current: Entitlement?
    private var loaded = false

    init(secrets: SecretStore, verify: @escaping TokenCheck) {
        self.secrets = secrets
        self.verify = verify
    }

    /// The raw token in the keychain, for a caller that checks it together with other proofs.
    func storedToken() -> String? {
        secrets.read(.activation)
    }

    /// Reads the keychain once. A token that does not check is deleted. Returns when one ran out, for the words.
    @discardableResult
    func restore(now: Date) -> Date? {
        guard !loaded else { return nil }
        loaded = true
        guard let token = secrets.read(.activation) else { return nil }
        if let entitlement = verify(token, now) {
            current = entitlement
            return nil
        }
        secrets.delete(.activation)
        return EntitlementToken.isExpiredButOtherwiseGood(token, now: now, verify: verify) ? EntitlementToken.expiry(of: token) : nil
    }

    /// Takes what a caller already checked from `storedToken()`.
    func adopt(_ entitlement: Entitlement?) {
        loaded = true
        current = entitlement
    }

    /// Takes the link's token. Nil when the URL is not an activation link at all.
    func open(_ url: URL, now: Date) -> ActivationOutcome? {
        guard ActivationLink.matches(url) else { return nil }
        restore(now: now)
        let token = ActivationLink.token(in: url)
        switch ActivationLink.decide(token: token, current: current, now: now, verify: verify) {
        case .refuse(let expired):
            return .refused(expired: expired)
        case .keep(let held):
            return .activated(until: held.expiresAt)
        case .replace(let entitlement):
            current = entitlement
            if let token { secrets.write(token, for: .activation) }
            return .activated(until: entitlement.expiresAt)
        }
    }

    /// Forgets an activation that ran out. Returns its end date when it did.
    @discardableResult
    func forgetIfExpired(now: Date) -> Date? {
        guard let current, current.expiresAt <= now else { return nil }
        self.current = nil
        secrets.delete(.activation)
        return current.expiresAt
    }
}
