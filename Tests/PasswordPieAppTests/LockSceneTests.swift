import AppKit
import PasswordPieCore
import XCTest
@testable import PasswordPie

/// `docs/UX.md`, "Lock": ⌘L, the short lock scene with the padlock click, and locking with the Mac's screen.
@MainActor
final class LockSceneTests: XCTestCase {
    private var directory: URL!
    private var played: [LockSound] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("lockscene-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("PASSWORDPIE_DB", directory.appendingPathComponent("test.kdbx").path, 1)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
        // Another test hands focus back to the terminal, and a panel hides when another app comes forward.
        setenv("PASSWORDPIE_STICKY", "1", 1)
        played = []
    }

    override func tearDownWithError() throws {
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        unsetenv("PASSWORDPIE_STICKY")
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: Screen lock

    func testLockingTheMacLocksTheVault() {
        let center = NotificationCenter()
        var locks = 0
        let monitor = AutoLockMonitor(settings: AutoLockSettings(), distributed: center) { locks += 1 }
        monitor.start()
        center.post(name: AutoLockMonitor.screenLocked, object: nil)
        XCTAssertEqual(locks, 1)
    }

    func testScreenLockFollowsTheScreenSaverSwitch() {
        let center = NotificationCenter()
        var locks = 0
        let monitor = AutoLockMonitor(settings: AutoLockSettings(lockOnScreenSaver: false), distributed: center) { locks += 1 }
        monitor.start()
        center.post(name: AutoLockMonitor.screenLocked, object: nil)
        center.post(name: AutoLockMonitor.screenSaverStarted, object: nil)
        XCTAssertEqual(locks, 0)
    }

    // MARK: ⌘L

    func testCommandLLocksTheOpenMenuThenTheSceneFadesAway() async throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "the panel needs a screen to become visible")
        let (session, panel) = openPanel()
        defer { panel.hide() }

        XCTAssertTrue(panel.panel.performKeyEquivalent(with: try commandL(panel)))

        XCTAssertTrue(session.locked)
        XCTAssertTrue(panel.isVisible, "the lock screen shows before it fades")
        XCTAssertTrue(panel.lockingOut)
        XCTAssertTrue(panel.lockModel.locking, "no password field while the scene plays")
        await waitUntil { !panel.isVisible }
        XCTAssertEqual(played, [.lock])
        XCTAssertFalse(panel.lockingOut)
        XCTAssertFalse(panel.lockModel.locking)
        XCTAssertEqual(panel.panel.alphaValue, 1, "the next showing starts opaque")
    }

    func testCommandLIsIgnoredWhileLocked() throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "the panel needs a screen to become visible")
        let (session, panel) = openPanel()
        defer { panel.hide() }
        session.lock()
        panel.show(.hotkey)
        played = []

        XCTAssertFalse(panel.panel.performKeyEquivalent(with: try commandL(panel)))
        XCTAssertTrue(played.isEmpty)
    }

    func testTheShortcutDuringTheSceneKeepsTheLockScreen() async throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "the panel needs a screen to become visible")
        let (session, panel) = openPanel(scene: LockScene(settle: 0.02, fadeStart: 0.2, fadeDuration: 0.05))
        defer { panel.hide() }
        session.lock()
        XCTAssertTrue(panel.lockingOut)

        panel.toggle(.hotkey)

        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(panel.lockingOut)
        XCTAssertFalse(panel.lockModel.locking, "the password field is back")
        XCTAssertEqual(panel.panel.alphaValue, 1)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(panel.isVisible, "the cancelled fade does not hide it later")
        XCTAssertEqual(panel.panel.alphaValue, 1)
    }

    func testClosingDuringTheSceneEndsIt() async throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "the panel needs a screen to become visible")
        let (session, panel) = openPanel(scene: LockScene(settle: 0.02, fadeStart: 0.2, fadeDuration: 0.05))
        session.lock()
        panel.hide()
        XCTAssertFalse(panel.lockingOut)
        XCTAssertEqual(panel.panel.alphaValue, 1)

        panel.show(.hotkey)
        defer { panel.hide() }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(panel.isVisible, "the old scene does not hide the new showing")
    }

    func testLockingWithTheMenuClosedIsSilent() async throws {
        let (session, panel) = openPanel(show: false)
        session.lock()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(played.isEmpty)
        XCTAssertFalse(panel.lockingOut)
    }

    func testUnlockingInTheOpenMenuPlaysTheOpeningClick() async throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "the panel needs a screen to become visible")
        let (session, panel) = openPanel()
        defer { panel.hide() }
        session.lock()
        panel.show(.hotkey)
        played = []

        session.passwordDraft = "pw"
        session.unlock()
        await waitUntil { !session.locked }

        XCTAssertEqual(played, [.unlock])
    }

    // MARK: Sounds

    func testThePadlockSoundsAreTheSystemSettingsOnes() throws {
        for sound in [LockSound.lock, .unlock] {
            let url = try XCTUnwrap(LockSoundPlayer.url(for: sound), "\(sound)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
            XCTAssertNotNil(NSSound(contentsOf: url, byReference: true))
        }
    }

    func testSoundsFollowTheSystemSoundEffectsSetting() throws {
        let name = "lockscene-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(LockSoundPlayer.soundEffectsEnabled(defaults), "on unless turned off")
        defaults.set(0, forKey: LockSoundPlayer.soundEffectsKey)
        XCTAssertFalse(LockSoundPlayer.soundEffectsEnabled(defaults))
        defaults.set(1, forKey: LockSoundPlayer.soundEffectsKey)
        XCTAssertTrue(LockSoundPlayer.soundEffectsEnabled(defaults))
    }

    // MARK: Helpers

    private func openPanel(show: Bool = true,
                           scene: LockScene = LockScene(settle: 0.01, fadeStart: 0.05, fadeDuration: 0.02)) -> (VaultSession, PanelController) {
        let session = VaultSession()
        session.restore()
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        XCTAssertFalse(session.locked)
        let panel = PanelController(session: session)
        panel.lockScene = scene
        panel.playSound = { [unowned self] in self.played.append($0) }
        if show { panel.show(.hotkey) }
        return (session, panel)
    }

    private func commandL(_ panel: PanelController) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                       windowNumber: panel.panel.windowNumber, context: nil, characters: "l",
                                       charactersIgnoringModifiers: "l", isARepeat: false, keyCode: 37))
    }

    private func waitUntil(timeout: TimeInterval = 5, _ predicate: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline {
                XCTFail("timed out")
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
