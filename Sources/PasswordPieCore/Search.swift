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

/// How much a top-ranked site can lift an entry's match score: `final = match * (1 + weight * popularity)`.
/// Kept under 0.25 so popularity can reorder entries within a match class but never lift one class over the next:
/// the closest classes score 1.0, 0.8, 0.6 and 0.4, a step of at least 1.25x, and the biggest lift is 1.2x.
let popularityWeight = 0.2

/// Entries matching every token of `query`. Favorites come first, then the best match scaled by how popular the site is,
/// then title order. An empty query matches nothing here; callers show the initial menu.
public func searchEntries(
    _ entries: [VaultEntry],
    query: String,
    scope: SearchScope,
    popularity: DomainPopularity = .bundled
) -> [VaultEntry] {
    let tokens = searchTokens(query)
    guard !tokens.isEmpty else { return [] }
    let candidates = entries.filter { !$0.trashed }.map { SearchIndexEntry($0) }
    for substring in [false, true] {
        var hits: [(entry: VaultEntry, score: Double)] = []
        for candidate in candidates {
            guard let match = candidate.score(tokens, substring: substring, allFields: scope == .allFields) else { continue }
            hits.append((candidate.entry, match * (1 + popularityWeight * popularity.popularity(forHost: candidate.rankHost))))
        }
        if !hits.isEmpty {
            return hits.sorted { lhs, rhs in
                if lhs.entry.favorite != rhs.entry.favorite { return lhs.entry.favorite }
                if abs(lhs.score - rhs.score) > 1e-9 { return lhs.score > rhs.score }
                let order = lhs.entry.title.localizedCaseInsensitiveCompare(rhs.entry.title)
                if order != .orderedSame { return order == .orderedAscending }
                return lhs.entry.id.uuidString < rhs.entry.id.uuidString
            }.map(\.entry)
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
