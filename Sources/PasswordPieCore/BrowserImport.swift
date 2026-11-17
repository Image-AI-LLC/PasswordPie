import Foundation

/// Where an exported password list came from. Each source owns one group and one tag in the KeePass database.
public enum BrowserImportSource: String, CaseIterable, Sendable {
    case chrome
    case applePasswords
    case firefox
    case edge
    case brave
    case onePassword
    case bitwarden
    case protonPass
    case lastPass
    case dashlane
    /// Any other app, as a CSV file whose first row names its columns.
    case csv

    /// Used as the group name and as the tag that marks entries this import manages.
    public var label: String {
        switch self {
        case .chrome: return "Chrome"
        case .applePasswords: return "Apple Passwords"
        case .firefox: return "Firefox"
        case .edge: return "Edge"
        case .brave: return "Brave"
        case .onePassword: return "1Password"
        case .bitwarden: return "Bitwarden"
        case .protonPass: return "Proton Pass"
        case .lastPass: return "LastPass"
        case .dashlane: return "Dashlane"
        case .csv: return "Imported"
        }
    }

    /// A browser, or Apple Passwords, exports its whole list every time, so a site missing from the next export was
    /// deleted there. A password manager often exports one vault or folder, so a missing item means nothing.
    public var exportsWholeList: Bool {
        switch self {
        case .chrome, .applePasswords, .firefox, .edge, .brave: return true
        case .onePassword, .bitwarden, .protonPass, .lastPass, .dashlane, .csv: return false
        }
    }

    /// A password manager's folders and vaults become groups inside the source's own. A browser has none.
    public var keepsFolders: Bool { !exportsWholeList && self != .csv }
}

/// What was read from an export, before any of it is in the database.
public struct ImportedFile: Equatable, Sendable {
    public var entries: [VaultEntry]
    /// Anyone who has the file can read the passwords in it, so it should not stay on disk.
    public var plainText: Bool

    public init(entries: [VaultEntry], plainText: Bool) {
        self.entries = entries
        self.plainText = plainText
    }
}

public struct BrowserImportSummary: Equatable, Sendable {
    public var added: Int
    public var updated: Int
    public var unchanged: Int
    public var removed: Int

    public init(added: Int = 0, updated: Int = 0, unchanged: Int = 0, removed: Int = 0) {
        self.added = added
        self.updated = updated
        self.unchanged = unchanged
        self.removed = removed
    }
}

