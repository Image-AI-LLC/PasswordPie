#if PP_DIRECT
import CommonCrypto
import CryptoKit
import Foundation
import SQLite3
import Security

// Direct-channel only. Package.swift leaves PP_DIRECT out of the App Store build, so none of this reaches the store binary.

public enum ChromeLoginsError: Error, Equatable, CustomStringConvertible {
    case noChrome
    case wrongKey
    case keychain(OSStatus)
    case database(String)
    /// macOS 27 denies another app's files (EPERM) and posts "Data Access Blocked" instead of asking.
    case accessDenied

    public var description: String {
        switch self {
        case .noChrome: return "Chrome's password store was not found on this Mac."
        case .wrongKey: return "Chrome's passwords could not be decrypted with the Chrome Safe Storage key."
        case .keychain(let status): return "Couldn't read the Chrome Safe Storage key from the keychain (\(status))."
        case .database(let message): return message
        case .accessDenied:
            return "macOS blocked PasswordPie from reading Chrome. Open Privacy & Security → Files & Folders → PasswordPie, and turn on Google Chrome. That notice calls Chrome's files data from other apps."
        }
    }
}

/// How Chrome on macOS protects saved passwords: the value is `v10` plus AES-128-CBC, keyed from the
/// "Chrome Safe Storage" keychain item with PBKDF2-HMAC-SHA1 (salt `saltysalt`, 1003 rounds).
public enum ChromeSafeStorage {
    static let salt = Data("saltysalt".utf8)
    static let iterations = 1003
    static let keyLength = 16
    static let version = Data("v10".utf8)
    /// 16 spaces.
    static let iv = Data(repeating: 0x20, count: 16)

    public static func deriveKey(password: Data) throws -> Data {
        try pbkdf2SHA1(password: password, salt: salt, iterations: iterations, length: keyLength)
    }

