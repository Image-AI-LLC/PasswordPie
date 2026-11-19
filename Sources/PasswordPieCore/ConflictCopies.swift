import Foundation

/// A second copy of a database that a sync tool left because two Macs changed the file before either saw the other's
/// change. One Mac's version stays under the database's name and the other's is kept like this.
public struct ConflictCopy: Equatable, Sendable, Identifiable {
    public enum Tool: String, Sendable {
        case syncthing = "Syncthing"
        case dropbox = "Dropbox"
        case unison = "Unison"
        case iCloudDrive = "iCloud Drive"
        /// A name a sync tool or a person could have given: "Passwords 2.kdbx".
        case unknown = ""
    }

    public var url: URL
    public var tool: Tool
    /// False for a name a person could also have given a copy they made. Such a copy is offered, never merged unasked.
    public var certain: Bool
    /// True for a version iCloud Drive holds for the file, which is not a file in the folder.
    public var isFileVersion = false

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }

    public init(url: URL, tool: Tool, certain: Bool, isFileVersion: Bool = false) {
        self.url = url
        self.tool = tool
        self.certain = certain
        self.isFileVersion = isFileVersion
    }
}

/// Finds the copies sync tools leave beside a database (docs/UX.md, "The same database on two Macs"). The names, for a
/// database `Passwords.kdbx`:
///
/// | Tool | Copy | From |
/// |---|---|---|
/// | Syncthing | `Passwords.sync-conflict-20261120-031800-ABCDEFG.kdbx` | docs.syncthing.net/users/syncing.html, "Conflicting Changes": `<filename>.sync-conflict-<date>-<time>-<modifiedBy>.<ext>` |
/// | Dropbox | `Passwords (Ada's conflicted copy 2026-11-20).kdbx` | help.dropbox.com/organize/conflicted-copy: "The editor's username, "conflicted copy", and the save date will be added to the filename." |
/// | Unison | `Passwords.kdbx (conflict_on_2026-11-20)`, `Passwords.kdbx (conflict #1_on_2026-11-20)` | Only with its `copyonconflict` preference. The name is from Unison's source (`src/files.ml`, `finishCopy`); the manual does not give it |
/// | iCloud Drive | no file: a conflict version of the file (`NSFileVersion.unresolvedConflictVersionsOfItem(at:)`) | developer.apple.com/documentation/foundation/nsfileversion: "one file is chosen as the current version and any other versions are tagged as being in conflict" |
///
/// Apple documents no name for a second file. `Passwords 2.kdbx`, which Finder and iCloud Drive are seen to make, is
/// therefore found as a name a person could have given too, like any `Passwords (…).kdbx`: offered, never merged
/// unasked. Unison without `copyonconflict` leaves no copy: its backups (`.bak.1.Passwords.kdbx`) are earlier versions.
public enum ConflictCopies {
    /// What kind of copy of `database` (a file name) a file named `name` beside it is, or nil when it is not one.
    public static func kind(ofFileNamed name: String, besideDatabaseNamed database: String) -> (tool: ConflictCopy.Tool, certain: Bool)? {
        guard name != database, !name.hasPrefix(".") else { return nil }
        let url = URL(fileURLWithPath: database)
        let ext = url.pathExtension
        let stem = ext.isEmpty ? database : String(database.dropLast(ext.count + 1))
        guard !stem.isEmpty else { return nil }
        // Unison adds to the whole name, extension included.
        if name.hasPrefix(database + " (conflict"), name.hasSuffix(")"), name.contains("_on_") {
            return name.contains("_was_deleted") ? nil : (.unison, true)
        }
        // Every other tool keeps the extension last.
        let suffix = ext.isEmpty ? "" : "." + ext
        guard name.count > stem.count + suffix.count, name.hasPrefix(stem), name.lowercased().hasSuffix(suffix.lowercased()) else { return nil }
        let middle = String(name.dropFirst(stem.count).dropLast(suffix.count))
        if middle.hasPrefix(".sync-conflict-") { return (.syncthing, true) }
        if middle.hasPrefix(" ("), middle.hasSuffix(")") {
            return middle.contains("conflicted copy") ? (.dropbox, true) : (.unknown, false)
        }
        if middle.hasPrefix(" "), middle.dropFirst().allSatisfy(\.isNumber), middle.count > 1 { return (.unknown, false) }
        return nil
    }

    /// The copies beside `database`, by name, and the conflict versions iCloud Drive holds for it. Files only.
    public static func find(beside database: URL) -> [ConflictCopy] {
        let manager = FileManager.default
        let folder = database.deletingLastPathComponent()
        var found: [ConflictCopy] = []
        let names = (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names.sorted() {
            guard let kind = kind(ofFileNamed: name, besideDatabaseNamed: database.lastPathComponent) else { continue }
            let url = folder.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            found.append(ConflictCopy(url: url, tool: kind.tool, certain: kind.certain))
        }
        for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: database) ?? [] {
            found.append(ConflictCopy(url: version.url, tool: .iCloudDrive, certain: true, isFileVersion: true))
        }
        return found
    }

    /// Tells iCloud Drive that a conflict version was dealt with: it was merged into the database. The version stays
    /// among the file's versions; nothing is deleted.
    public static func markResolved(_ copy: ConflictCopy, of database: URL) {
        guard copy.isFileVersion else { return }
        for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: database) ?? [] where version.url == copy.url {
            version.isResolved = true
        }
    }
}
