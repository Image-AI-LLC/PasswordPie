import Foundation

/// Combines live accounts that share a website, username, and password.
/// A different value of the same field is kept under a numbered name, such as `Title (2)`.
/// Split restores each account from before the merge and marks it so it stays separate.
public enum EntryMerge {
    public static let keepSeparateKey = "PasswordPie.KeepSeparate"
    public static let manifestKey = "PasswordPie.Merge"

    public static func isReservedKey(_ key: String) -> Bool {
        key.caseInsensitiveCompare(keepSeparateKey) == .orderedSame
            || key.caseInsensitiveCompare(manifestKey) == .orderedSame
            || key.caseInsensitiveCompare(PreviousPasswords.key) == .orderedSame
    }

    public static func keepsSeparate(_ entry: VaultEntry) -> Bool {
        entry.value(for: keepSeparateKey) == "1"
    }

    public static func setKeepSeparate(_ keep: Bool, on entry: inout VaultEntry) {
        if keep {
            entry.setValue("1", for: keepSeparateKey)
        } else {
            entry.fields.removeAll { $0.key == keepSeparateKey }
        }
    }

    /// How many accounts were folded into this one. `0` when it has not been merged.
    public static func partCount(_ entry: VaultEntry) -> Int {
        guard let manifest = readManifest(entry), manifest.parts.count >= 2 else { return 0 }
        return manifest.parts.count
    }

    /// Websites beyond the main one, kept under numbered names such as `URL (2)`.
    public static func otherWebsites(_ entry: VaultEntry) -> [VaultField] {
        entry.fields.filter { !$0.value.isEmpty && isNumberedSuffix($0.key, base: "URL") }
    }

    /// Fields a merge added beside the main title, username, password, website, notes, and one-time password.
    public static func extraFields(_ entry: VaultEntry) -> [VaultField] {
        entry.fields.filter { field in
            !field.key.isEmpty && !field.value.isEmpty && !isReservedKey(field.key) && !standardKeys.contains(field.key.lowercased())
        }
    }

    /// Live accounts with the same website, username, and password become one account.
    /// The copies are moved to the trash. An account marked keep-separate is left alone.
    /// Running this again does not stack suffixes or drop edits made after a merge.
    public static func merged(_ entries: [VaultEntry]) -> [VaultEntry] {
        var result = entries
        var groups: [Identity: [Int]] = [:]
        for (index, entry) in result.enumerated() {
            guard let identity = identity(of: entry) else { continue }
            groups[identity, default: []].append(index)
        }
        for indexes in groups.values where indexes.count >= 2 {
            let survivorIndex = indexes.max(by: { rank($0, in: result) < rank($1, in: result) }) ?? indexes[0]
            var entry = result[survivorIndex]
            var manifest = readManifest(entry) ?? Manifest(v: 1, parts: [Part(entry)])
            var taken = Set(entry.fields.map(\.key))
            var changed = false
            func take(_ part: Part) -> Bool {
                guard part.id != entry.id, !manifest.parts.contains(where: { $0.id == part.id }) else { return false }
                let number = manifest.parts.count + 1
                absorb(part, number: number, into: &entry, taken: &taken)
                manifest.parts.append(part)
                changed = true
                return true
            }
            for index in indexes where index != survivorIndex {
                let other = result[index]
                let alreadyKept = manifest.parts.contains { $0.id == other.id && $0.id != entry.id }
                var recorded = false
                if let nested = readManifest(other) {
                    for part in nested.parts where take(part) { recorded = true }
                    if keepLiveEdits(other, number: manifest.parts.count + 1, into: &entry, taken: &taken) {
                        recorded = true
                        changed = true
                    }
                } else if take(Part(other)) {
                    recorded = true
                } else if alreadyKept, keepLiveEdits(other, number: manifest.parts.count + 1, into: &entry, taken: &taken) {
                    recorded = true
                    changed = true
                }
                if recorded || alreadyKept {
                    result[index].trashed = true
                    #if PP_DIRECT
                    if PreviousPasswords.absorb(other, into: &entry, now: Date()) { changed = true }
                    #endif
                }
            }
            if changed {
                write(manifest, to: &entry)
                result[survivorIndex] = entry
            }
        }
        return result
    }

