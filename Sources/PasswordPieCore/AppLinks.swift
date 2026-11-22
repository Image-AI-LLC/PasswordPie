import Foundation

/// An app an account signs in to. See "An account remembers its app" in docs/UX.md.
public struct LinkedApp: Equatable, Hashable, Sendable {
    /// The app's bundle identifier, as the app declares it.
    public var bundleID: String
    /// Who signed the app. Nil when it has no team, or the signature could not be read.
    public var teamID: String?
    /// The name to show, kept so the link still reads well when the app is not installed.
    public var name: String

    public init(bundleID: String, teamID: String? = nil, name: String) {
        self.bundleID = bundleID
        self.teamID = teamID
        self.name = name
    }

    /// The same app: the identifier has no case. A link made with a team holds only for that team, so another app that
    /// claims the identifier is not it. A link made without one goes by the identifier.
    func isApp(_ running: LinkedApp) -> Bool {
        guard bundleID.caseInsensitiveCompare(running.bundleID) == .orderedSame else { return false }
        guard let teamID else { return true }
        return teamID == running.teamID
    }
}

/// The apps of an account, kept on the account itself in one field: a line per app,
/// `identifier<tab>team<tab>name[<tab>manual]`, with `-` for no team.
/// A line that starts with `!` is an app the user took back, which is never added again automatically.
public enum AppLinks {
    public static let key = "PasswordPie.Apps"
    private static let manualFlag = "manual"

    public static func isKey(_ key: String) -> Bool {
        key.caseInsensitiveCompare(Self.key) == .orderedSame
    }

    public static func apps(of entry: VaultEntry) -> [LinkedApp] {
        lines(of: entry).filter { !$0.refused }.map(\.app)
    }

    /// Apps the user previously removed from this account, in order.
    public static func refusedApps(of entry: VaultEntry) -> [LinkedApp] {
        lines(of: entry).filter { $0.refused }.map(\.app)
    }

    public static func isLinked(_ entry: VaultEntry, to app: LinkedApp) -> Bool {
        apps(of: entry).contains { $0.isApp(app) }
    }

    /// True when the account has a link for `app` that was added manually by the user (rather than automatically on copy).
    public static func isManual(_ entry: VaultEntry, to app: LinkedApp) -> Bool {
        lines(of: entry).contains { !$0.refused && $0.manual && $0.app.sameIdentifier(app) }
    }

    /// The user unlinked this app, or pressed Undo on its link. A refusal goes by the identifier alone: it is about the
    /// app the user saw named, and must hold when the signer cannot be read.
    public static func refuses(_ entry: VaultEntry, _ app: LinkedApp) -> Bool {
        lines(of: entry).contains { $0.refused && $0.app.sameIdentifier(app) }
    }

    /// False when the account already has an app with this identifier. That includes one signed by someone else, or
    /// whose signer cannot be read just now: the link that is there is never replaced or loosened on its own.
    /// A link clears an earlier refusal.
    @discardableResult
    public static func link(_ app: LinkedApp, to entry: inout VaultEntry, manual: Bool = false) -> Bool {
        var all = lines(of: entry)
        guard !all.contains(where: { !$0.refused && $0.app.sameIdentifier(app) }) else { return false }
        all.removeAll { $0.refused && $0.app.sameIdentifier(app) }
        all.append(Line(app: app, refused: false, manual: manual))
        write(all, to: &entry)
        return true
    }

    /// False when the account does not have the app. `remember` keeps the refusal.
    @discardableResult
    public static func unlink(_ app: LinkedApp, from entry: inout VaultEntry, remember: Bool = true) -> Bool {
        var all = lines(of: entry)
        guard let index = all.firstIndex(where: { !$0.refused && $0.app.sameIdentifier(app) }) else { return false }
        if remember {
            all[index].refused = true
            all[index].manual = false
        } else {
            all.remove(at: index)
        }
        write(all, to: &entry)
        return true
    }

