import Foundation

/// Auto-lock settings. Defaults: 5 minutes, and lock on idle, sleep, screen lock or screen saver, and user switch.
public struct AutoLockSettings: Equatable, Sendable {
    public var timeoutMinutes: Int
    public var lockOnIdle: Bool
    public var lockOnSleep: Bool
    public var lockOnScreenSaver: Bool
    public var lockOnUserSwitch: Bool

    public init(
        timeoutMinutes: Int = 5,
        lockOnIdle: Bool = true,
        lockOnSleep: Bool = true,
        lockOnScreenSaver: Bool = true,
        lockOnUserSwitch: Bool = true
    ) {
        self.timeoutMinutes = timeoutMinutes
        self.lockOnIdle = lockOnIdle
        self.lockOnSleep = lockOnSleep
        self.lockOnScreenSaver = lockOnScreenSaver
        self.lockOnUserSwitch = lockOnUserSwitch
    }

    /// Minutes of 0 or less fall back to 5.
    public var timeout: TimeInterval {
        timeoutMinutes > 0 ? TimeInterval(timeoutMinutes) * 60 : 300
    }
}

/// When to lock. A pure state machine: the clock and the system idle reading are injected, so tests need no timers or HID access.
///
/// The idle rule needs both the HID idle time and the time since the last in-app activity to exceed the timeout.
/// Only the second clock is ours, so a broken idle source (it once reported 1.4 million seconds) cannot lock a vault
/// that was just unlocked or used.
public struct AutoLockPolicy {
    public var settings: AutoLockSettings
    private let clock: () -> Date
    private let systemIdle: () -> TimeInterval
    private var lastActivity: Date
    private var wentToSleepAt: Date?

    public init(
        settings: AutoLockSettings = AutoLockSettings(),
        clock: @escaping () -> Date = { Date() },
        systemIdle: @escaping () -> TimeInterval
    ) {
        self.settings = settings
        self.clock = clock
        self.systemIdle = systemIdle
        lastActivity = clock()
    }

    /// Hotkey press, app (de)activation, unlock, any vault action.
    public mutating func registerActivity() {
        lastActivity = clock()
    }

    /// Run on the 30-second timer.
    public func shouldLockForIdle() -> Bool {
        guard settings.lockOnIdle else { return false }
        let limit = settings.timeout
        return systemIdle() > limit && clock().timeIntervalSince(lastActivity) > limit
    }

    public mutating func willSleep() -> Bool {
        wentToSleepAt = clock()
        return settings.lockOnSleep
    }

    public mutating func didWake() -> Bool {
        defer { wentToSleepAt = nil }
        guard settings.lockOnIdle, let slept = wentToSleepAt else { return false }
        return clock().timeIntervalSince(slept) >= settings.timeout
    }

    public func screenSaverDidStart() -> Bool { settings.lockOnScreenSaver }
    /// The power button, ⌃⌘Q or Lock Screen. The screen may stay lit, so no sleep notice comes; the screen saver switch covers it.
    public func screenDidLock() -> Bool { settings.lockOnScreenSaver }
    public func sessionDidResignActive() -> Bool { settings.lockOnUserSwitch }
    public func willPowerOff() -> Bool { true }
}

/// Touch ID may unlock for a limited time after the last master-password unlock; a Touch ID unlock does not extend it.
public enum TouchIDWindow {
    public static let defaultDays = 7

    public static func isValid(unlockedAt: Date?, now: Date, days: Int = defaultDays) -> Bool {
        guard let unlockedAt else { return false }
        return unlockedAt.addingTimeInterval(TimeInterval(days) * 86_400) >= now
    }
}
