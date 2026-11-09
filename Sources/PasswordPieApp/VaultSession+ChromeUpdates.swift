import AppKit
import PasswordPieCore

#if PP_DIRECT
/// Everything a write needs, with nothing tied to the main actor. A background update runs it off the main thread, because deriving
/// the key can take seconds. Restore runs it in place, like every other save the person asked for.
private struct ChromeWrite: Sendable {
    var path: String
    var url: URL
    var vault: Vault
    var password: String
    var baseline: Data
    var revision: Int
    /// Entries whose saved password this write changes.
    var updated: Set<UUID>

    func perform() throws -> Vault {
        var result = vault
        let data = try KDBX.save(vault: &result, password: password)
        try VaultFile.replace(url, with: data, password: password, expecting: result, baseline: baseline)
        result.noteFileContents(data)
        return result
    }
}

/// How the rules in "The newest password wins" (docs/UX.md) reach the file.
extension VaultSession {
    /// What keeps a login from replacing a password, given the rows read and the files open.
    func chromeJoinRules() -> ChromeJoinRules {
        var notForms = Set<UUID>()
        for row in chromeRows where !row.isForm { notForms.insert(row.loginID) }
        var readOnly = Set<UUID>()
        let unwritable = Set(openedFiles.filter { !VaultFormat.writesKDBX($0.url) || $0.vault.fileBaseline == nil }.map(\.url.path))
        if !unwritable.isEmpty {
            for entry in entries where listPaths[entry.id].map(unwritable.contains) == true { readOnly.insert(entry.id) }
        }
        return ChromeJoinRules(notForms: notForms, readOnly: readOnly)
    }

    /// Each listed entry's password date, as far as its file can tell.
    func chromePasswordDates() -> [UUID: Date] {
        var result: [UUID: Date] = [:]
        for file in openedFiles {
            let dates = file.vault.passwordDates()
            guard !dates.isEmpty else { continue }
            for (listID, path) in listPaths where path == file.url.path {
                if let origin = listOrigins[listID], let date = dates[origin] { result[listID] = date }
            }
        }
        return result
    }

    private func chromePlan(now: Date) -> ChromeUpdates.Plan {
        ChromeUpdates.plan(
            saved: entries,
            live: liveEntries,
            rows: chromeRows,
            dates: chromePasswordDates(),
            rules: chromeJoinRules(),
            now: now
        )
    }

    /// After every read. Silent when it works. More than the limit writes nothing and waits for the person.
    func reconcileChromeUpdates() {
        guard !locked, chromeSyncEnabled else { return }
        let now = chromeClock()
        if chromeWriteInFlight {
            chromeReconcileAgain = true
            return
        }
        let plan = chromePlan(now: now)
        let waiting = Set(plan.updates.map(\.entryID))
        chromeUpdateFailures.formIntersection(waiting)
        guard !plan.isEmpty else {
            chromeBatch = nil
            chromeHeldEvents = []
            return
        }
        if ChromeUpdates.shouldHold(plan, saved: entries, alreadyHeld: chromeHeldEvents, now: now) {
            chromeHeldEvents.formUnion(plan.updates.compactMap { $0.replacement?.event })
            chromeBatch = ChromeBatch(accounts: plan.updates.map {
                ChromeBatch.Account(id: $0.entryID, title: $0.title, username: $0.username)
            })
            return
        }
        chromeBatch = nil
        chromeHeldEvents = []
        commit(plan, kind: .automatic, now: now) { _ in }
    }

