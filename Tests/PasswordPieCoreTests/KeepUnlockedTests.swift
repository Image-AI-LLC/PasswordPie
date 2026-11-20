import Foundation
import XCTest
@testable import PasswordPieCore

/// "Keep unlocked while this Mac is awake" (docs/UX.md, "Two databases at once, and a Mac nobody sits at"): with it in
/// force only idleness stops locking. Sleep, the screen lock, a user switch, logging out and Lock still lock, whatever
/// the Security switches say. Off, the policy is the one it always was.
final class KeepUnlockedTests: XCTestCase {
    final class Clock {
        var now = Date(timeIntervalSince1970: 2_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    private func policy(_ clock: Clock, keep: @escaping () -> Bool, settings: AutoLockSettings = AutoLockSettings()) -> AutoLockPolicy {
        var policy = AutoLockPolicy(settings: settings, clock: { clock.now }, systemIdle: { 1_000_000 })
        policy.keepUnlocked = keep
        return policy
    }

    func testIdleNeverLocksWhileItIsInForce() {
        let clock = Clock()
        var keep = true
        let p = policy(clock, keep: { keep })
        clock.advance(3_600)
        XCTAssertFalse(p.shouldLockForIdle(), "an hour idle, and the setting is in force")
        keep = false
        XCTAssertTrue(p.shouldLockForIdle(), "the same hour locks once it is not")
    }

    func testTheDisplaySleepingAndTheScreenSaverDoNotLock() {
        let clock = Clock()
        var p = policy(clock, keep: { true })
        XCTAssertFalse(p.displayDidSleep())
        clock.advance(3_600)
        XCTAssertFalse(p.didWake(), "the display waking after an hour is not the Mac waking")
        XCTAssertFalse(p.screenSaverDidStart())
    }

    func testEachListedEventStillLocks() {
        let clock = Clock()
        var p = policy(clock, keep: { true })
        XCTAssertTrue(p.willSleep(), "sleep")
        XCTAssertTrue(p.screenDidLock(), "the screen lock")
        XCTAssertTrue(p.sessionDidResignActive(), "switching to another user")
        XCTAssertTrue(p.willPowerOff(), "logging out, restarting, shutting down")
    }

    /// The setting decides on its own: switches turned off in Preferences > Security do not stop these.
    func testTheSecuritySwitchesDoNotWeakenIt() {
        let clock = Clock()
        let off = AutoLockSettings(lockOnIdle: false, lockOnSleep: false, lockOnScreenSaver: false, lockOnUserSwitch: false)
        var p = policy(clock, keep: { true }, settings: off)
        XCTAssertTrue(p.willSleep())
        XCTAssertTrue(p.screenDidLock())
        XCTAssertTrue(p.sessionDidResignActive())
    }

    /// Off (the default), every event answers as before: the display sleeping is a sleep, as it always was.
    func testOffIsTheOldPolicy() {
        let clock = Clock()
        var p = AutoLockPolicy(settings: AutoLockSettings(), clock: { clock.now }, systemIdle: { 1_000_000 })
        XCTAssertFalse(p.keepUnlocked())
        clock.advance(301)
        XCTAssertTrue(p.shouldLockForIdle())
        XCTAssertTrue(p.displayDidSleep())
        clock.advance(300)
        XCTAssertTrue(p.didWake())
        XCTAssertTrue(p.screenSaverDidStart())
        let off = AutoLockSettings(lockOnSleep: false, lockOnScreenSaver: false, lockOnUserSwitch: false)
        var quiet = AutoLockPolicy(settings: off, clock: { clock.now }, systemIdle: { 0 })
        XCTAssertFalse(quiet.displayDidSleep())
        XCTAssertFalse(quiet.willSleep())
        XCTAssertFalse(quiet.screenDidLock())
        XCTAssertFalse(quiet.sessionDidResignActive())
    }
}
