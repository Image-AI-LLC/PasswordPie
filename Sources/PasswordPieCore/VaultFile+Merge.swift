import Foundation

/// What `VaultFile.save` did.
public struct VaultFileSave: Sendable {
    /// What the file holds now, with the bytes it was read from or written as.
    public var vault: Vault
    /// Set when another copy was merged: the file had been replaced on disk, or a copy was merged in.
    public var merge: VaultMergeReport?
    /// False when the file already held everything, so nothing was written.
    public var wrote: Bool
    /// The copy of this Mac's file from before the merge, when one was kept.
    public var backup: URL?

    public init(vault: Vault, merge: VaultMergeReport? = nil, wrote: Bool, backup: URL? = nil) {
        self.vault = vault
        self.merge = merge
        self.wrote = wrote
        self.backup = backup
    }
}

// Saving a database that a sync tool may have replaced meanwhile (docs/UX.md, "The same database on two Macs"). The file
// is the other Mac's version then, and writing ours over it would lose what was changed there. So the file is read
// again and ours is merged into it. This is the one way the app writes a database it has open; reading a replaced file
// is the same call with nothing of its own to write.
extension VaultFile {
    /// How many copies from before a merge stay beside the database.
    static let mergeBackupsKept = 5

    /// `Passwords.kdbx.before-merge-20261120-031800`, beside the database.
    static func mergeBackupPrefix(for url: URL) -> String {
        "\(url.lastPathComponent).before-merge-"
    }

    /// Writes `vault` to its file at `url`, after merging what is there if the file no longer holds the bytes `vault`
    /// was read from, and after merging `other` in when one is given.
    ///
    /// - `onlyIfNeeded`: write only when a merge left something to write. This is how a replaced file is read again:
    ///   when it holds everything this Mac had, the result is simply that file.
    /// - A merge that changes the file first keeps this Mac's file from before it as a dated copy beside the
    ///   database. The file being replaced becomes the `.snapshot`, as on every save.
    /// - The new file replaces the old one in one step, and only while the old one is still what was read here. If it
    ///   changed again meanwhile, the whole thing is done again, a few times at most.
    /// - A file that changed and cannot be opened with these keys, or is another database, is left alone, and nothing
    ///   is written. `merging:` is the caller's choice and may be any database.
    /// - A vault that was never read from or written to the file at `url` does not write over it either: a file that is
    ///   there is merged into as the same database or refused, and one that arrives while the keys are being derived
    ///   makes the save read again.
    public static func save(
        _ vault: Vault,
        to url: URL,
        password: String,
        keyFile: Data?,
        merging other: Vault? = nil,
        onlyIfNeeded: Bool = false
    ) throws -> VaultFileSave {
        try save(vault, to: url, password: password, keyFile: keyFile, merging: other, onlyIfNeeded: onlyIfNeeded, now: Date(), afterRead: {}, beforeReplace: {})
    }

