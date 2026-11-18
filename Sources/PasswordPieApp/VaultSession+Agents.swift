#if PP_DIRECT
import Foundation
import PasswordPieAgent
import PasswordPieCore

/// The open database as agents see it (docs/AGENTS.md): only what the owner shared, from the database PasswordPie
/// unlocked, and never anything in the Recycle Bin. Sharing is kept in that database's own custom data, so it moves with
/// the file, is under the master key, and cannot be widened by writing the app's preferences.
extension VaultSession: AgentVault {
    /// The database the unlock opened. Other open databases are not offered to agents.
    private var agentFile: OpenedFile? {
        openedFiles.first { $0.url.path == databaseURL.path }
    }

    var agentVaultLocked: Bool { locked || unlocking || agentFile == nil }

    func agentSharedItems() -> [AgentItem] {
        guard !agentVaultLocked, let file = agentFile else { return [] }
        let sharing = AgentSharing(customData: file.vault.customData)
        guard !sharing.isEmpty else { return [] }
        let shared = file.vault.entries.filter(sharing.covers)
        let attachments = file.vault.attachmentNames(of: Set(shared.map(\.id)))
        return shared.map { entry in
            AgentItem(
                id: entry.id,
                database: file.url.path,
                folder: entry.groupPath,
                title: entry.title,
                fields: Self.agentFieldNames(entry),
                attachments: attachments[entry.id] ?? []
            )
        }
    }

    func agentSecret(_ item: AgentItem, field: AgentField) -> Data? {
        // Shared still, and in this database still: sharing may have changed since the request was resolved.
        guard !agentVaultLocked, let file = agentFile, file.url.path == item.database,
              let entry = file.vault.entries.first(where: { $0.id == item.id }),
              AgentSharing(customData: file.vault.customData).covers(entry) else { return nil }
        switch field {
        case .attachment(let name):
            return file.vault.attachment(named: name, of: entry.id)
        case .otp:
            return nil
        default:
            guard let key = field.keePassKey else { return nil }
            if case .custom = field, !Self.agentFieldNames(entry).contains(key) { return nil }
            return Data(entry.value(for: key).utf8)
        }
    }

    /// A shared item's entry in the database PasswordPie unlocked, for a login. Nil when it is no longer there or no
    /// longer shared.
    func agentEntry(_ item: AgentItem) -> VaultEntry? {
        guard !agentVaultLocked, let file = agentFile, file.url.path == item.database,
              let entry = file.vault.entries.first(where: { $0.id == item.id && !$0.trashed }),
              AgentSharing(customData: file.vault.customData).covers(entry) else { return nil }
        return entry
    }

    /// The id the list (and the browser bridge) knows a shared item by. It differs from the stored one only when two open
    /// files share a UUID.
    func agentListID(_ item: AgentItem) -> UUID? {
        guard agentEntry(item) != nil else { return nil }
        return listOrigins.first { $0.value == item.id && listPaths[$0.key] == item.database }?.key
            ?? (listPaths[item.id] == item.database ? item.id : nil)
    }

    /// The custom fields an agent may name: what the details view shows as fields, without PasswordPie's own bookkeeping.
    static func agentFieldNames(_ entry: VaultEntry) -> [String] {
        // The two-step secret, in any of the ways KeePass apps keep it, is not a field agents get.
        let standard: Set<String> = ["title", "username", "password", "url", "notes", "otp", "totp seed", "totp settings"]
        return entry.fields.filter { field in
            !standard.contains(field.key.lowercased()) && !field.key.lowercased().hasPrefix("timeotp")
                && !EntryMerge.isReservedKey(field.key) && !field.value.isEmpty
        }.map(\.key)
    }

    // MARK: Sharing, for the owner's UI

    /// What is shared in the current database.
    var agentSharing: AgentSharing {
        AgentSharing(customData: agentFile?.vault.customData ?? [:])
    }

