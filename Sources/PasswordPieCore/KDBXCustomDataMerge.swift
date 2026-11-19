import Foundation

// The database's custom data that PasswordPie writes, merged record by record when two copies of a database are merged
// (`KDBXMerge.swift`). Each of these changes on every Mac that uses the file, so "the later copy wins" would lose one
// Mac's records, and joining the two lists would bring back whatever one Mac took away. So a record that was taken
// away stays listed as taken away, with a time.
//
// These are in every build: the App Store app has no agent access, but it merges a file that the downloaded app uses on
// another Mac, and must not undo what was unshared or revoked there.
//
// A value this version cannot read is left as it is in the copy merged into, and ignored in the other.

// MARK: What agents may ask for

/// The stored form of `AgentSharing` (docs/AGENTS.md, "Sharing"): key `PasswordPie.AgentSharing`.
struct AgentSharingRecord: Codable, Equatable, Sendable {
    static let customDataKey = "PasswordPie.AgentSharing"

    var version = 1
    /// Shared items, by KeePass UUID.
    var items: [String] = []
    /// Shared folders, by group path below the root group.
    var folders: [[String]] = []
    /// When each shared item was shared, in seconds since 1970. Missing for one shared before times were kept.
    var itemTimes: [String: Double]?
    /// Items that were unshared, and when. Kept so that an older copy of the file cannot share them again.
    var unsharedItems: [String: Double]?
    var folderTimes: [FolderTime]?
    var unsharedFolders: [FolderTime]?

    struct FolderTime: Codable, Equatable, Sendable {
        var path: [String]
        var at: Double
    }

    enum Key: Hashable, Sendable {
        case item(UUID)
        case folder([String])
    }

    struct State: Equatable, Sendable {
        var shared: Bool
        /// 0 for an item shared before times were kept: earlier than anything that has a time.
        var at: Double
    }

    init(states: [Key: State]) {
        var itemTimes: [String: Double] = [:], unsharedItems: [String: Double] = [:]
        var folderTimes: [FolderTime] = [], unsharedFolders: [FolderTime] = []
        for (key, state) in states {
            switch key {
            case .item(let id):
                if state.shared {
                    items.append(id.uuidString)
                    if state.at > 0 { itemTimes[id.uuidString] = state.at }
                } else {
                    unsharedItems[id.uuidString] = state.at
                }
            case .folder(let path):
                if state.shared {
                    folders.append(path)
                    if state.at > 0 { folderTimes.append(FolderTime(path: path, at: state.at)) }
                } else {
                    unsharedFolders.append(FolderTime(path: path, at: state.at))
                }
            }
        }
        items.sort()
        folders.sort { $0.lexicographicallyPrecedes($1) }
        folderTimes.sort { $0.path.lexicographicallyPrecedes($1.path) }
        unsharedFolders.sort { $0.path.lexicographicallyPrecedes($1.path) }
        self.itemTimes = itemTimes.isEmpty ? nil : itemTimes
        self.unsharedItems = unsharedItems.isEmpty ? nil : unsharedItems
        self.folderTimes = folderTimes.isEmpty ? nil : folderTimes
        self.unsharedFolders = unsharedFolders.isEmpty ? nil : unsharedFolders
    }

    init?(text: String?) {
        guard let text, let stored = try? JSONDecoder().decode(AgentSharingRecord.self, from: Data(text.utf8)) else { return nil }
        self = stored
    }

    /// Every item and folder this names, shared or unshared. Named both ways, the later one counts, and unshared when
    /// the times are the same.
    var states: [Key: State] {
        var states: [Key: State] = [:]
        func note(_ key: Key, _ state: State) {
            states[key] = states[key].map { Self.later($0, state) } ?? state
        }
        for text in items {
            guard let id = UUID(uuidString: text) else { continue }
            note(.item(id), State(shared: true, at: itemTimes?[text] ?? itemTimes?[id.uuidString] ?? 0))
        }
        for (text, at) in unsharedItems ?? [:] {
            guard let id = UUID(uuidString: text) else { continue }
            note(.item(id), State(shared: false, at: at))
        }
        for path in folders where !path.isEmpty {
            note(.folder(path), State(shared: true, at: folderTimes?.first { $0.path == path }?.at ?? 0))
        }
        for folder in unsharedFolders ?? [] where !folder.path.isEmpty {
            note(.folder(folder.path), State(shared: false, at: folder.at))
        }
        return states
    }

    var text: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The later of two things said about one item or folder. At the same time, unshared: the safe one.
    static func later(_ lhs: State, _ rhs: State) -> State {
        if lhs.at != rhs.at { return lhs.at > rhs.at ? lhs : rhs }
        return lhs.shared ? rhs : lhs
    }

    /// For each item and folder the later of what the two copies say. One only a copy names stays as that copy has it.
    static func merged(_ ours: String?, _ theirs: String?) -> String? {
        guard let other = AgentSharingRecord(text: theirs) else { return ours }
        guard let mine = AgentSharingRecord(text: ours) else {
            // Nothing here: theirs. Something here this version cannot read: left alone.
            return ours ?? theirs
        }
        let (own, their) = (mine.states, other.states)
        let merged = own.merging(their) { later($0, $1) }
        if merged == own { return ours }
        if merged == their { return theirs }
        return AgentSharingRecord(states: merged).text
    }
}

// MARK: Standing permissions

