#if PP_DIRECT
import AppKit
import Combine
import LocalAuthentication
@testable import PasswordPieAgent
@testable import PasswordPieCore
import XCTest
@testable import PasswordPie

/// Two databases unlocked at once, the agents database, and "Keep unlocked while this Mac is awake" (docs/UX.md, "Two
/// databases at once, and a Mac nobody sits at"; docs/AGENTS.md, "The agents database"). Real database files in a
/// temporary folder, the real session, broker and grant store; a window that answers by itself.
@MainActor
final class AgentsDatabaseTests: XCTestCase {
    private var directory: URL!
    private var socketFolder: URL!
    private var personal: URL!
    private var agents: URL!
    private var cancellables: Set<AnyCancellable> = []
    private let agentsValue = "agents-db-value-4471"
    private let personalValue = "personal-db-value-9902"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agents-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketFolder = URL(fileURLWithPath: "/tmp").appendingPathComponent("ppd-\(getpid())-\(Int.random(in: 0..<1_000_000))")
        try FileManager.default.createDirectory(at: socketFolder, withIntermediateDirectories: true)
        personal = directory.appendingPathComponent("Personal.kdbx")
        agents = directory.appendingPathComponent("Agents.kdbx")
        // The list is not written to the preferences while PASSWORDPIE_DB is set.
        setenv("PASSWORDPIE_DB", agents.path, 1)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
        // Nothing of these files goes into the login keychain on a Mac with Touch ID.
        for url in [personal!, agents!] { UserDefaults.standard.set(true, forKey: "touchIDDeclined.\(url.path)") }
        UserDefaults.standard.removeObject(forKey: VaultSession.agentDatabaseKey)
        UserDefaults.standard.removeObject(forKey: VaultSession.agentKeepUnlockedKey)
    }

    override func tearDownWithError() throws {
        cancellables = []
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        for url in [personal!, agents!] {
            for key in ["touchIDDeclined", "touchIDEnabled", "touchIDUnlockedAt", "touchIDStale"] {
                UserDefaults.standard.removeObject(forKey: "\(key).\(url.path)")
            }
        }
        UserDefaults.standard.removeObject(forKey: VaultSession.agentDatabaseKey)
        UserDefaults.standard.removeObject(forKey: VaultSession.agentKeepUnlockedKey)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: socketFolder)
    }

    // MARK: Setting up two databases

    private func entry(_ title: String, in folder: [String], password: String) -> VaultEntry {
        var entry = VaultEntry(groupPath: folder)
        entry.title = title
        entry.password = password
        return entry
    }

    /// Agents.kdbx (Agents/Token, Agents shared) made first, then Personal.kdbx (Agents/Token too, also shared in its own
    /// file, and Personal/Bank), which is current and unlocked. Agents.kdbx is in the list and not open.
    private func twoDatabases() -> VaultSession {
        let session = VaultSession(writes: .inline)
        session.restore()
        session.passwordDraft = "agents-pw"
        session.confirmDraft = "agents-pw"
        session.unlock()
        session.saveEditing(entry("Token", in: ["Agents"], password: agentsValue))
        session.setFolderSharedWithAgents(["Agents"], true)
        session.lock()
        session.databaseURL = personal
        session.lock()
        session.passwordDraft = "personal-pw"
        session.confirmDraft = "personal-pw"
        session.unlock()
        session.saveEditing(entry("Token", in: ["Agents"], password: personalValue))
        session.saveEditing(entry("Bank", in: ["Personal"], password: "bank-pw-1"))
        // Shared in the personal file too: only the agents database's sharing may count once it is chosen.
        session.setFolderSharedWithAgents(["Agents"], true)
        return session
    }

    private struct Timeout: Error {}

    /// Waits for `condition`, failing (not hanging) when it never comes.
    private func until(_ condition: () -> Bool, _ what: String, seconds: Double = 15) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out: \(what)")
                throw Timeout()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func unlockAlongside(_ session: VaultSession, _ path: String, _ password: String) async -> String? {
        await withCheckedContinuation { continuation in
            session.unlockAlongside(path, password: password) { continuation.resume(returning: $0) }
        }
    }

    // MARK: Two databases unlocked at once

    func testASecondDatabaseUnlocksBesideTheFirstAndLockingLocksBoth() async throws {
        let session = twoDatabases()
        XCTAssertEqual(session.databasePaths, [personal.path, agents.path])
        XCTAssertEqual(session.openDatabasePaths, [personal.path], "no saved unlock: it did not open with this one")
        let wrong = await unlockAlongside(session, agents.path, "nope")
        XCTAssertNotNil(wrong)
        XCTAssertEqual(session.openDatabasePaths, [personal.path])
        let opened = await unlockAlongside(session, agents.path, "agents-pw")
        XCTAssertNil(opened)
        XCTAssertFalse(session.locked, "nothing was locked to do it")
        XCTAssertEqual(session.openDatabasePaths, [personal.path, agents.path])
        let tokens = session.entries.filter { $0.title == "Token" }
        XCTAssertEqual(tokens.count, 2, "the list and search hold the items of both")
        XCTAssertEqual(Set(tokens.compactMap { session.databaseName(of: $0.id) }), ["Personal.kdbx", "Agents.kdbx"])
        let bank = try XCTUnwrap(session.entries.first { $0.title == "Bank" })
        XCTAssertEqual(session.databaseName(of: bank.id), "Personal.kdbx")
        let rows = MenuBuilder.searchResults(entries: session.entries, query: "token", scope: .major, sources: session.entrySources)
        let labels = rows.filter { if case .entry = $0.kind { return true } else { return false } }.map(\.username)
        XCTAssertEqual(labels.sorted(), ["Agents.kdbx", "Personal.kdbx"], "two rows of one title each say their database")
        session.lock()
        XCTAssertEqual(session.openDatabasePaths, [])
        XCTAssertEqual(session.entries, [])
    }

    /// One database open: nothing names it, as before.
    func testOneDatabaseOpenNamesNone() throws {
        let session = twoDatabases()
        let bank = try XCTUnwrap(session.entries.first { $0.title == "Bank" })
        XCTAssertNil(session.databaseName(of: bank.id))
    }

    /// A change to the second database is saved into its own file, under its own password.
    func testAChangeToTheSecondDatabaseIsSavedInItsOwnFile() async throws {
        let session = twoDatabases()
        _ = await unlockAlongside(session, agents.path, "agents-pw")
        let token = try XCTUnwrap(session.entries.first { $0.title == "Token" && session.databaseName(of: $0.id) == "Agents.kdbx" })
        session.changeEntry(token.id) { $0.password = "changed-in-agents-1"; return true }
        await session.savesSettled()
        let agentsFile = try KDBX.load(data: Data(contentsOf: agents), password: "agents-pw", keyFile: nil)
        XCTAssertEqual(agentsFile.entries.first { $0.title == "Token" }?.password, "changed-in-agents-1")
        let personalFile = try KDBX.load(data: Data(contentsOf: personal), password: "personal-pw", keyFile: nil)
        XCTAssertEqual(personalFile.entries.first { $0.title == "Token" }?.password, personalValue)
    }

    // MARK: The agents database

    func testUntilChosenTheCurrentDatabaseServesAgents() {
        let session = twoDatabases()
        XCTAssertEqual(session.agentDatabasePath, personal.path)
        XCTAssertEqual(session.agentSharedItems().map(\.database), [personal.path])
    }

    func testReferencesSharingAndFoldersComeOnlyFromTheAgentsDatabase() async throws {
        let session = twoDatabases()
        session.chooseAgentDatabase(agents.path)
        XCTAssertEqual(UserDefaults.standard.string(forKey: VaultSession.agentDatabaseKey), agents.path, "a preference of this Mac")
        XCTAssertTrue(session.agentVaultLocked, "chosen, and not open yet")
        XCTAssertTrue(session.agentDatabaseNeedsUnlock)
        XCTAssertEqual(session.agentSharedItems(), [], "the personal file's sharing never stands in for it")
        _ = await unlockAlongside(session, agents.path, "agents-pw")
        XCTAssertFalse(session.agentVaultLocked)
        XCTAssertFalse(session.agentDatabaseNeedsUnlock)
        let shared = session.agentSharedItems()
        XCTAssertEqual(shared.map(\.database), [agents.path])
        XCTAssertEqual(session.agentSecret(try XCTUnwrap(shared.first), field: .password), Data(agentsValue.utf8))
        // An item of the personal database is neither shared nor shareable, whatever its own file says.
        let personalToken = try XCTUnwrap(session.entries.first { $0.title == "Token" && session.databaseName(of: $0.id) == "Personal.kdbx" })
        XCTAssertFalse(session.canShareWithAgents(personalToken.id))
        XCTAssertFalse(session.isSharedWithAgents(personalToken.id))
        let bank = try XCTUnwrap(session.entries.first { $0.title == "Bank" })
        XCTAssertFalse(session.canShareWithAgents(bank.id))
        XCTAssertEqual(session.agentFolders, [["Agents"]], "the pane lists the agents database's folders")
        // A folder ticked in the pane is written into the agents database's file.
        session.setFolderSharedWithAgents(["Agents"], false)
        await session.savesSettled()
        let agentsFile = try KDBX.load(data: Data(contentsOf: agents), password: "agents-pw", keyFile: nil)
        XCTAssertTrue(AgentSharing(customData: agentsFile.customData).folders.isEmpty)
        let personalFile = try KDBX.load(data: Data(contentsOf: personal), password: "personal-pw", keyFile: nil)
        XCTAssertEqual(AgentSharing(customData: personalFile.customData).folders, [["Agents"]], "the personal file is untouched")
        XCTAssertEqual(session.agentSharedItems(), [])
    }

    /// Choosing the current database is no choice: agents follow a switch, as they always did.
    func testChoosingTheCurrentDatabaseFollowsTheCurrentOne() {
        let session = twoDatabases()
        session.chooseAgentDatabase(agents.path)
        session.chooseAgentDatabase(personal.path)
        XCTAssertNil(session.agentDatabaseChoice)
        XCTAssertNil(UserDefaults.standard.string(forKey: VaultSession.agentDatabaseKey))
        session.chooseAgentDatabase(agents.path)
        session.forgetDatabase(agents.path)
        XCTAssertEqual(session.agentDatabasePath, personal.path, "removed from the list: back to the current database")
    }

    // MARK: Through the broker

    private func project() throws -> URL {
        let project = directory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Scripts"), withIntermediateDirectories: true)
        try "#!/bin/sh\necho deploy\n".write(to: project.appendingPathComponent("Scripts/deploy.sh"), atomically: true, encoding: .utf8)
        return project
    }

    private func request(_ project: URL, wait: Int = 0) -> AgentRequest {
        var request = AgentRequest(type: .use, id: 1)
        request.secrets = [AgentSecretRequest(name: "T", ref: "pp://Agents/Token", delivery: .env)]
        request.program = project.appendingPathComponent("Scripts/deploy.sh").path
        request.argv = ["Scripts/deploy.sh"]
        request.masking = true
        request.wait = wait
        request.environment = []
        return request
    }

    private func caller(in project: URL) -> AgentCaller {
        let agent = AgentProcess(pid: 10, startTime: 1, path: "/usr/local/bin/claude", name: "Claude Code")
        return AgentCaller(cli: AgentProcess(pid: 11, startTime: 2, path: "/x/passwordpie", name: "passwordpie"), chain: [agent],
                           agent: agent, sessionKey: "agent:10:1", cwd: project.path, project: project.path)
    }

    /// Agent access over the session, wired as the app wires it, with a window that answers by itself.
    private func access(_ session: VaultSession, choose: @escaping (AgentApprovalModel) -> Void) throws -> (AgentAccess, () -> Int) {
        let suite = "agents-db-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        var shown = 0
        let approver = AgentApprovalController(confirmation: AlwaysConfirms(), lasting: AgentLastingOptions(
            hasPremium: { true }, showPremium: {}, lastLength: { .days7 }, rememberLength: { _ in }
        ), show: { model in
            shown += 1
            DispatchQueue.main.async { choose(model) }
            return {}
        })
        let access = AgentAccess(
            session: session, defaults: defaults, socketPath: socketFolder.appendingPathComponent("d.sock").path,
            logURL: directory.appendingPathComponent("activity.jsonl"), approver: approver, hasPremium: { true },
            mac: "test-mac", linkFolder: directory.appendingPathComponent("bin")
        )
        access.setEnabled(true)
        access.grants.sessionAlive = { _ in true }
        session.agentStateChanges
            .receive(on: DispatchQueue.main)
            .sink { [weak access] in access?.agentStateChanged() }
            .store(in: &cancellables)
        addTeardownBlock { @MainActor in access.stop() }
        return (access, { shown })
    }

    func testAReferenceResolvesOnlyInTheAgentsDatabaseAndItsGrantIsKeptThere() async throws {
        let session = twoDatabases()
        session.chooseAgentDatabase(agents.path)
        _ = await unlockAlongside(session, agents.path, "agents-pw")
        let project = try project()
        let (access, shown) = try access(session) { $0.allow(for: .days7) }
        let first = await access.broker.handle(request(project), from: caller(in: project))
        XCTAssertEqual(first.secrets?.first?.value, agentsValue, "the agents database's Token, never the personal one's")
        let second = await access.broker.handle(request(project), from: caller(in: project))
        XCTAssertEqual(second.secrets?.first?.value, agentsValue)
        XCTAssertEqual(second.by, "7 days, this project")
        XCTAssertEqual(shown(), 1, "the grant read back from the agents database let it through")
        await session.savesSettled()
        let agentsFile = try KDBX.load(data: Data(contentsOf: agents), password: "agents-pw", keyFile: nil)
        XCTAssertEqual(AgentGrants(customData: agentsFile.customData).all.count, 1)
        let personalFile = try KDBX.load(data: Data(contentsOf: personal), password: "personal-pw", keyFile: nil)
        XCTAssertTrue(AgentGrants(customData: personalFile.customData).all.isEmpty, "no grant in the personal file")
        // The agents database goes back to the current one: its grants do not come along, so the window shows again.
        session.chooseAgentDatabase(personal.path)
        await Task.yield()
        let third = await access.broker.handle(request(project), from: caller(in: project))
        XCTAssertEqual(third.secrets?.first?.value, personalValue)
        XCTAssertEqual(shown(), 2)
    }

    /// Unlocked, but the agents database did not open: a request waits, asks for its password (the app opens
    /// Preferences > Agents), and goes on once it is open.
    func testARequestWaitsUntilTheAgentsDatabaseOpens() async throws {
        let session = twoDatabases()
        session.chooseAgentDatabase(agents.path)
        let project = try project()
        let (access, _) = try access(session) { $0.allow() }
        var asked = 0
        access.onNeedsUnlock = { asked += 1 }
        let pending = Task { await access.broker.handle(self.request(project, wait: 30), from: self.caller(in: project)) }
        defer { pending.cancel() }
        try await until({ asked > 0 }, "the request asks for an unlock")
        XCTAssertNotNil(session.agentWaitingLine)
        let opened = await unlockAlongside(session, agents.path, "agents-pw")
        XCTAssertNil(opened)
        let answer = await pending.value
        XCTAssertEqual(answer.secrets?.first?.value, agentsValue)
    }

    /// Locked with the agents database chosen: the request shows the lock screen; the unlock opens only the personal
    /// database (the agents one has no saved unlock), so it then asks for the agents database's password.
    func testAnUnlockThatLeavesTheAgentsDatabaseClosedAsksForItsPassword() async throws {
        let session = twoDatabases()
        session.chooseAgentDatabase(agents.path)
        session.lock()
        let project = try project()
        let (access, _) = try access(session) { $0.allow() }
        var asked: [Bool] = []
        access.onNeedsUnlock = { asked.append(session.locked) }
        let pending = Task { await access.broker.handle(self.request(project, wait: 30), from: self.caller(in: project)) }
        defer { pending.cancel() }
        try await until({ !asked.isEmpty }, "the request asks for an unlock")
        XCTAssertEqual(asked, [true], "locked: the lock screen")
        session.passwordDraft = "personal-pw"
        session.unlock()
        try await until({ asked.count >= 2 }, "the unlock that left it closed asks again")
        XCTAssertEqual(asked, [true, false], "unlocked, and the agents database still closed: its password")
        XCTAssertTrue(session.agentDatabaseNeedsUnlock)
        let opened = await unlockAlongside(session, agents.path, "agents-pw")
        XCTAssertNil(opened)
        let answer = await pending.value
        XCTAssertEqual(answer.secrets?.first?.value, agentsValue)
    }

    /// Closed again (locked, or another database chosen), and nothing is handed out: the request answers `locked`.
    func testLockingClosesTheAgentsDatabaseForAgents() async throws {
        let session = twoDatabases()
        session.chooseAgentDatabase(agents.path)
        _ = await unlockAlongside(session, agents.path, "agents-pw")
        let project = try project()
        let (access, _) = try access(session) { $0.allow() }
        session.lock()
        let answer = await access.broker.handle(request(project), from: caller(in: project))
        XCTAssertEqual(answer.code, AgentErrorCode.locked.rawValue)
    }

    // MARK: Keep unlocked while this Mac is awake

    func testKeepUnlockedIsInForceOnlyWithTheAgentsDatabaseAlone() async throws {
        let session = twoDatabases()
        session.agentAccessOn = true
        session.chooseAgentDatabase(agents.path)
        _ = await unlockAlongside(session, agents.path, "agents-pw")
        XCTAssertFalse(session.agentKeepUnlocked, "off by default")
        XCTAssertFalse(session.keepsAgentDatabaseUnlocked)
        session.setKeepAgentDatabaseUnlocked(true)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: VaultSession.agentKeepUnlockedKey), "a preference of this Mac")
        XCTAssertFalse(session.keepsAgentDatabaseUnlocked, "the personal database is open too")
        // The worker: only the agents database in its list.
        session.forgetDatabase(personal.path)
        XCTAssertEqual(session.databasePaths, [agents.path])
        XCTAssertTrue(session.locked, "removing the current database locks, as before")
        session.passwordDraft = "agents-pw"
        session.unlock()
        try await until({ !session.locked && !session.unlocking }, "the agents database unlocks")
        XCTAssertEqual(session.openDatabasePaths, [agents.path])
        XCTAssertTrue(session.keepsAgentDatabaseUnlocked)
        session.agentAccessOn = false
        XCTAssertFalse(session.keepsAgentDatabaseUnlocked, "agent access off: no reason to keep it open")
        session.agentAccessOn = true
        session.setKeepAgentDatabaseUnlocked(false)
        XCTAssertFalse(session.keepsAgentDatabaseUnlocked)
        session.setKeepAgentDatabaseUnlocked(true)
        session.lock()
        XCTAssertFalse(session.keepsAgentDatabaseUnlocked, "nothing is kept once locked")
    }

    /// The auto-lock monitor with the setting in force: idle and the screen saver leave it, the screen lock, sleep, a user
    /// switch and powering off lock it. With it off the monitor does what it always did.
    func testTheMonitorLocksOnEachListedEventAndNotOnIdle() {
        let distributed = NotificationCenter()
        let workspace = NSWorkspace.shared.notificationCenter
        var keep = true
        var locks = 0
        let monitor = AutoLockMonitor(settings: AutoLockSettings(timeoutMinutes: 1), distributed: distributed, keepUnlocked: { keep }) {
            locks += 1
        }
        monitor.start()
        distributed.post(name: AutoLockMonitor.screenSaverStarted, object: nil)
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertEqual(locks, 0, "the screen saver and the display sleeping are idleness")
        distributed.post(name: AutoLockMonitor.screenLocked, object: nil)
        XCTAssertEqual(locks, 1, "the screen lock")
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(locks, 2, "sleep")
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        XCTAssertEqual(locks, 3, "a user switch")
        workspace.post(name: NSWorkspace.willPowerOffNotification, object: nil)
        XCTAssertEqual(locks, 4, "logging out, restarting")
        keep = false
        distributed.post(name: AutoLockMonitor.screenSaverStarted, object: nil)
        XCTAssertEqual(locks, 5, "off: the screen saver locks as before")
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertEqual(locks, 6, "off: the display sleeping locks as before")
    }
}

/// Approving on a Mac without a usable Touch ID (W1: at that Mac over Screen Sharing): the window's confirmation is
/// Touch ID or the login password, never biometrics alone.
@MainActor
final class ApprovalWithoutTouchIDTests: XCTestCase {
    func testTheApprovalFallsBackToTheLoginPassword() {
        XCTAssertEqual(SystemOwnerConfirmation.policy, .deviceOwnerAuthentication)
        XCTAssertNotEqual(SystemOwnerConfirmation.policy, .deviceOwnerAuthenticationWithBiometrics)
    }
}

@MainActor
private final class AlwaysConfirms: OwnerConfirmation {
    func confirm(reason: String) async -> Bool { true }
    func cancel() {}
}
#endif
