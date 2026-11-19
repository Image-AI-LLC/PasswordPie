import AppKit
import PasswordPieCore
import UniformTypeIdentifiers

// The same database on two Macs (docs/UX.md): reading the file again when a sync tool replaced it, the copies such a
// tool leaves beside it, Merge from File…, and the line that says which items were changed on both Macs. The merge
// itself is `VaultMerge` and `VaultFile.save` in the core library; every write here goes through the session's one
// queue of saves, so reading a replaced file never runs beside a save.

/// The line under the search field about the database on more than one Mac. One at a time, the most pressing first.
enum MergeNotice: Equatable {
    /// The file changed on disk and cannot be read with this database's keys. The text is the whole reason.
    case unreadable(file: String, reason: String)
    case changedOnBoth(Int)
    case copyOffered(ConflictCopy)
    case copiesMerged([ConflictCopy])

    var summary: String {
        switch self {
        case .unreadable(let file, _): return "\(file) cannot be read"
        case .changedOnBoth(let count): return MergeSummary.changedOnBoth(count)
        // The words first: the panel is narrow, and a sync tool's file name is long.
        case .copyOffered(let copy): return "Possible copy: \(copy.shownName)"
        case .copiesMerged(let copies):
            return copies.count == 1 ? "A copy was merged in" : "\(copies.count) copies were merged in"
        }
    }

    var actionTitle: String {
        switch self {
        case .unreadable: return "Why?"
        case .changedOnBoth: return "Review"
        case .copyOffered: return "Merge…"
        case .copiesMerged: return "Move to Trash"
        }
    }
}

extension ConflictCopy {
    /// A version iCloud Drive holds has the database's own name: say what it is instead.
    var shownName: String { isFileVersion ? "A version in iCloud Drive" : name }
}

/// What a merge did, in words. Counts, never a title.
enum MergeSummary {
    static func changedOnBoth(_ count: Int) -> String {
        count == 1 ? "1 item was changed on both Macs" : "\(count) items were changed on both Macs"
    }

    /// "3 items added, 1 updated." for Merge from File…, or that there was nothing to add.
    static func text(_ report: VaultMergeReport?, fileName: String) -> String {
        guard let report, report.changed else { return "The database already has everything in \(fileName)." }
        var parts: [String] = []
        if report.added > 0 { parts.append(report.added == 1 ? "1 item added" : "\(report.added) items added") }
        if report.updated > 0 { parts.append("\(report.updated) updated") }
        if report.moved > 0 { parts.append("\(report.moved) moved") }
        if report.removed > 0 { parts.append("\(report.removed) removed") }
        var text = parts.isEmpty ? "Merged \(fileName)." : "Merged \(fileName): " + parts.joined(separator: ", ") + "."
        let both = report.changedOnBoth.count
        if both > 0 {
            text += " " + (both == 1 ? "1 item was changed in both" : "\(both) items were changed in both")
                + ": the later change is the item, and the earlier one is in its history."
        }
        return text
    }
}

/// What this unlock knows about the open databases' files and the copies beside them. Cleared on lock.
struct MergeState {
    struct Unreadable {
        var reason: String
        /// What the file looked like when it could not be read. It is not tried again until it changes.
        var signature: FileSignature?
        var dismissed = false
    }

    var unreadable: [String: Unreadable] = [:]
    /// Copies merged in this unlock that are still on disk, by database path: theirs to move to the Trash.
    var merged: [String: [ConflictCopy]] = [:]
    /// Copies that are offered, never merged unasked.
    var offered: [String: [ConflictCopy]] = [:]
    /// Databases whose file is being read again, or waits for its turn.
    var following: Set<String> = []
    /// Databases whose folder is being looked through for copies.
    var scanning: Set<String> = []
    var scanAgain: Set<String> = []
    /// Databases whose file changed again while it was being read: read once more when that read ends.
    var followAgain: Set<String> = []
    /// Copies whose merge waits for its turn or is being written, by database path: not opened a second time.
    var merging: [String: [ConflictCopy]] = [:]
}

