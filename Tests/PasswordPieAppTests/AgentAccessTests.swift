#if PP_DIRECT
import AppKit
import Darwin
@testable import PasswordPieAgent
@testable import PasswordPieCore
import SwiftUI
import XCTest
@testable import PasswordPie

/// The app side of agent access: what the session offers agents, where sharing is kept, the switch and the socket, the
/// approval window's rules and the lock screen line. The library and the tool are tested in PasswordPieAgentTests.
@MainActor
final class AgentAccessTests: XCTestCase {
    private var directory: URL!
    private var socketFolder: URL!
    private let planted = "planted-session-secret-71"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // sun_path is 104 bytes: the socket lives under /tmp.
        socketFolder = URL(fileURLWithPath: "/tmp").appendingPathComponent("ppa-\(getpid())-\(Int.random(in: 0..<1_000_000))")
        try FileManager.default.createDirectory(at: socketFolder, withIntermediateDirectories: true)
        setenv("PASSWORDPIE_DB", directory.appendingPathComponent("test.kdbx").path, 1)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: socketFolder)
    }

    private func unlockedSession() -> VaultSession {
        let session = VaultSession(writes: .inline)
        session.restore()
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        return session
    }

    private func entry(_ title: String, in folder: [String], password: String, fields: [VaultField] = []) -> VaultEntry {
        var entry = VaultEntry(groupPath: folder, fields: fields)
        entry.title = title
        entry.password = password
        return entry
    }

    /// A session holding Developer/Token (custom field Key ID), Personal/Bank and Personal/Other.
    private func populated() -> VaultSession {
        let session = unlockedSession()
        session.saveEditing(entry("Token", in: ["Developer"], password: planted, fields: [VaultField(key: "Key ID", value: "KEY-1")]))
        session.saveEditing(entry("Bank", in: ["Personal"], password: "bank-password"))
        session.saveEditing(entry("Other", in: ["Personal"], password: "other-password"))
        return session
    }

    private func listID(_ session: VaultSession, _ title: String) throws -> UUID {
        try XCTUnwrap(session.entries.first { $0.title == title && !$0.trashed }?.id)
    }

    // MARK: What agents see

    func testNothingIsSharedByDefault() {
        let session = populated()
        XCTAssertFalse(session.agentVaultLocked)
        XCTAssertEqual(session.agentSharedItems(), [])
    }

    func testAFolderSharesWhatIsInItAndAnItemSharesItself() throws {
        let session = populated()
        session.setFolderSharedWithAgents(["Developer"], true)
        XCTAssertEqual(session.agentSharedItems().map(\.title), ["Token"])
        XCTAssertEqual(session.agentSharedItems().first?.fields, ["Key ID"])
        session.setSharedWithAgents(try listID(session, "Bank"), true)
        XCTAssertEqual(Set(session.agentSharedItems().map(\.title)), ["Token", "Bank"])
        XCTAssertTrue(session.isSharedWithAgents(try listID(session, "Bank")))
        XCTAssertFalse(session.isSharedWithAgents(try listID(session, "Other")))
        XCTAssertEqual(session.agentSharedFolder(of: try listID(session, "Token")), ["Developer"])
        let token = try XCTUnwrap(session.agentSharedItems().first { $0.title == "Token" })
        XCTAssertEqual(session.agentSecret(token, field: .password), Data(planted.utf8))
        XCTAssertEqual(session.agentSecret(token, field: .custom("Key ID")), Data("KEY-1".utf8))
        XCTAssertNil(session.agentSecret(token, field: .custom("PasswordPie.PreviousPasswords")))
    }

    /// A two-step secret, however a KeePass app keeps it, is not a field an agent can name.
    func testTwoStepSecretsAreNotFields() throws {
        let session = unlockedSession()
        session.saveEditing(entry("Legacy", in: ["Developer"], password: "pw-legacy-1", fields: [
            VaultField(key: "TOTP Seed", value: "GEZDGNBVGY3TQOJQ"), VaultField(key: "TOTP Settings", value: "30;6"),
            VaultField(key: "TimeOtp-Secret-Base32", value: "GEZDGNBVGY3TQOJQ"), VaultField(key: "Region", value: "eu"),
        ]))
        session.setFolderSharedWithAgents(["Developer"], true)
        let item = try XCTUnwrap(session.agentSharedItems().first)
        XCTAssertEqual(item.fields, ["Region"])
        XCTAssertNil(session.agentSecret(item, field: .custom("TOTP Seed")))
    }

    func testUnsharingEndsAccessAndTheRecycleBinNeverCounts() throws {
        let session = populated()
        session.setFolderSharedWithAgents(["Developer"], true)
        let token = try XCTUnwrap(session.agentSharedItems().first)
        session.setFolderSharedWithAgents(["Developer"], false)
        XCTAssertEqual(session.agentSharedItems(), [])
        XCTAssertNil(session.agentSecret(token, field: .password), "a request resolved before the unshare gets nothing")
        session.setFolderSharedWithAgents(["Personal"], true)
        session.edit(try listID(session, "Bank"))
        session.deleteEditing()
        XCTAssertEqual(session.agentSharedItems().map(\.title), ["Other"])
    }

    func testLockedOffersNothing() throws {
        let session = populated()
        session.setFolderSharedWithAgents(["Developer"], true)
        let token = try XCTUnwrap(session.agentSharedItems().first)
        session.lock()
        XCTAssertTrue(session.agentVaultLocked)
        XCTAssertEqual(session.agentSharedItems(), [])
        XCTAssertNil(session.agentSecret(token, field: .password))
    }

    /// Sharing is kept in the database file (its custom data), not in the app's preferences: it survives a reopen, and
    /// writing a forged entry into the preferences shares nothing.
    func testSharingLivesInTheDatabaseNotInPreferences() async throws {
        let session = populated()
        session.setFolderSharedWithAgents(["Developer"], true)
        let tokenID = try XCTUnwrap(session.agentSharedItems().first?.id)
        let path = session.databaseURL.path
        session.lock()
        let reopened = VaultSession(writes: .inline)
        reopened.restore()
        reopened.passwordDraft = "pw"
        reopened.unlock()
        for _ in 0..<500 where reopened.agentVaultLocked { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(reopened.agentVaultLocked)
        let loaded = try KDBX.load(data: Data(contentsOf: URL(fileURLWithPath: path)), password: "pw", keyFile: nil)
        XCTAssertTrue(AgentSharing(customData: loaded.customData).isShared(folder: ["Developer"]))
        let preferences = UserDefaults.standard.dictionaryRepresentation().keys
        XCTAssertFalse(preferences.contains { $0.contains("AgentSharing") })
        UserDefaults.standard.set(#"{"version":1,"items":["\#(tokenID.uuidString)"],"folders":[["Personal"]]}"#, forKey: AgentSharing.customDataKey)
        defer { UserDefaults.standard.removeObject(forKey: AgentSharing.customDataKey) }
        let titles = Set(reopened.agentSharedItems().map(\.title))
        XCTAssertEqual(titles, ["Token"], "the forged preference shared nothing")
    }

    /// PRD check 5 against the real session: an unshared item and a nonexistent one answer the same.
    func testUnsharedAndNonexistentAnswerTheSameThroughTheBroker() async {
        let session = populated()
        session.setFolderSharedWithAgents(["Developer"], true)
        let approver = AgentApprovalController(confirmation: Confirms(true), show: { _ in {} })
        let broker = VaultBroker(vault: session, approver: approver, grants: NoAgentGrants(), activity: Activity()) { true }
        func ask(_ ref: String) async -> AgentResponse {
            var request = AgentRequest(type: .use, id: 1)
            request.secrets = [AgentSecretRequest(name: "T", ref: ref, delivery: .env)]
            request.wait = 0
            return await broker.handle(request, from: caller)
        }
        let unshared = await ask("pp://Personal/Bank")
        let missing = await ask("pp://Personal/Nothing")
        XCTAssertEqual(unshared.errorCode, .notAvailable)
        XCTAssertEqual(AgentCoding.encode(unshared), AgentCoding.encode(AgentResponse.error(.notAvailable, id: 1, ref: "pp://Personal/Bank")))
        XCTAssertEqual(missing.errorCode, .notAvailable)
        XCTAssertTrue(approver.open.isEmpty)
    }

    func testOnlyTheUnlockedDatabaseIsOffered() throws {
        let session = populated()
        session.setFolderSharedWithAgents(["Developer"], true)
        XCTAssertTrue(session.agentSharedItems().allSatisfy { $0.database == session.databaseURL.path })
    }

    // MARK: The switch and the socket

    private func access(_ session: VaultSession, defaults: UserDefaults) -> AgentAccess {
        AgentAccess(
            session: session,
            defaults: defaults,
            socketPath: socketFolder.appendingPathComponent("a.sock").path,
            logURL: directory.appendingPathComponent("activity.jsonl"),
            approver: AgentApprovalController(confirmation: Confirms(true), show: { _ in {} }),
            linkFolder: directory.appendingPathComponent("bin")
        )
    }

    /// Off by default, and no socket while off.
    func testNoSocketUntilTheSwitchIsOn() throws {
        let suite = "agents-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = unlockedSession()
        let access = access(session, defaults: defaults)
        let socket = socketFolder.appendingPathComponent("a.sock").path
        access.start()
        XCTAssertFalse(access.enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket))
        access.setEnabled(true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket))
        XCTAssertTrue(defaults.bool(forKey: AgentConstants.enabledKey))
        XCTAssertTrue(session.agentAccessOn, "Share with Agents shows in details")
        access.setEnabled(false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket))
        XCTAssertFalse(access.isListening)
        XCTAssertFalse(session.agentAccessOn)
    }

    func testTurningOffOrLockingWithdrawsPrompts() async throws {
        let suite = "agents-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let access = access(unlockedSession(), defaults: defaults)
        let prompt = Task { await access.approver.present(Self.prompt(raw: false)) }
        await Task.yield()
        while access.approver.open.isEmpty { await Task.yield() }
        access.vaultStateChanged(locked: true)
        let decision = await prompt.value
        XCTAssertEqual(decision, .dismissed)
        XCTAssertTrue(access.approver.open.isEmpty)
    }

    func testTheLinkGoesIntoTheUsersOwnFolderAndShowsItsCommand() throws {
        let suite = "agents-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let access = access(unlockedSession(), defaults: defaults)
        XCTAssertTrue(access.linkCommand.contains("ln -sf"))
        XCTAssertTrue(access.linkCommand.hasSuffix("/bin/passwordpie"))
        // The test runner is not an app bundle with the tool: nothing is linked, and it says so.
        access.createLink()
        XCTAssertFalse(FileManager.default.fileExists(atPath: access.linkURL.path))
        XCTAssertNotNil(access.linkStatus)
    }

    func testTheLockScreenNamesTheWaitingAgent() {
        let session = VaultSession(writes: .inline)
        session.restore()
        session.agentWaitingLine = AgentWaiting.lockScreenLine([AgentWaiting(agent: "Claude Code", count: 1)])
        XCTAssertEqual(LockScreenPresentation(session: session, locking: false).agentWaiting, "Claude Code is waiting for 1 secret.")
        let plain = LockScreenContent.fittedHeight(LockScreenPresentation(databaseName: "x.kdbx"))
        let waiting = LockScreenContent.fittedHeight(LockScreenPresentation(databaseName: "x.kdbx", agentWaiting: "Claude Code is waiting for 1 secret."))
        XCTAssertGreaterThan(waiting, plain, "the panel grows to show the line")
    }

    // MARK: The approval window

    private static func prompt(raw: Bool, rows: Int = 2) -> AgentApprovalPrompt {
        AgentApprovalPrompt(
            id: UUID(), kind: raw ? .read : .use, raw: raw, agent: "Claude Code", signature: "signed by Anthropic PBC", agentPID: 4182,
            startedIn: "Terminal", command: "Scripts/release-direct.sh", program: "/p/Scripts/release-direct.sh", project: "/p",
            reason: "Notarize 0.3.0",
            rows: (0..<rows).map { AgentApprovalRow(title: "Item \($0)", folder: "Developer", field: "password", delivery: raw ? .shown : .env, name: "T\($0)", tooShortToMask: false) }
        )
    }

    /// Every Allow needs Touch ID (or the login password): a click alone allows nothing.
    func testAllowNeedsTheOwnersConfirmation() async {
        var decisions: [AgentApprovalDecision] = []
        let refused = AgentApprovalModel(prompt: Self.prompt(raw: false), confirmation: Confirms(false)) { decisions.append($0) }
        refused.allow()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(decisions.isEmpty)
        XCTAssertTrue(refused.notConfirmed)
        let confirmed = AgentApprovalModel(prompt: Self.prompt(raw: false), confirmation: Confirms(true)) { decisions.append($0) }
        confirmed.toggle(0)
        confirmed.allow()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(decisions, [.allow([1])], "only the rows left ticked")
    }

    /// Withdrawn while the Touch ID sheet is up: the sheet is closed and nothing is allowed even if it succeeds after.
    func testAWithdrawnPromptClosesItsTouchIDSheet() async {
        let slow = SlowConfirmation()
        var decisions: [AgentApprovalDecision] = []
        let model = AgentApprovalModel(prompt: Self.prompt(raw: false), confirmation: slow) { decisions.append($0) }
        model.allow()
        for _ in 0..<20 { await Task.yield() }
        model.dismiss()
        XCTAssertTrue(slow.cancelled)
        slow.finish(true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(decisions, [.dismissed])
    }

    func testUntickingEverythingCannotAllowAndDenyAnswersAtOnce() {
        var decisions: [AgentApprovalDecision] = []
        let model = AgentApprovalModel(prompt: Self.prompt(raw: false), confirmation: Confirms(true)) { decisions.append($0) }
        model.toggle(0)
        model.toggle(1)
        XCTAssertFalse(model.canAllow)
        model.deny()
        model.deny()
        XCTAssertEqual(decisions, [.deny], "answered once")
    }

    func testTheWordingOfARawRead() {
        let raw = AgentApprovalModel(prompt: Self.prompt(raw: true, rows: 1), confirmation: Confirms(true)) { _ in }
        XCTAssertEqual(raw.title, "Claude Code wants to see 1 secret")
        XCTAssertEqual(raw.allowTitle, "Show to Agent")
        XCTAssertEqual(AgentApprovalModel.rawWarning, "The agent will see the value. It stays in the conversation, and in the model provider's records if the model is hosted.")
        let use = AgentApprovalModel(prompt: Self.prompt(raw: false), confirmation: Confirms(true)) { _ in }
        XCTAssertEqual(use.title, "Claude Code wants to use 2 secrets")
        XCTAssertEqual(use.allowTitle, "Allow Once")
        XCTAssertEqual(use.agentLine, "Claude Code, signed by Anthropic PBC, started in Terminal   (pid 4182)")
    }

    func testTheWindowDraws() {
        let model = AgentApprovalModel(prompt: Self.prompt(raw: true, rows: 1), confirmation: Confirms(true)) { _ in }
        let host = NSHostingView(rootView: AgentApprovalView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 460, height: 420)
        XCTAssertNotNil(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        XCTAssertGreaterThan(host.fittingSize.height, 200)
    }

    private var caller: AgentCaller {
        let agent = AgentProcess(pid: 10, startTime: 1, path: "/usr/local/bin/claude", name: "Claude Code")
        return AgentCaller(cli: AgentProcess(pid: 11, startTime: 2, path: "/x/passwordpie", name: "passwordpie"), chain: [agent],
                           agent: agent, sessionKey: "agent:10:1", cwd: "/p", project: "/p")
    }
}

@MainActor
private final class Confirms: OwnerConfirmation {
    let answer: Bool
    init(_ answer: Bool) { self.answer = answer }
    func confirm(reason: String) async -> Bool { answer }
    func cancel() {}
}

@MainActor
private final class SlowConfirmation: OwnerConfirmation {
    var cancelled = false
    private var pending: CheckedContinuation<Bool, Never>?
    func confirm(reason: String) async -> Bool { await withCheckedContinuation { pending = $0 } }
    func cancel() { cancelled = true }
    func finish(_ answer: Bool) {
        pending?.resume(returning: answer)
        pending = nil
    }
}

private final class Activity: AgentActivityLogging {
    func append(_ record: AgentActivityRecord) {}
}

/// Agent access is direct-download only: the App Store app links none of it and its bundle has no tool. And the app's
/// agent code writes nothing to a log, so no value can end up in one.
final class AgentChannelTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testOnlyTheDirectBuildLinksAndBundlesIt() throws {
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertTrue(manifest.contains(#"let agentLibrary: [Target.Dependency] = storeBuild ? [] : ["PasswordPieAgent"]"#))
        let makefile = try String(contentsOf: root.appendingPathComponent("Makefile"), encoding: .utf8)
        XCTAssertTrue(makefile.contains(#"$(if $(3),mkdir -p "$(2)/Contents/Helpers" && cp "$(1)/$(CLI)" "$(2)/Contents/Helpers/passwordpie")"#))
        XCTAssertTrue(makefile.contains("--identifier $(CLI_ID) --entitlements Entitlements/cli.entitlements"))
        // Every app file that names the agent library is inside #if PP_DIRECT.
        let app = root.appendingPathComponent("Sources/PasswordPieApp")
        for name in try FileManager.default.contentsOfDirectory(atPath: app.path) where name.hasSuffix(".swift") {
            let text = try String(contentsOf: app.appendingPathComponent(name), encoding: .utf8)
            guard text.contains("import PasswordPieAgent") else { continue }
            XCTAssertTrue(text.hasPrefix("#if PP_DIRECT"), name)
        }
    }

    func testTheAgentCodeLogsNothing() throws {
        let logging = try NSRegularExpression(pattern: #"\b(NSLog|os_log|print|debugPrint|Logger)\s*\("#)
        var files = [root.appendingPathComponent("Sources/PasswordPieAgent")]
        files += ["AgentAccess.swift", "AgentApproval.swift", "AgentsPane.swift", "VaultSession+Agents.swift"].map {
            root.appendingPathComponent("Sources/PasswordPieApp/\($0)")
        }
        var checked = 0
        for url in files {
            let urls = url.hasDirectoryPath
                ? try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                : [url]
            for file in urls where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                XCTAssertNil(logging.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), file.lastPathComponent)
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 8)
    }
}
#endif
