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

    public init(
        entries: [VaultEntry] = [],
        skipped: Int = 0,
        profileCount: Int = 0,
        failedProfiles: [String] = [],
        lastUsed: [UUID: Date] = [:]
    ) {
        self.entries = entries
        self.skipped = skipped
        self.profileCount = profileCount
        self.failedProfiles = failedProfiles
        self.lastUsed = lastUsed
    }
}

/// Size and modification time of Chrome's login stores. Unchanged files mean the passwords on disk are the ones already read.
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

    public init(files: [File] = []) {
        self.files = files
    }
}

public enum ChromeLogins {
    public static let groupName = "Chrome (live)"
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

    /// Login stores and their `-wal` and `-journal` files. Other Chrome files are left out, so a cookie write is not a password change.
    public static func storeSignature(root: URL = defaultRoot) -> ChromeStoreSignature {
        var files: [ChromeStoreSignature.File] = []
        for folder in profileFolders(root: root) {
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
        return ChromeStoreSignature(files: files)
    }

    private static func profileFolders(root: URL) -> [String] {
        let children = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return children.filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted { lhs, rhs in
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
        var seen = Set<UUID>()
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
                guard seen.insert(id).inserted else { continue }
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

    /// Chrome logins to show beside the database's own entries: one that the database already holds
    /// (same site, same account, same password) is hidden. A different password stays visible so the difference is not lost.
    public static func visible(_ live: [VaultEntry], against saved: [VaultEntry]) -> [VaultEntry] {
        var held = Set<String>()
        for entry in saved where !entry.trashed {
            held.insert(BrowserImport.matchKey(entry) + "\u{2}" + entry.password)
        }
        return live.filter { !held.contains(BrowserImport.matchKey($0) + "\u{2}" + $0.password) }
    }

    // MARK: Private

    private struct Row {
        var origin: String
        var username: String
        var passwordValue: Data
        var realm: String
        var lastUsed: Date?
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
        let sql = "SELECT origin_url, username_value, password_value, signon_realm, \(hasLastUsedColumn(db) ? "date_last_used" : "0") FROM logins WHERE blacklisted_by_user = 0"
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
                lastUsed: chromeDate(sqlite3_column_int64(statement, 4))
            ))
        }
        return rows
    }

    /// Chrome's `date_last_used` is microseconds since 1601-01-01, and 0 means never. Older Chrome has no such column.
    private static func chromeDate(_ microseconds: Int64) -> Date? {
        guard microseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(microseconds) / 1_000_000 - 11_644_473_600)
    }

    private static func hasLastUsedColumn(_ db: OpaquePointer?) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(logins)", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if text(statement, 1) == "date_last_used" { return true }
        }
        return false
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
}
#endif
