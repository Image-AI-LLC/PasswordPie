import CryptoKit
import Foundation

/// A reminder to change an account's password every so many days, counted from when the password last changed.
/// See "A reminder to change a password" in docs/UX.md.
public enum PasswordRotation {
    /// Days between changes. Missing or 0 means no reminder.
    public static let periodKey = "PasswordPie.ChangeEvery"
    /// The page where this account's password is changed.
    public static let resetLinkKey = "PasswordPie.ResetLink"
    /// When the password was set, and a short digest of it: `<seconds since 1970> <digest>`.
    /// Bound to the value, so a change made anywhere else is noticed and starts the clock again.
    public static let changedKey = "PasswordPie.PasswordChanged"

    public static let presets = [30, 60, 90, 180, 365]
    public static let longestPeriod = 3650

    public static func isKey(_ key: String) -> Bool {
        [periodKey, resetLinkKey, changedKey].contains { $0.caseInsensitiveCompare(key) == .orderedSame }
    }

    public static func period(of entry: VaultEntry) -> Int? {
        guard let days = Int(entry.value(for: periodKey).trimmingCharacters(in: .whitespaces)), days > 0 else { return nil }
        return min(days, longestPeriod)
    }

    public static func setPeriod(_ days: Int?, on entry: inout VaultEntry) {
        entry.fields.removeAll { $0.key == periodKey }
        if let days, days > 0 { entry.setValue(String(min(days, longestPeriod)), for: periodKey) }
    }

    public static func resetLink(of entry: VaultEntry) -> String {
        entry.value(for: resetLinkKey)
    }

    public static func setResetLink(_ link: String, on entry: inout VaultEntry) {
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.fields.removeAll { $0.key == resetLinkKey }
        if !link.isEmpty { entry.setValue(link, for: resetLinkKey) }
    }

    /// What Reset Password opens: the reset link, or the account's website when there is none.
    public static func resetAddress(of entry: VaultEntry) -> String {
        let link = resetLink(of: entry)
        return link.isEmpty ? entry.url : link
    }

    /// When the password the entry holds now was set. Nil when it was never recorded, or the password has changed since.
    public static func changed(of entry: VaultEntry) -> Date? {
        let parts = entry.value(for: changedKey).split(separator: " ")
        guard parts.count == 2, let seconds = TimeInterval(parts[0]), parts[1] == digest(entry.password) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Records when the password was set, for an entry with a reminder whose password has no date or has changed.
    /// `known` is the date PasswordPie has for this password, if any; an impossible date is not believed.
    /// True when the entry changed.
    @discardableResult
    public static func reconcile(_ entry: inout VaultEntry, known: Date? = nil, now: Date) -> Bool {
        guard period(of: entry) != nil else {
            let before = entry.fields.count
            entry.fields.removeAll { $0.key == changedKey }
            return entry.fields.count != before
        }
        guard changed(of: entry) == nil else { return false }
        // A date from the file can be anything: one before 1970 or after now is not believed, and never reaches Int().
        let date = known.flatMap { $0.timeIntervalSince1970 > 0 && $0 <= now ? $0 : nil } ?? now
        let stamp = "\(Int(date.timeIntervalSince1970)) \(digest(entry.password))"
        entry.fields.removeAll { $0.key == changedKey }
        entry.fields.append(VaultField(key: changedKey, value: stamp, protected: true))
        return true
    }

    /// The day the password should be changed by. Nil without a reminder or a recorded date.
    public static func dueDate(of entry: VaultEntry) -> Date? {
        guard let days = period(of: entry), let changed = changed(of: entry) else { return nil }
        return changed.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    public static func isDue(_ entry: VaultEntry, now: Date) -> Bool {
        guard !entry.trashed, let due = dueDate(of: entry) else { return false }
        return now >= due
    }

    /// Whole days until it is due: 0 today, negative once overdue. Nil without a reminder.
    public static func daysLeft(of entry: VaultEntry, now: Date, calendar: Calendar = .current) -> Int? {
        guard let due = dueDate(of: entry) else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day
    }

    /// "in 12 days", "today", "3 days ago".
    public static func phrase(daysLeft: Int) -> String {
        switch daysLeft {
        case 0: return "today"
        case 1: return "in 1 day"
        case -1: return "1 day ago"
        case let days where days > 0: return "in \(days) days"
        default: return "\(-daysLeft) days ago"
        }
    }

    /// The entries that are due, the longest overdue first.
    public static func due(in entries: [VaultEntry], now: Date) -> [VaultEntry] {
        entries.compactMap { entry -> (VaultEntry, Date)? in
            guard !entry.trashed, let due = dueDate(of: entry), now >= due else { return nil }
            return (entry, due)
        }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
    }

    /// Enough to tell that the password changed, and too short to say what it is.
    private static func digest(_ password: String) -> String {
        SHA256.hash(data: Data(password.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
