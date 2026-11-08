import Foundation
import Security

// The app's own PasswordPie account: what passwordpie.com answers, and what it means for Premium. No networking here;
// the app's `AccountClient` sends the requests and hands the replies to these types. See "Premium" in docs/CHANNELS.md.

/// The body of `GET /api/premium/entitlement`, and of a successful `POST /api/premium/apple/bind`, which adds the move.
public struct AccountEntitlementResponse: Equatable, Sendable {
    public var premium: Bool
    /// `lifetime`, `yearly` or `key`. What to show only: the pass decides.
    public var plan: String?
    /// When the account's Premium ends. Nil for lifetime.
    public var expiresAt: Date?
    /// The signed pass (an `EntitlementToken`). The only thing that turns Premium on.
    public var token: String?
    /// Bind only: the purchase came off another account.
    public var rebound: Bool?
    public var previousAccountEmailMasked: String?

    public init(
        premium: Bool, plan: String?, expiresAt: Date?, token: String?,
        rebound: Bool? = nil, previousAccountEmailMasked: String? = nil
    ) {
        self.premium = premium
        self.plan = plan
        self.expiresAt = expiresAt
        self.token = token
        self.rebound = rebound
        self.previousAccountEmailMasked = previousAccountEmailMasked
    }
}

/// One reply from passwordpie.com, as far as the app cares.
public enum AccountReply: Equatable, Sendable {
    case ok(AccountEntitlementResponse)
    /// 401: the session is gone. The app forgets it.
    case unauthorized
    /// No answer at all: offline, DNS, TLS, timeout.
    case unreachable
    /// Any other status, or a 200 that is not an entitlement.
    case rejected(status: Int, error: String?, nextAllowedAt: Date?, previousAccountEmailMasked: String?)

    public static func parse(status: Int, body: Data) -> AccountReply {
        if status == 401 { return .unauthorized }
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        if (200..<300).contains(status), let object, let premium = object["premium"] as? NSNumber, CFGetTypeID(premium) == CFBooleanGetTypeID() {
            return .ok(AccountEntitlementResponse(
                premium: premium.boolValue,
                plan: object["plan"] as? String,
                expiresAt: AccountDates.parse(object["expiresAt"]),
                token: object["token"] as? String,
                rebound: (object["rebound"] as? NSNumber)?.boolValue,
                previousAccountEmailMasked: object["previousAccountEmailMasked"] as? String
            ))
        }
        return .rejected(
            status: status,
            error: object?["error"] as? String,
            nextAllowedAt: AccountDates.parse(object?["nextAllowedAt"]),
            previousAccountEmailMasked: object?["previousAccountEmailMasked"] as? String
        )
    }
}

