import Foundation

public struct VaultWriteError: Error, Equatable, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// Replaces a KDBX file only after a copy of the previous file is kept and the new bytes open.
public enum VaultFile {
    /// `Passwords.kdbx` becomes `Passwords.kdbx.snapshot`, beside the database.
    public static func snapshotURL(for url: URL) -> URL {
        url.appendingPathExtension("snapshot")
    }

    public static func replace(_ url: URL, with data: Data, password: String, expecting vault: Vault) throws {
        try replace(url, with: data, password: password, expecting: vault, beforeReplace: {})
    }

    /// For a write nobody asked for at that moment: nothing happens unless the file still holds `baseline`, the bytes this
    /// session last read or wrote. The previous file is kept as the snapshot only once that holds.
    public static func replace(_ url: URL, with data: Data, password: String, expecting vault: Vault, baseline: Data) throws {
        try replace(url, with: data, password: password, expecting: vault, baseline: baseline, keepingSnapshot: true, beforeReplace: {})
    }

    /// Opens any vault. A `.kdbx` file with damaged XML opens from repaired text and is then rewritten, with the exact
    /// bytes that were decoded kept in a backup no later save touches. The rewrite happens only if the file still
    /// holds those bytes, so a newer version that sync delivered meanwhile stays. `.snapshot` is left as it was: it may
    /// be the last copy from before the damage. Any other file name is a copy the person opened, and is never rewritten.
    public static func openRecovering(url: URL, password: String, keyFile: Data? = nil) throws -> Vault {
        try openRecovering(url: url, password: password, keyFile: keyFile, beforeReplace: {})
    }

