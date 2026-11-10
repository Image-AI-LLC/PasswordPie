import Foundation

// Who has Premium in the direct app (docs/CHANNELS.md, "Who has Premium: the direct channel"). The app signs in to
// nothing and asks no site. It holds proofs that passwordpie.com signed, and believes the signature, never the sender:
//
// - a **pass** (`aud: passwordpie-app`, at most 7 days), which the browser extension hands over the bridge after it signs
//   in and each time it renews it;
// - an **activation** (`aud: passwordpie-activation`, at most a year), from a `passwordpie://activate` link.
//
// Not `#if`-ed by channel so the default test run covers it, and it holds no site address. Only the direct app uses it.

/// Checks a token at a moment: the claims when it is good, nil otherwise.
public typealias TokenCheck = (String, Date) -> Entitlement?

/// Where a pass came from. Each browser's pass is kept apart, so signing out in one leaves the other's.
public enum PassSource: String, CaseIterable, Sendable {
    case chrome
    case safari
    /// Kept by a direct build that signed in inside the app (unreleased builds before this one). It counts until its `exp`
    /// and nothing renews it.
    case appSignIn

    public init(_ browser: BridgeBrowser) {
        switch browser {
        case .chrome: self = .chrome
        case .safari: self = .safari
        }
    }
}

/// One place a proof is kept in the keychain.
public enum DirectPremiumSlot: Hashable, Sendable {
    case pass(PassSource)
    case activation
}

/// Why Premium went away on this Mac, so the Premium window can say what happened. Kept in memory only.
public enum PremiumLapse: Equatable, Sendable {
    /// The browser that delivered the pass signed out, or its session ended.
    case signedOutInBrowser
    /// The browser's account no longer has Premium.
    case browserAccountFree
    /// A pass ran out: no browser renewed it for a week.
    case passRanOut
    /// The activation ran out on this date.
    case activationRanOut(Date)
}

/// What the extension says when it takes its pass back.
public enum PassDropReason: String, Sendable {
    /// Signed out, or the site answered 401.
    case signedOut = "signed-out"
    /// The site answered `premium: false`.
    case noPremium = "no-premium"
}

/// A `premium` request from the extension.
public enum PassRelay: Equatable, Sendable {
    case pass(String)
    case drop(PassDropReason)
}

/// What the Premium window has to say about Premium.
public enum DirectPremiumStatus: Equatable, Sendable {
    case none
    /// A pass from the browser extension is good, so the extension keeps Premium up to date. `activationUntil` when an
    /// activation is held too.
    case fromBrowser(activationUntil: Date?)
    /// Only an activation.
    case activation(until: Date)
}

public struct DirectPremiumLoad: Equatable, Sendable {
    public var premium: DirectPremium
    /// What the keychain holds that does not check, to delete.
    public var discard: [DirectPremiumSlot]
    /// Something that would have checked had it not run out, and nothing else grants Premium.
    public var lapse: PremiumLapse?
}

public struct DirectPremiumExpiry: Equatable, Sendable {
    public var removed: [DirectPremiumSlot]
    public var lapse: PremiumLapse?

    public init(removed: [DirectPremiumSlot], lapse: PremiumLapse?) {
        self.removed = removed
        self.lapse = lapse
    }
}

/// The proofs the direct app holds, each one already checked.
public struct DirectPremium: Equatable, Sendable {
    public private(set) var passes: [PassSource: Entitlement]
    public private(set) var activation: Entitlement?

    public init(passes: [PassSource: Entitlement] = [:], activation: Entitlement? = nil) {
        self.passes = passes
        self.activation = activation
    }

    /// Read at every use: a proof stops counting the moment it runs out, with no event.
    public func grantsPremium(at now: Date) -> Bool {
        passes.values.contains { $0.expiresAt > now } || (activation.map { $0.expiresAt > now } ?? false)
    }

    public func status(at now: Date) -> DirectPremiumStatus {
        let activationUntil = activation.flatMap { $0.expiresAt > now ? $0.expiresAt : nil }
        if passes.values.contains(where: { $0.expiresAt > now }) { return .fromBrowser(activationUntil: activationUntil) }
        if let activationUntil { return .activation(until: activationUntil) }
        return .none
    }

    /// When the next proof runs out, so the app looks again then.
    public func nextExpiry(after now: Date) -> Date? {
        (passes.values.map(\.expiresAt) + [activation?.expiresAt].compactMap { $0 }).filter { $0 > now }.min()
    }

    /// What the keychain holds, checked: a pass against the pass audience and an activation against the activation
    /// audience, so neither stands in for the other.
    public static func load(
        passes: [PassSource: String],
        activation: String?,
        now: Date,
        verifyPass: TokenCheck,
        verifyActivation: TokenCheck
    ) -> DirectPremiumLoad {
        var premium = DirectPremium()
        var discard: [DirectPremiumSlot] = []
        var ranOut: PremiumLapse?
        for source in PassSource.allCases {
            guard let token = passes[source] else { continue }
            if let entitlement = verifyPass(token, now) {
                premium.passes[source] = entitlement
            } else {
                discard.append(.pass(source))
                if EntitlementToken.isExpiredButOtherwiseGood(token, now: now, verify: verifyPass) { ranOut = ranOut ?? .passRanOut }
            }
        }
        if let activation {
            if let entitlement = verifyActivation(activation, now) {
                premium.activation = entitlement
            } else {
                discard.append(.activation)
                if EntitlementToken.isExpiredButOtherwiseGood(activation, now: now, verify: verifyActivation),
                   let ended = EntitlementToken.expiry(of: activation) {
                    ranOut = .activationRanOut(ended)
                }
            }
        }
        return DirectPremiumLoad(premium: premium, discard: discard, lapse: premium.grantsPremium(at: now) ? nil : ranOut)
    }

    /// A pass from a browser. False, and nothing changes, when it does not check.
    public mutating func receivePass(_ token: String, from source: PassSource, now: Date, verify: TokenCheck) -> Bool {
        guard let entitlement = verify(token, now) else { return false }
        passes[source] = entitlement
        return true
    }

    /// The browser takes back the pass it delivered. Another browser's pass and an activation stay. Returns why Premium is
    /// now off, if it was on and is not any more.
    public mutating func dropPass(from source: PassSource, reason: PassDropReason, now: Date) -> PremiumLapse? {
        let before = grantsPremium(at: now)
        guard passes.removeValue(forKey: source) != nil, before, !grantsPremium(at: now) else { return nil }
        return reason == .signedOut ? .signedOutInBrowser : .browserAccountFree
    }

    public mutating func setActivation(_ entitlement: Entitlement?) {
        activation = entitlement
    }

    /// Removes what ran out by `now`. Says why when that ended Premium.
    public mutating func expire(now: Date) -> DirectPremiumExpiry {
        var removed: [DirectPremiumSlot] = []
        var lapse: PremiumLapse?
        for source in PassSource.allCases {
            guard let pass = passes[source], pass.expiresAt <= now else { continue }
            passes[source] = nil
            removed.append(.pass(source))
            lapse = lapse ?? .passRanOut
        }
        if let activation, activation.expiresAt <= now {
            self.activation = nil
            removed.append(.activation)
            lapse = .activationRanOut(activation.expiresAt)
        }
        return DirectPremiumExpiry(removed: removed, lapse: grantsPremium(at: now) ? nil : lapse)
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
