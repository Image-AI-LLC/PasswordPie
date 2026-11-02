#if PP_DIRECT
import Combine
import PasswordPieCore
import XCTest
@testable import PasswordPie

/// Chrome is read when the panel opens and the login files changed. A failed read keeps the passwords already shown.
@MainActor
final class ChromeRefreshTests: XCTestCase {
    private var directory: URL!
    private var chromeSyncDefault: Any?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("PASSWORDPIE_DB", directory.appendingPathComponent("test.kdbx").path, 1)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
        chromeSyncDefault = UserDefaults.standard.object(forKey: "chromeSyncEnabled")
    }

    override func tearDownWithError() throws {
        if let chromeSyncDefault {
            UserDefaults.standard.set(chromeSyncDefault, forKey: "chromeSyncEnabled")
        } else {
            UserDefaults.standard.removeObject(forKey: "chromeSyncEnabled")
        }
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        try? FileManager.default.removeItem(at: directory)
    }

    private func unlockedSession() -> VaultSession {
        let session = VaultSession()
        session.restore()
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        return session
    }

    func testUnlockPublishesTheChromeSwitchBeforeThePanelReacts() {
        UserDefaults.standard.set(true, forKey: "chromeSyncEnabled")
        let session = VaultSession()
        session.restore()
        var enabledWhenUnlocked: Bool?
        let cancellable = session.$locked.dropFirst().sink { locked in
            if !locked { enabledWhenUnlocked = session.chromeSyncEnabled }
        }
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        cancellable.cancel()
        XCTAssertEqual(enabledWhenUnlocked, true, "the open panel checks Chrome in this callback, so the switch has to be loaded already")
    }

    func testUnlockDoesNotReadChromeUntilThePanelIsShown() async {
        UserDefaults.standard.set(true, forKey: "chromeSyncEnabled")
        let script = ChromeScript()
        let session = VaultSession()
        session.chromeSource = script.source()
        session.restore()
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()

        XCTAssertTrue(session.chromeSyncEnabled)
        XCTAssertEqual(script.loads, 0, "unlock must not touch Chrome; the keychain prompt belongs to opening the panel")
        session.noteChromePanelShown()
        await waitUntil { script.loads == 1 }
        XCTAssertEqual(script.loads, 1)
    }

    func testAnUnchangedStoreDoesNotReadChrome() {
        let session = unlockedSession()
        session.chromeSyncEnabled = true
        let signature = sampleSignature(byteCount: 4)
        session.chromeStoreSignature = signature
        let script = ChromeScript()
        session.chromeSource = script.source()
        session.refreshChromeIfStoreChanged(signature)
        XCTAssertEqual(script.loads, 0)
        XCTAssertFalse(session.chromeBusy)
    }

    func testAFailedRereadKeepsThePasswordsAlreadyLoaded() async {
        let session = unlockedSession()
        let kept = login(title: "alpha.example", username: "ann", password: "kept")
        let used = Date(timeIntervalSince1970: 1_700_000_000)
        session.liveEntries = [kept]
        session.chromeLastUsed = [kept.id: used]
        session.chromeKey = Data(repeating: 7, count: 16)
        session.chromeStoreSignature = sampleSignature(byteCount: 4)
        session.chromeStatus = "1 password from 1 profile."
        session.chromeSyncEnabled = true
        let script = ChromeScript()
        script.block = true
        script.failure = ChromeLoginsError.database("database is locked")
        session.chromeSource = script.source()

        session.refreshChrome()
        XCTAssertTrue(session.chromeBusy)
        XCTAssertEqual(session.liveEntries, [kept], "the panel keeps showing the passwords it already has while Chrome is read")
        script.gate.signal()
        await waitUntil { !session.chromeBusy }

        XCTAssertEqual(session.liveEntries, [kept])
        XCTAssertEqual(session.chromeLastUsed[kept.id], used)
        XCTAssertEqual(session.chromeKey, Data(repeating: 7, count: 16))
        XCTAssertEqual(session.chromeStoreSignature, sampleSignature(byteCount: 4))
        XCTAssertEqual(session.chromeStatus, "1 password from 1 profile.")
        XCTAssertFalse(session.chromeStatusIsError)
    }

    func testTheFirstReadFailureIsReportedWhenNothingIsLoaded() async {
        let session = unlockedSession()
        session.chromeSyncEnabled = true
        let script = ChromeScript()
        script.failure = ChromeLoginsError.accessDenied
        session.chromeSource = script.source()

        session.refreshChrome()
        await waitUntil { !session.chromeBusy }

        XCTAssertTrue(session.liveEntries.isEmpty)
        XCTAssertTrue(session.chromeStatusIsError)
        XCTAssertTrue(session.chromeNeedsSettings)
        XCTAssertNil(session.chromeKey)
    }

    func testACompletedReadAddsNewLoginsToSearchOrder() async {
        let session = unlockedSession()
        let older = login(title: "alpha.example", username: "ann", password: "old")
        let newer = login(title: "beta.example", username: "bea", password: "new")
        session.liveEntries = [older]
        session.chromeLastUsed = [older.id: Date(timeIntervalSince1970: 1_000)]
        session.chromeSyncEnabled = true
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let script = ChromeScript()
        script.block = true
        script.success = (
            Data(repeating: 3, count: 16),
            ChromeLoginsResult(
                entries: [older, newer],
                profileCount: 1,
                lastUsed: [older.id: Date(timeIntervalSince1970: 1_000), newer.id: now]
            )
        )
        session.chromeSource = script.source(signature: sampleSignature(byteCount: 9))

        session.refreshChrome()
        XCTAssertEqual(session.liveEntries, [older])
        let during = entryTitles(MenuBuilder.searchResults(
            index: session.searchIndex, query: "example", scope: .major, lastUsed: session.lastUsedMap, now: now
        ))
        XCTAssertEqual(during, ["alpha.example"])
        script.gate.signal()
        await waitUntil { session.liveEntries.count == 2 }

        XCTAssertEqual(session.liveEntries, [older, newer])
        XCTAssertFalse(session.chromeBusy)
        XCTAssertEqual(session.chromeStoreSignature, sampleSignature(byteCount: 9))
        let titles = entryTitles(MenuBuilder.searchResults(
            index: session.searchIndex, query: "example", scope: .major, lastUsed: session.lastUsedMap, now: now
        ))
        XCTAssertEqual(titles, ["beta.example", "alpha.example"])
    }

    func testShowingAnUnlockedPanelComparesTheStore() async {
        let session = unlockedSession()
        session.chromeSyncEnabled = true
        let signature = sampleSignature(byteCount: 4)
        session.chromeStoreSignature = signature
        let script = ChromeScript()
        session.chromeSource = script.source(signature: signature)
        let panel = PanelController(session: session)
        defer { panel.hide() }

        panel.show(.hotkey)
        await waitUntil { script.signatures == 1 }

        XCTAssertEqual(script.loads, 0, "opening the panel only stats an unchanged store")
    }

    func testShowingALockedPanelDoesNotReadChrome() async {
        UserDefaults.standard.set(true, forKey: "chromeSyncEnabled")
        let session = VaultSession()
        let script = ChromeScript()
        session.chromeSource = script.source()
        session.chromeSyncEnabled = true
        let panel = PanelController(session: session)
        defer { panel.hide() }

        panel.show(.hotkey)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(script.signatures, 0)
        XCTAssertEqual(script.loads, 0)
    }

    func testACompletedReadReplacesAChangedPassword() async {
        let session = unlockedSession()
        let old = login(title: "alpha.example", username: "ann", password: "old-secret")
        var current = old
        current.password = "new-secret"
        session.liveEntries = [old]
        session.chromeSyncEnabled = true
        let script = ChromeScript()
        script.success = (Data(repeating: 3, count: 16), ChromeLoginsResult(entries: [current], profileCount: 1))
        session.chromeSource = script.source(signature: sampleSignature(byteCount: 9))

        session.refreshChrome()
        await waitUntil { !session.chromeBusy }

        XCTAssertEqual(session.liveEntries, [current])
        XCTAssertFalse(session.liveEntries.contains { $0.password == "old-secret" })
    }

    func testACompletedReadDropsARenamedAccount() async {
        let session = unlockedSession()
        let old = login(title: "alpha.example", username: "ann", password: "pw")
        let renamed = login(title: "alpha.example", username: "ann-new", password: "pw")
        session.liveEntries = [old]
        session.chromeSyncEnabled = true
        let script = ChromeScript()
        script.success = (Data(repeating: 3, count: 16), ChromeLoginsResult(entries: [renamed], profileCount: 1))
        session.chromeSource = script.source(signature: sampleSignature(byteCount: 9))

        session.refreshChrome()
        await waitUntil { !session.chromeBusy }

        XCTAssertEqual(session.liveEntries, [renamed])
        XCTAssertFalse(session.liveEntries.contains { $0.id == old.id })
    }

    func testAChangedLastUsedRebuildsSearchOrder() async {
        let session = unlockedSession()
        let older = login(title: "alpha.example", username: "ann", password: "a")
        let newer = login(title: "beta.example", username: "bea", password: "b")
        session.liveEntries = [older, newer]
        let early = Date(timeIntervalSince1970: 1_000)
        let late = Date(timeIntervalSince1970: 1_800_000_000)
        session.chromeLastUsed = [older.id: early, newer.id: late]
        session.chromeSyncEnabled = true
        let generation = session.menuGeneration
        let now = late
        let script = ChromeScript()
        script.success = (
            Data(repeating: 3, count: 16),
            ChromeLoginsResult(
                entries: [older, newer],
                profileCount: 1,
                lastUsed: [older.id: late, newer.id: early]
            )
        )
        session.chromeSource = script.source(signature: sampleSignature(byteCount: 9))

        session.refreshChrome()
        await waitUntil { !session.chromeBusy }

        XCTAssertNotEqual(session.menuGeneration, generation, "a new last-used time has to reach the open search")
        let titles = entryTitles(MenuBuilder.searchResults(
            index: session.searchIndex, query: "example", scope: .major, lastUsed: session.lastUsedMap, now: now
        ))
        XCTAssertEqual(titles, ["alpha.example", "beta.example"])
    }

    func testTheSameLoginsDoNotRebuildTheMenu() async {
        let session = unlockedSession()
        let kept = login(title: "alpha.example", username: "ann", password: "kept")
        session.liveEntries = [kept]
        session.chromeSyncEnabled = true
        let generation = session.menuGeneration
        let script = ChromeScript()
        script.success = (Data(repeating: 3, count: 16), ChromeLoginsResult(entries: [kept], profileCount: 1))
        session.chromeSource = script.source()

        session.refreshChrome()
        await waitUntil { !session.chromeBusy }

        XCTAssertEqual(session.liveEntries, [kept])
        XCTAssertEqual(session.menuGeneration, generation)
    }

    func testAReadThatFinishesAfterLockDoesNotRestorePasswords() async {
        let session = unlockedSession()
        let kept = login(title: "alpha.example", username: "ann", password: "kept")
        session.liveEntries = [kept]
        session.chromeSyncEnabled = true
        let script = ChromeScript()
        script.block = true
        script.success = (Data(repeating: 3, count: 16), ChromeLoginsResult(entries: [kept], profileCount: 1))
        session.chromeSource = script.source()

        session.refreshChrome()
        session.lock()
        script.gate.signal()
        await waitUntil { script.loads == 1 }
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(session.locked)
        XCTAssertTrue(session.liveEntries.isEmpty)
        XCTAssertNil(session.chromeStoreSignature)
    }

    private func sampleSignature(byteCount: Int) -> ChromeStoreSignature {
        ChromeStoreSignature(files: [
            ChromeStoreSignature.File(relativePath: "Default/Login Data", byteCount: byteCount, modifiedAt: 10)
        ])
    }

    private func login(title: String, username: String, password: String) -> VaultEntry {
        var entry = VaultEntry()
        entry.title = title
        entry.url = "https://\(title)/login"
        entry.username = username
        entry.password = password
        entry.groupPath = ["Chrome (live)", "Work"]
        return entry
    }

    private func entryTitles(_ rows: [MenuRow]) -> [String] {
        rows.compactMap { row in
            guard case .entry = row.kind else { return nil }
            return row.title
        }
    }

    private func waitUntil(timeout: TimeInterval = 2, _ predicate: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline {
                XCTFail("timed out")
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

private final class ChromeScript: @unchecked Sendable {
    private let lock = NSLock()
    private var loadCount = 0
    private var signatureCount = 0
    var block = false
    var failure: Error?
    var success: (key: Data, result: ChromeLoginsResult)?
    let gate = DispatchSemaphore(value: 0)

    var loads: Int {
        lock.lock()
        defer { lock.unlock() }
        return loadCount
    }

    var signatures: Int {
        lock.lock()
        defer { lock.unlock() }
        return signatureCount
    }

    func source(signature: ChromeStoreSignature = ChromeStoreSignature()) -> ChromeSnapshotSource {
        ChromeSnapshotSource(
            signature: { [self] in
                lock.lock()
                signatureCount += 1
                lock.unlock()
                return signature
            },
            load: { [self] cached in
                lock.lock()
                loadCount += 1
                lock.unlock()
                if block { gate.wait() }
                if let failure { throw failure }
                if let success { return success }
                return (cached ?? Data(repeating: 1, count: 16), ChromeLoginsResult())
            }
        )
    }
}
#endif
