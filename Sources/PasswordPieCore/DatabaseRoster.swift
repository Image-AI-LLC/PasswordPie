import Foundation

/// The databases PasswordPie can switch to. The current file stays first.
/// Opening another file keeps the previous ones. The last file cannot be removed.
public struct DatabaseRoster: Equatable, Sendable {
    public static let limit = 32

    public let current: String
    public let paths: [String]

    public init(current: String, remembered: [String] = [], limit: Int = DatabaseRoster.limit) {
        let cap = max(limit, 1)
        var ordered: [String] = []
        var seen = Set<String>()
        for path in [current] + remembered {
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            ordered.append(path)
            if ordered.count == cap { break }
        }
        self.current = ordered.first ?? current
        self.paths = ordered
    }

    /// Keeps paths whose keychain secret could not be deleted. The usual cap does not drop them.
    public func keeping(_ extras: [String]) -> DatabaseRoster {
        let added = extras.filter { !paths.contains($0) && !$0.isEmpty }
        guard !added.isEmpty else { return self }
        return DatabaseRoster(current: current, remembered: paths + added, limit: paths.count + added.count)
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

    /// Same file names stay distinguishable. A shared parent folder pulls in the next folder up.
    public static func menuTitles(for paths: [String]) -> [String] {
        let urls = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        var titles = urls.map { $0.lastPathComponent }
        var depth = 1
        while depth < 16 {
            var counts: [String: Int] = [:]
            for title in titles { counts[title, default: 0] += 1 }
            var changed = false
            for index in titles.indices where counts[titles[index], default: 0] > 1 {
                let chain = ancestorChain(urls[index], depth: depth)
                guard !chain.isEmpty else { continue }
                let next = "\(urls[index].lastPathComponent) — \(chain)"
                if next != titles[index] {
                    titles[index] = next
                    changed = true
                }
            }
            if !changed { break }
            depth += 1
        }
        return titles
    }

    private static func ancestorChain(_ url: URL, depth: Int) -> String {
        var current = url
        var parts: [String] = []
        for _ in 0..<depth {
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            let name = parent.lastPathComponent
            current = parent
            if name.isEmpty || parent.path == "/" { break }
            parts.insert(name, at: 0)
        }
        return parts.joined(separator: "/")
    }
}

/// A password unlock stores the file's secret only when Touch ID can gate the later read,
/// and only when the user has not turned that memory off for the file.
public enum UnlockMemory {
    /// `hardware` means biometrics can gate a later read, not merely that a sensor exists.
    /// An already-enabled file is refreshed only while that gate still works.
    public static func shouldStore(hardware: Bool, declined: Bool, alreadyEnabled: Bool = false) -> Bool {
        hardware && (!declined || alreadyEnabled)
    }
}
