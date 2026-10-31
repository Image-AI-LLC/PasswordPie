import Foundation

/// One entry in the merged list, still tied to the file it will be written back to.
public struct SourcedEntry: Equatable, Sendable {
    public var path: String
    /// Identity in the menu. Same as `entry.id` until that UUID already appeared in an earlier file.
    public var listID: UUID
    public var entry: VaultEntry

    public init(path: String, listID: UUID, entry: VaultEntry) {
        self.path = path
        self.listID = listID
        self.entry = entry
    }
}

/// Several databases become one list. The first group keeps its ids. A later copy of the same id gets a stable stand-in.
public enum EntryCatalog {
    public static func merge(_ groups: [(path: String, entries: [VaultEntry])]) -> [SourcedEntry] {
        var taken = Set<UUID>()
        var merged: [SourcedEntry] = []
        for group in groups {
            for entry in group.entries {
                let listID = allocate(path: group.path, entryID: entry.id, taken: &taken)
                merged.append(SourcedEntry(path: group.path, listID: listID, entry: entry))
            }
        }
        return merged
    }

    /// The rows that belong in one file, with the ids that file already stored.
    public static func storedEntries(path: String, merged: [SourcedEntry]) -> [VaultEntry] {
        merged.filter { $0.path == path }.map(\.entry)
    }

    /// Position of each menu row inside its own file. Two copies of one UUID stay on different rows.
    public static func indexes(in merged: [SourcedEntry]) -> [UUID: Int] {
        var seen: [String: Int] = [:]
        var slots: [UUID: Int] = [:]
        for item in merged {
            let index = seen[item.path, default: 0]
            seen[item.path] = index + 1
            slots[item.listID] = index
        }
        return slots
    }

    private static func allocate(path: String, entryID: UUID, taken: inout Set<UUID>) -> UUID {
        if taken.insert(entryID).inserted { return entryID }
        var salt = 1
        while true {
            let id = stableID(path: path, entryID: entryID, salt: salt)
            if taken.insert(id).inserted { return id }
            salt += 1
        }
    }

    static func stableID(path: String, entryID: UUID, salt: Int) -> UUID {
        var hash: UInt64 = 14_695_981_039_346_656_037
        func feed(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        for byte in path.utf8 { feed(byte) }
        feed(0)
        withUnsafeBytes(of: entryID.uuid) { buffer in
            for byte in buffer { feed(byte) }
        }
        feed(UInt8(truncatingIfNeeded: salt))
        var bytes = [UInt8](repeating: 0, count: 16)
        var mixed = hash
        for index in 0..<16 {
            bytes[index] = UInt8(truncatingIfNeeded: mixed)
            mixed = mixed &* 1_099_511_628_211 &+ UInt64(index) &+ UInt64(salt)
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
