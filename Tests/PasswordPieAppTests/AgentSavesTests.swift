#if PP_DIRECT
import AppKit
@testable import PasswordPieAgent
@testable import PasswordPieCore
import XCTest
@testable import PasswordPie

/// Saves agents proposed, with the real session, store and a database file on disk (docs/AGENTS.md, "Saving a secret";
/// docs/UX.md, "Agents save a new secret"). Every value an agent hands over starts with "PLANTED-".
@MainActor
final class AgentSavesTests: XCTestCase {
    private var directory: URL!
    private var socketFolder: URL!
    private var database: URL { directory.appendingPathComponent("agents.kdbx") }
    private let value = "PLANTED-sk_live_new_51f0"
    private let caller = AgentCaller(
        cli: AgentProcess(pid: 200, startTime: 2, path: "/x/passwordpie", name: "passwordpie"),
        chain: [], agent: AgentProcess(pid: 100, startTime: 1, path: "/usr/local/bin/claude", name: "Claude Code"),
        sessionKey: "agent:100:1", cwd: "/tmp/shop", project: "/tmp/shop"
    )

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-saves-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketFolder = URL(fileURLWithPath: "/tmp").appendingPathComponent("pps-\(getpid())-\(Int.random(in: 0..<1_000_000))")
        try FileManager.default.createDirectory(at: socketFolder, withIntermediateDirectories: true)
        setenv("PASSWORDPIE_DB", database.path, 1)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
        UserDefaults.standard.set(true, forKey: "touchIDDeclined.\(database.path)")
    }

    override func tearDownWithError() throws {
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        for key in ["touchIDDeclined", "touchIDEnabled", "touchIDUnlockedAt", "touchIDStale"] {
            UserDefaults.standard.removeObject(forKey: "\(key).\(database.path)")
        }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: socketFolder)
    }

    private func unlocked() -> VaultSession {
        let session = VaultSession(writes: .inline)
        session.restore()
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        return session
    }

    /// A database with Agents/Stripe (a username, a URL, the field API key) and Personal/Bank, Agents shared.
    private func populated() -> VaultSession {
        let session = unlocked()
        var stripe = VaultEntry(groupPath: ["Agents"])
        stripe.title = "Stripe"
        stripe.username = "shop@example.com"
        stripe.url = "https://dashboard.stripe.com"
        stripe.setValue("PLANTED-old-key", for: "API key", protected: true)
        session.saveEditing(stripe)
        var bank = VaultEntry(groupPath: ["Personal"])
        bank.title = "Bank"
        bank.password = "bank-pw"
        session.saveEditing(bank)
        session.setFolderSharedWithAgents(["Agents"], true)
        return session
    }

    /// The file as it is on disk now.
    private func onDisk() throws -> Vault {
        try KDBX.load(data: try Data(contentsOf: database), password: "pw", keyFile: nil)
    }

    private func broker(_ session: VaultSession, answer: AgentApprovalDecision) -> (VaultBroker, AgentSaves) {
        let broker = VaultBroker(vault: session, approver: Answers(answer), grants: NoAgentGrants(), activity: Lines()) { true }
        let saves = AgentSaves(session: session)
        broker.saves = saves
        broker.mac = "this-mac"
        return (broker, saves)
    }

    private func save(_ ref: String, _ bytes: Data, with broker: VaultBroker) async -> AgentResponse {
        var request = AgentRequest(type: .save, id: 1)
        request.secrets = [AgentSecretRequest(name: nil, ref: ref, delivery: .save)]
        request.setSaved(bytes)
        request.wait = 0
        return await broker.handle(request, from: caller)
    }

    // MARK: Saving in the window

    func testANewItemIsWrittenSharedAndTheProposalKeepsNoValue() async throws {
        let session = populated()
        let (broker, _) = broker(session, answer: .allow([0]))
        let answer = await save("pp://Agents/Cloudflare/API token", Data(value.utf8), with: broker)
        XCTAssertEqual(answer.save?.outcome, .saved, answer.detail ?? "")
        let file = try onDisk()
        let made = try XCTUnwrap(file.entries.first { $0.title == "Cloudflare" })
        XCTAssertEqual(made.groupPath, ["Agents"])
        XCTAssertEqual(made.value(for: "API token"), value)
        XCTAssertEqual(made.fields.first { $0.key == "API token" }?.protected, true, "a saved field is protected")
        XCTAssertTrue(AgentSharing(customData: file.customData).covers(made))
        XCTAssertEqual(AgentSharing(customData: file.customData).items, [], "its folder shares it: no share of its own")
        XCTAssertEqual(answer.save?.ref, AgentReference.id(made.id, field: .custom("API token")))
        let kept = AgentProposals(customData: file.customData).all
        XCTAssertEqual(kept.map(\.state), [.saved])
        XCTAssertEqual(kept.first?.savedItem, made.id)
        XCTAssertFalse(file.customData.values.joined().contains(value), "the saved proposal holds no value")
    }

    func testANewItemOutsideASharedFolderIsSharedOnItsOwn() async throws {
        let session = populated()
        let (broker, _) = broker(session, answer: .allow([0]))
        let answer = await save("pp://Tools/Deploy/token", Data(value.utf8), with: broker)
        XCTAssertEqual(answer.save?.outcome, .saved)
        let file = try onDisk()
        let made = try XCTUnwrap(file.entries.first { $0.title == "Deploy" })
        XCTAssertEqual(made.groupPath, ["Tools"], "the folder is made")
        XCTAssertEqual(AgentSharing(customData: file.customData).items, [made.id])
        XCTAssertNotNil(session.agentSharedItems().first { $0.id == made.id }, "the agent can ask for it, with the usual approval")
    }

    /// A change keeps the value before in the item's history, and leaves everything else of the item as it was.
    func testAChangeKeepsTheOldValueInTheHistory() async throws {
        let session = populated()
        let before = try XCTUnwrap(try onDisk().entries.first { $0.title == "Stripe" })
        let (broker, _) = broker(session, answer: .allow([0]))
        let answer = await save("pp://Agents/Stripe/API key", Data(value.utf8), with: broker)
        XCTAssertEqual(answer.save?.change, .changed)
        let file = try onDisk()
        let stripe = try XCTUnwrap(file.entries.first { $0.id == before.id })
        XCTAssertEqual(stripe.value(for: "API key"), value)
        XCTAssertEqual(stripe.title, "Stripe")
        XCTAssertEqual(stripe.username, "shop@example.com")
        XCTAssertEqual(stripe.url, "https://dashboard.stripe.com")
        XCTAssertEqual(stripe.groupPath, ["Agents"])
        let versions = file.versions(of: stripe.id)
        XCTAssertEqual(versions.last?.fields.first { $0.key == "API key" }?.value, "PLANTED-old-key", "the old value is in the history")
        XCTAssertEqual(file.entries.count, 2, "nothing made, nothing removed")
    }

    func testAChangedPasswordIsAlsoAPreviousPassword() async throws {
        let session = populated()
        session.setSharedWithAgents(try XCTUnwrap(session.entries.first { $0.title == "Bank" }).id, true)
        let (broker, _) = broker(session, answer: .allow([0]))
        let answer = await save("pp://Personal/Bank", Data("PLANTED-bank-new".utf8), with: broker)
        XCTAssertEqual(answer.save?.change, .changed)
        let bank = try XCTUnwrap(try onDisk().entries.first { $0.title == "Bank" })
        XCTAssertEqual(bank.password, "PLANTED-bank-new")
        XCTAssertEqual(PreviousPasswords.items(of: bank, now: Date()).map(\.value), ["bank-pw"], "listed among the previous passwords")
    }

    func testAnAttachedFileIsSavedAsItsBytes() async throws {
        let session = populated()
        let (broker, _) = broker(session, answer: .allow([0]))
        let key = Data([0x30, 0x82, 0x01, 0xFF, 0x00, 0x0A])
        let answer = await save("pp://Agents/Stripe/attachment/key.der", key, with: broker)
        XCTAssertEqual(answer.save?.change, .newField)
        let file = try onDisk()
        let stripe = try XCTUnwrap(file.entries.first { $0.title == "Stripe" })
        XCTAssertEqual(file.attachment(named: "key.der", of: stripe.id), key)
        XCTAssertEqual(stripe.value(for: "API key"), "PLANTED-old-key", "the fields stay")
    }

    // MARK: Waiting, and the list

    /// Decide Later keeps the proposal in the file: it is there after a restart, and saving it from the list writes the
    /// item and drops the value.
    func testAWaitingProposalOutlivesARestartAndIsSavedFromTheList() async throws {
        let session = populated()
        let (broker, _) = broker(session, answer: .dismissed)
        let answer = await save("pp://Agents/Night/token", Data(value.utf8), with: broker)
        XCTAssertEqual(answer.save?.outcome, .pending)
        let id = try XCTUnwrap(answer.save?.proposal)
        XCTAssertTrue(try onDisk().customData[AgentProposals.customDataKey]?.contains(id) ?? false, "kept in the file")
        XCTAssertNil(try onDisk().entries.first { $0.title == "Night" }, "not an item yet")
        session.lock()

        let restarted = VaultSession(writes: .inline)
        restarted.restore()
        restarted.passwordDraft = "pw"
        restarted.unlock()
        for _ in 0..<500 where restarted.agentVaultLocked { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(restarted.agentVaultLocked)
        let suite = "agent-saves-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let access = AgentAccess(
            session: restarted, defaults: defaults, socketPath: socketFolder.appendingPathComponent("a.sock").path,
            logURL: directory.appendingPathComponent("activity.jsonl"), approver: AgentApprovalController(show: { _ in {} }),
            confirmation: Confirmation(true), mac: "this-mac", linkFolder: directory.appendingPathComponent("bin")
        )
        access.setEnabled(true)
        defer { access.stop() }
        access.refreshSaves()
        XCTAssertEqual(access.waitingSaves.map(\.id), [id])
        guard !access.waitingSaves.isEmpty else { return }
        XCTAssertEqual(access.macText(access.waitingSaves[0]), "on this Mac")
        XCTAssertEqual(restarted.agentSavePreview(access.waitingSaves[0]), .success(.newItem))
        await access.saveProposal(access.waitingSaves[0])
        XCTAssertTrue(access.waitingSaves.isEmpty)
        let file = try onDisk()
        XCTAssertEqual(file.entries.first { $0.title == "Night" }?.value(for: "token"), value)
        XCTAssertFalse(file.customData.values.joined().contains(value))
        let line = try XCTUnwrap(access.activity.first)
        XCTAssertEqual(line.outcome, .savedFromList)
        XCTAssertEqual(line.agent, "Claude Code")
        let log = try String(contentsOf: directory.appendingPathComponent("activity.jsonl"), encoding: .utf8)
        XCTAssertFalse(log.contains("PLANTED"), "no value in Activity")
    }

    func testSavingFromTheListNeedsTheOwnersConfirmation() async throws {
        let session = populated()
        let (broker, _) = broker(session, answer: .dismissed)
        _ = await save("pp://Agents/Night/token", Data(value.utf8), with: broker)
        let suite = "agent-saves-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let access = AgentAccess(
            session: session, defaults: defaults, socketPath: socketFolder.appendingPathComponent("b.sock").path,
            logURL: directory.appendingPathComponent("activity.jsonl"), approver: AgentApprovalController(show: { _ in {} }),
            confirmation: Confirmation(false), mac: "this-mac", linkFolder: directory.appendingPathComponent("bin")
        )
        access.setEnabled(true)
        defer { access.stop() }
        access.refreshSaves()
        await access.saveProposal(try XCTUnwrap(access.waitingSaves.first))
        XCTAssertEqual(access.waitingSaves.count, 1, "not confirmed: still waiting")
        XCTAssertNil(try onDisk().entries.first { $0.title == "Night" })
        await access.rejectProposal(access.waitingSaves[0])
        XCTAssertTrue(access.waitingSaves.isEmpty)
        XCTAssertEqual(AgentProposals(customData: try onDisk().customData).all.map(\.state), [.rejected])
        XCTAssertFalse(try onDisk().customData.values.joined().contains(value))
    }

    /// An item unshared while its change waited is not written; the list says why.
    func testAChangeToAnItemNoLongerSharedIsNotWritten() async throws {
        let session = populated()
        let (broker, saves) = broker(session, answer: .dismissed)
        let answer = await save("pp://Agents/Stripe/API key", Data(value.utf8), with: broker)
        let id = try XCTUnwrap(answer.save?.proposal)
        session.setFolderSharedWithAgents(["Agents"], false)
        let proposal = try XCTUnwrap(saves.proposals?.first)
        guard case .failure? = session.agentSavePreview(proposal) else { return XCTFail("the list should say it cannot be saved") }
        let result = await broker.saveProposal(id)
        guard case .failed = result else { return XCTFail("\(result)") }
        XCTAssertEqual(try onDisk().entries.first { $0.title == "Stripe" }?.value(for: "API key"), "PLANTED-old-key")
        XCTAssertEqual(saves.proposals?.first?.state, .pending, "it still waits, for Reject")
    }

    /// An item renamed and moved while its change waited: the list shows where the save writes now, and that is where it goes.
    func testAChangeToAnItemMovedWhileItWaitedShowsTheNewPlace() async throws {
        let session = populated()
        let (broker, saves) = broker(session, answer: .dismissed)
        let answer = await save("pp://Agents/Stripe/API key", Data(value.utf8), with: broker)
        let id = try XCTUnwrap(answer.save?.proposal)
        var stripe = try XCTUnwrap(session.entries.first { $0.title == "Stripe" })
        stripe.title = "Stripe (test mode)"
        stripe.groupPath = ["Agents", "Archive"]
        session.saveEditing(stripe)
        let proposal = try XCTUnwrap(saves.proposals?.first)
        let shown = session.agentSavePlaced(proposal)
        XCTAssertEqual(shown.title, "Stripe (test mode)")
        XCTAssertEqual(shown.folder, ["Agents", "Archive"])
        guard case .saved(let item, _) = await broker.saveProposal(id) else { return XCTFail("not saved") }
        let written = try XCTUnwrap(try onDisk().entries.first { $0.id == item })
        XCTAssertEqual(written.title, shown.title)
        XCTAssertEqual(written.groupPath, shown.folder)
        XCTAssertEqual(written.value(for: "API key"), value)
    }

    /// Two waiting proposals for one new place: the second one saved changes the item the first made.
    func testTheSecondProposalForANewPlaceChangesTheItemTheFirstMade() async throws {
        let session = populated()
        let (broker, _) = broker(session, answer: .dismissed)
        let first = await save("pp://Agents/Twice/token", Data("PLANTED-one".utf8), with: broker)
        let second = await save("pp://Agents/Twice/token", Data("PLANTED-two".utf8), with: broker)
        guard case .saved(_, .newItem) = await broker.saveProposal(try XCTUnwrap(first.save?.proposal)) else { return XCTFail("first") }
        guard case .saved(_, .changed) = await broker.saveProposal(try XCTUnwrap(second.save?.proposal)) else { return XCTFail("second") }
        let file = try onDisk()
        let items = file.entries.filter { $0.title == "Twice" }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.value(for: "token"), "PLANTED-two")
    }

    // MARK: The window

    /// The store counts in the write itself, which sees every proposal kept before it: requests that all passed the
    /// broker's count while a write was under way still leave at most twenty waiting.
    func testTheStoreKeepsAtMostTwentyWaiting() async throws {
        let session = populated()
        let (_, saves) = broker(session, answer: .dismissed)
        for index in 0..<AgentProposals.maxPending {
            let kept = await saves.propose(AgentProposal(
                id: String(format: "%08x", index), created: Date(), mac: "this-mac", agent: "a", agentName: "a", signature: "s", project: "/p",
                reason: nil, via: nil, item: nil, folder: ["Agents"], title: "P\(index)", field: .password, change: .newItem, value: Data(value.utf8)
            ))
            XCTAssertEqual(kept, .kept)
        }
        let over = await saves.propose(AgentProposal(
            id: "ffffffff", created: Date(), mac: "this-mac", agent: "a", agentName: "a", signature: "s", project: "/p",
            reason: nil, via: nil, item: nil, folder: ["Agents"], title: "Over", field: .password, change: .newItem, value: Data(value.utf8)
        ))
        XCTAssertEqual(over, .full)
        XCTAssertEqual(AgentProposals(customData: try onDisk().customData).pending(now: Date()).count, AgentProposals.maxPending)
    }

    private func savePrompt() -> AgentApprovalPrompt {
        AgentApprovalPrompt(
            id: UUID(), kind: .save, raw: false, agent: "Claude Code", signature: "signed by Anthropic PBC", agentPID: 100, startedIn: "Terminal",
            command: nil, program: nil, project: "/tmp/shop", reason: "Webhook key",
            rows: [AgentApprovalRow(title: "Stripe", folder: "Agents", field: "field API key", delivery: .save, name: nil, tooShortToMask: false,
                                    note: "a new item", item: nil)],
            lasting: .notOffered
        )
    }

    func testTheSaveWindowSaysSaveRejectAndDecideLaterAndOffersNoStandingPermission() async throws {
        var decided: [AgentApprovalDecision] = []
        let model = AgentApprovalModel(prompt: savePrompt(), confirmation: Confirmation(true)) { decided.append($0) }
        XCTAssertEqual(model.title, "Claude Code wants to save a secret")
        XCTAssertEqual(model.allowTitle, "Save")
        XCTAssertEqual(model.denyTitle, "Reject")
        XCTAssertFalse(model.offersLasting)
        XCTAssertEqual(model.rowLine(model.prompt.rows[0]), "field API key")
        model.later()
        XCTAssertEqual(decided, [.dismissed], "Decide Later leaves it waiting")

        let saving = AgentApprovalModel(prompt: savePrompt(), confirmation: Confirmation(true)) { decided.append($0) }
        saving.allow()
        for _ in 0..<100 where !saving.answered { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(decided.last, .allow([0]))
        let refused = AgentApprovalModel(prompt: savePrompt(), confirmation: Confirmation(false)) { decided.append($0) }
        refused.allow()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(refused.answered, "nothing is saved without Touch ID")
    }

    // MARK: A file KeePassXC made

    /// A save into a database KeePassXC wrote keeps everything else in it: other items, their attachments and history.
    func testASaveIntoAKeePassXCFileKeepsEverythingElse() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PasswordPieCoreTests/Fixtures")
        let keyFile = try Data(contentsOf: fixtures.appendingPathComponent("KeyFiles/any.key"))
        let data = try Data(contentsOf: fixtures.appendingPathComponent("Merge/mac-b.kdbx"))
        var vault = try KDBX.load(data: data, password: "pie-test", keyFile: keyFile)
        vault.noteFileContents(data)
        func lines(_ vault: Vault) -> [String: String] {
            var lines: [String: String] = [:]
            for entry in vault.entries where !entry.trashed {
                let attachments = vault.attachmentNames(of: entry.id).sorted().map { "\($0)=\(vault.attachment(named: $0, of: entry.id)?.count ?? -1)" }
                lines[entry.title] = "\(entry.groupPath) \(entry.fields.map { "\($0.key)=\($0.value)" }.sorted()) \(attachments) \(vault.versions(of: entry.id).count)"
            }
            return lines
        }
        let before = lines(vault)
        let history = vault.versions(of: try XCTUnwrap(vault.entries.first { $0.title == "Deploy" }).id).count
        let deploy = try XCTUnwrap(vault.entries.first { $0.title == "Deploy" })
        var sharing = AgentSharing()
        sharing.set(item: deploy.id, shared: true)
        sharing.write(into: &vault.customData)
        let proposal = AgentProposal(
            id: "AB12CD34", created: Date(), mac: "m", agent: "a", agentName: "Claude Code", signature: "s", project: "/p", reason: nil,
            via: nil, item: deploy.id, folder: deploy.groupPath, title: "Deploy", field: .custom("API key"), change: .newField,
            value: Data(value.utf8)
        )
        AgentProposals([proposal]).write(into: &vault.customData)
        guard case .saved = AgentSaveApply.apply("AB12CD34", to: &vault, now: Date()) else { return XCTFail("not saved") }
        let reopened = try KDBX.load(data: try KDBX.save(vault: &vault, password: "pie-test", keyFile: keyFile), password: "pie-test", keyFile: keyFile)
        var after = lines(reopened)
        let changed = try XCTUnwrap(reopened.entries.first { $0.id == deploy.id })
        XCTAssertEqual(changed.value(for: "API key"), value)
        XCTAssertEqual(reopened.versions(of: deploy.id).count, history + 1, "the version before is in the history")
        XCTAssertEqual(reopened.attachment(named: "deploy.pem", of: deploy.id), Data("second key, changed on B\n".utf8))
        after["Deploy"] = nil
        var others = before
        others["Deploy"] = nil
        XCTAssertEqual(after, others, "every other item as KeePassXC wrote it")
    }
}

@MainActor
private final class Answers: AgentApprover {
    let decision: AgentApprovalDecision
    init(_ decision: AgentApprovalDecision) { self.decision = decision }
    func present(_ prompt: AgentApprovalPrompt) async -> AgentApprovalDecision { decision }
    func withdraw(_ id: UUID) {}
}

private final class Lines: AgentActivityLogging, @unchecked Sendable {
    func append(_ record: AgentActivityRecord) {}
}

@MainActor
private final class Confirmation: OwnerConfirmation {
    let answer: Bool
    init(_ answer: Bool) { self.answer = answer }
    func confirm(reason: String) async -> Bool { answer }
    func cancel() {}
}
#endif