/// One item of the list of items changed on both Macs.
struct ChangedOnBothItem: Identifiable, Equatable {
    struct Version: Identifiable, Equatable {
        /// Its place in the item's history in the file, 0 for the oldest.
        var id: Int
        var modified: Date?
        /// The names of the fields that differ from the item as it is now. Never a value.
        var differing: [String]
        /// The version this record is about: the change that did not become the item.
        var isTheEarlierChange: Bool
    }

    var id: String
    /// The item in the menu.
    var listID: UUID
    var title: String
    var username: String
    /// In the Recycle Bin now: the other Mac moved it there after this Mac's change.
    var trashed = false
    var kept: Date
    var older: Date
    /// Newest first.
    var versions: [Version]
}

/// The questions Merge from File… asks. Tests answer them without a window.
@MainActor
protocol MergePrompting: AnyObject {
    /// The master password, and key file if any, of a file that this database's keys do not open. Nil: cancelled.
    func keys(forFileNamed name: String, wrong: Bool) -> (password: String, keyFile: Data?)?
    func show(_ text: String, title: String)
}

/// A file a sync folder holds under a copy's name is read unasked only when it is a regular file of a size a database
/// can be, and asks for this database's own key derivation: a named pipe, a device, a huge file or a header asking for
/// any amount of time or memory must not stall or exhaust the app. The file is opened once, without following a link or
/// waiting, and everything is checked and read through that one descriptor.
private func readableCopyData(at url: URL, deriving kdf: KDFKind) -> Data? {
    let limit = 512 * 1024 * 1024
    // Opened without waiting (a named pipe would block) and without following a link, and checked through the
    // descriptor that is read, so the file cannot be swapped between the check and the read.
    let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
    guard descriptor >= 0 else { return nil }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    // The header first, from the same descriptor: a file that asks for other key settings costs one small read.
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= limit,
          var data = try? handle.read(upToCount: KDBX.headerLimit), KDBX.kdf(ofHeader: data) == kdf else { return nil }
    guard data.count == KDBX.headerLimit else { return data }
    guard let rest = try? handle.read(upToCount: limit + 1 - data.count) else { return nil }
    data.append(rest)
    return data.count <= limit ? data : nil
}

extension VaultSession {
    static let mergeTitle = "Merge from File"

    // MARK: Reading a file that was replaced

    /// These databases' files changed on disk (all the open ones when nil): each is read again, and merged if this Mac
    /// has something it lacks. Called by the file watcher.
    func filesChangedOnDisk(_ paths: [String]? = nil) {
        guard !locked else { return }
        for file in openedFiles where Self.follows(file) && (paths?.contains(file.url.path) ?? true) {
            follow(file.url.path)
        }
    }

    /// Only a KeePass 2 database that is saved in place. An import is written beside its source, which is never
    /// rewritten.
    static func follows(_ file: OpenedFile) -> Bool {
        VaultFormat.writesKDBX(file.url) && file.pendingSaveURL == nil && file.vault.fileBaseline != nil
    }

    private func follow(_ path: String) {
        guard !mergeState.following.contains(path) else {
            mergeState.followAgain.insert(path)
            return
        }
        let signature = FileSignature(path: path)
        // It could not be read as it is now: nothing new to try.
        if let trouble = mergeState.unreadable[path], trouble.signature == signature { return }
        mergeState.following.insert(path)
        enqueueFileWork(path: path, merging: nil, settled: { _ in }, done: { [weak self] failure in
            guard let self else { return }
            self.mergeState.following.remove(path)
            if let failure {
                self.mergeState.unreadable[path] = MergeState.Unreadable(reason: failure, signature: signature)
            } else {
                self.mergeState.unreadable[path] = nil
            }
            self.refreshMergeNotice()
            // Not for a database that is no longer open: a lock ends the waiting reads on its way.
            if self.mergeState.followAgain.remove(path) != nil, self.openedFiles.contains(where: { $0.url.path == path }) {
                self.follow(path)
            }
        })
    }

