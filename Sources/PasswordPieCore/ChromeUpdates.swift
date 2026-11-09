#if PP_DIRECT
import CryptoKit
import Foundation

// Direct-channel only. The rules are in "The newest password wins" in docs/UX.md.

/// One row of Chrome's login stores. A login can have two: the profile's store and the account store.
public struct ChromeRow: Equatable, Sendable {
    public var loginID: UUID
    public var password: String
    /// Chrome's `date_password_modified`. Nil when Chrome has none or stores 0.
    public var modifiedAt: Date?
    /// An ordinary sign-in form. HTTP authentication, federated and app logins are not.
    public var isForm: Bool

    public init(loginID: UUID, password: String, modifiedAt: Date?, isForm: Bool) {
        self.loginID = loginID
        self.password = password
        self.modifiedAt = modifiedAt
        self.isForm = isForm
    }
}

/// What a Chrome login may do to a saved entry beyond sitting next to it.
public struct ChromeJoinRules: Equatable, Sendable {
    /// Logins that are not ordinary sign-in forms.
    public var notForms: Set<UUID>
    /// Saved entries in a file this app does not write back in place.
    public var readOnly: Set<UUID>

    public init(notForms: Set<UUID> = [], readOnly: Set<UUID> = []) {
        self.notForms = notForms
        self.readOnly = readOnly
    }
}

public enum ChromeUpdates {
    public static let batchLimit = 10
    /// Updates written without asking count toward the limit for this long, so a slow trickle is still "many".
    public static let batchWindow: TimeInterval = 86_400

    public struct Replacement: Equatable, Sendable {
        public var value: String
        public var date: Date
        public var event: String
    }

    /// A Chrome value that goes to the list without being saved.
    public struct Kept: Equatable, Sendable {
        public var value: String
        public var date: Date?
        public var event: String
    }

    /// Everything one read means for one saved entry.
    public struct Change: Equatable, Sendable {
        public var entryID: UUID
        public var title: String
        public var username: String
        public var previousDate: Date?
        public var replacement: Replacement?
        public var kept: [Kept]
        /// Rows repeating the winning value. Remembered, so they are not looked at again.
        public var settled: [String]
    }

    public struct Plan: Equatable, Sendable {
        public var changes: [Change] = []

        public init(changes: [Change] = []) { self.changes = changes }

        public var isEmpty: Bool { changes.isEmpty }
        /// The accounts whose saved password would change.
        public var updates: [Change] { changes.filter { $0.replacement != nil } }
    }

