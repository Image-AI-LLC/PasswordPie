import Foundation

/// The build's release channel (docs/CHANNELS.md). Code that differs by channel takes it as a value, so tests can check
/// both channels from one build.
public enum AppChannel: Equatable, Sendable {
    /// The download from passwordpie.com: it can read Chrome's saved passwords.
    case direct
    /// The Mac App Store app: no Chrome reader.
    case appStore

    public static let current: AppChannel = {
        #if PP_DIRECT
        return .direct
        #else
        return .appStore
        #endif
    }()
}

/// What an action row does. The app decides how; the menu only says which.
public enum MenuAction: Equatable, Sendable {
    /// Preferences, at "Import passwords".
    case importPasswords
    /// Preferences, at "Chrome". Direct channel only.
    case syncChrome
    /// The item editor with a new item, as the gear's New Item.
    case newItem
}

/// One row of the menu. Submenus carry their rows so a menu can be built and tested without any UI.
public struct MenuRow: Equatable, Sendable {
    /// What the app draws in front of rows that are not entries or categories.
    public enum Icon: Equatable, Sendable {
        case favorites, generator, folders, folder, tags, tag, passwordsToChange
        case importPasswords, syncChrome, newItem
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
        /// Runs `MenuAction` on Return or click. No submenu.
        case action(MenuAction)
    }

    public var kind: Kind
    public var title: String
    public var children: [MenuRow]
    public var category: ItemCategory?
    public var icon: Icon?
    public var favorite: Bool
    /// Shown after the title as " — username" when another row in the same list has the same title.
    public var username: String
    /// Website host for the site icon lookup. Nil when the row is not a site, or the entry has no website.
    public var siteHost: String?
    /// A second line under the title. Only the empty database's action rows have one; it makes them two-line rows.
    public var detail: String
    /// Shown in red after the title: how many accounts Passwords to Change holds.
    public var count: Int
    /// The account's password is due for a change: a red dot on its icon.
    public var due: Bool

    public init(
        kind: Kind,
        title: String = "",
        children: [MenuRow] = [],
        category: ItemCategory? = nil,
        icon: Icon? = nil,
        favorite: Bool = false,
        username: String = "",
        siteHost: String? = nil,
        detail: String = "",
        count: Int = 0,
        due: Bool = false
    ) {
        self.count = count
        self.due = due
        self.kind = kind
        self.title = title
        self.children = children
        self.category = category
        self.icon = icon
        self.favorite = favorite
        self.username = username
        self.siteHost = siteHost
        self.detail = detail
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
        categoryLimit: Int = MenuBuilder.categoryLimit,
        channel: AppChannel = .current,
        now: Date = Date()
    ) -> [MenuRow] {
        let visible = entries.filter { !$0.trashed }
        guard !visible.isEmpty else { return emptyDatabase(channel: channel) }
        var rows: [MenuRow] = []

        let due = PasswordRotation.due(in: visible, now: now)
        if !due.isEmpty {
            rows.append(MenuRow(
                kind: .submenu,
                title: "Passwords to Change",
                children: entryRows(due, sources: sources, alreadySorted: true, now: now),
                icon: .passwordsToChange,
                count: due.count
            ))
        }

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

    /// Nothing to list yet: a "Get Started" group of where entries come from, then the generator. The group goes away
    /// with the first entry. Each line says only what the app does (docs/UX.md, "A new database says what to do next").
    static func emptyDatabase(channel: AppChannel) -> [MenuRow] {
        var rows: [MenuRow] = [
            MenuRow(kind: .header, title: "Get Started"),
            MenuRow(
                kind: .action(.importPasswords),
                title: "Import Passwords…",
                icon: .importPasswords,
                detail: "From a Chrome or Apple Passwords export"
            )
        ]
        // The App Store app has no Chrome reader.
        if channel == .direct {
            rows.append(MenuRow(
                kind: .action(.syncChrome),
                title: "Sync Chrome Passwords…",
                icon: .syncChrome,
                detail: "Search what Chrome saved on this Mac"
            ))
        }
        rows.append(MenuRow(kind: .action(.newItem), title: "New Item…", icon: .newItem, detail: "A login, password or secure note"))
        rows.append(.separator)
        rows.append(MenuRow(kind: .generator, title: "Password Generator", icon: .generator))
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
        searchRows(searchEntries(entries, query: query, scope: scope, lastUsed: lastUsed, now: now), sources: sources)
    }

    /// Search results from a prepared index. While the index is still being built, only its entries so far take part.
    public static func searchResults(
        index: SearchIndex,
        query: String,
        scope: SearchScope,
        lastUsed: [UUID: Date] = [:],
        now: Date = Date(),
        sources: [UUID: String] = [:]
    ) -> [MenuRow] {
        searchRows(searchEntries(in: index, query: query, scope: scope, lastUsed: lastUsed, now: now), sources: sources)
    }

    private static func searchRows(_ found: [VaultEntry], sources: [UUID: String]) -> [MenuRow] {
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
    static func entryRows(_ entries: [VaultEntry], sources: [UUID: String] = [:], alreadySorted: Bool = false, now: Date = Date()) -> [MenuRow] {
        let sorted = alreadySorted ? entries : sortedForMenu(entries)
        let details = rowDetails(sorted, sources: sources)
        return sorted.indices.map { index in
            let entry = sorted[index]
            let title = entry.title
            return MenuRow(
                kind: .entry(entry.id),
                title: title.isEmpty ? "Untitled" : title,
                category: entry.category,
                favorite: entry.favorite,
                username: details[index],
                siteHost: websiteHost(of: entry),
                due: PasswordRotation.isDue(entry, now: now)
            )
        }
    }

    /// The text after each row's title. Same titles from different files show the file name. One file keeps the username.
    /// Each title is keyed once and grouped, so a list of thousands of entries stays linear.
    static func rowDetails(_ entries: [VaultEntry], sources: [UUID: String]) -> [String] {
        var groups: [String: [Int]] = [:]
        for index in entries.indices {
            groups[titleKey(entries[index].title), default: []].append(index)
        }
        var details = Array(repeating: "", count: entries.count)
        for members in groups.values where members.count > 1 {
            let labels = DatabaseRoster.menuTitles(for: members.map { sources[entries[$0].id] ?? "" })
            let distinct = Set(labels.filter { !$0.isEmpty })
            for (position, index) in members.enumerated() {
                let username = entries[index].username
                guard distinct.count > 1 else {
                    details[index] = username
                    continue
                }
                let label = labels[position]
                if username.isEmpty || label.isEmpty {
                    details[index] = label.isEmpty ? username : label
                } else {
                    details[index] = "\(username) — \(label)"
                }
            }
        }
        return details
    }

    /// Titles compare after Any-Latin; Latin-ASCII; Any-Lower, as the real menu does.
    /// Plain ASCII skips the ICU transform, which gives the same lowercase result and costs far more.
    static func titleKey(_ title: String) -> String {
        if title.utf8.allSatisfy({ $0 < 0x80 }) { return title.lowercased() }
        return title.applyingTransform(StringTransform("Any-Latin; Latin-ASCII; Any-Lower"), reverse: false) ?? title.lowercased()
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
