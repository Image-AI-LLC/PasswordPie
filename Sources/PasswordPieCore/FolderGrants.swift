import Foundation

/// Which folders the sandboxed App Store app needs to use a database. A database is never written alone: a save keeps the
/// previous version beside it (`VaultFile.snapshotURL`), writes through a temporary file in the same folder, and an import
/// is saved as a sibling `.kdbx`. The sandbox grants an Open or Save panel's file only, so the app asks for the folder
/// that holds the database and keeps a security-scoped bookmark of it. Paths only; the bookmarks are the app's.
public enum FolderGrants {
    /// The folder a database needs: the one holding the file, or the `.opvault` package.
    public static func folder(for database: String) -> String {
        normalized((normalized(database) as NSString).deletingLastPathComponent)
    }

    /// True when one of `folders` (allowed folders, or the app's own container) holds `database`, at any depth.
    public static func isCovered(_ database: String, by folders: [String]) -> Bool {
        let needed = folder(for: database)
        return folders.contains { holds(normalized($0), needed) }
    }

    /// The folder chosen in the panel will do when it is the database's folder or one above it.
    public static func accepts(chosen: String, for database: String) -> Bool {
        holds(normalized(chosen), folder(for: database))
    }

    /// The allowed folders that still hold a database in the list. The rest are forgotten.
    public static func stillNeeded(_ folders: [String], by databases: [String]) -> [String] {
        folders.filter { granted in databases.contains { isCovered($0, by: [granted]) } }
    }

    private static func holds(_ outer: String, _ inner: String) -> Bool {
        outer == "/" || inner == outer || inner.hasPrefix(outer + "/")
    }

    private static func normalized(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.isEmpty ? "/" : trimmed
    }
}
