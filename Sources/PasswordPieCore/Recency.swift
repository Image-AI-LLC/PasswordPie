import Foundation

/// How recently an account was used, as a score from 0 to 1.
public enum Recency {
    public static let halfLifeDays = 30.0

    /// 1 for an account used just now, halving every `halfLifeDays`. 0 when the time is unknown.
    /// A time in the future (clock skew) counts as just used.
    public static func score(lastUsed: Date?, now: Date = Date()) -> Double {
        guard let lastUsed else { return 0 }
        let days = max(0, now.timeIntervalSince(lastUsed)) / 86_400
        return pow(0.5, days / halfLifeDays)
    }
}

/// How the two ranking signals combine: `final = match * (1 + boost)`.
///
/// `boost = cap * (recencyShare * recency + (1 - recencyShare) * site)`, where `site` is the root domain's popularity.
/// Recency weighs more because it is the user's own behavior; site rank is only a general prior.
/// `cap` stays under 0.25. The closest match classes score 1.0, 0.8, 0.6 and 0.4, a step of at least 1.25 times,
/// so the boost reorders accounts inside one match class and never lifts a weaker class over a stronger one.
public enum RankingBoost {
    public static let cap = 0.24
    public static let recencyShare = 0.6

    public static func value(recency: Double, site: Double) -> Double {
        cap * (recencyShare * recency + (1 - recencyShare) * site)
    }
}

/// When each account was last used in PasswordPie: copied, filled or opened. Kept in a small private file beside the
/// database, not inside it, so using an account never rewrites the KeePass file. The file holds only entry IDs and times.
public final class UsageStore {
    public private(set) var lastUsed: [UUID: Date]
    private let url: URL

    public init(url: URL) {
        self.url = url
        var loaded: [UUID: Date] = [:]
        if let data = try? Data(contentsOf: url),
           let raw = try? JSONDecoder().decode([String: Double].self, from: data) {
            for (key, seconds) in raw {
                if let id = UUID(uuidString: key) { loaded[id] = Date(timeIntervalSince1970: seconds) }
            }
        }
        lastUsed = loaded
    }

    /// Keeps the later of the stored and the given time, then saves.
    public func record(_ id: UUID, at date: Date = Date()) throws {
        if let existing = lastUsed[id], existing >= date { return }
        lastUsed[id] = date
        let raw = Dictionary(uniqueKeysWithValues: lastUsed.map { ($0.key.uuidString, $0.value.timeIntervalSince1970) })
        let data = try JSONEncoder().encode(raw)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
