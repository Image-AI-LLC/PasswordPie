import Foundation

#if PP_DIRECT
/// What agents may ask for in one database: items, and folders (with what is in them now, later, and in their
/// subfolders). Agents see nothing by default. Kept in the database's own custom data, under the master key and moving
/// with the file, never in the app's preferences, so an agent that writes preferences (`defaults write`) cannot widen
/// it. See docs/AGENTS.md, "Sharing".
public struct AgentSharing: Equatable, Sendable {
    public static let customDataKey = "PasswordPie.AgentSharing"

    /// Items by their KeePass UUID.
    public private(set) var items: Set<UUID> = []
    /// Folders by their group path below the root group.
    public private(set) var folders: [[String]] = []

    public init() {}

    /// What `customData` says; nothing when it says nothing readable.
    public init(customData: [String: String]) {
        guard let text = customData[Self.customDataKey],
              let stored = try? JSONDecoder().decode(Stored.self, from: Data(text.utf8)) else { return }
        items = Set(stored.items.compactMap(UUID.init(uuidString:)))
        folders = stored.folders.filter { !$0.isEmpty }
    }

    public var isEmpty: Bool { items.isEmpty && folders.isEmpty }

    /// Writes this into `customData`, or removes the key when nothing is shared.
    public func write(into customData: inout [String: String]) {
        guard !isEmpty else {
            customData[Self.customDataKey] = nil
            return
        }
        let stored = Stored(version: 1, items: items.map(\.uuidString).sorted(), folders: folders.sorted { $0.lexicographicallyPrecedes($1) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        customData[Self.customDataKey] = (try? encoder.encode(stored)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// True for an item an agent may ask for. The Recycle Bin never counts.
    public func covers(_ entry: VaultEntry) -> Bool {
        guard !entry.trashed else { return false }
        return items.contains(entry.id) || folderCovering(entry.groupPath) != nil
    }

    /// The shared folder that `path` is in, or is.
    public func folderCovering(_ path: [String]) -> [String]? {
        folders.first { path.count >= $0.count && Array(path.prefix($0.count)) == $0 }
    }

    public func isShared(folder path: [String]) -> Bool { folders.contains(path) }

    public mutating func set(item id: UUID, shared: Bool) {
        if shared { items.insert(id) } else { items.remove(id) }
    }

    public mutating func set(folder path: [String], shared: Bool) {
        guard !path.isEmpty else { return }
        folders.removeAll { $0 == path }
        if shared { folders.append(path) }
    }

    private struct Stored: Codable {
        var version: Int
        var items: [String]
        var folders: [[String]]
    }
}
#endif
