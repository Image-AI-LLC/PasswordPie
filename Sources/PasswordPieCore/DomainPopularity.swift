import Foundation

/// How well known a site is, from a bundled table of the most popular root domains.
/// The table is compiled in, so search never makes a network call.
public struct DomainPopularity: Sendable {
    private let ranks: [String: Int]
    private let size: Int

    /// Ranks start at 1. `size` is the length of the full list the ranks came from, and sets the scale of `popularity`.
    public init(ranks: [String: Int], size: Int = 10_000) {
        self.ranks = ranks
        self.size = max(size, 1)
    }

    public var count: Int { ranks.count }

    public static let none = DomainPopularity(ranks: [:])

    /// The bundled top 10,000 domains. Parsed on first use.
    public static let bundled: DomainPopularity = {
        var ranks: [String: Int] = [:]
        ranks.reserveCapacity(10_000)
        var rank = 0
        for line in bundledDomainRankText.split(separator: "\n") {
            rank += 1
            ranks[String(line)] = rank
        }
        return DomainPopularity(ranks: ranks, size: max(rank, 1))
    }()

    /// The rank of the host's root domain. Walks the host's suffixes from longest to shortest and takes the first one in the table,
    /// so `gist.github.com` finds `github.com` and `www.bbc.co.uk` finds `bbc.co.uk` without a public suffix list.
    /// A bare suffix such as `co.uk` or `com` is never looked up.
    public func rank(forHost host: String) -> Int? {
        let labels = host.lowercased().split(separator: ".", omittingEmptySubsequences: true)
        guard labels.count >= 2 else { return nil }
        for start in 0...(labels.count - 2) {
            if let rank = ranks[labels[start...].joined(separator: ".")] { return rank }
        }
        return nil
    }

    /// 1 for rank 1, falling on a log scale to 0 at the end of the list. 0 for unranked sites.
    /// The log keeps rank 1 against rank 100 at about 1.0 against 0.5, where a reciprocal would be 100 times apart.
    public func popularity(forHost host: String) -> Double {
        guard let rank = rank(forHost: host) else { return 0 }
        return max(0, min(1, 1 - log(Double(rank)) / log(Double(size + 1))))
    }
}