enum AccountDates {
    /// ISO 8601, with or without fractional seconds (JavaScript's `toISOString` writes them).
    static func parse(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// Better Auth's `GET /api/auth/get-session`.
public enum AccountSessionInfo {
    /// `.none` when the session is gone (Better Auth answers `null`), `.some(nil)` when it has no email.
    public static func email(from body: Data) -> String?? {
        guard let object = (try? JSONSerialization.jsonObject(with: body, options: .fragmentsAllowed)) as? [String: Any],
              let user = object["user"] as? [String: Any] else { return .none }
        return .some(user["email"] as? String)
    }
}

/// What `POST /api/premium/apple/bind` did.
public enum AppleBindOutcome: Equatable, Sendable {
    case bound(AccountEntitlementResponse)
    /// The purchase is on another account. Moving it needs the user's say-so, then `restore: true`.
    case boundElsewhere(previousAccountEmailMasked: String?)
    case rebindLimited(nextAllowedAt: Date?)
    case invalidTransaction
    case signedOut
    case unreachable
    case failed

    public init(reply: AccountReply) {
        switch reply {
        case .ok(let response): self = .bound(response)
        case .unauthorized: self = .signedOut
        case .unreachable: self = .unreachable
        case .rejected(let status, let error, let next, let previous):
            switch (status, error) {
            case (_, "rebind-limited"): self = .rebindLimited(nextAllowedAt: next)
            case (_, "invalid-transaction"): self = .invalidTransaction
            // Any other conflict means another account holds it. Nothing moves without asking.
            case (409, _), (_, "bound-elsewhere"): self = .boundElsewhere(previousAccountEmailMasked: previous)
            default: self = .failed
            }
        }
    }
}

/// Whether this Mac's signed-in account has Premium right now.
public enum AccountPremium: Equatable, Sendable {
    case signedOut
    /// Signed in, no answer yet and nothing cached.
    case checking
    /// The site says the account has no Premium.
    case free
    /// A pass that checked. `accountExpiresAt` is the end of the account's Premium, when the site said so.
    case premium(Entitlement, accountExpiresAt: Date?)
    /// The site said Premium but its pass did not check: a wrong key, or something in between.
    case unverified
    /// The site could not be reached, and there is no good pass. `passExpired` when one ran out.
    case unreachable(passExpired: Bool)

    /// Takes the time because a pass can run out while the app is running.
    public func grantsPremium(at now: Date) -> Bool {
        if case .premium(let entitlement, _) = self { return entitlement.expiresAt > now }
        return false
    }

    /// When the pass runs out, so the app can ask again then.
    public var passExpires: Date? {
        if case .premium(let entitlement, _) = self { return entitlement.expiresAt }
        return nil
    }

    public var isSignedIn: Bool { self != .signedOut }
}

public struct AccountPremiumDecision: Equatable, Sendable {
    public var state: AccountPremium
    /// The pass to keep in the keychain. Nil means delete it.
    public var pass: String?
    /// The site ended the session (401): forget it too.
    public var sessionEnded: Bool

    /// The one rule: Premium needs a pass whose signature checks and which has not run out. The site's `premium: true` alone
    /// grants nothing, and nothing is Premium without a session.
    public static func evaluate(
        signedIn: Bool,
        cachedPass: String?,
        reply: AccountReply?,
        now: Date,
        verify: (String, Date) -> Entitlement? = { EntitlementToken.verifyTrusted($0, now: $1) }
    ) -> AccountPremiumDecision {
        guard signedIn else { return AccountPremiumDecision(state: .signedOut, pass: nil, sessionEnded: false) }
        switch reply {
        case .ok(let response):
            guard response.premium else { return AccountPremiumDecision(state: .free, pass: nil, sessionEnded: false) }
            if let token = response.token, let entitlement = verify(token, now) {
                return AccountPremiumDecision(state: .premium(entitlement, accountExpiresAt: response.expiresAt), pass: token, sessionEnded: false)
            }
            return AccountPremiumDecision(state: .unverified, pass: nil, sessionEnded: false)
        case .unauthorized:
            return AccountPremiumDecision(state: .signedOut, pass: nil, sessionEnded: true)
        case .unreachable, .rejected, nil:
            if let cachedPass, let entitlement = verify(cachedPass, now) {
                return AccountPremiumDecision(state: .premium(entitlement, accountExpiresAt: nil), pass: cachedPass, sessionEnded: false)
            }
            if reply == nil, cachedPass == nil { return AccountPremiumDecision(state: .checking, pass: nil, sessionEnded: false) }
            let expired = cachedPass.map { EntitlementToken.isExpiredButOtherwiseGood($0, now: now, verify: verify) } ?? false
            return AccountPremiumDecision(state: .unreachable(passExpired: expired), pass: nil, sessionEnded: false)
        }
    }
}

extension EntitlementToken {
    /// True when the pass would check at a moment before it ran out. Only to choose the words; it grants nothing.
    static func isExpiredButOtherwiseGood(_ jwt: String, now: Date, verify: (String, Date) -> Entitlement?) -> Bool {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let body = Data(base64URL: parts[1]),
              let claims = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let exp = (claims["exp"] as? NSNumber)?.doubleValue else { return false }
        let expiry = Date(timeIntervalSince1970: exp)
        guard expiry <= now else { return false }
        return verify(jwt, expiry.addingTimeInterval(-1)) != nil
    }
}

public struct AccountPremiumSummary: Equatable, Sendable {
    public var title: String
    public var detail: String

    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }
}

public extension AccountPremium {
    func summary(at now: Date, dateText: (Date) -> String) -> AccountPremiumSummary {
        switch self {
        case .signedOut:
            return AccountPremiumSummary(title: "Not signed in", detail: "Premium belongs to your PasswordPie account. Sign in to use it on this Mac.")
        case .checking:
            return AccountPremiumSummary(title: "Checking…", detail: "Asking passwordpie.com about this account's Premium.")
        case .free:
            return AccountPremiumSummary(title: "Free", detail: "Two-step codes need Premium. Everything else in PasswordPie is free.")
        case .unverified:
            return AccountPremiumSummary(
                title: "Not confirmed",
                detail: "The answer from passwordpie.com could not be checked, so codes stay locked. Check Again in a moment."
            )
        case .unreachable(let passExpired):
            return AccountPremiumSummary(
                title: "Offline",
                detail: passExpired
                    ? "PasswordPie could not reach passwordpie.com to renew Premium. Codes unlock as soon as it can."
                    : "PasswordPie could not reach passwordpie.com to check Premium. Codes unlock as soon as it can."
            )
        case .premium(let entitlement, let until):
            if entitlement.expiresAt <= now {
                return AccountPremiumSummary(title: "Renewing…", detail: "Asking passwordpie.com to renew Premium on this Mac.")
            }
            switch entitlement.plan {
            case "lifetime":
                return AccountPremiumSummary(title: "Premium: Lifetime", detail: "Two-step codes are yours for good.")
            case "yearly":
                return AccountPremiumSummary(title: "Premium: Yearly", detail: until.map { "Paid through \(dateText($0))." } ?? "Renews every year until you cancel.")
            case "key":
                return AccountPremiumSummary(title: "Premium", detail: until.map { "From a key, through \(dateText($0))." } ?? "From a key.")
            default:
                return AccountPremiumSummary(title: "Premium", detail: until.map { "Through \(dateText($0))." } ?? "")
            }
        }
    }
}

/// How passwordpie.com's sign-in for the app is reached. The site sends the browser back to `passwordpie://auth`.
public struct AccountSite: Equatable, Sendable {
    public static let production = AccountSite(base: URL(string: "https://passwordpie.com")!)
    public static let callbackScheme = "passwordpie"
    public static let callback = "passwordpie://auth"