/// The stored form of the standing permissions (`AgentGrants` in the agent library): key `PasswordPie.AgentGrants`, JSON
/// with `grants` and `revoked`, each record with an `id`. Read here as plain JSON, because the agent library is not part
/// of the App Store app and a grant's other fields are not this file's business: a record is kept whole.
enum AgentGrantsRecord {
    static let customDataKey = "PasswordPie.AgentGrants"

    private struct Parsed {
        var version: Int
        var grants: [String: [String: Any]]
        var revoked: [String: [String: Any]]
    }

    private static func parse(_ text: String?) -> Parsed? {
        guard let text, let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let grants = object["grants"] as? [[String: Any]] else { return nil }
        func byID(_ records: [[String: Any]]) -> [String: [String: Any]] {
            var result: [String: [String: Any]] = [:]
            for record in records {
                guard let id = (record["id"] as? String)?.uppercased(), result[id] == nil else { continue }
                result[id] = record
            }
            return result
        }
        return Parsed(
            version: object["version"] as? Int ?? 1,
            grants: byID(grants),
            revoked: byID(object["revoked"] as? [[String: Any]] ?? [])
        )
    }

    private static func canonical(_ record: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func canonical(_ records: [String: [String: Any]]) -> [String: String] {
        records.mapValues(canonical)
    }

    /// Every grant either copy has, except those either copy lists as revoked. A revoked grant stays listed as revoked,
    /// so the copy that still has it cannot bring it back. Should the two copies hold one grant differently, the one
    /// that ends sooner is kept.
    static func merged(_ ours: String?, _ theirs: String?) -> String? {
        guard let other = parse(theirs) else { return ours }
        guard let mine = parse(ours) else { return ours ?? theirs }
        let revoked = mine.revoked.merging(other.revoked) { own, _ in own }
        var grants = mine.grants
        for (id, record) in other.grants {
            guard let own = grants[id] else {
                grants[id] = record
                continue
            }
            let (a, b) = (canonical(own), canonical(record))
            guard a != b else { continue }
            let (ownEnds, theirEnds) = ((own["ends"] as? NSNumber)?.doubleValue ?? 0, (record["ends"] as? NSNumber)?.doubleValue ?? 0)
            if theirEnds < ownEnds || (theirEnds == ownEnds && b < a) { grants[id] = record }
        }
        for id in revoked.keys { grants[id] = nil }
        let (grantTexts, revokedTexts) = (canonical(grants), canonical(revoked))
        if grantTexts == canonical(mine.grants), revokedTexts == canonical(mine.revoked) { return ours }
        if grantTexts == canonical(other.grants), revokedTexts == canonical(other.revoked) { return theirs }
        guard !grants.isEmpty || !revoked.isEmpty else { return nil }
        var object: [String: Any] = [
            "version": max(mine.version, other.version),
            "grants": grants.keys.sorted().compactMap { grants[$0] }
        ]
        if !revoked.isEmpty { object["revoked"] = revoked.keys.sorted().compactMap { revoked[$0] } }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return ours }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: Items changed on both Macs

/// The items a merge found changed in both copies, kept in the database (key `PasswordPie.ChangedOnBoth`) so that every
/// Mac can say so once, not only the Mac that did the merge: the Mac whose change went into the history is the one that
/// needs to hear it. Item UUIDs and times, never a title or a value.
public enum MergeConflictLog {
    public static let customDataKey = "PasswordPie.ChangedOnBoth"
    /// The newest this many are kept.
    static let limit = 200

    public struct Record: Codable, Hashable, Sendable, Identifiable {
        public var item: UUID
        /// When the version that became current was last changed, in seconds since 1970.
        public var kept: Int64
        /// When the version that went into the item's history was.
        public var older: Int64

        public init(item: UUID, kept: Int64, older: Int64) {
            self.item = item
            self.kept = kept
            self.older = older
        }

        public var id: String { "\(item.uuidString) \(kept) \(older)" }
        public var keptDate: Date { Date(timeIntervalSince1970: TimeInterval(kept)) }
        public var olderDate: Date { Date(timeIntervalSince1970: TimeInterval(older)) }
    }

    private struct Stored: Codable {
        var version: Int
        var items: [Record]
    }

    private static func parse(_ text: String?) -> Set<Record>? {
        guard let text, let stored = try? JSONDecoder().decode(Stored.self, from: Data(text.utf8)) else { return nil }
        return Set(stored.items)
    }

    /// What the database lists, oldest first.
    public static func records(in customData: [String: String]) -> [Record] {
        ordered(parse(customData[customDataKey]) ?? [])
    }

    private static func ordered(_ records: Set<Record>) -> [Record] {
        records.sorted {
            if $0.kept != $1.kept { return $0.kept < $1.kept }
            if $0.item != $1.item { return $0.item.uuidString < $1.item.uuidString }
            return $0.older < $1.older
        }
    }

    /// Both copies' records and the ones this merge found, the newest `limit` of them.
    static func merged(_ ours: String?, _ theirs: String?, adding found: [Record]) -> String? {
        let mine = parse(ours)
        // Something here this version cannot read is left alone.
        if ours != nil, mine == nil { return ours }
        let other = parse(theirs) ?? []
        let merged = Set(ordered((mine ?? []).union(other).union(found)).suffix(limit))
        if let mine, merged == mine { return ours }
        if theirs != nil, merged == other { return theirs }
        guard !merged.isEmpty else { return ours }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Stored(version: 1, items: ordered(merged))) else { return ours }
        return String(decoding: data, as: UTF8.self)
    }
}
