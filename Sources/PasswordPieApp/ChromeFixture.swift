#if DEBUG && PP_DIRECT
import Foundation
import PasswordPieCore

/// Screenshot hook: a JSON list of logins standing in for Chrome, so a debug run never touches the keychain or Chrome's files.
/// `[{"site": "https://github.com", "user": "ann", "password": "x", "hoursAgo": 48}]`. `hoursAgo` missing means no date.
enum ChromeFixture {
    static var path: String? { ProcessInfo.processInfo.environment["PASSWORDPIE_CHROME_FIXTURE"] }

    private struct Login: Decodable {
        var site: String
        var user: String
        var password: String
        var hoursAgo: Double?
    }

    static func source() -> ChromeSnapshotSource? {
        guard let path else { return nil }
        return ChromeSnapshotSource(
            signature: { ChromeStoreSignature() },
            load: { _ in
                let logins = try JSONDecoder().decode([Login].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                var result = ChromeLoginsResult(profileCount: 1)
                for login in logins {
                    var entry = VaultEntry(groupPath: [ChromeLogins.groupName, "Fixture"])
                    entry.title = websiteHost(forWebsite: login.site) ?? login.site
                    entry.url = login.site
                    entry.username = login.user
                    entry.password = login.password
                    result.entries.append(entry)
                    let date = login.hoursAgo.map { Date().addingTimeInterval(-$0 * 3_600) }
                    result.rows.append(ChromeRow(loginID: entry.id, password: login.password, modifiedAt: date, isForm: true))
                }
                return (Data(repeating: 1, count: 16), result)
            }
        )
    }
}
#endif
