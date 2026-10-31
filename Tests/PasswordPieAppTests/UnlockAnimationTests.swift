import AppKit
import PasswordPieCore
import XCTest
@testable import PasswordPie

/// The rim turns while a database decrypts, and the unlock itself no longer blocks the main thread.
@MainActor
final class UnlockAnimationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("unlock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("PASSWORDPIE_DB", directory.appendingPathComponent("test.kdbx").path, 1)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: Rim spin

    func testRimSpinTurnsAtASteadySpeedFromRest() {
        var spin = RimSpin()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        XCTAssertEqual(spin.angle(at: start), 0)
        XCTAssertFalse(spin.isMoving)
        spin.start(at: start)
        XCTAssertTrue(spin.isSpinning)
        XCTAssertEqual(spin.angle(at: start.addingTimeInterval(0.5)), RimSpin.degreesPerSecond * 0.5, accuracy: 1e-9)
    }

    func testRimSpinStopsOnAScallopWithoutJumpingOrBraking() {
        var spin = RimSpin()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        spin.start(at: start)
        let stop = start.addingTimeInterval(0.37)
        let before = spin.angle(at: stop)
        let duration = spin.stop(at: stop)
        // No jump at the moment it stops.
        XCTAssertEqual(spin.angle(at: stop), before, accuracy: 1e-9)
        // The ease-out starts at the spin speed.
        let early = spin.angle(at: stop.addingTimeInterval(0.001)) - before
        XCTAssertEqual(early / 0.001, RimSpin.degreesPerSecond, accuracy: RimSpin.degreesPerSecond * 0.02)
        // It rests one to two scallops ahead, on a scallop, so it looks as it did before it turned.
        let rest = spin.angle(at: stop.addingTimeInterval(duration + 1))
        XCTAssertEqual(rest.truncatingRemainder(dividingBy: RimSpin.scallop), 0, accuracy: 1e-9)
        XCTAssertGreaterThan(rest - before, RimSpin.scallop - 1e-9)
        XCTAssertLessThanOrEqual(rest - before, 2 * RimSpin.scallop + 1e-9)
        XCTAssertTrue(spin.isMoving)
        spin.finishSettling(at: stop.addingTimeInterval(duration))
        XCTAssertFalse(spin.isMoving)
        XCTAssertEqual(spin.angle(at: .distantFuture), rest, accuracy: 1e-9)
    }

    func testRimSpinRestartsFromWhereItIs() {
        var spin = RimSpin()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        spin.start(at: start)
        let stop = start.addingTimeInterval(0.2)
        spin.stop(at: stop)
        let restart = stop.addingTimeInterval(0.05)
        let mid = spin.angle(at: restart)
        spin.start(at: restart)
        XCTAssertEqual(spin.angle(at: restart), mid.truncatingRemainder(dividingBy: 360), accuracy: 1e-9)
        XCTAssertTrue(spin.isSpinning)
    }

    // MARK: Icon parts

    func testRimAndKeyholeTogetherMakeTheMark() {
        let whole = MenuBarIcon.path()
        let rim = MenuBarIcon.rimPath()
        let keyhole = MenuBarIcon.keyholePath()
        XCTAssertEqual(rim.bounds.minX, whole.bounds.minX, accuracy: 1e-6)
        XCTAssertEqual(rim.bounds.maxY, whole.bounds.maxY, accuracy: 1e-6)
        // Away from the keyhole, the rim and the mark fill the same points.
        for x in stride(from: 0.5, to: 18, by: 1.0) {
            for y in stride(from: 0.5, to: 18, by: 1.0) where !keyhole.contains(NSPoint(x: x, y: y)) {
                XCTAssertEqual(rim.contains(NSPoint(x: x, y: y)), whole.contains(NSPoint(x: x, y: y)), "\(x),\(y)")
            }
        }
        XCTAssertTrue(rim.bounds.contains(keyhole.bounds))
        // The rim turns about the icon's centre, which is also the rim's own centre.
        XCTAssertEqual(rim.bounds.midX, MenuBarIcon.size.width / 2, accuracy: 1e-6)
        XCTAssertEqual(rim.bounds.midY, MenuBarIcon.size.height / 2, accuracy: 1e-6)
        // A point in the keyhole is filled in the rim and empty in the mark.
        let inKeyhole = NSPoint(x: 9, y: 0.75 * 14)
        XCTAssertTrue(keyhole.contains(inKeyhole))
        XCTAssertTrue(rim.contains(inKeyhole))
        XCTAssertFalse(whole.contains(inKeyhole))
    }

    // MARK: Asynchronous unlock

    private func lockedSession(password: String) -> VaultSession {
        let session = VaultSession()
        session.restore()
        session.passwordDraft = password
        session.confirmDraft = password
        session.unlock()
        XCTAssertFalse(session.locked)
        session.lock()
        XCTAssertTrue(session.locked)
        XCTAssertFalse(session.creating)
        return session
    }

    private func waitUntilIdle(_ session: VaultSession) async throws {
        for _ in 0..<500 where session.unlocking {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(session.unlocking)
    }

    func testUnlockDecryptsOffTheMainThreadAndReportsProgress() async throws {
        let session = lockedSession(password: "pw")
        session.passwordDraft = "pw"
        session.unlock()
        // The call returns at once; the lock screen can turn the logo while the key is derived.
        XCTAssertTrue(session.unlocking)
        XCTAssertTrue(session.locked)
        session.unlock()
        try await waitUntilIdle(session)
        XCTAssertFalse(session.locked)
        XCTAssertEqual(session.message, "")
    }

    func testWrongPasswordEndsUnlockingAndStaysLocked() async throws {
        let session = lockedSession(password: "pw")
        var wrong = 0
        session.onWrongPassword = { wrong += 1 }
        session.passwordDraft = "nope"
        session.unlock()
        XCTAssertTrue(session.unlocking)
        try await waitUntilIdle(session)
        XCTAssertTrue(session.locked)
        XCTAssertEqual(wrong, 1)
    }

    func testDecryptResultIsDroppedWhenTheDatabaseChanged() async throws {
        let session = lockedSession(password: "pw")
        session.passwordDraft = "pw"
        session.unlock()
        session.databaseURL = directory.appendingPathComponent("other.kdbx")
        try await waitUntilIdle(session)
        XCTAssertTrue(session.locked)
    }
}