    /// The accounts from before the merge, each marked keep-separate. Nil when this entry is not a merge.
    public static func split(_ entry: VaultEntry) -> [VaultEntry]? {
        guard let manifest = readManifest(entry), manifest.parts.count >= 2 else { return nil }
        return manifest.parts.enumerated().map { index, part in
            var restored = part.makeEntry()
            if index == 0 {
                restored.id = entry.id
                #if PP_DIRECT
                PreviousPasswords.carry(from: entry, to: &restored, now: Date())
                #endif
            }
            restored.trashed = false
            setKeepSeparate(true, on: &restored)
            return restored
        }
    }

    // MARK: Identity

    private struct Identity: Hashable {
        var host: String
        var username: String
        var password: String
    }

    /// Higher sorts later and wins: an existing merge, then the fuller account, then the earlier row.
    private static func rank(_ index: Int, in entries: [VaultEntry]) -> (Int, Int, Int, Int, Int) {
        let entry = entries[index]
        let merged = readManifest(entry) == nil ? 0 : 1
        let filled = entry.fields.filter { !$0.value.isEmpty && !isReservedKey($0.key) }.count
        return (merged, filled, entry.favorite ? 1 : 0, entry.otp.isEmpty ? 0 : 1, -index)
    }

    private static func identity(of entry: VaultEntry) -> Identity? {
        guard !entry.trashed, !blocksMerge(entry), let host = host(of: entry) else { return nil }
        let username = entry.username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !username.isEmpty, !entry.password.isEmpty else { return nil }
        return Identity(host: host, username: username, password: entry.password)
    }

    /// A keep-separate account, or a merge record this version cannot read, is never a merge candidate.
    private static func blocksMerge(_ entry: VaultEntry) -> Bool {
        if keepsSeparate(entry) { return true }
        let raw = entry.value(for: manifestKey)
        return !raw.isEmpty && readManifest(entry) == nil
    }

    private static func host(of entry: VaultEntry) -> String? {
        let url = entry.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let host = normalizedHost(url) { return host }
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.contains("."), !title.contains(where: { $0.isWhitespace || $0 == "/" }) else { return nil }
        let withScheme = title.contains("://") ? title : "https://\(title)"
        return normalizedHost(withScheme)
    }

    /// Lowercased host without a leading `www`. Path, query, and port are not part of the login.
    private static func normalizedHost(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        var host = urlSearchString(raw)
        while host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }

    // MARK: Fields

    private static let standardKeys: Set<String> = ["title", "username", "password", "url", "notes", "otp"]

    private static func canonicalKey(_ key: String) -> String {
        switch key.lowercased() {
        case "title": return "Title"
        case "username": return "UserName"
        case "password": return "Password"
        case "url": return "URL"
        case "notes": return "Notes"
        case "otp": return "otp"
        default: return key
        }
    }

    private static func primaryValue(_ entry: VaultEntry, _ key: String) -> String {
        entry.fields.first { canonicalKey($0.key) == key }?.value ?? ""
    }

    private static func isNumberedSuffix(_ key: String, base: String) -> Bool {
        let prefix = base + " ("
        guard key.hasPrefix(prefix), key.hasSuffix(")") else { return false }
        let start = key.index(key.startIndex, offsetBy: prefix.count)
        let end = key.index(before: key.endIndex)
        guard start < end else { return false }
        return key[start..<end].allSatisfy(\.isNumber)
    }

    private static func suffixedKey(_ base: String, number: Int, taken: Set<String>) -> String {
        var number = max(number, 2)
        while true {
            let candidate = "\(base) (\(number))"
            if !taken.contains(candidate) { return candidate }
            number += 1
        }
    }