    /// The stored entry behind a row of the list, when it is in the current database.
    private func agentStoredID(_ listID: UUID) -> UUID? {
        guard let path = listPaths[listID], path == databaseURL.path, storedEntry(listID) != nil else { return nil }
        return listOrigins[listID] ?? listID
    }

    /// Only items saved in the database PasswordPie unlocked can be shared (not a Chrome login, not another database's).
    func canShareWithAgents(_ listID: UUID) -> Bool { agentStoredID(listID) != nil }

    /// Shared on its own or through its folder.
    func isSharedWithAgents(_ listID: UUID) -> Bool {
        guard let id = agentStoredID(listID), let entry = agentFile?.vault.entries.first(where: { $0.id == id }) else { return false }
        return agentSharing.covers(entry)
    }

    /// The shared folder an item is in, when that is why it is shared.
    func agentSharedFolder(of listID: UUID) -> [String]? {
        guard let id = agentStoredID(listID), let entry = agentFile?.vault.entries.first(where: { $0.id == id }) else { return nil }
        return agentSharing.folderCovering(entry.groupPath)
    }

    func setSharedWithAgents(_ listID: UUID, _ shared: Bool, then done: @escaping (Bool) -> Void = { _ in }) {
        guard let id = agentStoredID(listID) else { return done(false) }
        changeAgentSharing({ $0.set(item: id, shared: shared) }, then: done)
    }

    func setFolderSharedWithAgents(_ path: [String], _ shared: Bool, then done: @escaping (Bool) -> Void = { _ in }) {
        changeAgentSharing({ $0.set(folder: path, shared: shared) }, then: done)
    }

    /// Every folder of the current database, outside the Recycle Bin, parents before children.
    var agentFolders: [[String]] {
        var folders = Set<[String]>()
        for entry in agentFile?.vault.entries ?? [] where !entry.trashed {
            for depth in stride(from: 1, through: entry.groupPath.count, by: 1) { folders.insert(Array(entry.groupPath.prefix(depth))) }
        }
        return folders.sorted { $0.lexicographicallyPrecedes($1) }
    }

    /// The items shared one by one, by their list id, for the Agents pane.
    var agentSharedEntries: [VaultEntry] {
        let sharing = agentSharing
        return entries.filter { entry in
            guard let id = agentStoredID(entry.id) else { return false }
            return sharing.items.contains(id)
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Unsharing an item or a folder also ends every standing permission that names an item no longer shared, in the
    /// same write.
    private func changeAgentSharing(_ change: @escaping (inout AgentSharing) -> Void, then done: @escaping (Bool) -> Void) {
        changeDatabase(at: databaseURL.path, { vault in
            var sharing = AgentSharing(customData: vault.customData)
            let before = sharing
            change(&sharing)
            guard sharing != before else { return false }
            sharing.write(into: &vault.customData)
            let shared = Set(vault.entries.filter(sharing.covers).map(\.id))
            var grants = AgentGrants(customData: vault.customData)
            grants.removeAll { grant in grant.secrets.contains { !shared.contains($0.item) } }
            grants.write(into: &vault.customData)
            return true
        }, then: done)
    }

    // MARK: Standing permissions

    /// The standing permissions kept in the database PasswordPie unlocked, or nil while locked. See "Standing
    /// permissions" in docs/AGENTS.md: kept in its custom data, so writing the app's preferences cannot add one.
    var agentGrants: AgentGrants? {
        guard !agentVaultLocked, let file = agentFile else { return nil }
        return AgentGrants(customData: file.vault.customData)
    }

    /// Changes the standing permissions in the database PasswordPie unlocked and writes the file.
    func changeAgentGrants(_ edit: @escaping (inout AgentGrants) -> Void, then done: @escaping (Bool) -> Void = { _ in }) {
        changeDatabase(at: databaseURL.path, { vault in
            let before = AgentGrants(customData: vault.customData)
            var grants = before
            edit(&grants)
            guard grants != before else { return false }
            grants.write(into: &vault.customData)
            return true
        }, then: done)
    }
}
#endif
