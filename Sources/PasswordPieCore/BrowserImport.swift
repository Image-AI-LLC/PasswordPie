import Foundation

/// Where an exported password list came from. Each source owns one group and one tag in the KeePass database.
public enum BrowserImportSource: String, CaseIterable, Sendable {
    case chrome
    case applePasswords

    /// Used as the group name and as the tag that marks entries this import manages.
    public var label: String {
        switch self {
        case .chrome: return "Chrome"
        case .applePasswords: return "Apple Passwords"
        }
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
        let columns = Set(header.map { $0.lowercased().filter { $0.isLetter || $0.isNumber } })
        guard columns.contains("password") else {
            throw VaultOpenError.invalid("This isn't a \(source.label) password export. It has no Password column.")
        }
        let loaded = try loadCSV(data)
        guard !loaded.entries.isEmpty else {
            throw VaultOpenError.invalid("The export has no passwords in it.")
        }
        return loaded.entries.map { loadedEntry in
            var entry = loadedEntry
            entry.groupPath = [source.label]
            entry.tags = source.label
            return entry
        }
    }

    /// Merges an export into the database. Only entries tagged with the source are touched:
    /// matches get the new password, new sites are added, and sites missing from the export go to the recycle bin.
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
        for (index, entry) in existing.enumerated() where isManaged(entry, by: source) {
            managed[matchKey(entry), default: []].append(index)
        }
        var matched = Set<Int>()

        for incoming in imported {
            let key = matchKey(incoming)
            if let index = managed[key]?.first {
                managed[key]?.removeFirst()
                matched.insert(index)
                if existing[index].trashed { continue }
                var current = result[index]
                if current.password != incoming.password || current.otp != incoming.otp {
                    current.password = incoming.password
                    if !incoming.otp.isEmpty { current.otp = incoming.otp }
                    result[index] = current
                    summary.updated += 1
                } else {
                    summary.unchanged += 1
                }
            } else {
                var fresh = incoming
                fresh.groupPath = [source.label]
                fresh.tags = source.label
                result.append(fresh)
                summary.added += 1
            }
        }

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
        (entry.trashed || entry.groupPath == [source.label])
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
