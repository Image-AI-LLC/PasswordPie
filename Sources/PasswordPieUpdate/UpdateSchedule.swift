import Foundation

/// When the app starts the updater. See "Updates that install themselves" in docs/UX.md.
public enum UpdateSchedule {
    /// Between two checks that got an answer.
    public static let interval: TimeInterval = 7 * 24 * 60 * 60
    /// After a check that failed (offline, GitHub down).
    public static let retryInterval: TimeInterval = 24 * 60 * 60

    /// `lastAnswer`: the last check that reached GitHub and understood it. `lastAttempt`: the last check started, whatever
    /// came of it. A clock set back makes either date lie in the future; then the check is due.
    public static func isDue(lastAnswer: Date?, lastAttempt: Date?, now: Date) -> Bool {
        elapsed(since: lastAnswer, now: now, atLeast: interval) && elapsed(since: lastAttempt, now: now, atLeast: retryInterval)
    }

    private static func elapsed(since date: Date?, now: Date, atLeast seconds: TimeInterval) -> Bool {
        guard let date else { return true }
        let passed = now.timeIntervalSince(date)
        return passed >= seconds || passed < 0
    }
}