    public enum Provider: String, Sendable {
        case apple
        case google
    }

    public var base: URL

    public init(base: URL) {
        self.base = base
    }

    public func signInURL(state: String, provider: Provider?) -> URL {
        var components = URLComponents(url: base.appendingPathComponent("app/sign-in"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "state", value: state)]
            + (provider.map { [URLQueryItem(name: "provider", value: $0.rawValue)] } ?? [])
            + [URLQueryItem(name: "callback", value: Self.callback)]
        return components.url!
    }

    public var entitlementURL: URL { base.appendingPathComponent("api/premium/entitlement") }
    public var appleBindURL: URL { base.appendingPathComponent("api/premium/apple/bind") }
    public var exchangeURL: URL { base.appendingPathComponent("api/auth/app/exchange") }
    public var sessionURL: URL { base.appendingPathComponent("api/auth/get-session") }
    public var signOutURL: URL { base.appendingPathComponent("api/auth/sign-out") }

    /// 32 random bytes, base64url: ties a callback to the sign-in this app started.
    public static func newState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// The `passwordpie://auth?…` the sign-in sheet ends on.
public enum AccountSignInCallback: Equatable, Sendable {
    /// A one-time code, exchanged at `/api/auth/app/exchange` for the session token.
    case code(String)
    /// The session token itself.
    case token(String)
    /// The site said why it failed, such as `access_denied`.
    case failed(String)
    /// Not ours: another scheme or path, or a `state` this app did not start.
    case invalid

    public init(url: URL, expectedState: String) {
        guard url.scheme == AccountSite.callbackScheme, url.host == "auth",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            self = .invalid
            return
        }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        guard let state = value("state"), state == expectedState else {
            self = .invalid
            return
        }
        if let error = value("error") {
            self = .failed(error)
        } else if let token = value("token") {
            self = .token(token)
        } else if let code = value("code") {
            self = .code(code)
        } else {
            self = .invalid
        }
    }
}

/// The words for moving an App Store purchase between accounts. One purchase moves at most once a year.
public enum PremiumMoveText {
    public static let confirmTitle = "Move Premium to this account?"
    public static let confirmButton = "Move Premium"

    public static func confirmMessage(previousAccountEmailMasked: String?) -> String {
        let on = previousAccountEmailMasked.map { "This purchase is on \($0)." } ?? "This purchase is on another PasswordPie account."
        return "\(on) Moving it takes Premium from that account. A purchase can move to another account once a year."
    }

    public static func moved(previousAccountEmailMasked: String?) -> String {
        "Premium moved to this account. \(previousAccountEmailMasked ?? "The other account") no longer has Premium from this purchase."
    }

    public static func limited(nextAllowedAt: Date?, dateText: (Date) -> String) -> String {
        guard let nextAllowedAt else {
            return "This purchase moved to another account less than a year ago, so it cannot move again yet."
        }
        return "This purchase moved to another account less than a year ago. It can move again on \(dateText(nextAllowedAt))."
    }
}