    /// After every write and every read of a replaced file. `readAgain`: nothing of this Mac's was being saved.
    func mergeSettled(_ saved: VaultFileSave, path: String, readAgain: Bool) {
        if saved.wrote || saved.merge != nil { mergeState.unreadable[path] = nil }
        // The other Mac's items may fold into ours, as after opening a file.
        if readAgain, saved.merge != nil { foldDuplicates(at: path) }
        refreshMergeNotice()
    }

    /// A database was opened: what its list of items changed on both Macs holds from before this Mac ever opened it
    /// is not news here.
    func mergeOpened(_ path: String) {
        let key = Self.seenChangesKey(path)
        if UserDefaults.standard.object(forKey: key) == nil, let file = openedFiles.first(where: { $0.url.path == path }) {
            UserDefaults.standard.set(MergeConflictLog.records(in: file.vault.customData).map(\.id), forKey: key)
        }
        lookForCopies(of: [path])
    }

    /// A database leaves the list: what this Mac remembered having shown and merged for it goes too.
    func forgetMergeMemory(of path: String) {
        UserDefaults.standard.removeObject(forKey: Self.seenChangesKey(path))
        UserDefaults.standard.removeObject(forKey: Self.handledCopiesKey(path))
    }

    // MARK: Items changed on both Macs

    private static func seenChangesKey(_ path: String) -> String { "mergeSeenChanges.\(path)" }

    private var currentFile: OpenedFile? {
        openedFiles.first { $0.url.path == databaseURL.path }
    }

    /// The menu's id for an item of the current database, by the id the file has for it.
    private func listID(forStored id: UUID) -> UUID? {
        let path = databaseURL.path
        return entries.first { listOrigins[$0.id] == id && listPaths[$0.id] == path }?.id
    }

    /// What the current database lists as changed on both Macs, for the items it still has. One in the Recycle Bin
    /// counts: a change here that lost to a later move to the bin on the other Mac is exactly what must not go unseen.
    private func changeRecords() -> [MergeConflictLog.Record] {
        guard let file = currentFile else { return [] }
        return MergeConflictLog.records(in: file.vault.customData).filter { listID(forStored: $0.item) != nil }
    }

    private func unseenChangeRecords() -> [MergeConflictLog.Record] {
        let seen = Set(UserDefaults.standard.stringArray(forKey: Self.seenChangesKey(databaseURL.path)) ?? [])
        return changeRecords().filter { !seen.contains($0.id) }
    }

    /// True while the gear menu offers Changed on Both Macs….
    var hasItemsChangedOnBoth: Bool { !locked && !changeRecords().isEmpty }

    /// The list, newest first: each item once, with its newest record, and its earlier versions.
    func itemsChangedOnBoth() -> [ChangedOnBothItem] {
        guard let file = currentFile else { return [] }
        var items: [ChangedOnBothItem] = []
        var listed = Set<UUID>()
        for record in changeRecords().reversed() where listed.insert(record.item).inserted {
            // Among everything the database holds, the Recycle Bin included.
            guard let listID = listID(forStored: record.item), let entry = entries.first(where: { $0.id == listID }) else { continue }
            let versions = file.vault.versions(of: record.item).reversed().map { version in
                ChangedOnBothItem.Version(
                    id: version.id,
                    modified: version.modified,
                    differing: Self.differingFields(version, from: entry),
                    isTheEarlierChange: version.modified.map { Int64($0.timeIntervalSince1970.rounded(.down)) } == record.older
                )
            }
            items.append(ChangedOnBothItem(
                id: record.id, listID: listID, title: entry.title, username: entry.username, trashed: entry.trashed,
                kept: record.keptDate, older: record.olderDate, versions: Array(versions)
            ))
        }
        return items
    }

    /// PasswordPie's own bookkeeping fields are not something a person changed.
    private static func isBookkeeping(_ key: String) -> Bool {
        key == PreviousPasswords.key || key.caseInsensitiveCompare(PasswordRotation.changedKey) == .orderedSame
    }