    private static func equivalent(_ key: String, _ lhs: String, _ rhs: String) -> Bool {
        if key == "otp" || key == "Password" { return lhs == rhs }
        return lhs.trimmingCharacters(in: .whitespacesAndNewlines) == rhs.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum NoteMerge {
        case keep
        case replace(String)
        case conflict
    }

    /// The longer note wins when one is contained in the other. Otherwise both are kept.
    private static func mergeNotes(existing: String, incoming: String) -> NoteMerge {
        let kept = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let added = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        if added.isEmpty || kept == added || kept.contains(added) { return .keep }
        if kept.isEmpty || added.contains(kept) { return .replace(incoming) }
        return .conflict
    }

    /// Copies fields edited after a merge onto the survivor. The manifest parts stay the pre-merge accounts.
    private static func keepLiveEdits(
        _ other: VaultEntry,
        number: Int,
        into entry: inout VaultEntry,
        taken: inout Set<String>
    ) -> Bool {
        let before = entry
        absorb(Part(other), number: number, into: &entry, taken: &taken)
        return entry != before
    }

    private static func absorb(_ part: Part, number: Int, into entry: inout VaultEntry, taken: inout Set<String>) {
        let incoming = part.makeEntry()
        let favorite = entry.favorite || incoming.favorite
        let existingTags = tags(of: entry)
        let incomingTags = tags(of: incoming)
        var union = existingTags
        for tag in incomingTags where !union.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            union.append(tag)
        }
        entry.tags = union.joined(separator: ",")
        entry.favorite = favorite
        if !sameTags(existingTags, incomingTags), !incoming.tags.isEmpty {
            add(incoming.tags, for: "Tags", number: number, protected: false, to: &entry, taken: &taken)
        }
        if incoming.groupPath != entry.groupPath {
            let label = incoming.groupPath.joined(separator: " / ")
            if !label.isEmpty {
                add(label, for: "Group", number: number, protected: false, to: &entry, taken: &taken)
            }
        }
        for field in incoming.fields {
            guard !field.key.isEmpty, !field.value.isEmpty, !isReservedKey(field.key) else { continue }
            let key = canonicalKey(field.key)
            if key == "Password" { continue }
            if key == "Notes" {
                switch mergeNotes(existing: entry.notes, incoming: field.value) {
                case .keep:
                    continue
                case .replace(let text):
                    entry.notes = text
                    taken.insert("Notes")
                    continue
                case .conflict:
                    break
                }
            }
            let current = primaryValue(entry, key)
            if current.isEmpty {
                entry.setValue(field.value, for: key, protected: field.protected || key == "otp")
                taken.insert(key)
                continue
            }
            if equivalent(key, current, field.value) { continue }
            if entry.fields.contains(where: { isNumberedSuffix($0.key, base: key) && equivalent(key, $0.value, field.value) }) {
                continue
            }
            add(field.value, for: key, number: number, protected: field.protected || key == "otp", to: &entry, taken: &taken)
        }
    }

    private static func add(
        _ value: String,
        for base: String,
        number: Int,
        protected: Bool,
        to entry: inout VaultEntry,
        taken: inout Set<String>
    ) {
        let name = suffixedKey(base, number: number, taken: taken)
        entry.setValue(value, for: name, protected: protected)
        taken.insert(name)
    }

    private static func tags(of entry: VaultEntry) -> [String] {
        entry.tagList.filter { $0.caseInsensitiveCompare("Favorite") != .orderedSame }
    }

    private static func sameTags(_ lhs: [String], _ rhs: [String]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return lhs.allSatisfy { tag in rhs.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
    }

    // MARK: Manifest

    private struct Manifest: Codable {
        var v: Int
        var parts: [Part]
    }

    private struct Part: Codable {
        var id: UUID
        var group: [String]
        var tags: String
        var fields: [StoredField]

        init(_ entry: VaultEntry) {
            id = entry.id
            group = entry.groupPath
            tags = entry.tags
            fields = entry.fields.filter { !EntryMerge.isReservedKey($0.key) }.map {
                StoredField(key: $0.key, value: $0.value, protected: $0.protected)
            }
        }

        func makeEntry() -> VaultEntry {
            VaultEntry(
                id: id,
                groupPath: group,
                tags: tags,
                fields: fields.map { VaultField(key: $0.key, value: $0.value, protected: $0.protected) }
            )
        }
    }

    private struct StoredField: Codable {
        var key: String
        var value: String
        var protected: Bool
    }

    private static func readManifest(_ entry: VaultEntry) -> Manifest? {
        let raw = entry.value(for: manifestKey)
        guard let data = raw.data(using: .utf8), !data.isEmpty else { return nil }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data), manifest.v == 1, !manifest.parts.isEmpty else {
            return nil
        }
        return manifest
    }

    private static func write(_ manifest: Manifest, to entry: inout VaultEntry) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(manifest), let text = String(data: data, encoding: .utf8) else { return }
        entry.setValue(text, for: manifestKey, protected: true)
    }
}