    /// Takes each line of `other`, linked or refused, for an app `entry` has no line for. What `entry` already says about
    /// an app is not changed. True when a line was added.
    @discardableResult
    public static func absorb(_ other: VaultEntry, into entry: inout VaultEntry) -> Bool {
        var all = lines(of: entry)
        var added = false
        for line in lines(of: other) where !all.contains(where: { $0.app.sameIdentifier(line.app) }) {
            all.append(line)
            added = true
        }
        if added { write(all, to: &entry) }
        return added
    }

    /// The live accounts linked to `app`, in the order of a site's accounts: favorites, the most recently used, title.
    public static func entries(_ entries: [VaultEntry], linkedTo app: LinkedApp, lastUsed: [UUID: Date] = [:]) -> [VaultEntry] {
        // A cheap test first: thousands of accounts, and almost none has the field.
        let found = entries.filter { entry in
            !entry.trashed && entry.fields.contains { $0.key == key } && isLinked(entry, to: app)
        }
        return SiteSuggestions.ordered(found, lastUsed: lastUsed)
    }

    private struct Line {
        var app: LinkedApp
        var refused: Bool
        var manual: Bool
    }

    private static func lines(of entry: VaultEntry) -> [Line] {
        entry.value(for: key).split(whereSeparator: \.isNewline).compactMap { raw in
            var text = String(raw)
            let refused = text.hasPrefix("!")
            if refused { text.removeFirst() }
            let parts = text.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let bundleID = parts[0].trimmingCharacters(in: .whitespaces)
            // An identifier is letters, digits, hyphens and dots. Anything else is not a line of ours.
            guard !bundleID.isEmpty, bundleID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }),
                  bundleID.contains(".") else { return nil }
            let team = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            let name = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : ""
            let flag = parts.count > 3 ? parts[3].trimmingCharacters(in: .whitespaces).lowercased() : ""
            return Line(
                app: LinkedApp(
                    bundleID: bundleID,
                    teamID: team.isEmpty || team == "-" ? nil : team,
                    name: name.isEmpty ? bundleID : name
                ),
                refused: refused,
                manual: !refused && flag == manualFlag
            )
        }
    }

    private static func write(_ lines: [Line], to entry: inout VaultEntry) {
        entry.fields.removeAll { $0.key == key }
        guard !lines.isEmpty else { return }
        let text = lines.map { line in
            // Every character that ends a line when the field is read back, not only \n.
            let name = String(line.app.name.map { $0.isNewline || $0 == "\t" ? " " : $0 })
            var columns = [line.app.bundleID, line.app.teamID ?? "-", name]
            if !line.refused && line.manual { columns.append(manualFlag) }
            return (line.refused ? "!" : "") + columns.joined(separator: "\t")
        }.joined(separator: "\n")
        entry.setValue(text, for: key)
    }
}

/// One app that PasswordPie does not add to accounts automatically. Manual adding from an account still works.
public struct AutoLinkExclusion: Codable, Equatable, Hashable, Identifiable, Sendable {
    public enum Reason: String, Codable, Equatable, Hashable, Sendable {
        /// Excluded automatically after the user undid 3 distinct automatic links in this app.
        case afterUndos
        /// Added directly by the user in Preferences.
        case manual

        public var label: String {
            switch self {
            case .afterUndos: "After 3 undos"
            case .manual: "Excluded manually"
            }
        }
    }

    public let bundleID: String
    public var name: String
    public var reason: Reason

    public var id: String { bundleID.lowercased() }

    public init(bundleID: String, name: String, reason: Reason) {
        self.bundleID = bundleID
        self.name = name
        self.reason = reason
    }
}

/// App-level automatic linking exclusions and per-app auto-undo counts.
/// After undoing 3 distinct automatically-added accounts in the same app, that app stops auto-linking.
/// Manual linking from an account's details still works at any time.
public struct AppLinkAutoExclusions: Codable, Equatable, Sendable {
    public static let undoThreshold = 3