    static func save(
        _ vault: Vault,
        to url: URL,
        password: String,
        keyFile: Data?,
        merging other: Vault? = nil,
        onlyIfNeeded: Bool = false,
        now: Date,
        afterRead: () throws -> Void = {},
        beforeReplace: () throws -> Void
    ) throws -> VaultFileSave {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try saveOnce(vault, to: url, password: password, keyFile: keyFile, merging: other, onlyIfNeeded: onlyIfNeeded, now: now, afterRead: afterRead, beforeReplace: beforeReplace)
            } catch let error as VaultWriteError where error == changedOnDisk && attempt < 3 {
                // Replaced again between reading it and writing: read it again.
                continue
            }
        }
    }

    private static func saveOnce(
        _ vault: Vault,
        to url: URL,
        password: String,
        keyFile: Data?,
        merging other: Vault?,
        onlyIfNeeded: Bool,
        now: Date,
        afterRead: () throws -> Void,
        beforeReplace: () throws -> Void
    ) throws -> VaultFileSave {
        let onDisk = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        try afterRead()
        var current = vault
        var report: VaultMergeReport?
        var needsWrite = !onlyIfNeeded
        var merged = false

        if let onDisk, onDisk != vault.fileBaseline {
            // Nothing below may write over a file this vault was not read from.
            guard vault.preserve != nil else {
                if vault.fileBaseline == nil {
                    throw VaultWriteError("\(url.lastPathComponent) is already there and this database was not read from it, so nothing was changed.")
                }
                throw VaultWriteError("\(url.lastPathComponent) changed on disk and this database cannot be merged with it, so nothing was changed.")
            }
            var theirs: Vault
            do {
                theirs = try KDBX.load(data: onDisk, password: password, keyFile: keyFile)
            } catch {
                throw unreadable(url, error)
            }
            // Another database that happens to open with the same keys is not a newer version of this one.
            guard theirs.rootGroupID == vault.rootGroupID else {
                throw VaultWriteError("\(url.lastPathComponent) was replaced on disk by another database, so nothing was changed. Lock PasswordPie and unlock to open the file that is there now.")
            }
            theirs.noteFileContents(onDisk)
            let outcome = try VaultMerge.merge(vault, into: theirs)
            report = outcome.report
            if outcome.report.changed {
                current = outcome.vault
                needsWrite = true
                merged = true
            } else {
                // The file holds everything this Mac had: it is the database now.
                current = theirs
                needsWrite = false
            }
        }
        if let other {
            let outcome = try VaultMerge.merge(other, into: current)
            var combined = report ?? VaultMergeReport()
            combined.add(outcome.report)
            report = combined
            if outcome.report.changed {
                current = outcome.vault
                needsWrite = true
                merged = true
            }
        }
        guard needsWrite else {
            return VaultFileSave(vault: current, merge: report, wrote: false, backup: nil)
        }

        var backup: URL?
        if merged, let known = vault.fileBaseline {
            do {
                backup = try keepMergeBackup(known, of: url, now: now)
            } catch {
                let reason = (error as? VaultWriteError)?.description ?? error.localizedDescription
                throw VaultWriteError("A copy of the database from before the merge could not be kept, so nothing was changed. \(reason)")
            }
        }
        var written = current
        let data = try KDBX.save(vault: &written, password: password, keyFile: keyFile)
        if let onDisk {
            try replace(url, with: data, password: password, keyFile: keyFile, expecting: written, baseline: onDisk,
                        keepingSnapshot: true, beforeReplace: beforeReplace)
        } else {
            // A file that arrived since it was read is not written over: the next round reads it.
            guard !FileManager.default.fileExists(atPath: url.path) else { throw changedOnDisk }
            try replace(url, with: data, password: password, keyFile: keyFile, expecting: written, beforeReplace: beforeReplace)
        }
        written.noteFileContents(data)
        return VaultFileSave(vault: written, merge: report, wrote: true, backup: backup)
    }

    private static func unreadable(_ url: URL, _ error: Error) -> VaultWriteError {
        let name = url.lastPathComponent
        if let kdbx = error as? KDBXError, kdbx == .wrongPassword {
            return VaultWriteError("\(name) changed on disk and does not open with this master password, so nothing was changed. If the password was changed on another Mac, lock PasswordPie and unlock with the new one.")
        }
        let reason = (error as? KDBXError)?.description ?? (error as? KeyFileError)?.description ?? error.localizedDescription
        return VaultWriteError("\(name) changed on disk and could not be read, so nothing was changed. \(reason)")
    }

    /// Removes the copies kept from before a merge, after a key change: each holds the database under the old keys.
    /// Returns the names of those that could not be removed. A folder that cannot be listed returns `"<prefix>*"`, so
    /// the copies that may be left are reported too.
    static func removeMergeBackups(of url: URL) -> [String] {
        let manager = FileManager.default
        let folder = url.deletingLastPathComponent()
        let prefix = mergeBackupPrefix(for: url)
        guard let listed = try? manager.contentsOfDirectory(atPath: folder.path) else { return ["\(prefix)*"] }
        let names = listed.filter { $0.hasPrefix(prefix) }.sorted()
        return names.filter { name in
            do {
                try manager.removeItem(at: folder.appendingPathComponent(name))
                return false
            } catch {
                return true
            }
        }
    }

    /// This Mac's file as it was before a merge, written from the bytes that were read, 0600. A copy that already holds
    /// the same bytes is reused. Only the newest `mergeBackupsKept` stay.
    static func keepMergeBackup(_ bytes: Data, of url: URL, now: Date) throws -> URL {
        let manager = FileManager.default
        let folder = url.deletingLastPathComponent()
        let prefix = mergeBackupPrefix(for: url)
        let existing = try manager.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(prefix) }.sorted()
        for name in existing {
            let candidate = folder.appendingPathComponent(name)
            if (try? Data(contentsOf: candidate)) == bytes { return candidate }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now)
        var backup = folder.appendingPathComponent(prefix + stamp)
        var number = 2
        while manager.fileExists(atPath: backup.path) {
            backup = folder.appendingPathComponent("\(prefix)\(stamp)-\(number)")
            number += 1
        }
        // Private from the first byte: the folder is often one a sync tool reads.
        let descriptor = open(backup.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            throw VaultWriteError("The copy could not be created (\(errno)).")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
        try handle.close()
        try restrict(backup)
        guard try Data(contentsOf: backup) == bytes else {
            throw VaultWriteError("The copy did not match the database.")
        }
        // The names sort by time. A copy that cannot be removed is one too many, not a failed merge. The copy just made is
        // never the one removed, also when a copy synced from a Mac with a faster clock sorts after it.
        let all = (existing + [backup.lastPathComponent]).sorted()
        for name in all.dropLast(mergeBackupsKept) where name != backup.lastPathComponent {
            try? manager.removeItem(at: folder.appendingPathComponent(name))
        }
        return backup
    }
}
