import Foundation

/// One row of the item editor: a website beyond the main one, or a field outside the editor's fixed rows.
public struct EditableField: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// The name it is stored under. Empty for a row added in the editor.
    public var key: String
    public var name: String
    public var value: String
    public var protected: Bool

    public init(id: UUID = UUID(), key: String = "", name: String = "", value: String = "", protected: Bool = false) {
        self.id = id
        self.key = key
        self.name = name
        self.value = value
        self.protected = protected
    }
}

/// What the editor lists beside its fixed rows, and how the edited rows go back into the entry.
/// See docs/UX.md, "Edit every field of an item".
public enum EntryFields {
    private static let standardKeys: Set<String> = ["title", "username", "password", "url", "notes", "otp"]

    /// The websites after the main one.
    public static func websites(of entry: VaultEntry) -> [EditableField] {
        EntryMerge.otherWebsites(entry).map { EditableField(key: $0.key, name: $0.key, value: $0.value, protected: $0.protected) }
    }

    /// Every filled field that has no row of its own. PasswordPie's bookkeeping and the one-time password settings are left out.
    public static func custom(of entry: VaultEntry) -> [EditableField] {
        let websites = Set(EntryMerge.otherWebsites(entry).map(\.key))
        return entry.fields.filter { isCustom($0, websites: websites) }
            .map { EditableField(key: $0.key, name: $0.key, value: $0.value, protected: $0.protected) }
    }

    /// A form input that had no name when it was saved, kept under a made-up one such as `no_name_eeaae`.
    /// The editor lists these apart, folded, so they can be removed together.
    public static func isUnnamed(_ name: String) -> Bool {
        name.lowercased().hasPrefix("no_name")
    }

    private static func isCustom(_ field: VaultField, websites: Set<String>) -> Bool {
        let key = field.key.lowercased()
        return !field.key.isEmpty && !field.value.isEmpty && !standardKeys.contains(key) && !key.hasPrefix("timeotp")
            && !EntryMerge.isReservedKey(field.key) && !websites.contains(field.key)
    }

    /// Puts the editor's rows back. A row that is gone removes its field, an empty row is dropped, and a row that was not
    /// touched keeps its place, so saving without a change leaves the entry as it was.
    public static func apply(websites: [EditableField], custom: [EditableField], to entry: inout VaultEntry) {
        let listed = Set((Self.websites(of: entry) + Self.custom(of: entry)).map(\.key))
        var sites = websites.map { row -> EditableField in
            var row = row
            row.value = row.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return row
        }.filter { !$0.value.isEmpty }
        if entry.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let first = sites.first {
            entry.url = first.value
            sites.removeFirst()
        }
        let fields = custom.filter { !$0.value.isEmpty }

        // Names that cannot be given out: the fixed rows, the bookkeeping, and everything the editor does not list.
        var taken = standardKeys
        taken.insert(EntryMerge.keepSeparateKey.lowercased())
        taken.insert(EntryMerge.manifestKey.lowercased())
        taken.insert(PreviousPasswords.key.lowercased())
        for field in entry.fields where !listed.contains(field.key) { taken.insert(field.key.lowercased()) }
        // A row that keeps its name has it before a renamed or new row can ask for the same one.
        for row in sites where listed.contains(row.key) { taken.insert(row.key.lowercased()) }
        for row in fields where listed.contains(row.key) && name(of: row) == row.key { taken.insert(row.key.lowercased()) }

        var replaced: [String: [VaultField]] = [:]
        var added: [VaultField] = []
        for row in sites {
            if listed.contains(row.key) {
                replaced[row.key, default: []].append(VaultField(key: row.key, value: row.value, protected: row.protected))
            } else {
                added.append(VaultField(key: unique("URL", from: 2, always: true, taken: &taken), value: row.value))
            }
        }
        for row in fields {
            let wanted = name(of: row)
            let kept = listed.contains(row.key)
            let key = kept && wanted == row.key ? row.key : unique(wanted, from: 2, always: false, taken: &taken)
            let field = VaultField(key: key, value: row.value, protected: row.protected)
            if kept { replaced[row.key, default: []].append(field) } else { added.append(field) }
        }
        // Fields that share a key take their rows in order, so each keeps its own value.
        var next: [String: Int] = [:]
        entry.fields = entry.fields.compactMap { field in
            guard listed.contains(field.key), !field.value.isEmpty else { return field }
            let index = next[field.key, default: 0]
            next[field.key] = index + 1
            let rows = replaced[field.key] ?? []
            return index < rows.count ? rows[index] : nil
        } + added
    }

    private static func name(of row: EditableField) -> String {
        let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return row.key.isEmpty ? "Field" : row.key
    }

    /// `base`, or `base (2)`, `base (3)` and so on when the name is taken. `always` numbers it from the start, as a website is.
    private static func unique(_ base: String, from start: Int, always: Bool, taken: inout Set<String>) -> String {
        var candidate = always ? "\(base) (\(start))" : base
        var number = start
        while taken.contains(candidate.lowercased()) {
            candidate = "\(base) (\(number))"
            number += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }
}