    public private(set) var excluded: [AutoLinkExclusion] = []
    /// Lowercased bundleID -> distinct account UUIDs whose automatic link was undone/removed.
    public private(set) var undoneAccounts: [String: [UUID]] = [:]

    public init(excluded: [AutoLinkExclusion] = [], undoneAccounts: [String: [UUID]] = [:]) {
        self.excluded = excluded
        self.undoneAccounts = undoneAccounts
    }

    public func isExcluded(bundleID: String) -> Bool {
        let key = bundleID.lowercased()
        return excluded.contains { $0.bundleID.lowercased() == key }
    }

    public func undoCount(for bundleID: String) -> Int {
        undoneAccounts[bundleID.lowercased()]?.count ?? 0
    }

    /// Records that the user undid or removed an automatically-added link for `entryID` in `app`.
    /// Returns true if this undo reached `undoThreshold` and newly excluded the app.
    @discardableResult
    public mutating func recordAutoUndo(app: LinkedApp, entryID: UUID) -> Bool {
        let key = app.bundleID.lowercased()
        guard !isExcluded(bundleID: key) else { return false }
        var accounts = undoneAccounts[key] ?? []
        if !accounts.contains(entryID) {
            accounts.append(entryID)
        }
        if accounts.count >= Self.undoThreshold {
            undoneAccounts.removeValue(forKey: key)
            excluded.append(AutoLinkExclusion(bundleID: app.bundleID, name: app.name, reason: .afterUndos))
            return true
        }
        undoneAccounts[key] = accounts
        return false
    }

    /// Clears a pending undo strike for `(bundleID, entryID)` (for example if the user re-links the account or presses
    /// Undo on an accidental × click). Does not re-enable an app that is already excluded.
    public mutating func clearUndo(bundleID: String, entryID: UUID) {
        let key = bundleID.lowercased()
        guard var accounts = undoneAccounts[key] else { return }
        accounts.removeAll { $0 == entryID }
        if accounts.isEmpty {
            undoneAccounts.removeValue(forKey: key)
        } else {
            undoneAccounts[key] = accounts
        }
    }

    /// Proactively excludes `app` from automatic linking (Preferences › General). Returns true if newly added.
    @discardableResult
    public mutating func excludeManually(_ app: LinkedApp) -> Bool {
        let key = app.bundleID.lowercased()
        guard !isExcluded(bundleID: key) else { return false }
        undoneAccounts.removeValue(forKey: key)
        excluded.append(AutoLinkExclusion(bundleID: app.bundleID, name: app.name, reason: .manual))
        return true
    }

    /// Re-enables automatic linking for `bundleID` and resets its undo count. Returns true if it was excluded.
    @discardableResult
    public mutating func reenable(bundleID: String) -> Bool {
        let key = bundleID.lowercased()
        let before = excluded.count
        excluded.removeAll { $0.bundleID.lowercased() == key }
        undoneAccounts.removeValue(forKey: key)
        return excluded.count != before
    }

    public static func decode(_ data: Data?) -> AppLinkAutoExclusions {
        guard let data, let decoded = try? JSONDecoder().decode(AppLinkAutoExclusions.self, from: data) else {
            return AppLinkAutoExclusions()
        }
        return decoded
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)) ?? Data()
    }
}

private extension LinkedApp {
    func sameIdentifier(_ other: LinkedApp) -> Bool {
        bundleID.caseInsensitiveCompare(other.bundleID) == .orderedSame
    }
}

extension MenuBuilder {
    /// The group at the top of the panel for the app in front: a header with the app's icon and name, then its
    /// accounts, as `siteRows` lists a site's. Empty when the app has no accounts.
    public static func appRows(app: LinkedApp, entries: [VaultEntry], sources: [UUID: String] = [:]) -> [MenuRow] {
        var rows = siteRows(site: app.name, entries: entries, sources: sources)
        if !rows.isEmpty { rows[0].appBundleID = app.bundleID }
        return rows
    }
}