    /// `Try Again`. A file that changed on disk is read again first, because the write would be refused forever otherwise.
    func retryChromeUpdates() {
        guard !chromeWriteInFlight else { return }
        let generation = catalogGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            for file in self.openedFiles where VaultFormat.writesKDBX(file.url) {
                guard let onDisk = try? Data(contentsOf: file.url), onDisk != file.vault.fileBaseline else { continue }
                let (url, password, keyFile, revision) = (file.url, file.password, file.keyFile, file.revision)
                let loaded = await Task.detached(priority: .userInitiated) {
                    try? VaultFile.openRecovering(url: url, password: password, keyFile: keyFile)
                }.value
                guard generation == self.catalogGeneration, let loaded,
                      let index = self.openedFiles.firstIndex(where: { $0.url == url }),
                      self.openedFiles[index].revision == revision else { continue }
                self.openedFiles[index].vault = loaded
                self.openedFiles[index].committedEntries = loaded.entries
                self.openedFiles[index].revision += 1
                self.publishCatalog()
            }
            self.reconcileChromeUpdates()
        }
    }

    func applyChromeBatch() {
        decideChromeBatch(kind: .approved)
    }

    /// Keeps the saved passwords. Chrome's values go to previous passwords, and this batch is not asked about again.
    func dismissChromeBatch() {
        decideChromeBatch(kind: .declined)
    }

    private func decideChromeBatch(kind: PreviousPasswords.EventKind) {
        guard !chromeWriteInFlight else { return }
        chromeBatchError = ""
        let now = chromeClock()
        let plan = chromePlan(now: now)
        guard !plan.isEmpty else {
            chromeBatch = nil
            chromeHeldEvents = []
            return
        }
        commit(plan, kind: kind, now: now) { [weak self] succeeded in
            guard let self else { return }
            if succeeded {
                self.chromeBatch = nil
                self.chromeHeldEvents = []
            } else {
                self.chromeBatchError = kind == .approved
                    ? "Couldn't update. Using the saved passwords."
                    : "Couldn't save that. These accounts are still waiting."
            }
        }
    }

    /// One click, with no confirmation, because the password it replaces moves into the same list.
    /// A failure changes nothing, and the row says so.
    func restorePreviousPassword(_ itemID: UUID, of id: UUID) -> Bool {
        let date = chromePasswordDates()[id]
        let now = chromeClock()
        return transact(id) { entry in
            PreviousPasswords.restore(itemID, on: &entry, previousDate: date, now: now)
        }
    }

    func clearPreviousPasswords(of id: UUID) -> Bool {
        transact(id) { entry in
            PreviousPasswords.clear(on: &entry)
            return true
        }
    }

    /// A change the person just asked for, written before anything else happens. Nothing is published unless the file was replaced.
    private func transact(_ id: UUID, _ change: (inout VaultEntry) -> Bool) -> Bool {
        guard !chromeWriteInFlight, let path = listPaths[id], let slot = listSlots[id], let origin = listOrigins[id],
              let index = openedFiles.firstIndex(where: { $0.url.path == path }),
              openedFiles[index].vault.entries.indices.contains(slot),
              openedFiles[index].vault.entries[slot].id == origin,
              let baseline = openedFiles[index].vault.fileBaseline else { return false }
        var vault = openedFiles[index].vault
        guard change(&vault.entries[slot]) else { return false }
        onActivity?()
        let write = ChromeWrite(path: path, url: openedFiles[index].url, vault: vault, password: openedFiles[index].password, baseline: baseline, revision: openedFiles[index].revision, updated: [])
        guard let written = try? write.perform() else { return false }
        adopt(written, at: index)
        return true
    }

    private func adopt(_ vault: Vault, at index: Int) {
        openedFiles[index].vault = vault
        openedFiles[index].committedEntries = vault.entries
        openedFiles[index].revision += 1
        publishCatalog()
    }

    /// One write per file, each all or nothing. The list changes only after the file was replaced.
    private func commit(_ plan: ChromeUpdates.Plan, kind: PreviousPasswords.EventKind, now: Date, done: @escaping (Bool) -> Void) {
        let writes = stage(plan, kind: kind, now: now)
        guard !writes.isEmpty else {
            done(true)
            return
        }
        chromeWriteInFlight = true
        let generation = catalogGeneration
        Task { @MainActor [weak self] in
            var succeeded = true
            var overtaken = false
            for write in writes {
                let outcome = await Task.detached(priority: .userInitiated) { Result { try write.perform() } }.value
                guard let self, generation == self.catalogGeneration else { return }
                guard let index = self.openedFiles.firstIndex(where: { $0.url.path == write.path }) else {
                    succeeded = false
                    continue
                }
                // The person saved something while this ran, so what's in memory is theirs. The next plan starts from it.
                if self.openedFiles[index].revision != write.revision {
                    overtaken = true
                    succeeded = false
                    continue
                }
                switch outcome {
                case .success(let written):
                    self.adopt(written, at: index)
                    self.chromeUpdateFailures.subtract(write.updated)
                case .failure:
                    succeeded = false
                    self.chromeUpdateFailures.formUnion(write.updated)
                }
            }
            guard let self else { return }
            self.chromeWriteInFlight = false
            done(succeeded)
            if overtaken || self.chromeReconcileAgain {
                self.chromeReconcileAgain = false
                self.reconcileChromeUpdates()
            }
        }
    }

    private func stage(_ plan: ChromeUpdates.Plan, kind: PreviousPasswords.EventKind, now: Date) -> [ChromeWrite] {
        var staged: [String: ChromeWrite] = [:]
        var order: [String] = []
        for change in plan.changes {
            guard let path = listPaths[change.entryID], let slot = listSlots[change.entryID], let origin = listOrigins[change.entryID],
                  let file = openedFiles.first(where: { $0.url.path == path }), let baseline = file.vault.fileBaseline,
                  file.vault.entries.indices.contains(slot), file.vault.entries[slot].id == origin else { continue }
            var write = staged[path] ?? ChromeWrite(path: path, url: file.url, vault: file.vault, password: file.password, baseline: baseline, revision: file.revision, updated: [])
            if staged[path] == nil { order.append(path) }
            ChromeUpdates.apply(change, to: &write.vault.entries[slot], kind: kind, now: now)
            if change.replacement != nil, kind != .declined { write.updated.insert(change.entryID) }
            staged[path] = write
        }
        return order.compactMap { staged[$0] }
    }
}
#endif
