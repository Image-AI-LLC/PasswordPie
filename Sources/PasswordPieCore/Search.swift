import Foundation

public enum SearchScope: String, Sendable, Equatable {
    /// Title and URL host words.
    case major
    /// Major fields plus username, notes, tags and custom fields.
    case allFields
}

/// Case- and diacritic-insensitive fold, the behavior of NSPredicate `[cd]`.
public func foldForSearch(_ text: String) -> String {
    let decomposed = text.decomposedStringWithCanonicalMapping
    let scalars = decomposed.unicodeScalars.filter { !CharacterSet.nonBaseCharacters.contains($0) }
    return String(String.UnicodeScalarView(scalars)).lowercased()
}

/// Host-like piece of a URL used in search: after `//`, cut at `?`, `/`, or `:`, then fold.
public func urlSearchString(_ url: String) -> String {
    var body = url
    if let marker = body.range(of: "//") {
        body = String(body[marker.upperBound...])
    }
    let end = body.firstIndex(where: { $0 == "?" || $0 == "/" || $0 == ":" }) ?? body.endIndex
    return foldForSearch(String(body[..<end]))
}

/// Lowercased, whitespace-split, de-duplicated query tokens.
public func searchTokens(_ query: String) -> [String] {
    let folded = foldForSearch(query)
    var seen = Set<String>()
    var tokens: [String] = []
    for part in folded.unicodeScalars.split(whereSeparator: { CharacterSet.whitespacesAndNewlines.contains($0) }) {
        let token = String(String.UnicodeScalarView(part))
        if seen.insert(token).inserted {
            tokens.append(token)
        }
    }
    return tokens
}

/// Alphabetical (localized, case-insensitive); search results also put favorites first.
public func sortedForMenu(_ entries: [VaultEntry], favoritesFirst: Bool = false) -> [VaultEntry] {
    entries.sorted { lhs, rhs in
        if favoritesFirst, lhs.favorite != rhs.favorite { return lhs.favorite }
        let order = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

private func wordList(_ text: String) -> [String] {
    text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
}

private func hasPunctuation(_ token: String) -> Bool {
    token.contains { !$0.isLetter && !$0.isNumber }
}

private let standardKeys: Set<String> = ["title", "username", "password", "url", "notes", "otp"]

/// Entries matching every token of `query`, sorted. An empty query matches nothing here; callers show the initial menu.
public func searchEntries(_ entries: [VaultEntry], query: String, scope: SearchScope) -> [VaultEntry] {
    let tokens = searchTokens(query)
    guard !tokens.isEmpty else { return [] }
    let candidates = entries.filter { !$0.trashed }.map { SearchIndexEntry($0) }
    for substring in [false, true] {
        let hits = candidates.filter { candidate in
            tokens.allSatisfy { candidate.matches($0, substring: substring, allFields: scope == .allFields) }
        }
        if !hits.isEmpty {
            return sortedForMenu(hits.map(\.entry), favoritesFirst: true)
        }
    }
    return []
}

private struct SearchIndexEntry {
    let entry: VaultEntry
    let title: String
    let host: String
    let words: [String]
    let extra: [String]

    init(_ entry: VaultEntry) {
        self.entry = entry
        title = foldForSearch(entry.title)
        host = urlSearchString(entry.url)
        words = wordList(title) + wordList(host)
        var extra = [foldForSearch(entry.username), foldForSearch(entry.notes), foldForSearch(entry.tags)]
        for field in entry.fields where !standardKeys.contains(field.key.lowercased()) {
            extra.append(foldForSearch(field.key))
            extra.append(foldForSearch(field.value))
        }
        self.extra = extra
    }

    func matches(_ token: String, substring: Bool, allFields: Bool) -> Bool {
        if hasPunctuation(token) {
            if title.contains(token) || host.contains(token) { return true }
        } else if substring {
            if words.contains(where: { $0.contains(token) }) { return true }
        } else if words.contains(where: { $0.hasPrefix(token) }) {
            return true
        }
        return allFields && extra.contains { $0.contains(token) }
    }
}
