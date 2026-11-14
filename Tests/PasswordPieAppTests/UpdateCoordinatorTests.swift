#if PP_DIRECT
import Foundation
import PasswordPieUpdate
import XCTest
@testable import PasswordPie

@MainActor
final class UpdateCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var idle = true
    private var checks: [(UpdateOutcome?) -> Void] = []
    private var installs: [(path: String, relaunch: Bool)] = []
    private var installStarts = true
    private var quits = 0
    private var stagedOnDisk = true
    private let day: TimeInterval = 24 * 60 * 60

    override func setUp() {
        suite = "UpdateCoordinatorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func coordinator(hasUpdater: Bool = true) -> UpdateCoordinator {
        UpdateCoordinator(environment: .init(
            defaults: defaults,
            now: { [unowned self] in self.now },
            installedVersion: "0.2.0",
            hasUpdater: hasUpdater,
            check: { [unowned self] completion in self.checks.append(completion) },
            install: { [unowned self] path, relaunch in
                self.installs.append((path, relaunch))
                return self.installStarts
            },
            stagedExists: { [unowned self] _ in self.stagedOnDisk },
            quit: { [unowned self] in self.quits += 1 },
            isIdle: { [unowned self] in self.idle }
        ))
    }

    private let staged = UpdateOutcome(.staged, version: "0.3.0", path: "/cache/PasswordPie-0.3.0/PasswordPie.app")

    func testChecksWhenDueAndNotAgainForAWeek() {
        let updates = coordinator()
        XCTAssertTrue(updates.automatic, "on unless turned off")
        updates.tick()
        XCTAssertEqual(checks.count, 1)
        XCTAssertEqual(updates.state, .checking)
        updates.tick()
        XCTAssertEqual(checks.count, 1, "one check at a time")
        checks[0](UpdateOutcome(.upToDate, version: "0.2.0"))
        XCTAssertEqual(updates.state, .idle)
        XCTAssertEqual(updates.statusLine, "PasswordPie 0.2.0 is up to date. Checked today.")
        now += 6 * day
        updates.tick()
        XCTAssertEqual(checks.count, 1)
        now += 1 * day
        updates.tick()
        XCTAssertEqual(checks.count, 2)
    }

    func testAFailedCheckIsTriedAgainADayLater() {
        let updates = coordinator()
        updates.tick()
        checks[0](UpdateOutcome(.failed, message: "GitHub did not answer."))
        XCTAssertEqual(updates.state, .failed("GitHub did not answer."))
        XCTAssertEqual(updates.statusLine, "The last check failed: GitHub did not answer.")
        now += 0.5 * day
        updates.tick()
        XCTAssertEqual(checks.count, 1)
        now += 0.5 * day
        updates.tick()
        XCTAssertEqual(checks.count, 2)
        // An updater that printed nothing it should have.
        checks[1](nil)
        XCTAssertEqual(updates.state, .failed("The updater did not answer."))
    }

    func testTurnedOffAsksNothingUntilCheckNow() {
        let updates = coordinator()
        updates.automatic = false
        updates.tick()
        XCTAssertTrue(checks.isEmpty)
        XCTAssertFalse(coordinator().automatic, "the switch is remembered")
        updates.checkNow()
        XCTAssertEqual(checks.count, 1)
        idle = true
        checks[0](staged)
        XCTAssertEqual(updates.state, .ready("0.3.0"))
        XCTAssertTrue(installs.isEmpty, "off: it waits for Restart to Update")
        XCTAssertEqual(updates.statusLine, "PasswordPie 0.3.0 is ready. Press Restart to Update to install it.")
        updates.appWillTerminate()
        XCTAssertTrue(installs.isEmpty, "off: quitting does not install either")
        updates.restartToUpdate()
        XCTAssertEqual(installs.map(\.path), [staged.path])
        XCTAssertEqual(quits, 1)
    }

    func testAStagedUpdateInstallsOnceTheAppIsIdle() {
        let updates = coordinator()
        idle = false
        updates.tick()
        checks[0](staged)
        XCTAssertEqual(updates.state, .ready("0.3.0"))
        XCTAssertEqual(updates.statusLine, "PasswordPie 0.3.0 is ready. It installs the next time PasswordPie is locked.")
        XCTAssertTrue(installs.isEmpty, "not while unlocked or with a window open")
        updates.installIfIdle()
        XCTAssertTrue(installs.isEmpty)
        idle = true
        updates.installIfIdle()
        XCTAssertEqual(installs.count, 1)
        XCTAssertEqual(installs[0].path, staged.path)
        XCTAssertTrue(installs[0].relaunch)
        XCTAssertEqual(quits, 1)
        // Quitting for the install does not start a second one.
        updates.appWillTerminate()
        updates.installIfIdle()
        XCTAssertEqual(installs.count, 1)
    }

    func testStagedWhileIdleInstallsAtOnce() {
        let updates = coordinator()
        updates.tick()
        checks[0](staged)
        XCTAssertEqual(installs.count, 1)
        XCTAssertEqual(quits, 1)
    }

    func testQuittingInstallsWithoutStartingAgain() {
        let updates = coordinator()
        idle = false
        updates.tick()
        checks[0](staged)
        updates.appWillTerminate()
        XCTAssertEqual(installs.count, 1)
        XCTAssertFalse(installs[0].relaunch)
        XCTAssertEqual(quits, 0, "already quitting")
    }

    func testAnUpdateWaitingAtStartIsInstalledFirstAndOnlyOnce() {
        idle = false
        let first = coordinator()
        first.tick()
        checks[0](staged)
        // The app was killed before it could install. The next start does it.
        let second = coordinator()
        XCTAssertEqual(second.state, .ready("0.3.0"))
        XCTAssertTrue(second.installAtLaunch())
        XCTAssertEqual(installs.count, 1)
        XCTAssertTrue(installs[0].relaunch)
        XCTAssertEqual(quits, 0, "the caller exits")
        // Whether or not that worked, the start after it does not try again: no restart loop.
        let third = coordinator()
        XCTAssertEqual(third.state, .idle)
        XCTAssertFalse(third.installAtLaunch())
        XCTAssertEqual(installs.count, 1)
    }

    func testNothingWaitingOrTurnedOffStartsNormally() {
        XCTAssertFalse(coordinator().installAtLaunch())
        idle = false
        let first = coordinator()
        first.tick()
        checks[0](staged)
        first.automatic = false
        XCTAssertFalse(coordinator().installAtLaunch())
        XCTAssertTrue(installs.isEmpty)
    }

    func testAnUpdaterThatDoesNotStartLeavesTheAppRunning() {
        let updates = coordinator()
        installStarts = false
        updates.tick()
        checks[0](staged)
        XCTAssertEqual(quits, 0)
        XCTAssertEqual(updates.state, .failed("The updater could not be started."))
        XCTAssertFalse(coordinator().installAtLaunch(), "and it is not tried at every start")
    }

    func testACopyThatCannotReplaceItselfOffersTheDownload() {
        let updates = coordinator()
        updates.tick()
        checks[0](UpdateOutcome(.available, version: "0.3.0"))
        XCTAssertEqual(updates.state, .available("0.3.0"))
        XCTAssertEqual(updates.statusLine, "PasswordPie 0.3.0 is available, but this copy cannot replace itself. Download it instead.")
        XCTAssertTrue(installs.isEmpty)
        now += 6 * day
        updates.tick()
        XCTAssertEqual(checks.count, 1, "an answer, so a week until the next check")
    }

    func testABuildThatIsNotAReleaseStopsAsking() {
        let updates = coordinator()
        updates.tick()
        checks[0](UpdateOutcome(.notEligible))
        XCTAssertEqual(updates.state, .unavailable)
        XCTAssertEqual(updates.statusLine, "This build is not a release, so it does not update itself.")
        now += 30 * day
        updates.tick()
        updates.checkNow()
        XCTAssertEqual(checks.count, 1)
        // No updater in the bundle (`swift run`): the same, without starting anything.
        let bare = coordinator(hasUpdater: false)
        XCTAssertEqual(bare.state, .unavailable)
        bare.tick()
        bare.checkNow()
        XCTAssertEqual(checks.count, 1)
    }

    func testBeingUpToDateForgetsAStagedUpdate() {
        idle = false
        let updates = coordinator()
        updates.tick()
        checks[0](staged)
        updates.checkNow()
        checks[1](UpdateOutcome(.upToDate, version: "0.2.0"))
        XCTAssertEqual(updates.state, .idle)
        XCTAssertFalse(coordinator().installAtLaunch())
    }

    func testAFailedCheckKeepsAStagedUpdateWaiting() {
        idle = false
        let updates = coordinator()
        updates.tick()
        checks[0](staged)
        updates.checkNow()
        checks[1](UpdateOutcome(.failed, message: "GitHub did not answer."))
        XCTAssertEqual(updates.state, .ready("0.3.0"))
        idle = true
        updates.installIfIdle()
        XCTAssertEqual(installs.map(\.path), [staged.path])
    }

    func testAFailedCheckThatThrewTheStagedCopyAwayLeavesNothingWaiting() {
        idle = false
        let updates = coordinator()
        updates.tick()
        checks[0](staged)
        // A newer release was found, the cache emptied for it, and its download failed.
        updates.checkNow()
        stagedOnDisk = false
        checks[1](UpdateOutcome(.failed, message: "The download failed."))
        XCTAssertEqual(updates.state, .failed("The download failed."))
        idle = true
        updates.installIfIdle()
        updates.restartToUpdate()
        XCTAssertTrue(installs.isEmpty)
        XCTAssertEqual(quits, 0)
        XCTAssertFalse(coordinator().installAtLaunch())
    }

    func testTheStatusLineSaysWhenItLastChecked() {
        let updates = coordinator()
        XCTAssertEqual(updates.statusLine, "PasswordPie 0.2.0. Not checked yet.")
        updates.checkNow()
        XCTAssertEqual(updates.statusLine, "Checking…")
        checks[0](UpdateOutcome(.upToDate, version: "0.2.0"))
        now += 3 * day
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        XCTAssertEqual(updates.statusLine, "PasswordPie 0.2.0 is up to date. Checked \(formatter.string(from: now - 3 * day)).")
    }
}
#endif