    static func differingFields(_ version: VaultEntryVersion, from entry: VaultEntry) -> [String] {
        func values(_ fields: [VaultField]) -> [String: String] {
            Dictionary(fields.filter { !$0.key.isEmpty && !isBookkeeping($0.key) }.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        }
        let (old, new) = (values(version.fields), values(entry.fields))
        let order = version.fields.map(\.key) + entry.fields.map(\.key)
        var names: [String] = []
        for key in order where old[key] != new[key] && !isBookkeeping(key) {
            let name = fieldName(key)
            if !names.contains(name) { names.append(name) }
        }
        if version.tags != entry.tags { names.append("Tags") }
        return names
    }

    private static func fieldName(_ key: String) -> String {
        switch key {
        case "UserName": return "Username"
        case "URL": return "Website"
        case "otp": return "Two-step code"
        default: return key
        }
    }

    /// Makes an earlier version the item again. The version it replaces goes into the history, as with any edit. The
    /// list of older passwords stays as it is now: it is a record of what was, not part of a version.
    func restoreVersion(_ version: Int, of listID: UUID, then done: @escaping (Bool) -> Void = { _ in }) {
        guard let stored = listOrigins[listID], let path = listPaths[listID],
              let file = openedFiles.first(where: { $0.url.path == path }),
              let earlier = file.vault.versions(of: stored).first(where: { $0.id == version }) else {
            done(false)
            return
        }
        changeEntry(listID, { entry in
            var fields = earlier.fields.filter { $0.key != PreviousPasswords.key }
            fields += entry.fields.filter { $0.key == PreviousPasswords.key }
            guard fields != entry.fields || earlier.tags != entry.tags else { return false }
            entry.fields = fields
            entry.tags = earlier.tags
            return true
        }, then: done)
    }

    /// The line was read (Review) or dismissed (×): these are not news on this Mac any more.
    func markChangesSeen() {
        let path = databaseURL.path
        guard let file = currentFile else { return }
        // Only what the database still lists is remembered, so the preference does not grow.
        UserDefaults.standard.set(MergeConflictLog.records(in: file.vault.customData).map(\.id), forKey: Self.seenChangesKey(path))
        refreshMergeNotice()
    }

    // MARK: The line under the search field

    func refreshMergeNotice() {
        let notice = locked ? nil : currentMergeNotice()
        if notice != mergeNotice { mergeNotice = notice }
    }

    private func currentMergeNotice() -> MergeNotice? {
        let path = databaseURL.path
        if let trouble = mergeState.unreadable[path], !trouble.dismissed {
            return .unreadable(file: databaseURL.lastPathComponent, reason: trouble.reason)
        }
        let unseen = Set(unseenChangeRecords().map(\.item)).count
        if unseen > 0 { return .changedOnBoth(unseen) }
        if let copy = mergeState.offered[path]?.first { return .copyOffered(copy) }
        if let copies = mergeState.merged[path], !copies.isEmpty { return .copiesMerged(copies) }
        return nil
    }

    /// The line's button.
    func performMergeNotice() {
        guard let notice = mergeNotice else { return }
        switch notice {
        case .unreadable(_, let reason):
            mergePrompts.show(reason, title: "The database changed on disk")
        case .changedOnBoth:
            AppDelegate.shared?.showChangedOnBoth()
            markChangesSeen()
        case .copyOffered(let copy):
            mergeFile(at: copy.url, offered: copy)
        case .copiesMerged(let copies):
            trash(copies)
        }
    }

    /// The line's ×.
    func dismissMergeNotice() {
        guard let notice = mergeNotice else { return }
        let path = databaseURL.path
        switch notice {
        case .unreadable:
            mergeState.unreadable[path]?.dismissed = true
        case .changedOnBoth:
            markChangesSeen()
        case .copyOffered(let copy):
            rememberHandled(copy, of: path)
            mergeState.offered[path]?.removeAll { $0 == copy }
        case .copiesMerged:
            mergeState.merged[path] = nil
        }
        refreshMergeNotice()
    }

    /// Moves merged copies to the Trash: the database holds everything they do. One that cannot be moved stays listed.
    private func trash(_ copies: [ConflictCopy]) {
        let path = databaseURL.path
        var failed: [ConflictCopy] = []
        let merged = handledCopies(of: path)
        for copy in copies {
            // Only the file that was merged. One a sync tool or a person has written again since holds something the
            // database may lack: it stays, and is looked at afresh.
            guard merged[copy.url.path] == FileSignature(path: copy.url.path)?.text else { continue }
            do {
                try moveToTrash(copy.url)
            } catch {
                failed.append(copy)
            }
        }
        mergeState.merged[path] = failed.isEmpty ? nil : failed
        lookForCopies(of: [path])
        if let first = failed.first {
            mergePrompts.show("\(first.name) could not be moved to the Trash. It is still beside the database.", title: "Move to Trash")
        }
        refreshMergeNotice()
    }

    // MARK: The copies a sync tool leaves

    private static func handledCopiesKey(_ path: String) -> String { "mergeHandledCopies.\(path)" }

    /// Copies already merged or dismissed, by path, as the file looked then. A copy that changed since counts as new.
    private func handledCopies(of path: String) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: Self.handledCopiesKey(path)) as? [String: String] ?? [:]
    }

    /// `signature` is the copy's as of the moment its bytes were read; nil takes the file's as it is now.
    private func rememberHandled(_ copy: ConflictCopy, of path: String, signature: String? = nil) {
        var handled = handledCopies(of: path).filter { FileManager.default.fileExists(atPath: $0.key) }
        handled[copy.url.path] = signature ?? FileSignature(path: copy.url.path)?.text ?? ""
        UserDefaults.standard.set(handled, forKey: Self.handledCopiesKey(path))
    }

    /// Looks beside these databases (all the open ones when nil) for copies a sync tool left. One that is certainly the
    /// other Mac's version of this database is merged in; any other is offered. Called after unlocking and when a
    /// database's folder changes.
    func lookForCopies(of paths: [String]? = nil) {
        guard !locked else { return }
        for file in openedFiles where Self.follows(file) && (paths?.contains(file.url.path) ?? true) {
            lookForCopies(beside: file)
        }
    }

    private func lookForCopies(beside file: OpenedFile) {
        let path = file.url.path
        guard !mergeState.scanning.contains(path) else {
            mergeState.scanAgain.insert(path)
            return
        }
        // What is listed and gone from disk is dropped: someone moved it away.
        mergeState.merged[path]?.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
        mergeState.offered[path]?.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
        let handled = handledCopies(of: path)
        let known = (mergeState.merged[path] ?? []) + (mergeState.offered[path] ?? []) + (mergeState.merging[path] ?? [])
        mergeState.scanning.insert(path)
        let (url, password, keyFile, ours, ourKDF, generation) = (file.url, file.password, file.keyFile, file.vault.rootGroupID, file.vault.kdf.kind, catalogGeneration)
        // Listing the folder can be slow, and opening a copy derives its key, which can take seconds: off the main
        // thread, as unlocking is.
        let load: @Sendable () -> [(ConflictCopy, Vault?, String)] = {
            let found = ConflictCopies.find(beside: url).filter { copy in
                !known.contains(copy) && handled[copy.url.path] != (FileSignature(path: copy.url.path)?.text ?? "")
            }
            return found.map { copy in
                // A name a person could have given is never opened unasked.
                // The signature is taken before the bytes are read: a copy written again after that is not the one merged.
                let signature = FileSignature(path: copy.url.path)?.text ?? ""
                guard copy.certain else { return (copy, nil, signature) }
                // Its header is untrusted until a key opens it: a key derivation other than this database's own, which
                // could ask for any amount of time or memory, is not run unasked.
                let vault = readableCopyData(at: copy.url, deriving: ourKDF).flatMap {
                    try? KDBX.load(data: $0, password: password, keyFile: keyFile)
                }
                // The other Mac's version of this database opens with its keys and has its root group.
                return (copy, vault.flatMap { $0.rootGroupID != nil && $0.rootGroupID == ours ? $0 : nil }, signature)
            }
        }
        let finish: @MainActor ([(ConflictCopy, Vault?, String)]) -> Void = { [weak self] opened in
            guard let self else { return }
            self.mergeState.scanning.remove(path)
            guard generation == self.catalogGeneration, !self.locked else { return }
            for (copy, vault, signature) in opened {
                guard let vault else {
                    // Not certainly this database with these keys: asked about, never merged unasked.
                    self.mergeState.offered[path, default: []].append(copy)
                    continue
                }
                // From now until its merge is written, another look through the folder leaves it alone.
                self.mergeState.merging[path, default: []].append(copy)
                self.enqueueFileWork(path: path, merging: vault, settled: { [weak self] _ in
                    guard let self else { return }
                    self.rememberHandled(copy, of: path, signature: signature)
                    if copy.isFileVersion {
                        ConflictCopies.markResolved(copy, of: URL(fileURLWithPath: path))
                    } else {
                        if self.mergeState.merged[path]?.contains(copy) != true { self.mergeState.merged[path, default: []].append(copy) }
                    }
                }, done: { [weak self] _ in
                    self?.mergeState.merging[path]?.removeAll { $0 == copy }
                    self?.refreshMergeNotice()
                })
            }
            self.refreshMergeNotice()
            if self.mergeState.scanAgain.remove(path) != nil { self.lookForCopies(of: [path]) }
        }
        guard writesInBackground else {
            finish(load())
            return
        }
        Task { @MainActor in
            finish(await Task.detached(priority: .utility, operation: load).value)
        }
    }

    // MARK: Merge from File…

    /// The gear menu's Merge from File…: a KeePass database the person picks is merged into the open one.
    func mergeFromFile() {
        guard !locked else { return }
        AppDelegate.shared?.presentFilePanel { [weak self] in
            guard let self, !self.locked else { return }
            let chooser = NSOpenPanel()
            chooser.canChooseFiles = true
            chooser.canChooseDirectories = false
            chooser.allowsMultipleSelection = false
            chooser.allowedContentTypes = [UTType(filenameExtension: "kdbx") ?? .data]
            chooser.message = "Choose a KeePass database to merge into \(self.databaseURL.lastPathComponent). The chosen file is not changed."
            chooser.prompt = "Merge"
            guard chooser.runModal() == .OK, let url = chooser.url else { return }
            self.mergeFile(at: url)
        }
    }

    /// Merges the database at `url` into the open one and says what came of it. This database's keys are tried first;
    /// if they do not open the file, its own are asked for. `offered` is the copy the line under the search field was
    /// about, which is then not offered again.
    func mergeFile(at url: URL, offered: ConflictCopy? = nil) {
        guard !locked, let file = currentFile else { return }
        let name = url.lastPathComponent
        guard Self.follows(file) else {
            mergePrompts.show("Only a KeePass .kdbx database can take a merge. Save this one as a database first.", title: Self.mergeTitle)
            return
        }
        guard url.standardizedFileURL.path != file.url.standardizedFileURL.path else {
            mergePrompts.show("\(name) is the open database.", title: Self.mergeTitle)
            return
        }
        // As the offered copy was when it was read, not when the merge is done.
        let offeredSignature = offered.map { _ in FileSignature(path: url.path)?.text ?? "" }
        openForMerge(url, password: file.password, keyFile: file.keyFile, firstTry: true) { [weak self] vault in
            guard let self else { return }
            let path = file.url.path
            // "Possible copy" was a guess from the file's name. A file that turns out to be another database is not
            // folded into this one on that guess: Merge from File… is the way to ask for exactly that.
            if let offered, vault.rootGroupID != file.vault.rootGroupID {
                self.rememberHandled(offered, of: path, signature: offeredSignature)
                self.mergeState.offered[path]?.removeAll { $0 == offered }
                self.refreshMergeNotice()
                self.mergePrompts.show("\(name) is another database, not a copy of this one, so it was not merged. To bring its items in all the same, choose Merge from File… in the gear menu.", title: Self.mergeTitle)
                return
            }
            var report: VaultMergeReport?
            self.enqueueFileWork(path: path, merging: vault, settled: { saved in
                report = saved.merge
            }, done: { [weak self] failure in
                guard let self else { return }
                if let failure {
                    if failure == Self.lockedBeforeMergeText {
                        // `lock()` is calling this: the window waits until it has returned.
                        DispatchQueue.main.async { self.mergePrompts.show(failure, title: Self.mergeTitle) }
                    } else {
                        self.mergePrompts.show(failure, title: Self.mergeTitle)
                    }
                    return
                }
                if let offered {
                    self.rememberHandled(offered, of: path, signature: offeredSignature)
                    self.mergeState.offered[path]?.removeAll { $0 == offered }
                    if !offered.isFileVersion { self.mergeState.merged[path, default: []].append(offered) }
                }
                self.refreshMergeNotice()
                self.mergePrompts.show(MergeSummary.text(report, fileName: name), title: Self.mergeTitle)
            })
        }
    }

    /// Opens the file to merge, asking for its keys for as long as the ones tried are wrong and the person goes on.
    private func openForMerge(_ url: URL, password: String, keyFile: Data?, firstTry: Bool, then merge: @escaping @MainActor (Vault) -> Void) {
        let name = url.lastPathComponent
        let load: @Sendable () -> Result<Vault, Error> = {
            Result { try KDBX.load(data: try Data(contentsOf: url), password: password, keyFile: keyFile) }
        }
        let generation = catalogGeneration
        let finish: @MainActor (Result<Vault, Error>) -> Void = { [weak self] result in
            guard let self, generation == self.catalogGeneration, !self.locked else { return }
            switch result {
            case .success(let vault):
                merge(vault)
            case .failure(let error) where self.isWrongPassword(error):
                guard let keys = self.mergePrompts.keys(forFileNamed: name, wrong: !firstTry) else { return }
                self.openForMerge(url, password: keys.password, keyFile: keys.keyFile, firstTry: false, then: merge)
            case .failure(let error):
                self.mergePrompts.show("\(name) could not be read. \(self.openErrorText(error))", title: Self.mergeTitle)
            }
        }
        guard writesInBackground else {
            finish(load())
            return
        }
        Task { @MainActor in
            finish(await Task.detached(priority: .userInitiated, operation: load).value)
        }
    }
}

