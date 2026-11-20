#if PP_DIRECT
import Foundation
import PasswordPieAgent
import PasswordPieCore

/// The broker's save store: proposals kept in the agents database's custom data, and the owner's Save, which writes the
/// value into an item in the same write. See docs/AGENTS.md, "Saving a secret".
@MainActor
final class AgentSaves: AgentSaveStore {
    private weak var session: VaultSession?
    var clock: () -> Date = Date.init
    /// A proposal was kept, saved or rejected: the Agents pane reads them again.
    var onChange: (() -> Void)?

    init(session: VaultSession) {
        self.session = session
    }

    var proposals: [AgentProposal]? {
        guard let custom = session?.agentCustomData else { return nil }
        return AgentProposals(customData: custom).current(now: clock())
    }

    func propose(_ proposal: AgentProposal) async -> AgentProposeResult {
        let now = clock()
        // The limit is checked in the write, which sees every proposal kept before it, not in what the file held when asked.
        var full = false
        let written = await change { vault in
            var all = AgentProposals(customData: vault.customData)
            all.forgetEnded(now: now)
            guard all.pending(now: now).count < AgentProposals.maxPending else {
                full = true
                return false
            }
            all.add(proposal)
            all.write(into: &vault.customData)
            return true
        }
        return written ? .kept : (full ? .full : .notWritten)
    }

    func save(_ id: String) async -> AgentSaveResult {
        let now = clock()
        var result = AgentSaveResult.failed("It is no longer waiting.")
        let written = await change { vault in
            result = AgentSaveApply.apply(id, to: &vault, now: now)
            if case .saved = result { return true }
            return false
        }
        if case .saved = result, !written { return .failed("PasswordPie could not write the agents database. Nothing was saved.") }
        return result
    }

    func reject(_ id: String) async -> Bool {
        let now = clock()
        return await change { vault in
            var all = AgentProposals(customData: vault.customData)
            guard let proposal = all.current(now: now).first(where: { $0.id == id && $0.state == .pending }) else { return false }
            all.replace(proposal.answered(.rejected, at: now))
            all.forgetEnded(now: now)
            all.write(into: &vault.customData)
            return true
        }
    }

    /// One write of the agents database; true once it is on disk.
    private func change(_ edit: @escaping (inout Vault) -> Bool) async -> Bool {
        guard let session, !session.agentVaultLocked else { return false }
        let path = session.agentDatabasePath
        let written = await withCheckedContinuation { continuation in
            session.changeDatabase(at: path, edit) { continuation.resume(returning: $0) }
        }
        onChange?()
        return written
    }
}

/// Writes a saved proposal into the database: the item made or changed, the proposal marked saved without its value.
/// Pure, on a `Vault`, so it is tested with real database files. The previous version of a changed item goes into its
/// history when the file is written (`KDBXPreserve`), as for any edit.
enum AgentSaveApply {
    static func apply(_ id: String, to vault: inout Vault, now: Date) -> AgentSaveResult {
        var proposals = AgentProposals(customData: vault.customData)
        guard let proposal = proposals.current(now: now).first(where: { $0.id == id && $0.state == .pending }),
              let bytes = proposal.bytes, !bytes.isEmpty else { return .failed("It is no longer waiting.") }
        let field = proposal.fieldValue
        if let key = field.keePassKey, case .custom = field, EntryMerge.isReservedKey(key) || VaultBroker.unsavable(field) != nil {
            return .failed("PasswordPie keeps the field \(key) itself.")
        }
        if case .otp = field { return .failed("A save cannot set a two-step code.") }
        var sharing = AgentSharing(customData: vault.customData)
        let index: Int?
        switch target(of: proposal, in: vault, sharing: sharing) {
        case .success(let found): index = found
        case .failure(let problem): return .failed(problem.message)
        }

        let change: AgentSaveChange
        let item: UUID
        if let index {
            var entry = vault.entries[index]
            let had = set(field, to: bytes, on: &entry, held: vault.attachment(named: attachmentName(field) ?? "", of: entry.id), now: now)
            change = had ? .changed : .newField
            item = entry.id
            vault.entries[index] = entry
        } else {
            var entry = VaultEntry(groupPath: proposal.folder)
            entry.title = proposal.title
            _ = set(field, to: bytes, on: &entry, held: nil, now: now)
            change = .newItem
            item = entry.id
            vault.entries.append(entry)
            // Made for agents: shared, so the agent can use it with the usual approval. Its folder may already be.
            if !sharing.covers(entry) {
                sharing.set(item: entry.id, shared: true, at: now)
                sharing.write(into: &vault.customData)
            }
        }
        proposals.replace(proposal.answered(.saved, at: now, item: item))
        proposals.forgetEnded(now: now)
        proposals.write(into: &vault.customData)
        return .saved(item: item, change: change)
    }

