import AppKit
import PasswordPieCore

/// The App Store app's folder grants: "The App Store app asks once for a database's folder" in docs/UX.md, and the rules
/// in `FolderGrants`. Outside the sandbox (the download, tests) every folder is usable, nothing is asked and nothing kept.
final class FolderAccess {
    static let defaultsKey = "folderBookmarks"

    /// What a bookmark resolves to. `stale` asks for a fresh bookmark while access still works.
    struct Resolved {
        let url: URL
        let stale: Bool
    }

    /// The pieces that touch the system. Tests replace them.
    struct System {
        var makeBookmark: (URL) throws -> Data
        var resolveBookmark: (Data) throws -> Resolved
        var startAccessing: (URL) -> Bool
        var stopAccessing: (URL) -> Void
        /// Asks for the folder that holds the database; nil when cancelled.
        var askForFolder: (URL) -> URL?

        static let live = System(
            makeBookmark: { try $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) },
            resolveBookmark: { data in
                var stale = false
                let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
                return Resolved(url: url, stale: stale)
            },
            startAccessing: { $0.startAccessingSecurityScopedResource() },
            stopAccessing: { $0.stopAccessingSecurityScopedResource() },
            askForFolder: FolderAccess.runFolderPanel
        )
    }

    let sandboxed: Bool
    private let defaults: UserDefaults
    private let system: System
    /// Allowed folder path → its bookmark, as saved.
    private(set) var bookmarks: [String: Data]
    /// Folders whose access was started in this process, so it can be stopped when the folder is forgotten.
    private var started: [String: URL] = [:]
    /// Folders the sandbox always lets the app use: its own container.
    private let ownFolders: [String]

    init(
        sandboxed: Bool = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil,
        defaults: UserDefaults = .standard,
        ownFolder: String = NSHomeDirectory(),
        system: System = .live
    ) {
        self.sandboxed = sandboxed
        self.defaults = defaults
        self.system = system
        self.ownFolders = [URL(fileURLWithPath: ownFolder).resolvingSymlinksInPath().path]
        bookmarks = sandboxed ? (defaults.dictionary(forKey: Self.defaultsKey) as? [String: Data] ?? [:]) : [:]
    }

    /// Starts access to every allowed folder. Run once, before any database is read. A bookmark that no longer resolves
    /// is dropped; a stale one is made again.
    func restore() {
        guard sandboxed else { return }
        var kept: [String: Data] = [:]
        for data in bookmarks.values {
            guard let resolved = try? system.resolveBookmark(data), system.startAccessing(resolved.url) else { continue }
            let current = Self.realFolder(resolved.url)
            started[current] = resolved.url
            kept[current] = resolved.stale ? ((try? system.makeBookmark(resolved.url)) ?? data) : data
        }
        bookmarks = kept
        save()
    }

    /// True when PasswordPie may read and write beside this database without asking.
    func isUsable(_ database: URL) -> Bool {
        !sandboxed || FolderGrants.isCovered(Self.realItem(database), by: ownFolders + Array(bookmarks.keys))
    }

    /// Asks for the database's folder when it is not usable yet. False when the person cancelled or chose a folder that
    /// does not hold the database; nothing is kept then.
    func ensure(_ database: URL) -> Bool {
        if isUsable(database) { return true }
        guard let chosen = system.askForFolder(database),
              FolderGrants.accepts(chosen: Self.realFolder(chosen), for: Self.realItem(database)),
              let data = try? system.makeBookmark(chosen) else { return false }
        let key = Self.realFolder(chosen)
        if system.startAccessing(chosen) { started[key] = chosen }
        bookmarks[key] = data
        save()
        return true
    }

    /// Forgets the folders no database in the list needs any more.
    func prune(keeping databases: [String]) {
        guard sandboxed else { return }
        // The keys are real folders (symbolic links resolved), so the databases are resolved the same way.
        let real = databases.map { Self.realItem(URL(fileURLWithPath: $0)) }
        let needed = Set(FolderGrants.stillNeeded(Array(bookmarks.keys), by: real))
        for path in bookmarks.keys where !needed.contains(path) {
            if let url = started.removeValue(forKey: path) { system.stopAccessing(url) }
            bookmarks.removeValue(forKey: path)
        }
        save()
    }

    static func declined(_ database: URL) -> String {
        "PasswordPie needs access to the folder “\(database.deletingLastPathComponent().lastPathComponent)” to open "
            + "“\(database.lastPathComponent)”. Choose it again and select Allow."
    }

    /// A folder's path with symbolic links resolved, so `~/Dropbox` and the folder it points to match.
    private static func realFolder(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    /// A database's path in the resolved folder around it. Only the folder is resolved: a database that is not created
    /// yet has nothing to resolve.
    private static func realItem(_ url: URL) -> String {
        url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
    }

    private func save() {
        defaults.set(bookmarks, forKey: Self.defaultsKey)
    }

    private static func runFolderPanel(for database: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = database.deletingLastPathComponent()
        panel.prompt = "Allow"
        let folder = database.deletingLastPathComponent().lastPathComponent
        panel.message = "PasswordPie keeps the previous version of “\(database.lastPathComponent)” beside it, so a save "
            + "can always be undone. Allow access to the folder “\(folder)” to open this database."
        return panel.runModal() == .OK ? panel.url : nil
    }
}
