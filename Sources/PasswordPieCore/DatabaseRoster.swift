import Foundation

/// The databases PasswordPie can switch to. The current file stays first.
/// Opening another file keeps the previous ones. The last file cannot be removed.
public struct DatabaseRoster: Equatable, Sendable {
    public static let limit = 32

    public let current: String
    public let paths: [String]

    public init(current: String, remembered: [String] = []) {
        var ordered: [String] = []
        var seen = Set<String>()
        for path in [current] + remembered {
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            ordered.append(path)
            if ordered.count == Self.limit { break }
        }
        self.current = ordered.first ?? current
        self.paths = ordered
    }

    public func selecting(_ path: String) -> DatabaseRoster {
        guard !path.isEmpty else { return self }
        return DatabaseRoster(current: path, remembered: paths)
    }

    /// Drops one file. Removing the current file selects the next one. Removing the last file does nothing.
    public func removing(_ path: String) -> DatabaseRoster {
        let remaining = paths.filter { $0 != path }
        guard !remaining.isEmpty, remaining.count != paths.count else { return self }
        let next = path == current ? remaining[0] : current
        return DatabaseRoster(current: next, remembered: remaining)
    }

    /// Same file names from different folders stay distinguishable.
    public static func menuTitles(for paths: [String]) -> [String] {
        let names = paths.map { URL(fileURLWithPath: $0).lastPathComponent }
        var counts: [String: Int] = [:]
        for name in names { counts[name, default: 0] += 1 }
        return zip(paths, names).map { path, name in
            guard counts[name, default: 0] > 1 else { return name }
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
            return parent.isEmpty ? name : "\(name) — \(parent)"
        }
    }
}

/// A password unlock stores the file's secret only when Touch ID can gate the later read,
/// and only when the user has not turned that memory off for the file.
public enum UnlockMemory {
    public static func shouldStore(hardware: Bool, declined: Bool) -> Bool {
        hardware && !declined
    }
}
