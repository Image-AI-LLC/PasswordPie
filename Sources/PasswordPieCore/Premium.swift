import Foundation

/// The two things PasswordPie Premium can be bought as. The prices live in App Store Connect, never here.
public enum PremiumPlan: String, CaseIterable, Sendable {
    case lifetime
    case yearly

    public var productID: String { "com.oldcai.passwordpie.premium.\(rawValue)" }

    public init?(productID: String) {
        guard let plan = Self.allCases.first(where: { $0.productID == productID }) else { return nil }
        self = plan
    }
}

/// One transaction as the store reported it. `verified` is false for anything that failed Apple's signature check.
public struct PremiumTransaction: Equatable, Sendable {
    public var productID: String
    public var verified: Bool
    public var revocationDate: Date?
    public var expirationDate: Date?

    public init(productID: String, verified: Bool, revocationDate: Date?, expirationDate: Date?) {
        self.productID = productID
        self.verified = verified
        self.revocationDate = revocationDate
        self.expirationDate = expirationDate
    }

    /// A purchase that still counts: verified, not refunded, not run out, and one of ours.
    public func isActive(at now: Date) -> Bool {
        guard verified, revocationDate == nil, PremiumPlan(productID: productID) != nil else { return false }
        if let expirationDate { return expirationDate > now }
        return PremiumPlan(productID: productID) == .lifetime
    }
}

/// What this Mac's Apple Account owns, as StoreKit says. In the App Store app this is what turns codes on.
public enum PremiumStatus: Equatable, Sendable {
    /// The store has not answered yet. Not Premium.
    case checking
    case free
    /// `expires` is the end of the paid period.
    case yearly(expires: Date)
    /// Also holds a subscription that is still running, because it keeps charging until it is cancelled.
    case lifetime(subscriptionExpires: Date?)

    /// What the store's transactions add up to. A transaction counts only if it is verified, not revoked and not expired.
    public init(transactions: [PremiumTransaction], now: Date) {
        var lifetime = false
        var subscriptionExpires: Date?
        for transaction in transactions where transaction.verified && transaction.revocationDate == nil {
            switch PremiumPlan(productID: transaction.productID) {
            case .lifetime:
                if let expiration = transaction.expirationDate, expiration <= now { continue }
                lifetime = true
            case .yearly:
                guard let expiration = transaction.expirationDate, expiration > now else { continue }
                subscriptionExpires = max(subscriptionExpires ?? expiration, expiration)
            case nil:
                continue
            }
        }
        if lifetime {
            self = .lifetime(subscriptionExpires: subscriptionExpires)
        } else if let subscriptionExpires {
            self = .yearly(expires: subscriptionExpires)
        } else {
            self = .free
        }
    }

    /// Takes the time because a subscription can end while the app is running, with no event from the store.
    public func grantsPremium(at now: Date) -> Bool {
        switch self {
        case .checking, .free: return false
        case .yearly(let expires): return expires > now
        case .lifetime: return true
        }
    }

    public func ownedPlans(at now: Date) -> Set<PremiumPlan> {
        switch self {
        case .checking, .free:
            return []
        case .yearly(let expires):
            return expires > now ? [.yearly] : []
        case .lifetime(let subscriptionExpires):
            if let subscriptionExpires, subscriptionExpires > now { return [.lifetime, .yearly] }
            return [.lifetime]
        }
    }

    /// When a running subscription ends, so the store can look again at that moment.
    public var nextExpiration: Date? {
        switch self {
        case .yearly(let expires): return expires
        case .lifetime(let subscriptionExpires): return subscriptionExpires
        default: return nil
        }
    }
}

/// A subscription's length, as the store reports it.
public struct PremiumPeriod: Equatable, Sendable {
    public enum Unit: String, Sendable {
        case day, week, month, year
    }

    public var value: Int
    public var unit: Unit

    public init(value: Int, unit: Unit) {
        self.value = value
        self.unit = unit
    }

    /// "1 year"
    public var text: String { "\(value) \(unit.rawValue)\(value == 1 ? "" : "s")" }
    /// "year" as in "every year"; "2 months" as in "every 2 months".
    public var renewalWord: String { value == 1 ? unit.rawValue : text }
}

/// A plan the store offered. Every string comes from the store, so the App Store sets the currency and the price.
public struct PremiumProduct: Equatable, Sendable, Identifiable {
    public var plan: PremiumPlan
    public var displayName: String
    public var displayPrice: String
    /// Nil for a one-time purchase.
    public var period: PremiumPeriod?

    public var id: PremiumPlan { plan }

    public init(plan: PremiumPlan, displayName: String, displayPrice: String, period: PremiumPeriod?) {
        self.plan = plan
        self.displayName = displayName
        self.displayPrice = displayPrice
        self.period = period
    }

    public var summary: String {
        guard let period else { return "One payment. No subscription." }
        return "Renews every \(period.renewalWord) until you cancel."
    }

    public var buttonTitle: String {
        guard let period else { return displayPrice }
        return "\(displayPrice) / \(period.renewalWord)"
    }

    /// The terms App Store guideline 3.1.2 asks for next to a subscription. Nil for a one-time purchase.
    public var renewalDisclosure: String? {
        guard let period else { return nil }
        return "\(displayName) is a \(period.text) subscription at \(displayPrice). It renews automatically at that price unless you "
            + "cancel at least 24 hours before the end of the period. Payment is charged to your Apple Account when you confirm, and "
            + "each renewal is charged in the last 24 hours of the period. Cancel any time under Manage Subscription."
    }
}

public enum PremiumLinks {
    public static let termsOfService = URL(string: "https://passwordpie.com/terms-of-service")!
    public static let privacyPolicy = URL(string: "https://passwordpie.com/privacy-policy")!
    /// Apple's own page. `AppStore.showManageSubscriptions` does not exist on macOS.
    public static let manageSubscriptions = URL(string: "https://apps.apple.com/account/subscriptions")!
}

/// Whether an item's one-time code can be made. Holding the settings is the only way to reach `code`, so a locked item
/// never has a code computed for it.
public enum OneTimeCodeAccess: Equatable, Sendable {
    /// The item has no two-step code.
    case noCode
    /// The item has one, and this user does not have Premium.
    case locked
    case available(OTPSettings)
}

/// The one gate in front of two-step codes. The app target calls `TOTP.code` nowhere else: `PremiumGateTests` checks.
public enum OneTimeCodes {
    /// Whether the item stores a two-step secret at all. Free users still see that it does.
    public static func hasCode(_ entry: VaultEntry) -> Bool {
        TOTP.parse(entry: entry) != nil
    }

    public static func access(for entry: VaultEntry, hasPremium: Bool) -> OneTimeCodeAccess {
        guard let settings = TOTP.parse(entry: entry) else { return .noCode }
        return hasPremium ? .available(settings) : .locked
    }

    public static func code(settings: OTPSettings, at date: Date = Date()) -> String {
        TOTP.code(settings: settings, at: date)
    }
}

public extension OneTimeCodeAccess {
    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}
