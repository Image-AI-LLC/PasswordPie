import Foundation

/// Older values of an account's password, kept in one protected field beside it, independent of the file's history limits.
/// See "The newest password wins" in docs/UX.md.
public enum PreviousPasswords {
    public static let key = "PasswordPie.PreviousPasswords"
    public static let maxItems = 10
    public static let retention: TimeInterval = 90 * 86_400
    /// How long the `password` label says it came from Chrome.
    public static let chromeLabelDuration: TimeInterval = 7 * 86_400
    /// Decisions are remembered without limit of time, and only the newest of them when there are more than this.
    static let maxEvents = 64

    public enum Source: String, Codable, Sendable {
        case saved, chrome
    }

    public struct Item: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var value: String
        public var source: Source
        /// When this value was set. Nil is shown as `date unknown`.
        public var date: Date?
        /// When it joined the list. The 90 days count from here.
        public var enteredAt: Date
        /// True once this value has been the saved password.
        public var used: Bool

        public init(id: UUID = UUID(), value: String, source: Source, date: Date?, enteredAt: Date, used: Bool) {
            self.id = id
            self.value = value
            self.source = source
            self.date = date
            self.enteredAt = enteredAt
            self.used = used
        }
    }

    /// When the saved password was set. Bound to its value: an edit in another app makes it stop applying.
    public struct Current: Codable, Equatable, Sendable {
        public var value: String
        public var date: Date
        public var source: Source
        public var event: String?

        public init(value: String, date: Date, source: Source, event: String?) {
            self.value = value
            self.date = date
            self.source = source
            self.event = event
        }
    }

    public enum EventKind: String, Codable, Sendable {
        /// Written without asking. These count toward "many at once".
        case automatic
        /// Written after the person chose Apply.
        case approved
        /// The person dismissed the batch this event was in.
        case declined
        /// Never a candidate for the saved password. Its value went to the list.
        case kept
    }

    /// One change Chrome reported. A later change is another event, even with the same value.
    public struct Event: Codable, Equatable, Sendable {
        public var id: String
        public var at: Date
        public var kind: EventKind

        public init(id: String, at: Date, kind: EventKind) {
            self.id = id
            self.at = at
            self.kind = kind
        }
    }

    public struct State: Codable, Equatable, Sendable {
        public var v = 1
        public var current: Current?
        public var items: [Item] = []
        public var events: [Event] = []

        public init() {}

        var isEmpty: Bool { current == nil && items.isEmpty && events.isEmpty }
    }

    /// False when the field holds something this version does not understand. Such an entry is left as it is.
    public static func isReadable(_ entry: VaultEntry) -> Bool {
        let raw = entry.value(for: key)
        return raw.isEmpty || decode(raw) != nil
    }

    public static func state(of entry: VaultEntry) -> State {
        decode(entry.value(for: key)) ?? State()
    }

    public static func set(_ state: State, on entry: inout VaultEntry) {
        guard !state.isEmpty else {
            entry.fields.removeAll { $0.key == key }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(state), let text = String(data: data, encoding: .utf8) else { return }
        entry.setValue(text, for: key, protected: true)
    }

    /// What the details list: distinct values, none equal to the saved password, newest first.
    public static func items(of entry: VaultEntry, now: Date) -> [Item] {
        var state = state(of: entry)
        state.items.removeAll { $0.value == entry.password }
        return trimmed(state, now: now).items
    }

    public static func trimmed(_ state: State, now: Date) -> State {
        var result = state
        var distinct: [Item] = []
        for item in state.items.sorted(by: { $0.enteredAt > $1.enteredAt }) {
            if let index = distinct.firstIndex(where: { $0.value == item.value }) {
                distinct[index].used = distinct[index].used || item.used
            } else {
                distinct.append(item)
            }
        }
        // `distinct` is newest-entered first, so the first used value is the one most recently replaced.
        let protectedID = distinct.first(where: \.used)?.id
        var kept = distinct.filter { now.timeIntervalSince($0.enteredAt) < retention || $0.id == protectedID }
        while kept.count > maxItems {
            let evictable = kept.filter { $0.id != protectedID }
            guard let victim = evictable.last(where: { !$0.used }) ?? evictable.last else { break }
            kept.removeAll { $0.id == victim.id }
        }
        result.items = kept.sorted { ($0.date ?? $0.enteredAt) > ($1.date ?? $1.enteredAt) }
        result.events = Array(state.events.suffix(maxEvents))
        return result
    }

    /// The date of the saved password: the record bound to it, otherwise what the file's history says.
    public static func passwordDate(of entry: VaultEntry, fallback: Date?) -> Date? {
        if let current = state(of: entry).current, current.value == entry.password { return current.date }
        return fallback
    }

    /// When Chrome updated the saved password, while the label should say so. Nil for a password changed here.
    public static func chromeUpdateDate(of entry: VaultEntry, now: Date) -> Date? {
        guard let current = state(of: entry).current, current.value == entry.password, current.source == .chrome,
              now.timeIntervalSince(current.date) < chromeLabelDuration else { return nil }
        return current.date
    }

    /// `entry` already holds the new password. The one it replaced goes to the list.
    public static func recordChange(from oldValue: String, on entry: inout VaultEntry, previousDate: Date?, now: Date) {
        guard oldValue != entry.password, isReadable(entry) else { return }
        var state = state(of: entry)
        retire(oldValue, into: &state, previousDate: previousDate, now: now)
        state.items.removeAll { $0.value == entry.password }
        state.current = Current(value: entry.password, date: now, source: .saved, event: nil)
        set(trimmed(state, now: now), on: &entry)
    }

    /// Makes a listed value the saved password. The one it replaces takes its place in the list.
    @discardableResult
    public static func restore(_ id: UUID, on entry: inout VaultEntry, previousDate: Date?, now: Date) -> Bool {
        var state = state(of: entry)
        guard let item = state.items.first(where: { $0.id == id }) else { return false }
        retire(entry.password, into: &state, previousDate: previousDate, now: now)
        state.items.removeAll { $0.value == item.value }
        state.current = Current(value: item.value, date: now, source: .saved, event: nil)
        entry.password = item.value
        set(trimmed(state, now: now), on: &entry)
        return true
    }

    /// Empties the list. What was decided about Chrome's changes stays, so a cleared value does not return on the next read.
    public static func clear(on entry: inout VaultEntry) {
        guard isReadable(entry) else { return }
        var state = state(of: entry)
        state.items = []
        set(state, on: &entry)
    }

    /// A split brings back the first account as it was before the merge. Its list stays, and the password it had goes on it.
    public static func carry(from merged: VaultEntry, to restored: inout VaultEntry, now: Date) {
        if let record = merged.fields.first(where: { $0.key == key }) {
            restored.fields.removeAll { $0.key == key }
            restored.fields.append(record)
        }
        recordChange(from: merged.password, on: &restored, previousDate: passwordDate(of: merged, fallback: nil), now: now)
    }

    /// Two accounts folding into one keep both lists. False when nothing changed.
    @discardableResult
    public static func absorb(_ other: VaultEntry, into entry: inout VaultEntry, now: Date) -> Bool {
        guard isReadable(entry), isReadable(other) else { return false }
        let incoming = state(of: other)
        guard !incoming.items.isEmpty || !incoming.events.isEmpty else { return false }
        let existing = state(of: entry)
        var combined = existing
        combined.items += incoming.items.filter { $0.value != entry.password }
        let known = Set(existing.events.map(\.id))
        combined.events = incoming.events.filter { !known.contains($0.id) } + existing.events
        let result = trimmed(combined, now: now)
        guard result != existing else { return false }
        set(result, on: &entry)
        return true
    }

    /// Moves the value leaving the saved slot into the list. It carries the source and date it had while saved.
    static func retire(_ value: String, into state: inout State, previousDate: Date?, now: Date) {
        guard !value.isEmpty else { return }
        let bound = state.current?.value == value ? state.current : nil
        state.items.removeAll { $0.value == value }
        state.items.append(Item(
            value: value,
            source: bound?.source ?? .saved,
            date: bound?.date ?? previousDate,
            enteredAt: now,
            used: true
        ))
    }

    private static func decode(_ raw: String) -> State? {
        guard !raw.isEmpty, let data = raw.data(using: .utf8),
              let state = try? JSONDecoder().decode(State.self, from: data), state.v == 1 else { return nil }
        return state
    }
}
