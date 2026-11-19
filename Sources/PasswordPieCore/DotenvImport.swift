import Foundation

/// Puts what `DotenvFolder` read into a database: an item per dotenv file, found again by its folder and name, so the
/// same folder imported twice updates fields instead of making second items. Nothing is ever removed: a variable or a key
/// file that is gone from the folder stays in its item. See docs/UX.md, "A folder of .env files becomes items".
public enum DotenvImport {
    /// What importing an item would change, by name. Never a value.
    public struct Changes: Equatable, Sendable {
        public var newFields: [String] = []
        public var changedFields: [String] = []
        public var newFiles: [String] = []
        public var changedFiles: [String] = []
        public var notes = false

        public var isEmpty: Bool {
            newFields.isEmpty && changedFields.isEmpty && newFiles.isEmpty && changedFiles.isEmpty && !notes
        }
    }

    public enum Status: Equatable, Sendable {
        /// No item of that name is in that folder.
        case new
        case changes(Changes)
        case upToDate
    }

    public struct Summary: Equatable, Sendable {
        public var added = 0
        public var updated = 0
        public var unchanged = 0

        public init(added: Int = 0, updated: Int = 0, unchanged: Int = 0) {
            self.added = added
            self.updated = updated
            self.unchanged = unchanged
        }
    }

    /// "Agents/Keys" typed into Put them inside: the folders everything lands in. Empty for the top of the database.
    public static func parentPath(_ text: String) -> [String] {
        text.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The item already in the database for `item`: in the same folder, under the same name, and not in the Recycle Bin.
    static func existing(_ item: DotenvPlan.Item, inside parent: [String], in entries: [VaultEntry]) -> Int? {
        let folder = parent + item.folder
        return entries.firstIndex { !$0.trashed && $0.groupPath == folder && $0.title == item.title }
    }

    public static func status(of item: DotenvPlan.Item, inside parent: [String], in vault: Vault) -> Status {
        guard let index = existing(item, inside: parent, in: vault.entries) else { return .new }
        let changes = changes(of: item, to: vault.entries[index], in: vault)
        return changes.isEmpty ? .upToDate : .changes(changes)
    }

    /// Adds the items, or updates the ones already there. The entries carry their new key files as attachments for the
    /// save to write.
    public static func apply(_ items: [DotenvPlan.Item], inside parent: [String], to vault: inout Vault) -> Summary {
        var summary = Summary()
        for item in items {
            guard let index = existing(item, inside: parent, in: vault.entries) else {
                var entry = VaultEntry(groupPath: parent + item.folder)
                entry.title = item.title
                for field in item.fields { entry.setValue(field.value, for: field.key, protected: true) }
                if !item.notes.isEmpty { entry.notes = item.notes }
                entry.attachments = item.keyFiles.map { VaultAttachment(name: $0.name, data: $0.data) }
                vault.entries.append(entry)
                summary.added += 1
                continue
            }
            let changes = changes(of: item, to: vault.entries[index], in: vault)
            guard !changes.isEmpty else {
                summary.unchanged += 1
                continue
            }
            var entry = vault.entries[index]
            let touched = Set(changes.newFields + changes.changedFields)
            for field in item.fields where touched.contains(field.key) {
                entry.setValue(field.value, for: field.key, protected: true)
            }
            if changes.notes { entry.notes = item.notes }
            let files = Set(changes.newFiles + changes.changedFiles)
            entry.attachments = item.keyFiles.filter { files.contains($0.name) }.map { VaultAttachment(name: $0.name, data: $0.data) }
            vault.entries[index] = entry
            summary.updated += 1
        }
        return summary
    }

    private static func changes(of item: DotenvPlan.Item, to entry: VaultEntry, in vault: Vault) -> Changes {
        var changes = Changes()
        for field in item.fields {
            guard let stored = entry.fields.first(where: { $0.key == field.key }) else {
                changes.newFields.append(field.key)
                continue
            }
            // A value kept unprotected is protected by the import, as every variable is.
            if stored.value != field.value || !stored.protected { changes.changedFields.append(field.key) }
        }
        // A file without comments says nothing about the notes someone wrote in the item.
        changes.notes = !item.notes.isEmpty && entry.notes != item.notes
        for keyFile in item.keyFiles {
            guard let stored = vault.attachment(named: keyFile.name, of: entry.id) else {
                changes.newFiles.append(keyFile.name)
                continue
            }
            if stored != keyFile.data { changes.changedFiles.append(keyFile.name) }
        }
        return changes
    }

    // MARK: Checking the folder against the database

    /// One name of the folder to compare with the database: a variable, or a key file.
    public struct Subject: Equatable, Sendable {
        /// The file it is in, as a path inside the folder.
        public var file: String
        /// The variable's name, or the key file's.
        public var name: String
        public var folder: [String]
        public var title: String
        /// The field that holds it, or nil for a key file, which is the attachment `name`.
        public var key: String?
        /// What the file holds.
        public var expected: Data
    }

    /// Every variable and key file of the plan, with where an import puts it.
    public static func subjects(of plan: DotenvPlan, inside parent: [String]) -> [Subject] {
        plan.items.flatMap { item -> [Subject] in
            let folder = parent + item.folder
            let fields = item.fields.map {
                Subject(file: item.file ?? "", name: $0.name, folder: folder, title: item.title, key: $0.key, expected: Data($0.value.utf8))
            }
            let files = item.keyFiles.map {
                Subject(file: $0.path, name: $0.name, folder: folder, title: item.title, key: nil, expected: $0.data)
            }
            return fields + files
        }
    }
}
