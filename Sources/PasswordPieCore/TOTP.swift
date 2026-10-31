import Foundation
import CryptoKit

public struct OTPSettings: Equatable, Sendable {
    public var secret: Data
    public var digits: Int
    public var period: Int
    public var algorithm: OTPAlgorithm

    public init(secret: Data, digits: Int = 6, period: Int = 30, algorithm: OTPAlgorithm = .sha1) {
        self.secret = secret
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
    }
}

public enum OTPAlgorithm: String, Sendable, Equatable {
    case sha1
    case sha256
    case sha512
}

public enum TOTP {
    public static func parse(entry: VaultEntry) -> OTPSettings? {
        if let otp = entry.fields.first(where: { $0.key.caseInsensitiveCompare("otp") == .orderedSame })?.value,
           let settings = parseOTPAuth(otp) {
            return settings
        }
        let secretText = field(entry, "TimeOtp-Secret-Base32") ?? field(entry, "TOTP Seed")
        guard let secretText, let secret = base32Decode(secretText.filter { !$0.isWhitespace }) else {
            if let legacy = field(entry, "TOTP Settings") {
                return parseLegacy(legacy, secret: field(entry, "TOTP Seed"))
            }
            return nil
        }
        let algorithm = OTPAlgorithm(rawValue: (field(entry, "TimeOtp-Algorithm") ?? "SHA1").lowercased()) ?? .sha1
        let digits = Int(field(entry, "TimeOtp-Length") ?? "") ?? 6
        let period = Int(field(entry, "TimeOtp-Period") ?? "") ?? 30
        return OTPSettings(secret: secret, digits: digits, period: max(period, 1), algorithm: algorithm)
    }

    public static func code(settings: OTPSettings, at date: Date = Date()) -> String {
        let counter = UInt64(date.timeIntervalSince1970) / UInt64(max(settings.period, 1))
        return code(settings: settings, counter: counter)
    }

    public static func code(settings: OTPSettings, counter: UInt64) -> String {
        var bigEndian = counter.bigEndian
        let message = Data(bytes: &bigEndian, count: 8)
        let mac: Data
        let key = SymmetricKey(data: settings.secret)
        switch settings.algorithm {
        case .sha1:
            mac = Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256:
            mac = Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512:
            mac = Data(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }
        let offset = Int(mac[mac.count - 1] & 0x0f)
        let binary = (UInt32(mac[offset]) & 0x7f) << 24
            | UInt32(mac[offset + 1]) << 16
            | UInt32(mac[offset + 2]) << 8
            | UInt32(mac[offset + 3])
        let digits = min(max(settings.digits, 6), 8)
        let modulus = UInt32(pow10(digits))
        let value = binary % modulus
        return String(format: "%0*u", digits, value)
    }

    public static func otpAuthURL(secretBase32: String, title: String, username: String) -> String {
        let label = [title, username].filter { !$0.isEmpty }.joined(separator: ":")
        var parts = URLComponents()
        parts.scheme = "otpauth"
        parts.host = "totp"
        parts.path = "/" + label
        parts.queryItems = [
            URLQueryItem(name: "secret", value: secretBase32.filter { !$0.isWhitespace }.uppercased()),
            URLQueryItem(name: "issuer", value: title),
            URLQueryItem(name: "period", value: "30"),
            URLQueryItem(name: "digits", value: "6")
        ]
        return parts.string ?? "otpauth://totp?secret=\(secretBase32)"
    }

    public static func parseOTPAuth(_ raw: String) -> OTPSettings? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "otpauth" else {
            return nil
        }
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") })
        guard let secretText = items["secret"], let secret = base32Decode(secretText) else {
            return nil
        }
        let digits = Int(items["digits"] ?? "") ?? 6
        let period = Int(items["period"] ?? "") ?? Int(items["step"] ?? "") ?? 30
        let algorithm = OTPAlgorithm(rawValue: (items["algorithm"] ?? "sha1").lowercased()) ?? .sha1
        return OTPSettings(secret: secret, digits: digits, period: max(period, 1), algorithm: algorithm)
    }

    public static func base32Decode(_ text: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var values: [UInt8] = []
        for character in text.uppercased().filter({ $0 != "=" && !$0.isWhitespace }) {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            values.append(UInt8(alphabet.distance(from: alphabet.startIndex, to: index)))
        }
        if values.isEmpty { return nil }
        var output = Data()
        var buffer = 0
        var bits = 0
        for value in values {
            buffer = (buffer << 5) | Int(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((buffer >> bits) & 0xff))
            }
        }
        return output
    }
}

private func field(_ entry: VaultEntry, _ key: String) -> String? {
    entry.fields.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
}

private func parseLegacy(_ settings: String, secret: String?) -> OTPSettings? {
    guard let secret, let data = TOTP.base32Decode(secret) else { return nil }
    let pieces = settings.split(separator: ";").map(String.init)
    let period = pieces.count > 0 ? Int(pieces[0]) ?? 30 : 30
    let digits = pieces.count > 1 ? Int(pieces[1]) ?? 6 : 6
    return OTPSettings(secret: data, digits: digits, period: max(period, 1))
}

private func pow10(_ digits: Int) -> Int {
    var value = 1
    for _ in 0..<digits { value *= 10 }
    return value
}