    /// One change Chrome made. The same value at a later time is another event.
    public static func eventID(login: UUID, date: Date?, value: String) -> String {
        let stamp = date.map { String(Int64(($0.timeIntervalSince1970 * 1_000_000).rounded())) } ?? "none"
        let digest = SHA256.hash(data: Data(["chrome-event", login.uuidString, stamp, value].joined(separator: "\u{1}").utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// `dates` is each entry's password date from the file. Entries are matched as the list shows them.
    public static func plan(
        saved: [VaultEntry],
        live: [VaultEntry],
        rows: [ChromeRow],
        dates: [UUID: Date],
        rules: ChromeJoinRules = ChromeJoinRules(),
        now: Date = Date()
    ) -> Plan {
        guard !live.isEmpty, !rows.isEmpty else { return Plan() }
        let rowsByLogin = Dictionary(grouping: rows, by: \.loginID)
        let placed = ChromeLogins.placement(saved: saved, live: live, rules: rules)
        var plan = Plan()
        for (index, logins) in placed.joined.sorted(by: { $0.key < $1.key }) {
            let entry = saved[index]
            guard !rules.readOnly.contains(entry.id), PreviousPasswords.isReadable(entry) else { continue }
            let previousDate = PreviousPasswords.passwordDate(of: entry, fallback: dates[entry.id])
            let handled = Set(PreviousPasswords.state(of: entry).events.map(\.id))
            let servesOneSite = EntryMerge.otherWebsites(entry).isEmpty
            var seen = Set<String>()
            var candidates: [Replacement] = []
            var kept: [Kept] = []
            for login in logins {
                let mayWrite = servesOneSite && ChromeLogins.isSameAccountForWriting(entry, login, among: placed.writingCounts, rules: rules)
                for row in rowsByLogin[login.id] ?? [] where !row.password.isEmpty && row.password != entry.password {
                    let event = eventID(login: login.id, date: row.modifiedAt, value: row.password)
                    guard !handled.contains(event), seen.insert(event).inserted else { continue }
                    let date = trustworthy(row.modifiedAt, now: now)
                    if mayWrite, let date, let previousDate, isLater(date, than: previousDate) {
                        candidates.append(Replacement(value: row.password, date: date, event: event))
                    } else {
                        kept.append(Kept(value: row.password, date: date, event: event))
                    }
                }
            }
            let ordered = candidates.sorted { ($0.date, $0.event) > ($1.date, $1.event) }
            let winner = ordered.first
            var settled: [String] = []
            for other in ordered.dropFirst() {
                if other.value == winner?.value {
                    settled.append(other.event)
                } else {
                    kept.append(Kept(value: other.value, date: other.date, event: other.event))
                }
            }
            guard winner != nil || !kept.isEmpty else { continue }
            plan.changes.append(Change(
                entryID: entry.id,
                title: entry.title,
                username: entry.username,
                previousDate: previousDate,
                replacement: winner,
                kept: kept,
                settled: settled
            ))
        }
        return plan
    }

    /// More than the limit writes nothing until the person decides. A batch already waiting stays waiting.
    public static func shouldHold(_ plan: Plan, saved: [VaultEntry], alreadyHeld: Set<String>, now: Date = Date()) -> Bool {
        let updates = plan.updates
        guard !updates.isEmpty else { return false }
        if updates.contains(where: { alreadyHeld.contains($0.replacement?.event ?? "") }) { return true }
        return recentlyApplied(in: saved, now: now) + updates.count > batchLimit
    }

    /// `declined` leaves the saved password alone and puts Chrome's value in the list.
    public static func apply(_ change: Change, to entry: inout VaultEntry, kind: PreviousPasswords.EventKind, now: Date = Date()) {
        var state = PreviousPasswords.state(of: entry)
        // Once a record exists the date no longer depends on how much history the file keeps.
        if state.current?.value != entry.password, let date = change.previousDate {
            state.current = PreviousPasswords.Current(value: entry.password, date: date, source: .saved, event: nil)
        }
        func remember(_ value: String, date: Date?, event: String, kind: PreviousPasswords.EventKind) {
            state.events.append(PreviousPasswords.Event(id: event, at: now, kind: kind))
            guard value != entry.password else { return }
            if let index = state.items.firstIndex(where: { $0.value == value }) {
                if state.items[index].date == nil { state.items[index].date = date }
            } else {
                state.items.append(PreviousPasswords.Item(value: value, source: .chrome, date: date, enteredAt: now, used: false))
            }
        }
        if let replacement = change.replacement {
            if kind == .declined {
                remember(replacement.value, date: replacement.date, event: replacement.event, kind: .declined)
            } else {
                PreviousPasswords.retire(entry.password, into: &state, previousDate: change.previousDate, now: now)
                state.items.removeAll { $0.value == replacement.value }
                state.current = PreviousPasswords.Current(value: replacement.value, date: replacement.date, source: .chrome, event: replacement.event)
                state.events.append(PreviousPasswords.Event(id: replacement.event, at: now, kind: kind))
                entry.password = replacement.value
            }
        }
        for item in change.kept {
            remember(item.value, date: item.date, event: item.event, kind: .kept)
        }
        for event in change.settled {
            state.events.append(PreviousPasswords.Event(id: event, at: now, kind: .kept))
        }
        PreviousPasswords.set(PreviousPasswords.trimmed(state, now: now), on: &entry)
    }

    /// Chrome's clock can only say something if it is a real time that has already happened.
    private static func trustworthy(_ date: Date?, now: Date) -> Date? {
        guard let date, date.timeIntervalSince1970 > 0, date <= now else { return nil }
        return date
    }

    /// Whole seconds, the precision of a KeePass time. Inside one second it is a tie, and a tie stays with the database.
    private static func isLater(_ date: Date, than other: Date) -> Bool {
        date.timeIntervalSince1970.rounded(.down) > other.timeIntervalSince1970.rounded(.down)
    }

    private static func recentlyApplied(in saved: [VaultEntry], now: Date) -> Int {
        var events = Set<String>()
        for entry in saved {
            for event in PreviousPasswords.state(of: entry).events
            where event.kind == .automatic && now.timeIntervalSince(event.at) < batchWindow {
                events.insert(event.id)
            }
        }
        return events.count
    }
}
#endif
