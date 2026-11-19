import Foundation

#if PP_DIRECT
/// What agents may ask for in one database: items, and folders (with what is in them now, later, and in their
/// subfolders). Agents see nothing by default. Kept in the database's own custom data, under the master key and moving
/// with the file, never in the app's preferences, so an agent that writes preferences (`defaults write`) cannot widen
/// it. See docs/AGENTS.md, "Sharing".
public struct AgentSharing: Equatable, Sendable {
    public static let customDataKey = AgentSharingRecord.customDataKey

    /// Items by their KeePass UUID.
    public private(set) var items: Set<UUID> = []
    /// Folders by their group path below the root group.
    public private(set) var folders: [[String]] = []
    /// When each item and folder was shared or unshared. What was unshared stays here, so that merging an older copy of
    /// the file from another Mac cannot share it again (`AgentSharingRecord.merged`).
    private var states: [AgentSharingRecord.Key: AgentSharingRecord.State] = [:]

    public init() {}

    /// What `customData` says; nothing when it says nothing readable.
    public init(customData: [String: String]) {
        guard let stored = AgentSharingRecord(text: customData[Self.customDataKey]) else { return }
        states = stored.states
        for (key, state) in states where state.shared {
            switch key {
            case .item(let id): items.insert(id)
            case .folder(let path): folders.append(path)
            }
        }
        folders.sort { $0.lexicographicallyPrecedes($1) }
    }

    /// True when nothing is shared.
    public var isEmpty: Bool { items.isEmpty && folders.isEmpty }

    /// Writes this into `customData`, or removes the key when nothing is shared and nothing was ever unshared.
    public func write(into customData: inout [String: String]) {
        guard !states.isEmpty else {
            customData[Self.customDataKey] = nil
            return
        }
        customData[Self.customDataKey] = AgentSharingRecord(states: states).text
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

    public mutating func set(item id: UUID, shared: Bool, at now: Date = Date()) {
        guard items.contains(id) != shared else { return }
        if shared { items.insert(id) } else { items.remove(id) }
        note(.item(id), shared: shared, at: now)
    }

    public mutating func set(folder path: [String], shared: Bool, at now: Date = Date()) {
        guard !path.isEmpty, folders.contains(path) != shared else { return }
        folders.removeAll { $0 == path }
        if shared {
            folders.append(path)
            folders.sort { $0.lexicographicallyPrecedes($1) }
        }
        note(.folder(path), shared: shared, at: now)
    }

    /// Later than what was said before about the same item, also when the clock says otherwise: this is the newer
    /// decision.
    private mutating func note(_ key: AgentSharingRecord.Key, shared: Bool, at now: Date) {
        let seconds = max(now.timeIntervalSince1970.rounded(), (states[key]?.at ?? 0) + 1)
        states[key] = AgentSharingRecord.State(shared: shared, at: seconds)
    }
}
#endif
