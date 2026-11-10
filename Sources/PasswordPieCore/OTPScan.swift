import CoreGraphics
import Foundation
import Vision

// Two-step QR codes: reading one, checking what it says, and finding the item it belongs to. A scanned code comes from a
// web page or a screenshot, so nothing here trusts it. Nothing here makes a code either: that stays behind `OneTimeCodes`.

/// A two-step code read from a QR code or an `otpauth://` link, checked and ready to store.
public struct ScannedOTP: Equatable, Sendable {
    /// Who the code is for, such as "GitHub". Empty when the link names nobody.
    public var issuer: String
    /// The account at the issuer, such as "ada@example.com". May be empty.
    public var account: String
    public var settings: OTPSettings
    /// The link to store in the item's `otp` field: `otpauth://totp/…` with only the parameters PasswordPie reads.
    public var uri: String
}

/// Why a scanned code was refused. Each has one sentence for the person who scanned it.
public enum OTPImportError: Error, Equatable, Sendable {
    case notOTPAuth
    case hotp
    case migration
    case badSecret
    /// The `digits` value as written.
    case digits(String)
    /// The `period` value as written.
    case period(String)
    /// The `algorithm` value as written.
    case algorithm(String)

    public var message: String {
        switch self {
        case .notOTPAuth:
            return "This QR code is not a two-step code. Two-step QR codes start with otpauth://."
        case .hotp:
            return "This is a counter-based (HOTP) code. PasswordPie makes time-based codes only."
        case .migration:
            return "This is a Google Authenticator export. Scan the QR code the website shows instead."
        case .badSecret:
            return "The secret in this code is missing or is not valid Base32."
        case .digits(let raw):
            return "This code asks for \(raw.isEmpty ? "no number of" : raw) digits. PasswordPie makes codes of 6 to 8 digits."
        case .period(let raw):
            return "This code's time step, \(raw.isEmpty ? "empty" : "\"\(raw)\""), is not a whole number of seconds above 0."
        case .algorithm(let raw):
            return "PasswordPie does not know the algorithm \"\(raw)\". It makes SHA1, SHA256 and SHA512 codes."
        }
    }
}

