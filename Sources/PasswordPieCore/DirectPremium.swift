import Foundation

// Who has Premium in the direct app (docs/CHANNELS.md, "Who has Premium: the direct channel"). The app signs in to
// nothing and asks no site. It holds one proof that passwordpie.com signed, and believes the signature, never the sender:
// an **activation** (`aud: passwordpie-activation`, at most a year), from a `passwordpie://activate` link.
//
// The browser extension has nothing to do with it: it has no account, and it carries no proof (it did until 2026-11-11).
//
// Not `#if`-ed by channel so the default test run covers it, and it holds no site address. Only the direct app uses it.

/// Checks a token at a moment: the claims when it is good, nil otherwise.
public typealias TokenCheck = (String, Date) -> Entitlement?

/// Why Premium went away on this Mac, so the Premium window can say what happened. Kept in memory only.
public enum PremiumLapse: Equatable, Sendable {
    /// The activation ran out on this date.
    case activationRanOut(Date)
}

/// What the Premium window has to say about Premium.
public enum DirectPremiumStatus: Equatable, Sendable {
    case none
    case activation(until: Date)
}

public struct DirectPremiumLoad: Equatable, Sendable {
    public var premium: DirectPremium
    /// The keychain's token does not check: delete it.
    public var discard: Bool
    /// It would have checked had it not run out.
    public var lapse: PremiumLapse?
}

/// The proof the direct app holds, already checked.
public struct DirectPremium: Equatable, Sendable {
    public private(set) var activation: Entitlement?

    public init(activation: Entitlement? = nil) {
        self.activation = activation
    }

    /// Read at every use: the activation stops counting the moment it runs out, with no event.
    public func grantsPremium(at now: Date) -> Bool {
        activation.map { $0.expiresAt > now } ?? false
    }

    public func status(at now: Date) -> DirectPremiumStatus {
        guard let activation, activation.expiresAt > now else { return .none }
        return .activation(until: activation.expiresAt)
    }

    /// When the activation runs out, so the app looks again then.
    public func nextExpiry(after now: Date) -> Date? {
        activation.flatMap { $0.expiresAt > now ? $0.expiresAt : nil }
    }

    /// What the keychain holds, checked against the activation audience.
    public static func load(activation: String?, now: Date, verify: TokenCheck) -> DirectPremiumLoad {
        guard let activation else { return DirectPremiumLoad(premium: DirectPremium(), discard: false, lapse: nil) }
        if let entitlement = verify(activation, now) {
            return DirectPremiumLoad(premium: DirectPremium(activation: entitlement), discard: false, lapse: nil)
        }
        var lapse: PremiumLapse?
        if EntitlementToken.isExpiredButOtherwiseGood(activation, now: now, verify: verify),
           let ended = EntitlementToken.expiry(of: activation) {
            lapse = .activationRanOut(ended)
        }
        return DirectPremiumLoad(premium: DirectPremium(), discard: true, lapse: lapse)
    }

    public mutating func setActivation(_ entitlement: Entitlement?) {
        activation = entitlement
    }

    /// Removes an activation that ran out by `now`, and says when it ended. Nil when nothing was removed.
    public mutating func expire(now: Date) -> PremiumLapse? {
        guard let activation, activation.expiresAt <= now else { return nil }
        self.activation = nil
        return .activationRanOut(activation.expiresAt)
    }
}

/// What to do with an activation link's token.
public enum ActivationDecision: Equatable, Sendable {
    /// It checks and lasts longer than what is held: keep it.
    case replace(Entitlement)
    /// It checks, but what is held lasts as long or longer.
    case keep(Entitlement)
    /// It does not check. `expired` when it would have, but ran out.
    case refuse(expired: Bool)
}

public extension ActivationLink {
    /// Any page can open the scheme, so nothing here trusts the link: only a token that checks changes anything, and the
    /// longest-lasting wins. Shared by both channels.
    static func decide(token: String?, current: Entitlement?, now: Date, verify: TokenCheck) -> ActivationDecision {
        guard let token, let entitlement = verify(token, now) else {
            let expired = token.map { EntitlementToken.isExpiredButOtherwiseGood($0, now: now, verify: verify) } ?? false
            return .refuse(expired: expired)
        }
        if let current, current.expiresAt > now, current.expiresAt >= entitlement.expiresAt { return .keep(current) }
        return .replace(entitlement)
    }
}
