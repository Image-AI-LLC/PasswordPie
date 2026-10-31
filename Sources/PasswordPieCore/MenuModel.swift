import Foundation

/// One row of the menu. Submenus carry their rows so a menu can be built and tested without any UI.
public struct MenuRow: Equatable, Sendable {
    /// What the app draws in front of rows that are not entries or categories.
    public enum Icon: Equatable, Sendable {
        case favorites, generator, folders, folder, tags, tag
    }

    public enum Kind: Equatable, Sendable {
        case entry(UUID)
        case submenu
        case generator
        case separator
        case header
        /// "Show N more …": selecting it replaces the row with `children` in place.
        case showMore
        case disabled
    }

    public var kind: Kind
    public var title: String
    public var children: [MenuRow]
    public var category: ItemCategory?
    public var icon: Icon?
    public var favorite: Bool
    /// Shown after the title as " — username" when another row in the same list has the same title.
    public var username: String

    public init(
        kind: Kind,
        title: String = "",
        children: [MenuRow] = [],
        category: ItemCategory? = nil,
        icon: Icon? = nil,
        favorite: Bool = false,
        username: String = ""
    ) {
        self.kind = kind
        self.title = title
        self.children = children
        self.category = category
        self.icon = icon
        self.favorite = favorite
        self.username = username
    }

    public static let separator = MenuRow(kind: .separator)

    public var entryID: UUID? {
        if case .entry(let id) = kind { return id }
        return nil
    }

    public var isSelectable: Bool {
        switch kind {
        case .separator, .header, .disabled: return false
        default: return true
        }
    }

    public var opensSubmenu: Bool {
        switch kind {
        case .submenu, .generator: return true
        default: return false
        }
    }
}

public enum MenuBuilder {
    public static let categoryLimit = 5
    public static let groupLimit = 5

    /// The menu shown when the search field is empty: no items at the top level.
    public static func topLevel(
        entries: [VaultEntry],
        sources: [UUID: String] = [:],
        categoryLimit: Int = MenuBuilder.categoryLimit
    ) -> [MenuRow] {
        let visible = entries.filter { !$0.trashed }
        var rows: [MenuRow] = []

        let favorites = visible.filter(\.favorite)
        if !favorites.isEmpty {
            rows.append(MenuRow(kind: .submenu, title: "Favorites", children: entryRows(favorites, sources: sources), icon: .favorites))
        }
        rows.append(MenuRow(kind: .generator, title: "Password Generator", icon: .generator))

        let byCategory = Dictionary(grouping: visible, by: \.category)
        let categories = ItemCategory.allCases.filter { byCategory[$0] != nil }
        if !categories.isEmpty {
            rows.append(.separator)
            let categoryRows = categories.map { category in
                MenuRow(kind: .submenu, title: category.pluralName, children: entryRows(byCategory[category] ?? [], sources: sources), category: category)
            }
            if categoryRows.count > categoryLimit + 1 {
                rows += categoryRows.prefix(categoryLimit)
                let rest = Array(categoryRows.dropFirst(categoryLimit))
                rows.append(MenuRow(kind: .showMore, title: "Show \(rest.count) more categories", children: rest))
            } else {
                rows += categoryRows
            }
        }

        var tail: [MenuRow] = []
        let folders = folderRows(visible, prefix: [], sources: sources)
        if !folders.isEmpty {
            tail.append(MenuRow(kind: .submenu, title: "Folders", children: folders, icon: .folders))
        }
        let tags = tagRows(visible, sources: sources)
        if !tags.isEmpty {
            tail.append(MenuRow(kind: .submenu, title: "Tags", children: tags, icon: .tags))
        }
        if !tail.isEmpty {
            if rows.last?.kind != .separator { rows.append(.separator) }
            rows += tail
        }
        return rows
    }