public enum OTPAuthImport {
    /// Checks a scanned or pasted link. Strict where `TOTP.parseOTPAuth` (stored items) is lenient: an unknown algorithm
    /// is refused rather than read as SHA1, because a wrong code is worse than none.
    public static func parse(_ raw: String) -> Result<ScannedOTP, OTPImportError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased() else {
            return .failure(.notOTPAuth)
        }
        if scheme == "otpauth-migration" { return .failure(.migration) }
        guard scheme == "otpauth" else { return .failure(.notOTPAuth) }
        switch components.host?.lowercased() {
        case "totp": break
        case "hotp": return .failure(.hotp)
        default: return .failure(.notOTPAuth)
        }
        let items = TOTP.firstValues(components.queryItems ?? [])
        guard let secretText = items["secret"], let secret = TOTP.base32Decode(secretText) else { return .failure(.badSecret) }
        var digits = 6
        if let text = items["digits"] {
            guard let value = Int(text.trimmingCharacters(in: .whitespaces)), (6...8).contains(value) else { return .failure(.digits(text)) }
            digits = value
        }
        var period = 30
        if let text = items["period"] {
            guard let value = Int(text.trimmingCharacters(in: .whitespaces)), value > 0 else { return .failure(.period(text)) }
            period = value
        }
        var algorithm = OTPAlgorithm.sha1
        if let text = items["algorithm"] {
            guard let value = OTPAlgorithm(rawValue: text.trimmingCharacters(in: .whitespaces).lowercased()) else { return .failure(.algorithm(text)) }
            algorithm = value
        }
        let label = components.path.hasPrefix("/") ? String(components.path.dropFirst()) : components.path
        var issuer = ""
        var account = label
        if let colon = label.firstIndex(of: ":") {
            issuer = String(label[..<colon])
            account = String(label[label.index(after: colon)...])
        }
        if let named = items["issuer"], !named.trimmingCharacters(in: .whitespaces).isEmpty { issuer = named }
        issuer = issuer.trimmingCharacters(in: .whitespacesAndNewlines)
        account = account.trimmingCharacters(in: .whitespacesAndNewlines)
        let settings = OTPSettings(secret: secret, digits: digits, period: period, algorithm: algorithm)
        return .success(ScannedOTP(issuer: issuer, account: account, settings: settings, uri: uri(issuer: issuer, account: account, settings: settings)))
    }

    /// The first two-step code among the texts of the QR codes in one picture. With none, the most telling refusal: a
    /// two-step link that was refused says more than a QR code for a web page. Nil when there were no QR codes at all.
    public static func firstScan(in payloads: [String]) -> Result<ScannedOTP, OTPImportError>? {
        var refusal: OTPImportError?
        for payload in payloads {
            switch parse(payload) {
            case .success(let scan):
                return .success(scan)
            case .failure(let error):
                if refusal == nil || refusal == .notOTPAuth { refusal = error }
            }
        }
        return refusal.map { .failure($0) }
    }

    static func uri(issuer: String, account: String, settings: OTPSettings) -> String {
        var parts = URLComponents()
        parts.scheme = "otpauth"
        parts.host = "totp"
        parts.path = "/" + (issuer.isEmpty ? account : "\(issuer):\(account)")
        var query = [URLQueryItem(name: "secret", value: TOTP.base32Encode(settings.secret))]
        if !issuer.isEmpty { query.append(URLQueryItem(name: "issuer", value: issuer)) }
        query.append(URLQueryItem(name: "period", value: String(settings.period)))
        query.append(URLQueryItem(name: "digits", value: String(settings.digits)))
        if settings.algorithm != .sha1 { query.append(URLQueryItem(name: "algorithm", value: settings.algorithm.rawValue.uppercased())) }
        parts.queryItems = query
        return parts.string ?? "otpauth://totp/?secret=\(TOTP.base32Encode(settings.secret))"
    }
}

/// Which items a scanned code probably belongs to.
public enum OTPScanMatch {
    /// Items on the page's site first, those whose username is the scanned account before the others. Then items whose title
    /// or website names the issuer, the account first again. Nothing else, and never the Recycle Bin.
    public static func candidates(in entries: [VaultEntry], issuer: String, account: String, pageURL: String?) -> [VaultEntry] {
        let site = pageURL.flatMap { BrowserSite(url: $0) }?.key
        let needle = squeezed(issuer)
        let wanted = account.trimmingCharacters(in: .whitespaces).lowercased()
        var ranked: [(entry: VaultEntry, tier: Int)] = []
        for entry in entries where !entry.trashed {
            let hosts = entryWebsites(entry).compactMap { BrowserSite(url: $0) }
            let sameAccount = !wanted.isEmpty && entry.username.trimmingCharacters(in: .whitespaces).lowercased() == wanted
            if let site, hosts.contains(where: { $0.key == site }) {
                ranked.append((entry, sameAccount ? 0 : 1))
            } else if needle.count >= 2, squeezed(entry.title).contains(needle) || hosts.contains(where: { $0.host.contains(needle) }) {
                ranked.append((entry, sameAccount ? 2 : 3))
            }
        }
        return ranked.sorted { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            let order = lhs.entry.title.localizedCaseInsensitiveCompare(rhs.entry.title)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.entry.id.uuidString < rhs.entry.id.uuidString
        }.map(\.entry)
    }

    private static func squeezed(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }
}

/// Reads QR codes in a picture with macOS's own Vision, on this Mac. Other barcode types are ignored.
public enum QRCodeReader {
    public static func payloads(in image: CGImage) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        var seen = Set<String>()
        return (request.results ?? []).compactMap(\.payloadStringValue).filter { seen.insert($0).inserted }
    }
}
