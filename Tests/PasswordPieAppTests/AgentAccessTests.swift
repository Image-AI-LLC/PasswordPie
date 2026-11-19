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

    func testTheLinkCommandQuotesPaths() {
        XCTAssertEqual(AgentAccess.shellQuoted("/Applications/PasswordPie.app/Contents/Helpers/passwordpie"), "/Applications/PasswordPie.app/Contents/Helpers/passwordpie")
        XCTAssertEqual(AgentAccess.shellQuoted("/Volumes/My Apps/O'Neil.app"), "'/Volumes/My Apps/O'\\''Neil.app'")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(AgentAccess.shellQuoted(home + "/my bin"), "~/'my bin'")
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

    // MARK: Rows by item

    /// A request for many secrets: `counts` fields of each item, asked for item by item unless `interleaved`.
    private static func prompt(items counts: [Int], interleaved: Bool = false, short: Set<Int> = []) -> AgentApprovalPrompt {
        var rows: [AgentApprovalRow] = []
        let ids = counts.map { _ in UUID() }
        for (item, count) in counts.enumerated() {
            for field in 0..<count {
                rows.append(AgentApprovalRow(
                    title: "Item \(item)", folder: "stripe", field: "field VAR_\(item)_\(field)", delivery: field == 0 && count > 2 ? .file : .env,
                    name: "VAR_\(item)_\(field)", tooShortToMask: false, item: ids[item]
                ))
            }
        }
        if interleaved { rows = rows.enumerated().sorted { ($0.offset % 2, $0.offset) < ($1.offset % 2, $1.offset) }.map(\.element) }
        for index in short { rows[index].tooShortToMask = true }
        var prompt = Self.prompt(raw: false)
        prompt.rows = rows
        return prompt
    }

    /// Twelve fields of one item are one row that opens, and every field keeps its own checkbox.
    func testManySecretsOfOneItemAreOneRowThatOpens() async {
        var decisions: [AgentApprovalDecision] = []
        let model = AgentApprovalModel(prompt: Self.prompt(items: [12, 1, 3]), confirmation: Confirms(true)) { decisions.append($0) }
        XCTAssertEqual(model.title, "Claude Code wants to use 16 secrets")
        XCTAssertEqual(model.groups.map(\.rows), [Array(0..<12), [12], [13, 14, 15]])
        XCTAssertEqual(model.groups.map(\.title), ["Item 0", "Item 1", "Item 2"])
        let twelve = model.groups[0]
        XCTAssertFalse(model.isOpen(twelve), "many secrets: an item starts closed")
        XCTAssertTrue(model.isOpen(model.groups[1]), "a single secret has nothing to open")
        XCTAssertEqual(model.groupLine(twelve), "12 secrets · 11 environment variables, 1 file for the command")
        XCTAssertEqual(model.tick(of: twelve), .all)

        // Open it and untick two fields: the item's checkbox says "some", and the closed row says how many are out.
        model.toggleOpen(twelve)
        XCTAssertTrue(model.isOpen(twelve))
        model.toggle(3)
        model.toggle(7)
        XCTAssertEqual(model.tick(of: twelve), .some)
        XCTAssertEqual(model.groupLine(twelve), "12 secrets · 11 environment variables, 1 file for the command · 2 left out")
        // The item's checkbox on a part-ticked item ticks the rest; again, it unticks them all. Another item's rows
        // stay as they are, also the one that was unticked.
        model.toggle(13)
        model.toggle(group: twelve)
        XCTAssertEqual(model.tick(of: twelve), .all)
        XCTAssertFalse(model.ticked.contains(13), "another item's unticked row is not ticked with it")
        model.toggle(group: twelve)
        XCTAssertEqual(model.tick(of: twelve), .none)
        XCTAssertEqual(model.groupLine(twelve), "12 secrets · 11 environment variables, 1 file for the command · all left out")
        XCTAssertEqual(model.tick(of: model.groups[2]), .some, "another item's rows are not touched")
        model.toggle(5)
        model.allow()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(decisions, [.allow([5, 12, 14, 15])], "the answer is still row by row")
    }

    func testAFewSecretsAreAllInViewAndRowsOfOneItemStayTogether() {
        let few = AgentApprovalModel(prompt: Self.prompt(items: [2, 2]), confirmation: Confirms(true)) { _ in }
        XCTAssertEqual(few.groups.map(\.rows), [[0, 1], [2, 3]])
        XCTAssertTrue(few.groups.allSatisfy(few.isOpen), "up to six secrets, every row shows")
        few.toggleOpen(few.groups[0])
        XCTAssertFalse(few.isOpen(few.groups[0]))

        // Asked for in any order, an item's secrets are under the item, where it was first asked for.
        let mixed = AgentApprovalModel(prompt: Self.prompt(items: [4, 4], interleaved: true), confirmation: Confirms(true)) { _ in }
        XCTAssertEqual(mixed.groups.count, 2)
        XCTAssertEqual(mixed.groups.map(\.id), [0, 2])
        XCTAssertEqual(Set(mixed.groups.flatMap(\.rows)), Set(0..<8))
        XCTAssertTrue(mixed.groups.allSatisfy { group in Set(group.rows.map { mixed.prompt.rows[$0].title }).count == 1 })
        XCTAssertFalse(mixed.isOpen(mixed.groups[0]))

        // Rows that name no item (an older broker), and two items with one title, are never put together.
        let plain = AgentApprovalModel(prompt: Self.prompt(raw: false, rows: 8), confirmation: Confirms(true)) { _ in }
        XCTAssertEqual(plain.groups.map(\.rows), (0..<8).map { [$0] })
        var twins = Self.prompt(items: [1, 1])
        twins.rows[1].title = twins.rows[0].title
        XCTAssertEqual(AgentApprovalModel(prompt: twins, confirmation: Confirms(true)) { _ in }.groups.count, 2)
    }

    func testAClosedItemStillSaysWhatIsTooShortToHide() {
        let model = AgentApprovalModel(prompt: Self.prompt(items: [8], short: [1, 4]), confirmation: Confirms(true)) { _ in }
        XCTAssertEqual(model.tooShortCount(model.groups[0]), 2)
    }

    func testAnItemsCheckboxDoesNothingWhileTouchIDIsUp() async {
        let slow = SlowConfirmation()
        let model = AgentApprovalModel(prompt: Self.prompt(items: [8]), confirmation: slow) { _ in }
        model.allow()
        model.toggle(group: model.groups[0])
        XCTAssertEqual(model.tick(of: model.groups[0]), .all)
        model.dismiss()
        slow.finish(false)
    }

    func testTheWindowDrawsManySecretsWithoutGrowingPastTheScreen() {
        let model = AgentApprovalModel(prompt: Self.prompt(items: [12, 10, 9, 8, 7, 6, 5, 4, 3, 2, 2, 2, 2, 2]), confirmation: Confirms(true)) { _ in }
        for group in model.groups { model.toggleOpen(group) }
        let host = NSHostingView(rootView: AgentApprovalView(model: model))
        XCTAssertNotNil(host.bitmapImageRepForCachingDisplay(in: NSRect(x: 0, y: 0, width: 520, height: 700)))
        XCTAssertLessThan(host.fittingSize.height, 700, "74 rows scroll inside the window")
        XCTAssertGreaterThan(host.fittingSize.height, 300)
    }

    func testTheWindowDraws() {
        let model = AgentApprovalModel(prompt: Self.prompt(raw: true, rows: 1), confirmation: Confirms(true)) { _ in }
        let host = NSHostingView(rootView: AgentApprovalView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 460, height: 420)
        XCTAssertNotNil(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        XCTAssertGreaterThan(host.fittingSize.height, 200)
    }

    // MARK: Standing permissions

    /// What the window's lasting choice sees: Premium or not, the Premium window, and the last length.
    private final class LastingProbe {
        var premium: Bool
        var premiumShown = 0
        var last: AgentGrantLength = .days7
        init(premium: Bool) { self.premium = premium }
        @MainActor var options: AgentLastingOptions {
            AgentLastingOptions(
                hasPremium: { self.premium }, showPremium: { self.premiumShown += 1 },
                lastLength: { self.last }, rememberLength: { self.last = $0 }
            )
        }
    }

    private static func lastingPrompt(_ lasting: AgentLastingChoice = .offered, raw: Bool = false) -> AgentApprovalPrompt {
        var prompt = prompt(raw: raw, rows: 1)
        prompt.lasting = lasting
        return prompt
    }

    /// Without Premium the lasting choices say Premium; choosing one opens the Premium window, asks for no Touch ID and
    /// approves nothing. Allow Once still works from the same window.
    func testWithoutPremiumALastingChoiceOpensThePremiumWindowAndApprovesNothing() async {
        let probe = LastingProbe(premium: false)
        let touch = CountingConfirmation()
        var decisions: [AgentApprovalDecision] = []
        let model = AgentApprovalModel(prompt: Self.lastingPrompt(), confirmation: touch, lasting: probe.options) { decisions.append($0) }
        XCTAssertTrue(model.offersLasting)
        XCTAssertEqual(model.lastingTitle, "Allow for 7 days · Premium")
        XCTAssertEqual(AgentGrantLength.allCases.map(model.lengthTitle), [
            "This agent session — Premium", "8 hours — Premium", "7 days — Premium", "30 days — Premium",
        ])
        for length in AgentGrantLength.allCases { model.allow(for: length) }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(probe.premiumShown, 4)
        XCTAssertEqual(touch.asked, 0)
        XCTAssertTrue(decisions.isEmpty, "nothing approved; the window stays")
        model.allow()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(decisions, [.allow([0])])
    }

    /// With Premium: Touch ID, then the lasting decision with the chosen length, which is preselected next time.
    func testWithPremiumALastingChoiceAsksForTouchIDAndIsRemembered() async {
        let probe = LastingProbe(premium: true)
        let touch = CountingConfirmation()
        var decisions: [AgentApprovalDecision] = []
        let model = AgentApprovalModel(prompt: Self.lastingPrompt(), confirmation: touch, lasting: probe.options) { decisions.append($0) }
        XCTAssertEqual(model.lastingTitle, "Allow for 7 days")
        model.allow(for: .days30)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(touch.asked, 1)
        XCTAssertEqual(touch.reasons, ["let Claude Code use 1 secret for 30 days in this project"])
        XCTAssertEqual(decisions, [.allowLasting([0], .days30)])
        XCTAssertEqual(probe.last, .days30)
        let next = AgentApprovalModel(prompt: Self.lastingPrompt(), confirmation: touch, lasting: probe.options) { _ in }
        XCTAssertEqual(next.lastingTitle, "Allow for 30 days")
        let refused = AgentApprovalModel(prompt: Self.lastingPrompt(), confirmation: Confirms(false), lasting: probe.options) { decisions.append($0) }
        refused.allow(for: .hours8)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(decisions.count, 1, "no Touch ID, nothing allowed")
    }

    /// No agent in the chain: only "this agent session", and the length chosen last for agents is left as it was.
    func testWithNoAgentOnlyTheSessionIsOffered() async {
        let probe = LastingProbe(premium: true)
        probe.last = .days30
        var decisions: [AgentApprovalDecision] = []
        let model = AgentApprovalModel(prompt: Self.lastingPrompt(.sessionOnly), confirmation: Confirms(true), lasting: probe.options) { decisions.append($0) }
        XCTAssertEqual(model.lengths, [.session])
        XCTAssertEqual(model.lastingTitle, "Allow for This Agent Session")
        model.allow(for: .days30)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(decisions.isEmpty)
        model.allow(for: .session)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(decisions, [.allowLasting([0], .session)])
        XCTAssertEqual(probe.last, .days30)
    }

    func testNoLastingChoiceForRawReadsOrInlineCode() async {
        let probe = LastingProbe(premium: true)
        let raw = AgentApprovalModel(prompt: Self.lastingPrompt(.notOffered, raw: true), confirmation: Confirms(true), lasting: probe.options) { _ in }
        XCTAssertFalse(raw.offersLasting)
        var decisions: [AgentApprovalDecision] = []
        let inline = AgentApprovalModel(prompt: Self.lastingPrompt(.unavailable("Inline code asks every time.")), confirmation: Confirms(true), lasting: probe.options) {
            decisions.append($0)
        }
        XCTAssertTrue(inline.offersLasting)
        XCTAssertFalse(inline.canAllowLasting)
        XCTAssertEqual(inline.lastingUnavailable, "Inline code asks every time.")
        inline.allow(for: .days7)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(decisions.isEmpty)
        let host = NSHostingView(rootView: AgentApprovalView(model: inline))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 460)
        XCTAssertNotNil(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    }

    // MARK: Answering the window on a Mac nobody sits at (debug builds)

    func testTheDebugScriptReadsItsSteps() {
        XCTAssertEqual(AgentApprovalScript.steps("allow"), [.allow])
        XCTAssertEqual(AgentApprovalScript.steps("deny"), [.deny])
        XCTAssertEqual(AgentApprovalScript.steps(" lasting , allow\n"), [.lasting(nil), .allow])
        XCTAssertEqual(AgentApprovalScript.steps("lasting:7d,lasting:session,hold"), [.lasting(.days7), .lasting(.session), .hold])
        XCTAssertEqual(AgentApprovalScript.steps("yes"), [.deny], "a word it does not know never allows")
        XCTAssertEqual(AgentApprovalScript.steps("lasting:forever"), [.deny])
        XCTAssertEqual(AgentApprovalScript.steps(""), [])
        XCTAssertEqual(AgentApprovalScript.steps("@/tmp/steps") { $0 == "/tmp/steps" ? "lasting:8h\n" : nil }, [.lasting(.hours8)])
        XCTAssertEqual(AgentApprovalScript.steps("@/tmp/missing") { _ in nil }, [.deny], "a file that cannot be read denies")
    }

    /// `lasting,allow` without Premium: the Premium window opens, nothing is approved by it, then Allow Once answers.
    func testTheDebugScriptWalksAFreeUsersPath() async {
        let probe = LastingProbe(premium: false)
        var decisions: [AgentApprovalDecision] = []
        let model = AgentApprovalModel(prompt: Self.lastingPrompt(), confirmation: Confirms(true), lasting: probe.options) { decisions.append($0) }
        await AgentApprovalScript.run([.lasting(nil), .allow, .deny], on: model, every: 0).value
        XCTAssertEqual(probe.premiumShown, 1)
        XCTAssertEqual(decisions, [.allow([0])], "answered once; the steps after the answer do nothing")
    }

    func testTheDebugScriptChoosesALength() async {
        let probe = LastingProbe(premium: true)
        var decisions: [AgentApprovalDecision] = []
        let model = AgentApprovalModel(prompt: Self.lastingPrompt(), confirmation: Confirms(true), lasting: probe.options) { decisions.append($0) }
        await AgentApprovalScript.run([.lasting(.hours8)], on: model, every: 0).value
        XCTAssertEqual(decisions, [.allowLasting([0], .hours8)])
        let held = AgentApprovalModel(prompt: Self.lastingPrompt(), confirmation: Confirms(true), lasting: probe.options) { decisions.append($0) }
        await AgentApprovalScript.run([.hold], on: held, every: 0).value
        XCTAssertFalse(held.answered)
        XCTAssertEqual(held.debugSummary["lasting"] as? String, "Allow for 8 hours")
        XCTAssertEqual(held.debugSummary["allow"] as? String, "Allow Once")
    }

    /// A project with a script, for requests that can have a standing permission.
    private func project() throws -> URL {
        let project = directory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Scripts"), withIntermediateDirectories: true)
        try "#!/bin/sh\necho deploy\n".write(to: project.appendingPathComponent("Scripts/deploy.sh"), atomically: true, encoding: .utf8)
        return project
    }

    private func deploy(_ project: URL) -> AgentRequest {
        var request = AgentRequest(type: .use, id: 1)
        request.secrets = [AgentSecretRequest(name: "T", ref: "pp://Developer/Token", delivery: .env)]
        request.program = project.appendingPathComponent("Scripts/deploy.sh").path
        request.argv = ["Scripts/deploy.sh"]
        request.masking = true
        request.wait = 0
        request.environment = []
        return request
    }

    private func caller(in project: URL) -> AgentCaller {
        var caller = caller
        caller.cwd = project.path
        caller.project = project.path
        return caller
    }

    /// Agent access over the real session, with a window that answers by itself: `choose` runs on each model shown.
    private func grantingAccess(
        _ session: VaultSession, premium: Bool, choose: @escaping (AgentApprovalModel) -> Void
    ) throws -> (AgentAccess, LastingProbe, () -> Int) {
        let suite = "agents-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let probe = LastingProbe(premium: premium)
        var shown = 0
        let approver = AgentApprovalController(confirmation: Confirms(true), lasting: probe.options, show: { model in
            shown += 1
            DispatchQueue.main.async { choose(model) }
            return {}
        })
        let access = AgentAccess(
            session: session, defaults: defaults, socketPath: socketFolder.appendingPathComponent("g.sock").path,
            logURL: directory.appendingPathComponent("activity.jsonl"), approver: approver, hasPremium: { probe.premium },
            mac: "test-mac", linkFolder: directory.appendingPathComponent("bin")
        )
        access.setEnabled(true)
        access.grants.sessionAlive = { _ in true }
        addTeardownBlock { @MainActor in access.stop() }
        return (access, probe, { shown })
    }

    /// The owner's acceptance, in the app: with Premium, "7 days, this project" lets the next identical request through
    /// with no window, says so in Activity, shows in the pane, and lights the menu-bar dot.
    func testSevenDaysThisProjectThroughTheApp() async throws {
        let session = populated()
        session.setFolderSharedWithAgents(["Developer"], true)
        let project = try project()
        let (access, _, shown) = try grantingAccess(session, premium: true) { $0.allow(for: .days7) }
        var dots = 0
        access.onSilentUse = { dots += 1 }
        let first = await access.broker.handle(deploy(project), from: caller(in: project))
        XCTAssertEqual(first.secrets?.first?.value, planted)
        XCTAssertEqual(shown(), 1)
        let second = await access.broker.handle(deploy(project), from: caller(in: project))
        XCTAssertEqual(second.secrets?.first?.value, planted)
        XCTAssertEqual(second.by, "7 days, this project")
        XCTAssertEqual(shown(), 1, "no window the second time")
        XCTAssertEqual(access.activity.first?.outcomeText, "allowed by 7 days, this project")
        XCTAssertEqual(dots, 1)
        XCTAssertEqual(access.standing.count, 1)
        XCTAssertEqual(access.standing.first?.program?.display, "Scripts/deploy.sh")
        // Kept in the database file, with this Mac's identifier.
        let loaded = try KDBX.load(data: Data(contentsOf: session.databaseURL), password: "pw", keyFile: nil)
        XCTAssertEqual(AgentGrants(customData: loaded.customData).all.map(\.mac), ["test-mac"])
        XCTAssertFalse(loaded.customData.values.joined().contains(planted))
        // Revoke All, from the gear menu or the pane: the next request asks.
        access.revokeAll()
        _ = await access.broker.handle(deploy(project), from: caller(in: project))
        XCTAssertEqual(shown(), 2)
    }

    /// The acceptance's other half: a free user's lasting choice never produces a grant.
    func testAFreeUsersLastingChoiceNeverProducesAGrant() async throws {
        let session = populated()
        session.setFolderSharedWithAgents(["Developer"], true)
        let project = try project()
        let (access, probe, shown) = try grantingAccess(session, premium: false) { model in
            model.allow(for: .days30)
            model.allow()
        }
        let first = await access.broker.handle(deploy(project), from: caller(in: project))
        XCTAssertEqual(first.secrets?.first?.value, planted, "Allow Once is free")
        XCTAssertEqual(probe.premiumShown, 1)
        XCTAssertNil(session.agentGrants?.all.first)
        XCTAssertEqual(access.activity.first?.outcome, .allowedOnce)
        _ = await access.broker.handle(deploy(project), from: caller(in: project))
        XCTAssertEqual(shown(), 2, "it asks again")
        // Even a lasting decision that reached the store without Premium makes none.
        let token = try XCTUnwrap(session.agentSharedItems().first)
        let secret = AgentResolvedSecret(item: token, field: .password, delivery: .env, name: "T", ref: "pp://Developer/Token")
        let query = AgentGrantQuery(caller: caller(in: project), kind: .use, raw: false, program: deploy(project).program, argv: ["Scripts/deploy.sh"], secrets: [secret])
        XCTAssertEqual(access.grants.lastingChoice(for: query), .offered)
        XCTAssertNil(access.grants.approved(query, decision: .allowLasting([0], .days7)))
        XCTAssertNil(session.agentGrants?.all.first)
        probe.premium = true
        XCTAssertEqual(access.grants.lastingChoice(for: query), .offered)
        XCTAssertNotNil(access.grants.approved(query, decision: .allowLasting([0], .days7)), "the same call with Premium does make one")
    }

    /// PRD check 9: writing PasswordPie's preferences cannot add a standing permission, and one made on another Mac does
    /// not count here.
    func testForgedPreferencesOrAnotherMacsGrantAddNothing() async throws {
        let session = populated()
        session.setFolderSharedWithAgents(["Developer"], true)
        let project = try project()
        let (access, _, shown) = try grantingAccess(session, premium: true) { $0.deny() }
        let token = try XCTUnwrap(session.agentSharedItems().first)
        func forged(mac: String) -> AgentGrants {
            AgentGrants([AgentGrant(
                mac: mac, created: Date(), length: .days30, session: nil, kind: .use, agent: caller.grantIdentity, agentName: "Claude Code",
                project: project.path, program: nil, secrets: [AgentGrantSecret(item: token.id, field: ["password"], delivery: .env, name: "T")],
                labels: ["Developer/Token › password"]
            )])
        }
        var preferences: [String: String] = [:]
        forged(mac: "test-mac").write(into: &preferences)
        UserDefaults.standard.set(preferences[AgentGrants.customDataKey], forKey: AgentGrants.customDataKey)
        defer { UserDefaults.standard.removeObject(forKey: AgentGrants.customDataKey) }
        _ = await access.broker.handle(deploy(project), from: caller(in: project))
        XCTAssertEqual(shown(), 1, "the forged preference granted nothing")
        // In the database itself, but from another Mac (and bound to the right program, so only the Mac differs).
        guard case .bound(let program) = AgentProgramRule.bind(program: deploy(project).program, argv: ["Scripts/deploy.sh"], cwd: project.path, project: project.path) else {
            return XCTFail("the script binds")
        }
        var other = forged(mac: "another-mac").all[0]
        other.program = program
        session.changeAgentGrants { $0.add(other) }
        XCTAssertEqual(session.agentGrants?.all.count, 1)
        access.refreshStanding()
        XCTAssertEqual(access.standing, [], "another Mac's grant is not listed")
        XCTAssertTrue(access.anyGrants, "but Revoke All still has something to remove")
        _ = await access.broker.handle(deploy(project), from: caller(in: project))
        XCTAssertEqual(shown(), 2, "another Mac's grant does not count here")
        // The same grant with this Mac's identifier does: so only the Mac stopped it.
        var mine = other
        mine.id = UUID()
        mine.mac = "test-mac"
        session.changeAgentGrants { $0.add(mine) }
        let allowed = await access.broker.handle(deploy(project), from: caller(in: project))
        XCTAssertEqual(allowed.by, "30 days, this project")
    }

    /// Unsharing ends the standing permissions that name what is no longer shared; turning access off ends session ones.
    func testUnsharingAndTurningOffEndGrants() async throws {
        let session = populated()
        session.setFolderSharedWithAgents(["Developer"], true)
        let project = try project()
        var length = AgentGrantLength.days7
        let (access, _, _) = try grantingAccess(session, premium: true) { $0.allow(for: length) }
        _ = await access.broker.handle(deploy(project), from: caller(in: project))
        XCTAssertEqual(session.agentGrants?.all.count, 1)
        session.setFolderSharedWithAgents(["Developer"], false)
        XCTAssertEqual(session.agentGrants?.all.count, 0)
        session.setFolderSharedWithAgents(["Developer"], true)
        length = .session
        _ = await access.broker.handle(deploy(project), from: caller(in: project))
        XCTAssertEqual(session.agentGrants?.all.first?.session, caller.sessionKey)
        access.setEnabled(false)
        XCTAssertEqual(session.agentGrants?.all.count, 0)
        XCTAssertEqual(access.standing, [])
    }

    func testStandingPermissionsAreReadOnlyWhileUnlocked() async throws {
        let session = populated()
        session.setFolderSharedWithAgents(["Developer"], true)
        let project = try project()
        let (access, _, _) = try grantingAccess(session, premium: true) { $0.allow(for: .hours8) }
        _ = await access.broker.handle(deploy(project), from: caller(in: project))
        XCTAssertEqual(access.standing.count, 1)
        XCTAssertTrue(AgentAccess.endText(access.standing[0]).hasPrefix("until "))
        session.lock()
        access.vaultStateChanged(locked: true)
        XCTAssertNil(session.agentGrants)
        XCTAssertEqual(access.standing, [])
    }

    func testTheMenuBarDotChangesTheIcon() throws {
        func pixels(_ image: NSImage) throws -> Data {
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        }
        XCTAssertNotEqual(try pixels(MenuBarIcon.image()), try pixels(MenuBarIcon.image(dot: true)))
        XCTAssertTrue(MenuBarIcon.image(dot: true).isTemplate, "neutral: tinted by macOS like the pie, never orange")
        XCTAssertEqual(MenuBarIcon.silentUseSeconds, 5)
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
private final class CountingConfirmation: OwnerConfirmation {
    var asked = 0
    var reasons: [String] = []
    func confirm(reason: String) async -> Bool {
        asked += 1
        reasons.append(reason)
        return true
    }
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