    /// Search results: one group per category, each with a header, capped at `groupLimit` rows plus "Show N more items".
    public static func searchResults(
        entries: [VaultEntry],
        query: String,
        scope: SearchScope,
        lastUsed: [UUID: Date] = [:],
        now: Date = Date(),
        sources: [UUID: String] = [:]
    ) -> [MenuRow] {
        let found = searchEntries(entries, query: query, scope: scope, lastUsed: lastUsed, now: now)
        guard !found.isEmpty else {
            return [MenuRow(kind: .disabled, title: "No items found")]
        }
        let byCategory = Dictionary(grouping: found, by: \.category)
        var rows: [MenuRow] = []
        for category in ItemCategory.allCases {
            guard let group = byCategory[category] else { continue }
            rows.append(MenuRow(kind: .header, title: category.searchGroupTitle, category: category))
            let all = entryRows(group, sources: sources, alreadySorted: true)
            rows += all.prefix(groupLimit)
            if all.count > groupLimit {
                let rest = Array(all.dropFirst(groupLimit))
                rows.append(MenuRow(kind: .showMore, title: "Show \(rest.count) more items", children: rest))
            }
        }
        return rows
    }

    /// Rows for a list of entries; `alreadySorted` keeps the caller's order (search results sort favorites first).
    static func entryRows(_ entries: [VaultEntry], sources: [UUID: String] = [:], alreadySorted: Bool = false) -> [MenuRow] {
        let sorted = alreadySorted ? entries : sortedForMenu(entries)
        return sorted.map { entry in
            MenuRow(
                kind: .entry(entry.id),
                title: entry.title.isEmpty ? "Untitled" : entry.title,
                category: entry.category,
                favorite: entry.favorite,
                username: rowDetail(entry, peers: sorted, sources: sources)
            )
        }
    }

    /// Same titles from different files show the file name. One file keeps the username.
    static func rowDetail(_ entry: VaultEntry, peers: [VaultEntry], sources: [UUID: String]) -> String {
        let key = titleKey(entry.title)
        let sameTitle = peers.filter { titleKey($0.title) == key }
        guard sameTitle.count > 1 else { return "" }
        let paths = sameTitle.map { sources[$0.id] ?? "" }
        let labels = DatabaseRoster.menuTitles(for: paths)
        let distinct = Set(labels.filter { !$0.isEmpty })
        guard distinct.count > 1, let index = sameTitle.firstIndex(where: { $0.id == entry.id }) else {
            return entry.username
        }
        let label = labels[index]
        if entry.username.isEmpty || label.isEmpty { return label.isEmpty ? entry.username : label }
        return "\(entry.username) — \(label)"
    }

    /// Titles compare after Any-Latin; Latin-ASCII; Any-Lower, as the real menu does.
    static func titleKey(_ title: String) -> String {
        title.applyingTransform(StringTransform("Any-Latin; Latin-ASCII; Any-Lower"), reverse: false) ?? title.lowercased()
    }

    private static func folderRows(_ entries: [VaultEntry], prefix: [String], sources: [UUID: String]) -> [MenuRow] {
        let depth = prefix.count
        let inFolders = entries.filter { $0.groupPath.count > depth && Array($0.groupPath.prefix(depth)) == prefix }
        let names = Set(inFolders.map { $0.groupPath[depth] })
        let ordered = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return ordered.map { name in
            let path = prefix + [name]
            var children = folderRows(entries, prefix: path, sources: sources)
            let direct = entries.filter { $0.groupPath == path }
            if !children.isEmpty && !direct.isEmpty { children.append(.separator) }
            children += entryRows(direct, sources: sources)
            return MenuRow(kind: .submenu, title: name, children: children, icon: .folder)
        }
    }

    private static func tagRows(_ entries: [VaultEntry], sources: [UUID: String]) -> [MenuRow] {
        var byTag: [String: [VaultEntry]] = [:]
        var display: [String: String] = [:]
        for entry in entries {
            for tag in entry.tagList where tag.caseInsensitiveCompare("Favorite") != .orderedSame {
                let key = tag.lowercased()
                display[key] = display[key] ?? tag
                byTag[key, default: []].append(entry)
            }
        }
        return byTag.keys.sorted { display[$0]!.localizedCaseInsensitiveCompare(display[$1]!) == .orderedAscending }.map { key in
            MenuRow(kind: .submenu, title: display[key]!, children: entryRows(byTag[key]!, sources: sources), icon: .tag)
        }
    }
}
