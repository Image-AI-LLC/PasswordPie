import Foundation

/// One login from a Credential Exchange export, reduced to what PasswordPie keeps.
/// The app layer fills this from the system types (macOS 26+), so this file and its tests need no new OS.
public struct ExchangedItem: Equatable, Sendable {
    public struct TOTPSecret: Equatable, Sendable {
        public var secret: Data
        public var period: Int
        public var digits: Int
        public var algorithm: String

        public init(secret: Data, period: Int, digits: Int, algorithm: String) {
            self.secret = secret
            self.period = period
            self.digits = digits
            self.algorithm = algorithm
        }
    }

    public var title: String
    public var urls: [String]
    public var username: String?
    public var password: String?
    public var totp: TOTPSecret?
    public var note: String?

    public init(
        title: String,
        urls: [String] = [],
        username: String? = nil,
        password: String? = nil,
        totp: TOTPSecret? = nil,
        note: String? = nil
    ) {
        self.title = title
        self.urls = urls
        self.username = username
        self.password = password
        self.totp = totp
        self.note = note
    }
}

extension BrowserImport {
    /// Turns exchanged logins into entries placed in the source's group. Items with no password are not logins and are skipped.
    public static func entries(fromExchange items: [ExchangedItem], source: BrowserImportSource) -> [VaultEntry] {
        items.compactMap { item in
            guard let password = item.password, !password.isEmpty else { return nil }
            var entry = VaultEntry(groupPath: [source.label], tags: source.label)
            let url = item.urls.first ?? ""
            let site = host(of: url)
            entry.title = item.title.isEmpty ? site : item.title
            entry.url = url
            entry.username = item.username ?? ""
            entry.password = password
            entry.notes = item.note ?? ""
            if let totp = item.totp, !totp.secret.isEmpty {
                entry.otp = TOTP.otpAuthURL(
                    secretBase32: TOTP.base32Encode(totp.secret),
                    title: entry.title,
                    username: entry.username,
                    period: totp.period,
                    digits: totp.digits,
                    algorithm: totp.algorithm
                )
            }
            return entry
        }
    }
}
