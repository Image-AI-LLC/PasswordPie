import CryptoKit
import Foundation

// The Premium entitlement token that passwordpie.com issues to a signed-in account. The app checks it before a two-step
// code goes to the browser. The rules are in docs/ACCOUNTS.md, "The entitlement token".
// A token is never logged and never written to disk.

/// What a good token says.
public struct Entitlement: Equatable, Sendable {
    /// The account's user id on passwordpie.com.
    public var subject: String?
    /// `lifetime`, `yearly` or `key`, as the site said.
    public var plan: String?
    public var expiresAt: Date

    public init(subject: String?, plan: String?, expiresAt: Date) {
        self.subject = subject
        self.plan = plan
        self.expiresAt = expiresAt
    }
}

/// Why a token was refused. Only tests read it; the bridge says nothing about the reason.
public enum EntitlementError: Error, Equatable, Sendable {
    case malformed
    case unsupportedAlgorithm
    case badKey
    case badSignature
    case wrongIssuer
    case wrongAudience
    case expired
    case notYetValid
    case notPremium
}

/// A compact JWS signed with Ed25519 (`alg: EdDSA`, RFC 8037), shared by the app's own account and the browser's.
public enum EntitlementToken {
    public static let issuer = "https://passwordpie.com"
    public static let audience = "passwordpie-app"
    /// The longest token accepted, in bytes. Real ones are a few hundred.
    public static let maxLength = 4096
    /// How far ahead of this Mac's clock the site's may run.
    public static let clockSkew: TimeInterval = 300

    /// passwordpie.com's key (`kid: pp-1`), raw 32 bytes. **Empty until the site's worker hands over the production public
    /// key** (docs/ACCOUNTS.md, "Keys"): until then release builds trust no token.
    public static let publicKey = Data()

    /// The test key (`kid: pp-test`). Its private half is public in `extension/dev/test-key.json`, for the mock site.
    public static let testPublicKey = Data(base64URL: "0HFLn6glzMnKkdA6-y2G5E_51nQEfbrAa4Mc-fK-5Ro")!

    /// The keys this build trusts: the site's, and in debug or `make install` builds (`PP_DEV_EXTENSION`) also the test
    /// key. A release build that trusted it would let anyone mint Premium.
    public static var trustedKeys: [Data] {
        var keys = publicKey.isEmpty ? [] : [publicKey]
        #if DEBUG || PP_DEV_EXTENSION
        keys.append(testPublicKey)
        #endif
        return keys
    }

    /// The token's claims when it is good at `now` and signed with `publicKey`, nil otherwise.
    public static func verify(_ jwt: String, now: Date, publicKey: Data = EntitlementToken.publicKey) -> Entitlement? {
        try? check(jwt, now: now, publicKey: publicKey).get()
    }

    /// `verify` against every key in `trustedKeys`. What the bridge uses.
    public static func verifyTrusted(_ jwt: String?, now: Date) -> Entitlement? {
        guard let jwt else { return nil }
        for key in trustedKeys {
            if let entitlement = verify(jwt, now: now, publicKey: key) { return entitlement }
        }
        return nil
    }

    /// `verify` with the reason it failed.
    public static func check(_ jwt: String, now: Date, publicKey: Data) -> Result<Entitlement, EntitlementError> {
        guard jwt.utf8.count <= maxLength else { return .failure(.malformed) }
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = Data(base64URL: parts[0]),
              let claimsData = Data(base64URL: parts[1]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any] else {
            return .failure(.malformed)
        }
        guard header["alg"] as? String == "EdDSA" else { return .failure(.unsupportedAlgorithm) }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return .failure(.badKey) }
        guard let signature = Data(base64URL: parts[2]) else { return .failure(.malformed) }
        // The signed bytes are the two parts exactly as sent, not a re-encoding of them.
        guard key.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)) else { return .failure(.badSignature) }

        guard let claims = try? JSONSerialization.jsonObject(with: claimsData) as? [String: Any] else { return .failure(.malformed) }
        guard claims["iss"] as? String == issuer else { return .failure(.wrongIssuer) }
        let audiences: [String]
        switch claims["aud"] {
        case let one as String: audiences = [one]
        case let many as [Any]: audiences = many.compactMap { $0 as? String }
        default: audiences = []
        }
        guard audiences.contains(audience) else { return .failure(.wrongAudience) }
        guard let exp = seconds(claims["exp"]) else { return .failure(.malformed) }
        let expiresAt = Date(timeIntervalSince1970: exp)
        guard now < expiresAt else { return .failure(.expired) }
        for name in ["iat", "nbf"] {
            guard let value = claims[name] else { continue }
            guard let seconds = seconds(value) else { return .failure(.malformed) }
            if Date(timeIntervalSince1970: seconds) > now.addingTimeInterval(clockSkew) { return .failure(.notYetValid) }
        }
        // JSONSerialization reads `true` as an NSNumber that is also 1; only a real boolean counts.
        guard let premium = claims["premium"] as? NSNumber, CFGetTypeID(premium) == CFBooleanGetTypeID(), premium.boolValue else {
            return .failure(.notPremium)
        }
        return .success(Entitlement(subject: claims["sub"] as? String, plan: claims["plan"] as? String, expiresAt: expiresAt))
    }

    /// A NumericDate: seconds since 1970, a JSON number and not a boolean.
    private static func seconds(_ value: Any?) -> TimeInterval? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let seconds = number.doubleValue
        return seconds.isFinite ? seconds : nil
    }
}

public extension Data {
    /// Unpadded base64url (RFC 4648 §5), as JOSE writes it. Padding or any other character gives nil.
    init?<S: StringProtocol>(base64URL text: S) {
        guard text.utf8.allSatisfy({ byte in
            (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x5F
        }) else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        if base64.count % 4 == 1 { return nil }
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