/// Merge from File…'s windows.
@MainActor
final class AppKitMergePrompts: MergePrompting {
    func keys(forFileNamed name: String, wrong: Bool) -> (password: String, keyFile: Data?)? {
        let alert = NSAlert()
        alert.messageText = wrong ? "That did not open \(name)" : "\(name) has another master password"
        alert.informativeText = "Enter the master password of the file to merge. If it also needs a key file, choose it. Neither is kept."
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 30, width: 280, height: 22))
        field.placeholderString = "Master password"
        let chooser = KeyFileChooser(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 54))
        accessory.addSubview(field)
        accessory.addSubview(chooser)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = field
        let answer = AppDelegate.shared.map { $0.keepOpen { alert.runModal() } } ?? alert.runModal()
        guard answer == .alertFirstButtonReturn else { return nil }
        return (field.stringValue, chooser.contents)
    }

    func show(_ text: String, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        if let delegate = AppDelegate.shared {
            _ = delegate.keepOpen { alert.runModal() }
        } else {
            alert.runModal()
        }
    }
}

/// "Key File…" and the chosen file's name, inside the password question.
private final class KeyFileChooser: NSView {
    private(set) var contents: Data?
    private let button = NSButton(title: "Key File…", target: nil, action: nil)
    private let label = NSTextField(labelWithString: "No key file")

    override init(frame: NSRect) {
        super.init(frame: frame)
        button.target = self
        button.action = #selector(choose)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.sizeToFit()
        button.frame.origin = NSPoint(x: 0, y: 0)
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.frame = NSRect(x: button.frame.maxX + 8, y: 3, width: frame.width - button.frame.maxX - 8, height: 16)
        addSubview(button)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        contents = data
        label.stringValue = url.lastPathComponent
    }
}