    struct Problem: Error, Equatable {
        var message: String
    }

    /// The index of the item the proposal changes, or nil for a new one. An item it named must still be there and shared.
    /// A new one whose place a shared item holds by now (an earlier proposal for it was saved) changes that item.
    static func target(of proposal: AgentProposal, in vault: Vault, sharing: AgentSharing) -> Result<Int?, Problem> {
        if let id = proposal.item {
            guard let index = vault.entries.firstIndex(where: { $0.id == id && !$0.trashed }), sharing.covers(vault.entries[index]) else {
                return .failure(Problem(message: "The item is no longer in the agents database, or no longer shared with agents."))
            }
            return .success(index)
        }
        let places = vault.entries.indices.filter { index in
            let entry = vault.entries[index]
            return entry.groupPath == proposal.folder && entry.title == proposal.title && sharing.covers(entry)
        }
        if places.count > 1 { return .failure(Problem(message: "Two items shared with agents are at this place now.")) }
        return .success(places.first)
    }

    /// `proposal` with the folder and title its item has now, which is where a save writes; as proposed when the item is not found.
    static func placed(_ proposal: AgentProposal, in vault: Vault) -> AgentProposal {
        guard proposal.item != nil, case .success(let index?) = target(of: proposal, in: vault, sharing: AgentSharing(customData: vault.customData)) else {
            return proposal
        }
        var copy = proposal
        copy.folder = vault.entries[index].groupPath
        copy.title = vault.entries[index].title
        return copy
    }

    /// What saving it would do now, for the Agents pane: a new item, a new field or a change; or why it cannot be saved.
    static func preview(_ proposal: AgentProposal, in vault: Vault) -> Result<AgentSaveChange, Problem> {
        let sharing = AgentSharing(customData: vault.customData)
        switch target(of: proposal, in: vault, sharing: sharing) {
        case .failure(let problem):
            return .failure(problem)
        case .success(nil):
            return .success(.newItem)
        case .success(let index?):
            let entry = vault.entries[index]
            let field = proposal.fieldValue
            if let name = attachmentName(field) { return .success(vault.attachment(named: name, of: entry.id) == nil ? .newField : .changed) }
            return .success(entry.value(for: field.keePassKey ?? "").isEmpty ? .newField : .changed)
        }
    }

    private static func attachmentName(_ field: AgentField) -> String? {
        if case .attachment(let name) = field { return name }
        return nil
    }

    /// Sets one field or attached file. True when it held something before.
    private static func set(_ field: AgentField, to bytes: Data, on entry: inout VaultEntry, held attachment: Data?, now: Date) -> Bool {
        if let name = attachmentName(field) {
            entry.attachments.removeAll { $0.name == name }
            entry.attachments.append(VaultAttachment(name: name, data: bytes))
            return attachment != nil
        }
        guard let key = field.keePassKey else { return false }
        let text = String(decoding: bytes, as: UTF8.self)
        let old = entry.value(for: key)
        switch field {
        case .password:
            entry.password = text
            if !old.isEmpty { PreviousPasswords.recordChange(from: old, on: &entry, previousDate: nil, now: now) }
        case .custom:
            // A custom field an agent saves is a secret: protected, as the import of a dotenv file makes them.
            entry.setValue(text, for: key, protected: true)
        default:
            entry.setValue(text, for: key)
        }
        return !old.isEmpty
    }
}
#endif
