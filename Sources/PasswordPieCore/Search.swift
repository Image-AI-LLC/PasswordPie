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
/// Each title is read once: `title` searches the entry's fields, and a sort compares every entry many times.
public func sortedForMenu(_ entries: [VaultEntry], favoritesFirst: Bool = false) -> [VaultEntry] {
    entries.map { (entry: $0, title: $0.title, favorite: $0.favorite) }.sorted { lhs, rhs in
        if favoritesFirst, lhs.favorite != rhs.favorite { return lhs.favorite }
        let order = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.entry.id.uuidString < rhs.entry.id.uuidString
    }.map(\.entry)
}

private func wordList(_ text: String) -> [String] {
    text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
}

private func hasPunctuation(_ token: String) -> Bool {
    token.contains { !$0.isLetter && !$0.isNumber }
}

private let standardKeys: Set<String> = ["title", "username", "password", "url", "notes", "otp"]

/// Entries matching every token of `query`. Favorites come first, then the match score scaled by `1 + RankingBoost`
/// (how recently the account was used, and how popular its site is), then title order.
/// An empty query matches nothing here; callers show the initial menu.
public func searchEntries(
    _ entries: [VaultEntry],
    query: String,
    scope: SearchScope,
    popularity: DomainPopularity = .bundled,
    lastUsed: [UUID: Date] = [:],
    now: Date = Date()
) -> [VaultEntry] {
    guard !searchTokens(query).isEmpty else { return [] }
    return searchEntries(in: SearchIndex(entries), query: query, scope: scope, popularity: popularity, lastUsed: lastUsed, now: now)
}

/// The same search over a prepared index. Only the entries already in `index` take part, so a search during
/// indexing ranks what has been indexed so far.
public func searchEntries(
    in index: SearchIndex,
    query: String,
    scope: SearchScope,
    popularity: DomainPopularity = .bundled,
    lastUsed: [UUID: Date] = [:],
    now: Date = Date()
) -> [VaultEntry] {
    let tokens = searchTokens(query)
    guard !tokens.isEmpty else { return [] }
    for substring in [false, true] {
        var hits: [(item: SearchIndexEntry, score: Double)] = []
        for candidate in index.items {
            guard let match = candidate.score(tokens, substring: substring, allFields: scope == .allFields) else { continue }
            let boost = RankingBoost.value(
                recency: Recency.score(lastUsed: lastUsed[candidate.entry.id], now: now),
                site: popularity.popularity(forHost: candidate.rankHost)
            )
            hits.append((candidate, match * (1 + boost)))
        }
        if !hits.isEmpty {
            return hits.sorted { lhs, rhs in
                if lhs.item.entry.favorite != rhs.item.entry.favorite { return lhs.item.entry.favorite }
                if abs(lhs.score - rhs.score) > 1e-9 { return lhs.score > rhs.score }
                let order = lhs.item.displayTitle.localizedCaseInsensitiveCompare(rhs.item.displayTitle)
                if order != .orderedSame { return order == .orderedAscending }
                return lhs.item.entry.id.uuidString < rhs.item.entry.id.uuidString
            }.map(\.item.entry)
        }
    }
    return []
}

/// Folded search text for each entry, prepared once instead of on every keystroke.
/// It can be built a piece at a time: `adding` folds more entries, and `reusing` keeps the work done for entries that did not change.
public struct SearchIndex: Sendable {
    fileprivate var items: [SearchIndexEntry]

    public init() {
        items = []
    }

    /// Folds every entry that is not in the Recycle Bin.
    public init<S: Sequence>(_ entries: S) where S.Element == VaultEntry {
        items = entries.lazy.filter { !$0.trashed }.map(SearchIndexEntry.init)
    }

    /// The number of entries indexed so far.
    public var count: Int { items.count }

    /// This index with `other`'s entries added.
    public func adding(_ other: SearchIndex) -> SearchIndex {
        var copy = self
        copy.items += other.items
        return copy
    }

    /// An index for `entries` that keeps every prepared item whose entry did not change.
    /// `pending` holds the entries that still need folding, in their list order.
    public func reusing(for entries: [VaultEntry]) -> (index: SearchIndex, pending: [VaultEntry]) {
        var previous: [UUID: Int] = [:]
        previous.reserveCapacity(items.count)
        for position in items.indices { previous[items[position].entry.id] = position }
        var kept = SearchIndex()
        var pending: [VaultEntry] = []
        for entry in entries where !entry.trashed {
            if let position = previous[entry.id], items[position].entry == entry {
                kept.items.append(items[position])
            } else {
                pending.append(entry)
            }
        }
        return (kept, pending)
    }
}

fileprivate struct SearchIndexEntry: Sendable {
    let entry: VaultEntry
    /// The title as shown, for the final alphabetical tie-break.
    let displayTitle: String
    let title: String
    let host: String
    let words: [String]
    let extra: [String]

    init(_ entry: VaultEntry) {
        self.entry = entry
        displayTitle = entry.title
        title = foldForSearch(displayTitle)
        host = urlSearchString(entry.url)
        words = wordList(title) + wordList(host)
        var extra = [foldForSearch(entry.username), foldForSearch(entry.notes), foldForSearch(entry.tags)]
        for field in entry.fields where !standardKeys.contains(field.key.lowercased()) {
            extra.append(foldForSearch(field.key))
            extra.append(foldForSearch(field.value))
        }
        self.extra = extra
    }

    /// The host whose popularity counts: the URL's host, or a title that is itself a bare domain such as `github.com`.
    var rankHost: String {
        var candidate = host
        if candidate.isEmpty, title.contains("."), !title.contains(where: { $0.isWhitespace }) {
            candidate = title
        }
        if let at = candidate.lastIndex(of: "@") { candidate = String(candidate[candidate.index(after: at)...]) }
        return candidate
    }

    /// The mean of each token's match score, or nil when any token does not match.
    func score(_ tokens: [String], substring: Bool, allFields: Bool) -> Double? {
        var total = 0.0
        for token in tokens {
            guard let value = tokenScore(token, substring: substring, allFields: allFields) else { return nil }
            total += value
        }
        return total / Double(tokens.count)
    }

    /// Exact word 1.0, prefix of the first word 0.8, prefix of a later word 0.6, substring 0.4 (second pass only),
    /// a hit only in username, notes, tags or custom fields 0.2. A token with punctuation matches the title or host as a whole at 0.8.
    private func tokenScore(_ token: String, substring: Bool, allFields: Bool) -> Double? {
        var best: Double?
        func offer(_ value: Double) { best = max(best ?? 0, value) }
        if hasPunctuation(token) {
            if title.contains(token) || host.contains(token) { offer(0.8) }
        } else {
            for (index, word) in words.enumerated() {
                if word == token {
                    offer(1.0)
                } else if word.hasPrefix(token) {
                    offer(index == 0 ? 0.8 : 0.6)
                } else if substring, word.contains(token) {
                    offer(0.4)
                }
            }
        }
        if allFields, extra.contains(where: { $0.contains(token) }) { offer(0.2) }
        return best
    }
}