    static func openRecovering(
        url: URL,
        password: String,
        keyFile: Data? = nil,
        beforeReplace: () throws -> Void
    ) throws -> Vault {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return try VaultFormat.load(url: url, password: password, keyFile: keyFile)
        }
        let decoded = try Data(contentsOf: url)
        var vault = try VaultFormat.load(data: decoded, password: password, keyFile: keyFile, fileName: url.lastPathComponent)
        vault.noteFileContents(decoded)
        guard let recovery = vault.recovery else { return vault }
        let name = url.lastPathComponent
        guard VaultFormat.writesKDBX(url) else {
            vault.recoveryNotice = "\(name) has damaged XML and was opened from a repaired copy in memory. The file was not changed.\n\n\(recovery.summary)"
            return vault
        }
        do {
            let backup = try keepDamagedCopy(decoded, of: url)
            var healed = vault
            healed.recovery = nil
            let data = try KDBX.save(vault: &healed, password: password)
            try replace(url, with: data, password: password, expecting: healed, baseline: decoded, beforeReplace: beforeReplace)
            vault = healed
            vault.noteFileContents(data)
            vault.recoveryNotice = "Repaired \(name). The damaged file was kept as \(backup.lastPathComponent).\n\n\(recovery.summary)"
        } catch {
            let reason = (error as? VaultWriteError)?.description ?? error.localizedDescription
            vault.recoveryNotice = "\(name) has damaged XML and was opened from a repaired copy in memory. The file was not changed: \(reason)\n\n\(recovery.summary)"
        }
        return vault
    }

    static func replace(
        _ url: URL,
        with data: Data,
        password: String,
        expecting expected: Vault,
        baseline: Data? = nil,
        keepingSnapshot: Bool = false,
        beforeSnapshotCommit: () throws -> Void = {},
        beforeReplace: () throws -> Void,
        afterCommit: () throws -> Void = {},
        exchange: (URL, URL) -> Int32 = { renamex_np($0.path, $1.path, UInt32(RENAME_SWAP)) }
    ) throws {
        let manager = FileManager.default
        let exists = manager.fileExists(atPath: url.path)
        if baseline != nil, !exists {
            throw VaultWriteError("The database is no longer on disk.")
        }
        if let baseline, keepingSnapshot, try Data(contentsOf: url) != baseline {
            throw changedOnDisk
        }
        if exists, baseline == nil || keepingSnapshot {
            try copySnapshot(of: url, beforeCommit: beforeSnapshotCommit)
            try restrict(url)
        }
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).passwordpie-write")
        var consumed = false
        defer {
            if !consumed, manager.fileExists(atPath: temp.path) {
                try? manager.removeItem(at: temp)
            }
        }
        try data.write(to: temp, options: .atomic)
        try restrict(temp)
        let loaded: Vault
        do {
            loaded = try KDBX.load(data: Data(contentsOf: temp), password: password)
        } catch {
            throw refused(error, existed: exists)
        }
        // A save moves an entry the model dropped into the recycle bin, so the file may hold more trashed entries.
        let expectedIDs = Set(expected.entries.map(\.id))
        var found = loaded
        found.entries.removeAll { $0.trashed && !expectedIDs.contains($0.id) }
        guard contentKeys(found) == contentKeys(expected) else {
            throw VaultWriteError("The saved database did not contain the same accounts, so the original file was kept.")
        }
        if let wanted = expected.preserve, let actual = loaded.preserve {
            guard wanted.binaryPayloads == actual.binaryPayloads,
                  let wantedRoot = wanted.document.rootElement(), let actualRoot = actual.document.rootElement(),
                  canonicalTree(wantedRoot) == canonicalTree(actualRoot) else {
                throw VaultWriteError("The saved database read back differently from what was saved, so the original file was kept.")
            }
        }
        try beforeReplace()
        if exists {
            let reference = try baseline ?? Data(contentsOf: snapshotURL(for: url))
            if try commitBySwap(temp: temp, url: url, reference: reference, keepTemp: &consumed, exchange: exchange) {
                // `temp` now holds the old file, and the defer removes it.
            } else {
                guard try Data(contentsOf: url) == reference else { throw changedOnDisk }
                _ = try manager.replaceItemAt(url, withItemAt: temp)
                consumed = true
            }
        } else {
            try manager.moveItem(at: temp, to: url)
            consumed = true
        }
        // The new file is in place. Nothing after this line can be a failed save. It was written 0600 before the commit,
        // so a failure here cannot leave it looser than that.
        do {
            try afterCommit()
            try restrict(url)
        } catch {
            return
        }
    }

    private static let changedOnDisk = VaultWriteError("The database changed on disk during the save. The original file was kept.")

    /// Exchanges the two files in one step, so a writer cannot land between the comparison and the replace. What came out
    /// is compared afterwards, and put back if it was not what this session expected. False where the volume cannot swap.
    private static func commitBySwap(
        temp: URL,
        url: URL,
        reference: Data,
        keepTemp: inout Bool,
        exchange: (URL, URL) -> Int32
    ) throws -> Bool {
        guard exchange(temp, url) == 0 else {
            if errno == ENOTSUP || errno == EINVAL { return false }
            throw VaultWriteError("The database could not be replaced (\(errno)).")
        }
        if (try? Data(contentsOf: temp)) == reference { return true }
        guard exchange(temp, url) == 0 else {
            // `temp` is now the only copy of the other writer's version, so it must outlive this call.
            keepTemp = true
            throw VaultWriteError("The database changed on disk during the save, and the other version is at \(temp.lastPathComponent).")
        }
        throw changedOnDisk
    }

    // MARK: Read-back

    /// One line per account, sorted, covering everything the model can change.
    private static func contentKeys(_ vault: Vault) -> [[String]] {
        vault.entries.map { entry in
            // A trashed entry stays wherever the bin is, and the reader drops these same path segments.
            let path = entry.trashed ? [] : entry.groupPath.filter {
                !$0.isEmpty && $0.caseInsensitiveCompare("Recycle Bin") != .orderedSame
            }
            let fields = entry.fields.filter { !$0.key.isEmpty }.map { "\($0.protected)\u{1F}\($0.key)\u{1F}\($0.value)" }.sorted()
            return [entry.id.uuidString, String(entry.trashed), entry.tags, path.joined(separator: "\u{1F}")] + fields
        }.sorted { $0.lexicographicallyPrecedes($1) }
    }

    /// The whole decrypted document, history and metadata included. Whitespace between elements does not count.
    private static func canonicalTree(_ element: XMLElement) -> [String] {
        let attributes = (element.attributes ?? []).map { "\($0.name ?? "")=\($0.stringValue ?? "")" }.sorted()
        var lines = ["<\(element.name ?? "") \(attributes.joined(separator: " "))"]
        let children = element.children ?? []
        let hasElements = children.contains { $0.kind == .element }
        for child in children {
            if let nested = child as? XMLElement {
                lines += canonicalTree(nested)
            } else if child.kind == .comment {
                lines.append("!\(child.stringValue ?? "")")
            } else if child.kind == .text {
                let text = child.stringValue ?? ""
                if !hasElements || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append("=\(text)")
                }
            }
        }
        lines.removeAll { $0 == "=" }
        lines.append(">")
        return lines
    }

    // MARK: Damaged files

    /// Written from the decoded bytes, not by copying the path, so it holds what was repaired even if the file just
    /// changed, and a symlink cannot make the backup point back at the live file. A repeat open reuses an equal backup.
    private static func keepDamagedCopy(_ bytes: Data, of url: URL) throws -> URL {
        let manager = FileManager.default
        let folder = url.deletingLastPathComponent()
        let prefix = "\(url.lastPathComponent).damaged-"
        for name in try manager.contentsOfDirectory(atPath: folder.path) where name.hasPrefix(prefix) {
            let existing = folder.appendingPathComponent(name)
            if (try? Data(contentsOf: existing)) == bytes { return existing }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var backup = folder.appendingPathComponent(prefix + formatter.string(from: Date()))
        if manager.fileExists(atPath: backup.path) {
            backup = folder.appendingPathComponent(prefix + UUID().uuidString)
        }
        try bytes.write(to: backup, options: .withoutOverwriting)
        try restrict(backup)
        guard try Data(contentsOf: backup) == bytes else {
            throw VaultWriteError("The backup of the damaged file did not match it.")
        }
        return backup
    }

    private static func copySnapshot(of url: URL, beforeCommit: () throws -> Void) throws {
        let manager = FileManager.default
        let snapshot = snapshotURL(for: url)
        let staging = snapshot.appendingPathExtension("incoming")
        if manager.fileExists(atPath: staging.path) {
            try manager.removeItem(at: staging)
        }
        var consumed = false
        defer {
            if !consumed, manager.fileExists(atPath: staging.path) { try? manager.removeItem(at: staging) }
        }
        try manager.copyItem(at: url, to: staging)
        try restrict(staging)
        try beforeCommit()
        if manager.fileExists(atPath: snapshot.path) {
            _ = try manager.replaceItemAt(snapshot, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: snapshot)
        }
        consumed = true
        try restrict(snapshot)
    }

    private static func restrict(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func refused(_ error: Error, existed: Bool) -> VaultWriteError {
        let reason = (error as? KDBXError)?.description ?? "The new database could not be read."
        if existed {
            return VaultWriteError("The new database could not be read back, so the original file was kept. \(reason)")
        }
        return VaultWriteError("The new database could not be read back, so it was not saved. \(reason)")
    }
}