    static func pbkdf2SHA1(password: Data, salt: Data, iterations: Int, length: Int) throws -> Data {
        var output = Data(count: length)
        let status: Int32 = password.withUnsafeBytes { passwordRaw in
            salt.withUnsafeBytes { saltRaw in
                output.withUnsafeMutableBytes { outputRaw in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordRaw.bindMemory(to: Int8.self).baseAddress, password.count,
                        saltRaw.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), UInt32(iterations),
                        outputRaw.bindMemory(to: UInt8.self).baseAddress, length
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw ChromeLoginsError.database("Key derivation failed (\(status)).") }
        return output
    }

    public static func decrypt(_ blob: Data, key: Data) throws -> String {
        guard blob.starts(with: version) else {
            throw ChromeLoginsError.database("Unsupported password format.")
        }
        let cipher = Data(blob.dropFirst(version.count))
        guard !cipher.isEmpty, cipher.count % kCCBlockSizeAES128 == 0 else {
            throw ChromeLoginsError.database("Malformed password value.")
        }
        var plain = Data(count: cipher.count)
        var written = 0
        let status = plain.withUnsafeMutableBytes { plainRaw in
            cipher.withUnsafeBytes { cipherRaw in
                key.withUnsafeBytes { keyRaw in
                    iv.withUnsafeBytes { ivRaw in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyRaw.baseAddress, key.count, ivRaw.baseAddress,
                                cipherRaw.baseAddress, cipher.count, plainRaw.baseAddress, plainRaw.count, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess, let text = String(data: plain.prefix(written), encoding: .utf8) else {
            throw ChromeLoginsError.wrongKey
        }
        return text
    }

    /// The Safe Storage secret. macOS asks the user to allow this, so call it only after they turn the feature on.
    public static func keychainPassword() -> (status: OSStatus, password: Data?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Chrome Safe Storage",
            kSecAttrAccount as String: "Chrome",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, !data.isEmpty else { return (status == errSecSuccess ? errSecItemNotFound : status, nil) }
        return (status, data)
    }
}

public struct ChromeProfile: Equatable, Sendable {
    public var directoryName: String
    public var name: String
    public var directory: URL

    public init(directoryName: String, name: String, directory: URL) {
        self.directoryName = directoryName
        self.name = name
        self.directory = directory
    }
}

public struct ChromeLoginsResult: Sendable {
    public var entries: [VaultEntry]
    /// Passwords that were saved but could not be decrypted.
    public var skipped: Int
    public var profileCount: Int
    /// Display names of profiles that could not be read while another profile could.
    public var failedProfiles: [String]
    /// When Chrome last used each login (its `date_last_used`). Logins Chrome never used, or older Chrome without the column, are absent.
    public var lastUsed: [UUID: Date]
    /// Every decrypted row, including a second store's copy of a login. `entries` shows one value per login.
    public var rows: [ChromeRow]

    public init(
        entries: [VaultEntry] = [],
        skipped: Int = 0,
        profileCount: Int = 0,
        failedProfiles: [String] = [],
        lastUsed: [UUID: Date] = [:],
        rows: [ChromeRow] = []
    ) {
        self.entries = entries
        self.skipped = skipped
        self.profileCount = profileCount
        self.failedProfiles = failedProfiles
        self.lastUsed = lastUsed
        self.rows = rows
    }
}

/// Size and modification time of Chrome's login stores, plus each profile's display name.
/// Unchanged files and names mean the passwords already read are still current.
public struct ChromeStoreSignature: Equatable, Sendable {
    public struct File: Equatable, Sendable {
        public var relativePath: String
        public var byteCount: Int
        public var modifiedAt: TimeInterval

        public init(relativePath: String, byteCount: Int, modifiedAt: TimeInterval) {
            self.relativePath = relativePath
            self.byteCount = byteCount
            self.modifiedAt = modifiedAt
        }
    }

    public var files: [File]
    /// Folder name to the name Chrome shows. A rename leaves the login files untouched.
    public var profileNames: [String: String]

    public init(files: [File] = [], profileNames: [String: String] = [:]) {
        self.files = files
        self.profileNames = profileNames
    }
}

public enum ChromeLogins {
    public static let groupName = "Chrome (live)"
    public static let usernameFieldName = "Chrome username"
    static let storeNames = ["Login Data", "Login Data For Account"]

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
    }

    /// Every profile folder that has a login store, named as Chrome shows it. Chrome does not always create `Default`.
    public static func profiles(root: URL = defaultRoot) -> [ChromeProfile] {
        let names = profileNames(root: root)
        return profileFolders(root: root).compactMap { folder in
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            guard storeNames.contains(where: { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }) else { return nil }
            return ChromeProfile(directoryName: folder, name: names[folder] ?? folder, directory: directory)
        }
    }

    /// Login stores and their `-wal` and `-journal` files, plus profile display names.
    /// Other Chrome files are left out, so a cookie write is not a password change.
    /// Names come from the parsed `Local State` map, not that file's mtime, so unrelated Chrome settings do not force a read.
    public static func storeSignature(root: URL = defaultRoot) -> ChromeStoreSignature {
        var files: [ChromeStoreSignature.File] = []
        let knownNames = profileNames(root: root)
        var names: [String: String] = [:]
        for folder in profileFolders(root: root) {
            if let shown = knownNames[folder] { names[folder] = shown }
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            for store in storeNames {
                for suffix in ["", "-wal", "-journal"] {
                    let name = store + suffix
                    let url = directory.appendingPathComponent(name)
                    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                          let byteCount = values.fileSize,
                          let modified = values.contentModificationDate else { continue }
                    files.append(ChromeStoreSignature.File(
                        relativePath: "\(folder)/\(name)",
                        byteCount: byteCount,
                        modifiedAt: modified.timeIntervalSince1970
                    ))
                }
            }
        }
        return ChromeStoreSignature(files: files, profileNames: names)
    }

    /// Each folder once. `Default` can be a link to `Profile 1`, and reading both would show every password twice.
    /// A real folder keeps its name over a link to it, so ids follow the folder Chrome actually uses.
    private static func profileFolders(root: URL) -> [String] {
        let children = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let folders = children.filter { $0 == "Default" || $0.hasPrefix("Profile ") }
        func isLink(_ name: String) -> Bool {
            (try? root.appendingPathComponent(name).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        }
        var seen = Set<String>()
        let unique = (folders.filter { !isLink($0) } + folders.filter(isLink)).filter {
            seen.insert(root.appendingPathComponent($0).resolvingSymlinksInPath().path).inserted
        }
        return unique.sorted { lhs, rhs in
            if lhs == "Default" { return true }
            if rhs == "Default" { return false }
            return lhs.compare(rhs, options: .numeric) == .orderedAscending
        }
    }

    private static func profileNames(root: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("Local State")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] else { return [:] }
        var names: [String: String] = [:]
        for (folder, value) in cache {
            if let name = (value as? [String: Any])?["name"] as? String, !name.isEmpty { names[folder] = name }
        }
        return names
    }

    /// All profiles together. Throws only when nothing could be read; profiles that failed beside one that worked are listed in `failedProfiles`.
    public static func load(root: URL = defaultRoot, key: Data) throws -> ChromeLoginsResult {
        // A permission error must stay a permission error. `profiles` turns a failed list into "no Chrome".
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: root.path)
        } catch {
            if isAccessDenied(error) { throw ChromeLoginsError.accessDenied }
            throw ChromeLoginsError.noChrome
        }
        let profiles = profiles(root: root)
        guard !profiles.isEmpty else { throw ChromeLoginsError.noChrome }
        var combined = ChromeLoginsResult()
        var firstError: Error?
        var sawAccessDenied = false
        for profile in profiles {
            do {
                let part = try entries(in: profile, key: key)
                combined.entries += part.entries
                combined.rows += part.rows
                combined.lastUsed.merge(part.lastUsed) { max($0, $1) }
                combined.skipped += part.skipped
                combined.profileCount += 1
            } catch {
                if isAccessDenied(error) { sawAccessDenied = true }
                firstError = firstError ?? error
                combined.failedProfiles.append(profile.name)
            }
        }
        if combined.profileCount == 0, sawAccessDenied { throw ChromeLoginsError.accessDenied }
        if combined.profileCount == 0, let firstError { throw firstError }
        // Search reads the time under whichever site the account's row carries, so every site holds the latest use.
        for account in accounts(in: combined.entries) where account.count > 1 {
            guard let latest = account.compactMap({ combined.lastUsed[$0.id] }).max() else { continue }
            for login in account { combined.lastUsed[login.id] = latest }
        }
        return combined
    }

    /// macOS 27 returns EPERM for another app's files, and FileManager surfaces that as Cocoa 257 or 513.
    static func isAccessDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EPERM) || ns.code == Int(EACCES)) { return true }
        if ns.domain == NSCocoaErrorDomain
            && (ns.code == NSFileReadNoPermissionError || ns.code == NSFileWriteNoPermissionError) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isAccessDenied(underlying) }
        return false
    }

    /// Reads one profile's two login stores from private copies, so Chrome's locks are never contended and its files are never written.
    public static func entries(in profile: ChromeProfile, key: Data) throws -> ChromeLoginsResult {
        var result = ChromeLoginsResult()
        var shown: [UUID: (index: Int, modified: Date?)] = [:]
        var attempted = 0
        var decrypted = 0
        for store in storeNames {
            let source = profile.directory.appendingPathComponent(store)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let rows = try withPrivateCopy(of: source) { try readRows(at: $0) }
            for row in rows {
                attempted += 1
                guard let password = try? ChromeSafeStorage.decrypt(row.passwordValue, key: key) else {
                    result.skipped += 1
                    continue
                }
                decrypted += 1
                let id = stableID(profile: profile.directoryName, realm: row.realm, origin: row.origin, username: row.username)
                if let used = row.lastUsed, used > (result.lastUsed[id] ?? .distantPast) { result.lastUsed[id] = used }
                result.rows.append(ChromeRow(loginID: id, password: password, modifiedAt: row.passwordModified, isForm: row.isForm))
                if let existing = shown[id] {
                    // The list shows one value for a login that both stores hold: the one changed last.
                    if let modified = row.passwordModified, modified > (existing.modified ?? .distantPast) {
                        result.entries[existing.index].password = password
                        shown[id] = (existing.index, modified)
                    }
                    continue
                }
                shown[id] = (result.entries.count, row.passwordModified)
                var entry = VaultEntry(id: id, groupPath: groupPath(for: profile))
                entry.title = BrowserImport.host(of: row.origin).isEmpty ? row.origin : BrowserImport.host(of: row.origin)
                entry.url = row.origin
                entry.username = row.username
                entry.password = password
                result.entries.append(entry)
            }
        }
        if attempted > 0, decrypted == 0 { throw ChromeLoginsError.wrongKey }
        result.profileCount = 1
        return result
    }

    /// The list to show: one entry per account. Chrome is only read, so nothing here is written back.
    /// Logins with the same username and password on one domain are one account, as Chrome's own password list has it.
    /// A login joins a saved entry with its own id, then one with the same site, username and password, then the one saved entry
    /// it could replace the password of. The rest of its account comes along. An account with no such entry joins a copy saved
    /// from Chrome with the same site and password, which is a username renamed in Chrome. A different password on anything
    /// else stays its own row, so it can never overwrite another account. An account that joins nothing is listed as it is.
    public static func combined(saved: [VaultEntry], live: [VaultEntry], rules: ChromeJoinRules = ChromeJoinRules()) -> [VaultEntry] {
        view(saved: saved, live: live, rules: rules).entries
    }

    public struct View: Equatable, Sendable {
        public var entries: [VaultEntry]
        /// Rows with anything from Chrome in them. These carry the badge.
        public var fromChrome: Set<UUID>
    }

    public static func view(saved: [VaultEntry], live: [VaultEntry], rules: ChromeJoinRules = ChromeJoinRules()) -> View {
        guard !live.isEmpty else { return View(entries: saved, fromChrome: []) }
        let placed = placement(saved: saved, live: live, rules: rules)
        var shown = saved
        var fromChrome = Set(placed.lone.map(\.id))
        for (index, logins) in placed.joined {
            addChromeFields(logins, to: &shown[index])
            fromChrome.insert(saved[index].id)
        }
        return View(entries: shown + placed.lone, fromChrome: fromChrome)
    }

    struct Placement {
        var joined: [Int: [VaultEntry]]
        var lone: [VaultEntry]
        var writingCounts: [String: Int]
    }

    static func placement(saved: [VaultEntry], live: [VaultEntry], rules: ChromeJoinRules) -> Placement {
        var byID: [UUID: Int] = [:]
        var byAccount: [String: [Int]] = [:]
        var writingCounts: [String: Int] = [:]
        for (index, entry) in saved.enumerated() where !entry.trashed {
            if byID[entry.id] == nil { byID[entry.id] = index }
            for key in accountKeys(entry) { byAccount[key, default: []].append(index) }
            for key in writingKeys(entry) { writingCounts[key, default: 0] += 1 }
        }
        func savedAccount(for login: VaultEntry) -> Int? {
            let candidates = byAccount[BrowserImport.matchKey(login)] ?? []
            if let samePassword = candidates.first(where: { saved[$0].password == login.password }) { return samePassword }
            let same = candidates.filter { isSameAccountForWriting(saved[$0], login, among: writingCounts, rules: rules) }
            return same.count == 1 ? same[0] : nil
        }
        var joined: [Int: [VaultEntry]] = [:]
        var unmatched: [[VaultEntry]] = []
        for account in accounts(in: live) {
            var home = account.lazy.compactMap { byID[$0.id] }.first
            var rest: [VaultEntry] = []
            for login in account {
                if let index = byID[login.id] ?? savedAccount(for: login) {
                    joined[index, default: []].append(login)
                    home = home ?? index
                } else {
                    rest.append(login)
                }
            }
            if let home {
                joined[home, default: []] += rest
            } else {
                unmatched.append(account)
            }
        }
        var lone: [VaultEntry] = []
        if !unmatched.isEmpty {
            var renameCandidates: [String: [Int]] = [:]
            for (index, entry) in saved.enumerated() where !entry.trashed && joined[index] == nil && isChromeCopy(entry) {
                let websites = [entry.url] + EntryMerge.otherWebsites(entry).map(\.value)
                for website in websites {
                    renameCandidates[renameKey(website: website, password: entry.password), default: []].append(index)
                }
            }
            for account in unmatched {
                let renamed = account.lazy.compactMap { login in
                    renameCandidates[renameKey(website: login.url, password: login.password)]?.first { joined[$0] == nil }
                }.first
                if let renamed {
                    joined[renamed] = account
                } else {
                    lone.append(entry(forAccount: account))
                }
            }
        }
        return Placement(joined: joined, lone: lone, writingCounts: writingCounts)
    }

    /// One live saved entry, the same case-sensitive username, the same scheme, host and port, and an ordinary form login.
    static func isSameAccountForWriting(_ saved: VaultEntry, _ login: VaultEntry, among counts: [String: Int], rules: ChromeJoinRules) -> Bool {
        guard !rules.notForms.contains(login.id), !rules.readOnly.contains(saved.id), !EntryMerge.keepsSeparate(saved),
              !login.username.isEmpty, saved.username == login.username, let origin = writingOrigin(login.url) else { return false }
        let key = origin + "\u{1}" + login.username
        return writingKeys(saved).contains(key) && counts[key] == 1
    }

    /// Where a password write may land: each of the entry's sites with its exact username.
    private static func writingKeys(_ entry: VaultEntry) -> [String] {
        guard !entry.username.isEmpty else { return [] }
        let origins = ([entry.url] + EntryMerge.otherWebsites(entry).map(\.value)).compactMap(writingOrigin)
        return Array(Set(origins)).map { $0 + "\u{1}" + entry.username }
    }

    /// Scheme, host and port. `www.` is part of the host here, unlike in search and in showing one row.
    static func writingOrigin(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: trimmed), let scheme = parts.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        return "\(scheme)://\(host):\(parts.port ?? (scheme == "https" ? 443 : 80))"
    }

    /// The part of a host someone registers: `corp.example` for `gitlab.corp.example`, `bbc.co.uk` for `shop.bbc.co.uk`.
    /// This is an approximation of the public suffix list. A miss shows two rows or one row listing both sites, and never changes a password.
    static func registrableDomain(of host: String) -> String {
        let labels = host.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
        guard labels.count > 2, !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }), !host.contains(":") else { return host }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        let tld = labels[labels.count - 1]
        let keepsThree = sharedHostingDomains.contains(lastTwo)
            || (tld.count == 2 && countrySecondLevels.contains(labels[labels.count - 2]))
        return keepsThree ? labels.suffix(3).joined(separator: ".") : lastTwo
    }

    // MARK: Private

    private static let countrySecondLevels: Set<String> = ["ac", "co", "com", "edu", "go", "gob", "gov", "gouv", "mil", "ne", "net", "or", "org"]

    /// Every customer of these has a site of their own under the same two labels.
    private static let sharedHostingDomains: Set<String> = [
        "amazonaws.com", "azurewebsites.net", "blogspot.com", "cloudfront.net", "firebaseapp.com", "github.io", "gitlab.io", "herokuapp.com",
        "myshopify.com", "netlify.app", "ngrok-free.app", "ngrok.io", "notion.site", "pages.dev", "vercel.app", "web.app", "workers.dev"
    ]

    private struct AccountKey: Hashable {
        var place: String
        var username: String
        var password: String
    }

    /// A shared login needs a username and a password to say it is one account across sites. Otherwise only the same site is.
    /// `websiteHost` is nil for anything but http and https, so an app login stays with its own origin.
    private static func accountKey(_ login: VaultEntry) -> AccountKey {
        let username = login.username.lowercased()
        guard let host = websiteHost(forWebsite: login.url) else {
            return AccountKey(place: login.url.lowercased(), username: username, password: login.password)
        }
        let isShared = !username.isEmpty && !login.password.isEmpty
        return AccountKey(place: isShared ? registrableDomain(of: host) : host, username: username, password: login.password)
    }

    /// Chrome's logins by account, in the order each account first appears. Each one starts with its first site by name,
    /// so an account's row keeps its id however Chrome orders its rows.
    private static func accounts(in live: [VaultEntry]) -> [[VaultEntry]] {
        var positions: [AccountKey: Int] = [:]
        var accounts: [[VaultEntry]] = []
        for login in live {
            let key = accountKey(login)
            if let position = positions[key] {
                accounts[position].append(login)
            } else {
                positions[key] = accounts.count
                accounts.append([login])
            }
        }
        return accounts.map { account in
            guard account.count > 1 else { return account }
            return account.map { (login: $0, host: BrowserImport.host(of: $0.url)) }.sorted { lhs, rhs in
                if lhs.host != rhs.host { return lhs.host < rhs.host }
                let lhsSecure = lhs.login.url.lowercased().hasPrefix("https://")
                let rhsSecure = rhs.login.url.lowercased().hasPrefix("https://")
                if lhsSecure != rhsSecure { return lhsSecure }
                if lhs.login.url != rhs.login.url { return lhs.login.url < rhs.login.url }
                return lhs.login.id.uuidString < rhs.login.id.uuidString
            }.map(\.login)
        }
    }

    /// The row for an account no saved entry holds. Several sites are named for their domain.
    private static func entry(forAccount account: [VaultEntry]) -> VaultEntry {
        var entry = account[0]
        addChromeFields(Array(account.dropFirst()), to: &entry)
        if !EntryMerge.otherWebsites(entry).isEmpty, let host = websiteHost(forWebsite: entry.url) {
            entry.title = registrableDomain(of: host)
        }
        return entry
    }

    private static func isChromeCopy(_ entry: VaultEntry) -> Bool {
        entry.tagList.contains { $0.caseInsensitiveCompare(BrowserImportSource.chrome.label) == .orderedSame }
    }

    private static func renameKey(website: String, password: String) -> String {
        BrowserImport.host(of: website) + "\u{1}" + password
    }

    /// Where a saved entry can match a login: its main place, and each of its other websites.
    private static func accountKeys(_ entry: VaultEntry) -> [String] {
        var keys = [BrowserImport.matchKey(entry)]
        let username = entry.username.lowercased()
        for website in EntryMerge.otherWebsites(entry) {
            let key = BrowserImport.host(of: website.value) + "\u{1}" + username
            if !keys.contains(key) { keys.append(key) }
        }
        return keys
    }

    private static func addChromeFields(_ logins: [VaultEntry], to entry: inout VaultEntry) {
        var taken = Set(entry.fields.map(\.key))
        var usernames = [entry.username]
        var hosts = Set(([entry.url] + EntryMerge.otherWebsites(entry).map(\.value)).map(BrowserImport.host(of:)))
        func add(_ value: String, named base: String, protected: Bool, to entry: inout VaultEntry) {
            var key = base
            var number = 2
            while !taken.insert(key).inserted {
                key = "\(base) (\(number))"
                number += 1
            }
            entry.fields.append(VaultField(key: key, value: value, protected: protected))
        }
        for login in logins {
            if !login.url.isEmpty, hosts.insert(BrowserImport.host(of: login.url)).inserted {
                add(login.url, named: "URL", protected: false, to: &entry)
            }
            if !login.username.isEmpty, !usernames.contains(where: { $0.caseInsensitiveCompare(login.username) == .orderedSame }) {
                usernames.append(login.username)
                add(login.username, named: usernameFieldName, protected: false, to: &entry)
            }
        }
    }

    private struct Row {
        var origin: String
        var username: String
        var passwordValue: Data
        var realm: String
        var lastUsed: Date?
        var passwordModified: Date?
        /// Chrome's `scheme` column. 0 is an HTML form. An older store without it reads as -1.
        var scheme: Int32

        var isForm: Bool {
            scheme == 0 && (realm.hasPrefix("https://") || realm.hasPrefix("http://"))
        }
    }

    private static func groupPath(for profile: ChromeProfile) -> [String] {
        [groupName, profile.name]
    }

    private static func stableID(profile: String, realm: String, origin: String, username: String) -> UUID {
        let digest = SHA256.hash(data: Data(["chrome-live", profile, realm, origin, username].joined(separator: "\u{1}").utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Copies the database and its `-wal` and `-journal` files to a private temporary folder, runs `body` on the copy, then removes the folder.
    /// A failure to remove the copy is an error: it holds encrypted passwords and must not be left behind silently.
    private static func withPrivateCopy<T>(of database: URL, _ body: (URL) throws -> T) throws -> T {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appendingPathComponent("passwordpie-chrome-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var outcome: Result<T, Error>
        do {
            for suffix in ["", "-wal", "-journal"] {
                let from = URL(fileURLWithPath: database.path + suffix)
                guard fileManager.fileExists(atPath: from.path) else { continue }
                try fileManager.copyItem(at: from, to: folder.appendingPathComponent(database.lastPathComponent + suffix))
            }
            outcome = .success(try body(folder.appendingPathComponent(database.lastPathComponent)))
        } catch {
            outcome = .failure(error)
        }
        do {
            try fileManager.removeItem(at: folder)
        } catch {
            throw ChromeLoginsError.database("Couldn't remove the temporary copy of Chrome's password store at \(folder.path).")
        }
        return try outcome.get()
    }

    /// The copy is opened read-write only so SQLite can replay the copied write-ahead log; the original is never opened.
    private static func readRows(at copy: URL) throws -> [Row] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw ChromeLoginsError.database("Couldn't open Chrome's password store.")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let columns = columnNames(db)
        let lastUsed = columns.contains("date_last_used") ? "date_last_used" : "0"
        let modified = columns.contains("date_password_modified") ? "date_password_modified" : "0"
        let scheme = columns.contains("scheme") ? "scheme" : "-1"
        let sql = "SELECT origin_url, username_value, password_value, signon_realm, \(lastUsed), \(modified), \(scheme) FROM logins WHERE blacklisted_by_user = 0"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ChromeLoginsError.database("Chrome's password store has an unexpected layout.")
        }
        defer { sqlite3_finalize(statement) }
        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw ChromeLoginsError.database("Couldn't read Chrome's password store.") }
            let length = Int(sqlite3_column_bytes(statement, 2))
            guard length > 0, let bytes = sqlite3_column_blob(statement, 2) else { continue }
            rows.append(Row(
                origin: text(statement, 0),
                username: text(statement, 1),
                passwordValue: Data(bytes: bytes, count: length),
                realm: text(statement, 3),
                lastUsed: chromeDate(sqlite3_column_int64(statement, 4)),
                passwordModified: chromeDate(sqlite3_column_int64(statement, 5)),
                scheme: sqlite3_column_int(statement, 6)
            ))
        }
        return rows
    }

    /// Chrome's dates are microseconds since 1601-01-01, and 0 means never. Older Chrome has no such columns.
    private static func chromeDate(_ microseconds: Int64) -> Date? {
        guard microseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(microseconds) / 1_000_000 - 11_644_473_600)
    }

    private static func columnNames(_ db: OpaquePointer?) -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(logins)", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW { names.insert(text(statement, 1)) }
        return names
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
}
#endif