public enum BrowserImport {
    /// Reads a Chrome or Apple Passwords CSV export into entries placed in the source's group.
    public static func entries(fromCSV data: Data, source: BrowserImportSource) throws -> [VaultEntry] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else {
            throw VaultOpenError.invalid("The CSV file is not text.")
        }
        guard let header = parseCSV(text).first else {
            throw VaultOpenError.invalid("The CSV file is empty.")
        }
        guard csvNamesPassword(header) else {
            throw VaultOpenError.invalid("This file has no Password column, so it is not a password export.")
        }
        let placed = place(try loadCSV(data).entries, source: source)
        guard !placed.isEmpty else {
            throw VaultOpenError.invalid("The export has no passwords in it.")
        }
        return placed
    }

    /// Reads an export of any kind the source hands out: a CSV, a ZIP that holds one, a 1Password, Bitwarden or Proton
    /// Pass file. `VaultOpenError.wrongPassword` with an empty password means the file is protected and needs one.
    public static func read(_ url: URL, source: BrowserImportSource, password: String = "") throws -> ImportedFile {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw VaultOpenError.invalid("The file is no longer there.")
        }
        if isDirectory.boolValue {
            guard url.pathExtension.lowercased() == "opvault" else {
                throw VaultOpenError.invalid("Choose the exported file, not a folder.")
            }
            try expect(.onePassword, on: source)
            let vault = try loadOpVault(directory: url, password: password)
            return try imported(vault.entries, source: source, plainText: false)
        }
        return try read(data: try Data(contentsOf: url), source: source, password: password)
    }

    static func read(data: Data, source: BrowserImportSource, password: String = "") throws -> ImportedFile {
        // A slice keeps its parent's indices. Offsets below start at 0.
        let data = Data(data)
        if data.count >= 4, readU32LE(data, 0) == 0x9AA2D903 {
            throw VaultOpenError.invalid("This is a KeePass database. PasswordPie opens it as it is: choose Open Database… instead of importing it.")
        }
        if data.count >= 4, readU32LE(data, 0) == 0x04034b50 {
            return try read(zip: data, source: source, password: password)
        }
        // Past spaces, line ends and a UTF-8 byte order mark.
        let first = data.first { ![0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF].contains($0) }
        if first == UInt8(ascii: "{") {
            return try read(json: data, source: source, password: password)
        }
        return ImportedFile(entries: try entries(fromCSV: data, source: source), plainText: true)
    }

    private static func read(zip data: Data, source: BrowserImportSource, password: String) throws -> ImportedFile {
        let files = try unzip(data)
        if files["export.data"] != nil {
            try expect(.onePassword, on: source)
            return try imported(try loadPuxImport(data).entries, source: source, plainText: true)
        }
        func named(_ suffix: String) -> Data? {
            files.first { $0.key.lowercased() == suffix || $0.key.lowercased().hasSuffix("/" + suffix) }?.value
        }
        if let json = named("data.json") {
            return try read(json: json, source: source, password: password)
        }
        if named("data.pgp") != nil {
            throw VaultOpenError.unsupported("This Proton Pass export is encrypted with PGP. Export it again without encryption.")
        }
        let sheets = files.filter { $0.key.lowercased().hasSuffix(".csv") }
        // Safari's browsing data and Dashlane's export keep passwords in one sheet among several.
        if let sheet = named("passwords.csv") ?? named("credentials.csv") ?? (sheets.count == 1 ? sheets.first?.value : nil) {
            return ImportedFile(entries: try entries(fromCSV: sheet, source: source), plainText: true)
        }
        throw VaultOpenError.invalid("This ZIP has no password export in it.")
    }

    private static func read(json data: Data, source: BrowserImportSource, password: String) throws -> ImportedFile {
        guard let json = try? JSON.parse(data), json.object != nil else {
            throw VaultOpenError.invalid("This JSON file could not be read.")
        }
        if json["vaults"]?.object != nil {
            try expect(.protonPass, on: source)
            return try imported(try loadProtonPass(data).entries, source: source, plainText: true)
        }
        let protected = json["encrypted"]?.bool == true
        if protected || json["items"] != nil {
            try expect(.bitwarden, on: source)
            return try imported(try loadBitwarden(data, password: password).entries, source: source, plainText: !protected)
        }
        throw VaultOpenError.invalid("This JSON file is not a Bitwarden or Proton Pass export.")
    }

    /// A password manager's own file belongs on that manager's page. A CSV is taken anywhere.
    private static func expect(_ kind: BrowserImportSource, on source: BrowserImportSource) throws {
        guard kind != source else { return }
        throw VaultOpenError.invalid("This is a \(kind.label) export, not \(source == .csv ? "a CSV file" : "a \(source.label) one"). Go back and choose \(kind.label).")
    }

    private static func imported(_ entries: [VaultEntry], source: BrowserImportSource, plainText: Bool) throws -> ImportedFile {
        let placed = place(entries, source: source)
        guard !placed.isEmpty else { throw VaultOpenError.invalid("The export has no passwords in it.") }
        return ImportedFile(entries: placed, plainText: plainText)
    }

    /// Puts what a file held under the source's group, with the source's tag. What the other app had in its trash
    /// stays out.
    static func place(_ entries: [VaultEntry], source: BrowserImportSource) -> [VaultEntry] {
        entries.compactMap { loaded in
            guard !loaded.trashed else { return nil }
            var entry = loaded
            entry.groupPath = [source.label] + (source.keepsFolders ? entry.groupPath : [])
            addTag(&entry, source.label)
            if entry.title.isEmpty { entry.title = host(of: entry.url) }
            return entry
        }
    }

    /// Merges an export into the database. Only entries tagged with the source are touched:
    /// matches get the new password, new sites are added, and, for a source that exports its whole list, sites
    /// missing from the export go to the recycle bin.
    /// An entry the user already deleted is not brought back, and an empty export changes nothing.
    public static func merge(
        _ imported: [VaultEntry],
        into existing: [VaultEntry],
        source: BrowserImportSource
    ) -> (entries: [VaultEntry], summary: BrowserImportSummary) {
        guard !imported.isEmpty else { return (existing, BrowserImportSummary()) }

        var result = existing
        var summary = BrowserImportSummary()
        var managed: [String: [Int]] = [:]
        // Active entries go first, so a deleted twin never shadows a live entry with the same key.
        for trashed in [false, true] {
            for (index, entry) in existing.enumerated() where entry.trashed == trashed && isManaged(entry, by: source) {
                managed[matchKey(entry), default: []].append(index)
            }
        }
        var matched = Set<Int>()

        for incoming in imported {
            let key = matchKey(incoming)
            if let index = managed[key]?.first {
                managed[key]?.removeFirst()
                matched.insert(index)
                if existing[index].trashed { continue }
                var current = result[index]
                let otpChanged = !incoming.otp.isEmpty && current.otp != incoming.otp
                if current.password != incoming.password || otpChanged {
                    current.password = incoming.password
                    if !incoming.otp.isEmpty { current.otp = incoming.otp }
                    result[index] = current
                    summary.updated += 1
                } else {
                    summary.unchanged += 1
                }
            } else {
                var fresh = incoming
                if !source.keepsFolders || fresh.groupPath.first != source.label { fresh.groupPath = [source.label] }
                addTag(&fresh, source.label)
                result.append(fresh)
                summary.added += 1
            }
        }

        guard source.exportsWholeList else { return (result, summary) }
        for index in existing.indices where isManaged(existing[index], by: source) && !matched.contains(index) && !existing[index].trashed {
            result[index].trashed = true
            summary.removed += 1
        }
        return (result, summary)
    }

    /// Removes the plain-text export. It is deleted outright, not moved to the Trash, because the Trash keeps the passwords readable.
    public static func deleteExport(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    private static func isManaged(_ entry: VaultEntry, by source: BrowserImportSource) -> Bool {
        // A recycled entry has lost its group in the file, so only its tag can identify it.
        let inGroup = source.keepsFolders ? entry.groupPath.first == source.label : entry.groupPath == [source.label]
        return (entry.trashed || inGroup)
            && entry.tagList.contains { $0.caseInsensitiveCompare(source.label) == .orderedSame }
    }

    /// The same site and account in a new export. Scheme, `www.`, path and letter case do not matter.
    static func matchKey(_ entry: VaultEntry) -> String {
        let site = host(of: entry.url)
        let place = site.isEmpty ? entry.title.lowercased() : site
        return place + "\u{1}" + entry.username.lowercased()
    }

    static func host(of raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard var host = URLComponents(string: candidate)?.host?.lowercased(), !host.isEmpty else {
            return trimmed.lowercased()
        }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}
