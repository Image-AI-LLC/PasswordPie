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

    public static func replace(_ url: URL, with data: Data, password: String, entryIDs: [UUID]) throws {
        try replace(url, with: data, password: password, entryIDs: entryIDs, beforeReplace: {})
    }

    static func replace(
        _ url: URL,
        with data: Data,
        password: String,
        entryIDs: [UUID],
        beforeSnapshotCommit: () throws -> Void = {},
        beforeReplace: () throws -> Void
    ) throws {
        let manager = FileManager.default
        let exists = manager.fileExists(atPath: url.path)
        if exists {
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
        let actual = loaded.entries.map(\.id).sorted { $0.uuidString < $1.uuidString }
        let expected = entryIDs.sorted { $0.uuidString < $1.uuidString }
        guard actual == expected else {
            throw VaultWriteError("The saved database did not contain the same accounts, so the original file was kept.")
        }
        try beforeReplace()
        if exists {
            let current = try Data(contentsOf: url)
            let snapshot = try Data(contentsOf: snapshotURL(for: url))
            guard current == snapshot else {
                throw VaultWriteError("The database changed on disk during the save. The original file was kept.")
            }
            _ = try manager.replaceItemAt(url, withItemAt: temp)
        } else {
            try manager.moveItem(at: temp, to: url)
        }
        consumed = true
        try restrict(url)
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
